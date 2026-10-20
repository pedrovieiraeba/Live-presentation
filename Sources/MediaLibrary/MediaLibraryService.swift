import Diagnostics
import Foundation

/// Metadados lidos de um arquivo de mídia por decodificação real.
public struct MediaProbeResult: Equatable, Sendable {
    public var duration: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var codec: String?

    public init(duration: Double? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, codec: String? = nil) {
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
    }
}

public enum MediaProbeError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notPlayable
    case noVideoTrack

    public var description: String {
        switch self {
        case .unreadable(let reason): return "Arquivo ilegível: \(reason)"
        case .notPlayable: return "Formato não reproduzível neste Mac"
        case .noVideoTrack: return "O arquivo não contém trilha de vídeo"
        }
    }
}

public protocol MediaProbing: Sendable {
    func probe(_ url: URL, kind: MediaKind) async throws -> MediaProbeResult
}

/// Cria e resolve bookmarks do sistema (no macOS, acompanham arquivos movidos).
public protocol BookmarkResolving: Sendable {
    func makeBookmark(for url: URL) -> Data?
    /// Retorna a URL atual do arquivo e, se o bookmark estiver desatualizado, um novo.
    func resolve(_ bookmark: Data) -> (url: URL, refreshed: Data?)?
}

public protocol MediaAssetRepository: Sendable {
    func allMediaAssets() async throws -> [MediaAsset]
    func saveMediaAssets(_ assets: [MediaAsset]) async throws
    func deleteMediaAsset(id: UUID) async throws
}

public struct ImportProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

public struct ImportReport: Equatable, Sendable {
    public var added: [MediaAsset] = []
    public var skippedDuplicates = 0
    public var failures: [Failure] = []
    public var cancelled = false

    public struct Failure: Error, Equatable, Sendable {
        public var url: URL
        public var reason: String
    }
}

/// Importação, verificação de disponibilidade e relink. Toda leitura de arquivo
/// roda fora da main thread, com concorrência limitada e cancelável.
public actor MediaLibraryService {
    private let repository: MediaAssetRepository
    private let prober: MediaProbing
    private let bookmarks: BookmarkResolving?
    private let limiter: AsyncLimiter
    private let log = AppLogger(category: "media")

    public init(repository: MediaAssetRepository, prober: MediaProbing,
                bookmarks: BookmarkResolving? = nil, maxConcurrentProbes: Int = 4) {
        self.repository = repository
        self.prober = prober
        self.bookmarks = bookmarks
        self.limiter = AsyncLimiter(limit: maxConcurrentProbes)
    }

    public func assets() async throws -> [MediaAsset] {
        try await repository.allMediaAssets()
    }

    /// Importa arquivos e pastas. Itens já na biblioteca (mesmo caminho) são
    /// ignorados. Cancelar a tarefa interrompe a importação; o que já foi lido é salvo.
    public func importItems(_ urls: [URL],
                            progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> ImportReport {
        let files = MediaScanner.collectFiles(from: urls)
        let existingPaths = Set(try await repository.allMediaAssets().map(\.path))
        var report = ImportReport()
        let pending = files.filter { !existingPaths.contains($0.path) }
        report.skippedDuplicates = files.count - pending.count
        progress?(ImportProgress(completed: 0, total: pending.count))

        let prober = self.prober
        let bookmarks = self.bookmarks
        let limiter = self.limiter
        var completed = 0

        await withTaskGroup(of: Result<MediaAsset, ImportReport.Failure>?.self) { group in
            for url in pending {
                guard let kind = MediaFormats.kind(for: url) else { continue }
                group.addTask {
                    do {
                        return try await limiter.run {
                            let info = try await prober.probe(url, kind: kind)
                            return .success(MediaAsset(
                                name: url.deletingPathExtension().lastPathComponent,
                                path: url.path,
                                bookmark: bookmarks?.makeBookmark(for: url),
                                kind: kind,
                                fileSize: MediaScanner.fileSize(of: url),
                                duration: info.duration,
                                pixelWidth: info.pixelWidth,
                                pixelHeight: info.pixelHeight,
                                codec: info.codec))
                        }
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .failure(ImportReport.Failure(url: url, reason: "\(error)"))
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let asset)?: report.added.append(asset)
                case .failure(let failure)?: report.failures.append(failure)
                case nil: report.cancelled = true
                }
                completed += 1
                progress?(ImportProgress(completed: completed, total: pending.count))
            }
        }
        if Task.isCancelled { report.cancelled = true }

        report.added.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if !report.added.isEmpty { try await repository.saveMediaAssets(report.added) }
        log.info("Importação: \(report.added.count) adicionados, \(report.skippedDuplicates) duplicados, \(report.failures.count) falhas\(report.cancelled ? " (cancelada)" : "")")
        for failure in report.failures {
            log.warning("Falha ao importar \(failure.url.lastPathComponent): \(failure.reason)", code: "W-MEDIA-IMPORT")
        }
        return report
    }

    /// Verifica se cada arquivo continua no lugar; tenta reencontrar pelo bookmark.
    @discardableResult
    public func refreshAvailability(fileManager: FileManager = .default) async throws -> [MediaAsset] {
        var assets = try await repository.allMediaAssets()
        var changed: [MediaAsset] = []
        for index in assets.indices {
            var asset = assets[index]
            let before = asset
            if fileManager.fileExists(atPath: asset.path) {
                if asset.availability == .missing { asset.availability = .available; asset.lastError = nil }
            } else if let bookmark = asset.bookmark, let resolved = bookmarks?.resolve(bookmark),
                      fileManager.fileExists(atPath: resolved.url.path) {
                log.notice("Mídia movida reencontrada: \(asset.name) → \(resolved.url.path)")
                asset.path = resolved.url.path
                asset.bookmark = resolved.refreshed ?? bookmark
                asset.availability = .available
                asset.lastError = nil
            } else {
                asset.availability = .missing
            }
            if asset != before { changed.append(asset); assets[index] = asset }
        }
        if !changed.isEmpty { try await repository.saveMediaAssets(changed) }
        return assets
    }

    /// Aponta uma mídia para um novo arquivo, validando-o de verdade.
    public func relink(assetID: UUID, to url: URL) async throws -> MediaAsset {
        guard var asset = try await repository.allMediaAssets().first(where: { $0.id == assetID }) else {
            throw MediaProbeError.unreadable("mídia não encontrada na biblioteca")
        }
        guard let kind = MediaFormats.kind(for: url), kind == asset.kind else {
            throw MediaProbeError.unreadable("o novo arquivo não é do mesmo tipo (\(asset.kind.displayName))")
        }
        let info = try await prober.probe(url, kind: kind)
        asset.path = url.standardizedFileURL.path
        asset.bookmark = bookmarks?.makeBookmark(for: url)
        asset.fileSize = MediaScanner.fileSize(of: url)
        asset.duration = info.duration
        asset.pixelWidth = info.pixelWidth
        asset.pixelHeight = info.pixelHeight
        asset.codec = info.codec
        asset.availability = .available
        asset.lastError = nil
        try await repository.saveMediaAssets([asset])
        log.notice("Mídia \(asset.name) reapontada para \(asset.path)")
        return asset
    }

    /// Procura numa pasta arquivos para todas as mídias ausentes. Retorna quantas
    /// foram reapontadas; casos ambíguos ficam para o operador decidir.
    public func relinkMissing(searchingIn folder: URL) async throws -> Int {
        let missing = try await repository.allMediaAssets().filter { $0.availability == .missing }
        guard !missing.isEmpty else { return 0 }
        let candidates = MediaScanner.collectFiles(from: [folder])
            .map { RelinkMatcher.Candidate(url: $0, size: MediaScanner.fileSize(of: $0)) }
        var count = 0
        for (id, url) in RelinkMatcher.match(missing: missing, candidates: candidates) {
            try Task.checkCancellation()
            do {
                _ = try await relink(assetID: id, to: url)
                count += 1
            } catch {
                log.warning("Relink falhou para \(url.lastPathComponent): \(error)", code: "W-MEDIA-RELINK")
            }
        }
        return count
    }

    public func markUnsupported(assetID: UUID, reason: String) async throws {
        guard var asset = try await repository.allMediaAssets().first(where: { $0.id == assetID }) else { return }
        asset.availability = .unsupported
        asset.lastError = reason
        try await repository.saveMediaAssets([asset])
    }

    public func remove(assetID: UUID) async throws {
        try await repository.deleteMediaAsset(id: assetID)
    }
}
