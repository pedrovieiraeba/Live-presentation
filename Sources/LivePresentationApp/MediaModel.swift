import CoreGraphics
import Diagnostics
import Foundation
import MediaLibrary
import Persistence
import SwiftUI

/// Caixa para transportar CGImage entre tarefas.
private final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Estado da biblioteca de mídia na interface: lista, importação, miniaturas.
@MainActor
final class MediaModel: ObservableObject {
    @Published private(set) var assets: [MediaAsset] = []
    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var lastImportSummary: String?
    /// Incrementado quando novas miniaturas ficam prontas.
    @Published private(set) var thumbnailsVersion = 0

    var onAssetsChanged: (() -> Void)?
    var onError: ((String) -> Void)?

    private var service: MediaLibraryService?
    private var importTask: Task<Void, Never>?
    /// Miniaturas: no máximo ~96 MB e 400 itens; descartáveis.
    private let thumbnails = BoundedCache<UUID, CGImage>(costLimit: 96 * 1024 * 1024, countLimit: 400)
    private var pendingThumbnails: Set<UUID> = []
    private var failedThumbnails: Set<UUID> = []
    private let thumbnailLimiter = AsyncLimiter(limit: 3)
    private let log = AppLogger(category: "media")

    static let thumbnailSize = 360

    var assetsByID: [UUID: MediaAsset] { Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }) }
    var isImporting: Bool { importTask != nil }

    func attach(store: LibraryStore) async {
        service = MediaLibraryService(repository: store, prober: AppleMediaProbe(), bookmarks: AppleBookmarks())
        await refreshAvailability()
    }

    // MARK: Importação

    func importItems(_ urls: [URL]) {
        guard let service, importTask == nil, !urls.isEmpty else { return }
        importProgress = ImportProgress(completed: 0, total: 0)
        // O modelo vive enquanto o app vive; captura forte é intencional.
        let progressHandler: @Sendable (ImportProgress) -> Void = { progress in
            Task { @MainActor in self.importProgress = progress }
        }
        importTask = Task {
            do {
                let report = try await service.importItems(urls, progress: progressHandler)
                await finishImport(report)
            } catch {
                await finishImport(nil, error: error)
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func finishImport(_ report: ImportReport?, error: Error? = nil) async {
        importTask = nil
        importProgress = nil
        if let error {
            onError?("A importação falhou: \(error)")
        } else if let report {
            var parts = ["\(report.added.count) importado(s)"]
            if report.skippedDuplicates > 0 { parts.append("\(report.skippedDuplicates) já existia(m)") }
            if !report.failures.isEmpty { parts.append("\(report.failures.count) com falha") }
            if report.cancelled { parts.append("cancelada") }
            lastImportSummary = parts.joined(separator: " · ")
            if !report.failures.isEmpty {
                let list = report.failures.prefix(8).map { "• \($0.url.lastPathComponent): \($0.reason)" }
                onError?("Alguns arquivos não foram importados:\n" + list.joined(separator: "\n"))
            }
        }
        await reload()
    }

    // MARK: Manutenção

    func reload() async {
        guard let service else { return }
        do {
            assets = try await service.assets()
            onAssetsChanged?()
        } catch {
            onError?("Não foi possível ler a biblioteca de mídia: \(error)")
        }
    }

    func refreshAvailability() async {
        guard let service else { return }
        do {
            assets = try await service.refreshAvailability()
            let missing = assets.filter { $0.availability == .missing }.count
            if missing > 0 { log.warning("\(missing) mídia(s) ausente(s)", code: "W-MEDIA-MISSING") }
            onAssetsChanged?()
        } catch {
            onError?("Falha ao verificar arquivos de mídia: \(error)")
        }
    }

    func relink(_ asset: MediaAsset, to url: URL) async {
        guard let service else { return }
        do {
            _ = try await service.relink(assetID: asset.id, to: url)
            thumbnails.remove(asset.id)
            failedThumbnails.remove(asset.id)
            await reload()
        } catch {
            onError?("Não foi possível reapontar \(asset.name): \(error)")
        }
    }

    func relinkMissing(in folder: URL) async {
        guard let service else { return }
        do {
            let count = try await service.relinkMissing(searchingIn: folder)
            lastImportSummary = "\(count) mídia(s) reencontrada(s)"
            failedThumbnails.removeAll()
            await reload()
        } catch {
            onError?("Falha na busca de mídia ausente: \(error)")
        }
    }

    func remove(_ asset: MediaAsset) async {
        guard let service else { return }
        do {
            try await service.remove(assetID: asset.id)
            thumbnails.remove(asset.id)
            await reload()
        } catch {
            onError?("Não foi possível remover \(asset.name): \(error)")
        }
    }

    // MARK: Miniaturas

    /// Miniatura em cache, ou `nil` enquanto é gerada em segundo plano.
    func thumbnail(for asset: MediaAsset) -> CGImage? {
        if let image = thumbnails.value(for: asset.id) { return image }
        requestThumbnail(asset)
        return nil
    }

    private func requestThumbnail(_ asset: MediaAsset) {
        guard asset.availability == .available, !pendingThumbnails.contains(asset.id),
              !failedThumbnails.contains(asset.id) else { return }
        pendingThumbnails.insert(asset.id)
        let limiter = thumbnailLimiter
        let size = Self.thumbnailSize
        Task {
            do {
                let box = try await limiter.run {
                    ImageBox(try await ThumbnailGenerator.thumbnail(for: asset, maxPixelSize: size))
                }
                storeThumbnail(box.image, for: asset.id)
            } catch {
                thumbnailFailed(asset, error: error)
            }
        }
    }

    private func storeThumbnail(_ image: CGImage, for id: UUID) {
        pendingThumbnails.remove(id)
        thumbnails.insert(image, for: id, cost: image.width * image.height * 4)
        thumbnailsVersion &+= 1
    }

    private func thumbnailFailed(_ asset: MediaAsset, error: Error) {
        pendingThumbnails.remove(asset.id)
        guard !(error is CancellationError) else { return }
        failedThumbnails.insert(asset.id)
        log.warning("Miniatura indisponível para \(asset.name): \(error)", code: "W-MEDIA-THUMB")
    }

    /// Pressão de memória: descarta todas as miniaturas (são regeneráveis).
    func purgeThumbnails() {
        thumbnails.removeAll()
        thumbnailsVersion &+= 1
    }

    var thumbnailCacheBytes: Int { thumbnails.totalCost }
}
