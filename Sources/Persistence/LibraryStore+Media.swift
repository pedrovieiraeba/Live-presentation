import CompositionCore
import Foundation
import MediaLibrary

// MARK: Mídia

extension LibraryStore: MediaAssetRepository {
    public func allMediaAssets() throws -> [MediaAsset] {
        let stmt = try db.prepare("SELECT id, document FROM media_assets ORDER BY name COLLATE NOCASE, path")
        var result: [MediaAsset] = []
        while try stmt.step() {
            guard let json = stmt.text(at: 1) else { continue }
            do {
                result.append(try decoder.decode(MediaAsset.self, from: Data(json.utf8)))
            } catch {
                log.error("Mídia ilegível \(stmt.text(at: 0) ?? "?"): \(error)", code: "E-PERSIST-MEDIA-DECODE")
            }
        }
        return result
    }

    public func saveMediaAssets(_ assets: [MediaAsset]) throws {
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO media_assets (id, name, path, kind, imported_at, document) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, path = excluded.path, kind = excluded.kind, document = excluded.document
                """)
            for asset in assets {
                let json = String(decoding: try encoder.encode(asset), as: UTF8.self)
                try stmt.bind(.text(asset.id.uuidString), .text(asset.name), .text(asset.path),
                              .text(asset.kind.rawValue), .double(asset.importedAt.timeIntervalSince1970),
                              .text(json)).run()
            }
        }
    }

    public func deleteMediaAsset(id: UUID) throws {
        try db.prepare("DELETE FROM media_assets WHERE id = ?").bind(.text(id.uuidString)).run()
    }
}

// MARK: Cenas

extension LibraryStore {
    /// Cenas na ordem salva; nunca vazio (a cena padrão é criada se preciso).
    public func scenes() throws -> [CompositionScene] {
        let stmt = try db.prepare("SELECT id, document FROM scenes ORDER BY position")
        var result: [CompositionScene] = []
        while try stmt.step() {
            guard let json = stmt.text(at: 1) else { continue }
            do {
                result.append(try decoder.decode(CompositionScene.self, from: Data(json.utf8)))
            } catch {
                log.error("Cena ilegível \(stmt.text(at: 0) ?? "?"): \(error)", code: "E-PERSIST-SCENE-DECODE")
            }
        }
        return result.isEmpty ? [.standard] : result
    }

    /// Grava o conjunto completo de cenas (ordem incluída) numa transação.
    public func saveScenes(_ scenes: [CompositionScene]) throws {
        try db.transaction {
            try db.execute("DELETE FROM scenes")
            let stmt = try db.prepare("INSERT INTO scenes (id, name, position, document) VALUES (?, ?, ?, ?)")
            for (index, scene) in scenes.enumerated() {
                let json = String(decoding: try encoder.encode(scene), as: UTF8.self)
                try stmt.bind(.text(scene.id.uuidString), .text(scene.name), .int(index), .text(json)).run()
            }
        }
    }
}
