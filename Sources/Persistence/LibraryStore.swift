import CompositionCore
import Diagnostics
import Foundation
import MediaLibrary
import PresentationCore

public enum PersistenceError: Error, Equatable, CustomStringConvertible {
    case databaseFromNewerVersion(found: Int, supported: Int)
    case notFound(UUID)
    case corruptDocument(UUID)

    public var description: String {
        switch self {
        case let .databaseFromNewerVersion(found, supported):
            return "A biblioteca foi criada por uma versão mais nova do app (esquema \(found); suportado até \(supported))."
        case let .notFound(id):
            return "Item \(id) não encontrado na biblioteca."
        case let .corruptDocument(id):
            return "O documento \(id) está corrompido e não pôde ser lido."
        }
    }
}

public struct Playlist: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var presentationIDs: [UUID]

    public init(id: UUID = UUID(), name: String, presentationIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.presentationIDs = presentationIDs
    }
}

/// Persistência local da biblioteca (SQLite). Um actor serializa o acesso ao
/// banco, fora da main thread.
///
/// Documentos (apresentação, tema) são armazenados como JSON versionado numa
/// coluna; metadados consultáveis ficam em colunas próprias. Ver
/// docs/decisions/0002-persistencia-sqlite.md.
public actor LibraryStore {
    let db: SQLiteDatabase
    let log = AppLogger(category: "persistence")
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Abre (ou cria) a biblioteca no caminho dado. Use `":memory:"` em testes.
    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Migrations.migrate(db)
        log.info("Biblioteca aberta (esquema v\(Migrations.latestVersion))")
    }

    /// Local padrão: ~/Library/Application Support/LivePresentation/library.sqlite
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LivePresentation", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite")
    }

    // MARK: Apresentações

    public func save(_ presentation: Presentation) throws {
        let json = String(decoding: try encoder.encode(presentation), as: UTF8.self)
        try db.prepare("""
            INSERT INTO presentations (id, name, created_at, updated_at, slide_count, document_version, document)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at,
                slide_count = excluded.slide_count,
                document_version = excluded.document_version,
                document = excluded.document
            """)
            .bind(.text(presentation.id.uuidString), .text(presentation.name),
                  .double(presentation.createdAt.timeIntervalSince1970),
                  .double(presentation.updatedAt.timeIntervalSince1970),
                  .int(presentation.slideCount), .int(Presentation.documentVersion), .text(json))
            .run()
    }

    public func presentation(id: UUID) throws -> Presentation {
        let stmt = try db.prepare("SELECT document FROM presentations WHERE id = ?")
            .bind(.text(id.uuidString))
        guard try stmt.step(), let json = stmt.text(at: 0) else { throw PersistenceError.notFound(id) }
        do {
            return try decoder.decode(Presentation.self, from: Data(json.utf8))
        } catch {
            log.error("Documento ilegível: \(id) — \(error)", code: "E-PERSIST-DECODE")
            throw PersistenceError.corruptDocument(id)
        }
    }

    public func summaries() throws -> [PresentationSummary] {
        let stmt = try db.prepare("""
            SELECT id, name, created_at, updated_at, slide_count
            FROM presentations ORDER BY updated_at DESC, name COLLATE NOCASE
            """)
        var result: [PresentationSummary] = []
        while try stmt.step() {
            guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { continue }
            result.append(PresentationSummary(
                id: id, name: stmt.text(at: 1) ?? "",
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 2)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 3)),
                slideCount: stmt.int(at: 4)))
        }
        return result
    }

    public func deletePresentation(id: UUID) throws {
        try db.prepare("DELETE FROM presentations WHERE id = ?").bind(.text(id.uuidString)).run()
    }

    @discardableResult
    public func duplicatePresentation(id: UUID) throws -> Presentation {
        let copy = try presentation(id: id).duplicated()
        try save(copy)
        return copy
    }

    // MARK: Temas

    /// Temas de fábrica + temas do usuário. Temas de fábrica podem ser
    /// sobrescritos (mesmo ID) e voltam ao padrão se o registro for apagado.
    public func themes() throws -> [Theme] {
        let stmt = try db.prepare("SELECT document FROM themes ORDER BY name COLLATE NOCASE")
        var stored: [UUID: Theme] = [:]
        var order: [UUID] = []
        while try stmt.step() {
            guard let json = stmt.text(at: 0),
                  let theme = try? decoder.decode(Theme.self, from: Data(json.utf8)) else { continue }
            stored[theme.id] = theme
            order.append(theme.id)
        }
        let builtIn = Theme.builtIn.map { stored[$0.id] ?? $0 }
        let custom = order.filter { id in !Theme.builtIn.contains { $0.id == id } }.compactMap { stored[$0] }
        return builtIn + custom
    }

    public func save(_ theme: Theme) throws {
        let json = String(decoding: try encoder.encode(theme), as: UTF8.self)
        try db.prepare("""
            INSERT INTO themes (id, name, document) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, document = excluded.document
            """)
            .bind(.text(theme.id.uuidString), .text(theme.name), .text(json))
            .run()
    }

    public func deleteTheme(id: UUID) throws {
        try db.prepare("DELETE FROM themes WHERE id = ?").bind(.text(id.uuidString)).run()
    }

    // MARK: Playlists

    public func save(_ playlist: Playlist, position: Int? = nil) throws {
        try db.transaction {
            let pos: Int
            if let position {
                pos = position
            } else {
                let existing = try db.prepare("SELECT position FROM playlists WHERE id = ?")
                    .bind(.text(playlist.id.uuidString))
                if try existing.step() {
                    pos = existing.int(at: 0)
                } else {
                    let max = try db.prepare("SELECT COALESCE(MAX(position), -1) FROM playlists")
                    _ = try max.step()
                    pos = max.int(at: 0) + 1
                }
            }
            try db.prepare("""
                INSERT INTO playlists (id, name, position) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, position = excluded.position
                """)
                .bind(.text(playlist.id.uuidString), .text(playlist.name), .int(pos))
                .run()
            try db.prepare("DELETE FROM playlist_entries WHERE playlist_id = ?")
                .bind(.text(playlist.id.uuidString)).run()
            let insert = try db.prepare(
                "INSERT INTO playlist_entries (playlist_id, position, presentation_id) VALUES (?, ?, ?)")
            for (index, presentationID) in playlist.presentationIDs.enumerated() {
                try insert.bind(.text(playlist.id.uuidString), .int(index), .text(presentationID.uuidString)).run()
            }
        }
    }

    public func playlists() throws -> [Playlist] {
        var result: [Playlist] = []
        let stmt = try db.prepare("SELECT id, name FROM playlists ORDER BY position")
        while try stmt.step() {
            guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { continue }
            result.append(Playlist(id: id, name: stmt.text(at: 1) ?? ""))
        }
        let entries = try db.prepare(
            "SELECT presentation_id FROM playlist_entries WHERE playlist_id = ? ORDER BY position")
        for i in result.indices {
            try entries.bind(.text(result[i].id.uuidString))
            while try entries.step() {
                if let text = entries.text(at: 0), let id = UUID(uuidString: text) {
                    result[i].presentationIDs.append(id)
                }
            }
        }
        return result
    }

    public func deletePlaylist(id: UUID) throws {
        try db.prepare("DELETE FROM playlists WHERE id = ?").bind(.text(id.uuidString)).run()
    }

    // MARK: Estado da sessão (recuperação)

    public func saveSession(_ session: SessionSnapshot) throws {
        let json = String(decoding: try encoder.encode(session), as: UTF8.self)
        try db.prepare("""
            INSERT INTO session_state (key, value) VALUES ('session', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
            .bind(.text(json))
            .run()
    }

    /// Retorna `nil` se não houver sessão salva ou se ela estiver ilegível —
    /// uma sessão corrompida nunca deve impedir o app de abrir.
    public func loadSession() -> SessionSnapshot? {
        do {
            let stmt = try db.prepare("SELECT value FROM session_state WHERE key = 'session'")
            guard try stmt.step(), let json = stmt.text(at: 0) else { return nil }
            return try decoder.decode(SessionSnapshot.self, from: Data(json.utf8))
        } catch {
            log.warning("Sessão salva ignorada: \(error)", code: "W-SESSION-DECODE")
            return nil
        }
    }
}

/// O que é persistido para retomar o trabalho após um encerramento inesperado.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var activePresentationID: UUID?
    public var showState: ShowState?
    public var outputScreenName: String?
    /// Cena no ar na última sessão. Diferente do slide, a cena é restaurada:
    /// ela define o fundo/layout, não conteúdo de texto inesperado.
    public var programSceneID: UUID?
    public var compositionProfileID: String?
    /// Preferência de saída NDI (o envio só recomeça se o SDK estiver presente).
    public var ndiOutputEnabled: Bool?
    public var ndiOutputName: String?
    public var savedAt: Date

    public init(activePresentationID: UUID?, showState: ShowState?, outputScreenName: String? = nil,
                programSceneID: UUID? = nil, compositionProfileID: String? = nil,
                ndiOutputEnabled: Bool? = nil, ndiOutputName: String? = nil, savedAt: Date = Date()) {
        self.activePresentationID = activePresentationID
        self.showState = showState
        self.outputScreenName = outputScreenName
        self.programSceneID = programSceneID
        self.compositionProfileID = compositionProfileID
        self.ndiOutputEnabled = ndiOutputEnabled
        self.ndiOutputName = ndiOutputName
        self.savedAt = savedAt
    }
}
