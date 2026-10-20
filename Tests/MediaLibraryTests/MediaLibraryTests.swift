import XCTest
@testable import MediaLibrary

// MARK: Test doubles (explicitamente falsos: não decodificam mídia real)

/// Repositório em memória para testes.
actor InMemoryMediaRepository: MediaAssetRepository {
    var stored: [UUID: MediaAsset] = [:]
    func allMediaAssets() -> [MediaAsset] { stored.values.sorted { $0.path < $1.path } }
    func saveMediaAssets(_ assets: [MediaAsset]) { for a in assets { stored[a.id] = a } }
    func deleteMediaAsset(id: UUID) { stored[id] = nil }
}

/// Probe falso: "decodifica" pelo nome; arquivos com "broken" falham.
struct FakeProbe: MediaProbing {
    var delayNanoseconds: UInt64 = 0
    func probe(_ url: URL, kind: MediaKind) async throws -> MediaProbeResult {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if url.lastPathComponent.contains("broken") { throw MediaProbeError.notPlayable }
        return kind == .video
            ? MediaProbeResult(duration: 83, pixelWidth: 1920, pixelHeight: 1080, codec: "avc1")
            : MediaProbeResult(pixelWidth: 4000, pixelHeight: 3000)
    }
}

/// Resolve "bookmarks" que são apenas caminhos em UTF-8 apontando para um mapa de mudanças.
struct FakeBookmarks: BookmarkResolving {
    var moved: [String: URL]
    func makeBookmark(for url: URL) -> Data? { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) -> (url: URL, refreshed: Data?)? {
        let path = String(decoding: bookmark, as: UTF8.self)
        return moved[path].map { ($0, Data($0.path.utf8)) }
    }
}

final class MediaLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/.hidden"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func touch(_ name: String, bytes: Int = 10) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testScannerExpandsFoldersFiltersAndDedupes() throws {
        let a = try touch("a.JPG")
        try touch("sub/b.mov")
        try touch("sub/notes.txt")
        try touch("sub/.hidden/c.png")
        let files = MediaScanner.collectFiles(from: [dir, a])
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.JPG", "b.mov"])
    }

    func testImportAddsSkipsDuplicatesAndReportsFailures() async throws {
        try touch("one.png")
        try touch("clip.mp4")
        try touch("broken.mov")
        let repo = InMemoryMediaRepository()
        let service = MediaLibraryService(repository: repo, prober: FakeProbe(),
                                          bookmarks: FakeBookmarks(moved: [:]))

        let first = try await service.importItems([dir])
        XCTAssertEqual(first.added.count, 2)
        XCTAssertEqual(first.failures.map(\.url.lastPathComponent), ["broken.mov"])
        let video = try XCTUnwrap(first.added.first { $0.kind == .video })
        XCTAssertEqual(video.summary, "Vídeo · 1:23 · 1920×1080")
        XCTAssertEqual(video.fileSize, 10)
        XCTAssertNotNil(video.bookmark)

        let second = try await service.importItems([dir])
        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(second.skippedDuplicates, 2)
        let all = try await service.assets()
        XCTAssertEqual(all.count, 2)
    }

    func testImportCanBeCancelled() async throws {
        for i in 0..<20 { try touch("img\(i).png") }
        let repo = InMemoryMediaRepository()
        let service = MediaLibraryService(repository: repo,
                                          prober: FakeProbe(delayNanoseconds: 200_000_000),
                                          maxConcurrentProbes: 2)
        let dir = self.dir!
        let task = Task { try await service.importItems([dir]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertLessThan(report.added.count, 20)
    }

    func testAvailabilityMissingThenFoundByBookmark() async throws {
        let original = try touch("photo.png")
        let repo = InMemoryMediaRepository()
        let newURL = dir.appendingPathComponent("sub/photo.png")
        let service = MediaLibraryService(repository: repo, prober: FakeProbe(),
                                          bookmarks: FakeBookmarks(moved: [original.path: newURL]))
        _ = try await service.importItems([original])

        try FileManager.default.moveItem(at: original, to: newURL)
        let assets = try await service.refreshAvailability()
        XCTAssertEqual(assets.first?.availability, .available)
        XCTAssertEqual(assets.first?.path, newURL.path)
    }

    func testMissingWithoutBookmarkAndRelinkByFolderSearch() async throws {
        let original = try touch("logo.png", bytes: 42)
        let repo = InMemoryMediaRepository()
        let service = MediaLibraryService(repository: repo, prober: FakeProbe())
        _ = try await service.importItems([original])

        let elsewhere = dir.appendingPathComponent("sub")
        try FileManager.default.moveItem(at: original, to: elsewhere.appendingPathComponent("logo.png"))
        var assets = try await service.refreshAvailability()
        XCTAssertEqual(assets.first?.availability, .missing)

        let relinked = try await service.relinkMissing(searchingIn: elsewhere)
        XCTAssertEqual(relinked, 1)
        assets = try await service.assets()
        XCTAssertEqual(assets.first?.availability, .available)
        XCTAssertTrue(assets.first?.path.hasSuffix("sub/logo.png") ?? false)
    }

    func testRelinkRejectsDifferentKind() async throws {
        let image = try touch("a.png")
        let video = try touch("a.mov")
        let repo = InMemoryMediaRepository()
        let service = MediaLibraryService(repository: repo, prober: FakeProbe())
        let report = try await service.importItems([image])
        do {
            _ = try await service.relink(assetID: report.added[0].id, to: video)
            XCTFail("Deveria recusar troca de tipo")
        } catch {}
    }

    func testRelinkMatcherNeverPicksAmbiguousCandidates() {
        let asset = MediaAsset(name: "x", path: "/old/x.png", kind: .image, fileSize: 5)
        let unknownSize = MediaAsset(name: "y", path: "/old/y.png", kind: .image)
        let candidates = [
            RelinkMatcher.Candidate(url: URL(fileURLWithPath: "/new/x.png"), size: 5),
            RelinkMatcher.Candidate(url: URL(fileURLWithPath: "/new/other/x.png"), size: 9),
            RelinkMatcher.Candidate(url: URL(fileURLWithPath: "/a/y.png"), size: 1),
            RelinkMatcher.Candidate(url: URL(fileURLWithPath: "/b/y.png"), size: 2),
        ]
        let result = RelinkMatcher.match(missing: [asset, unknownSize], candidates: candidates)
        XCTAssertEqual(result[asset.id]?.path, "/new/x.png")
        XCTAssertNil(result[unknownSize.id], "Dois candidatos possíveis: o operador decide")
    }
}

final class BoundedCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedByCost() {
        let cache = BoundedCache<String, Int>(costLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "b", cost: 40)
        _ = cache.value(for: "a")            // "b" passa a ser o mais antigo
        cache.insert(3, for: "c", cost: 40)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.totalCost, 80)
    }

    func testRejectsOversizedAndTrims() {
        let cache = BoundedCache<String, Int>(costLimit: 100, countLimit: 2)
        cache.insert(1, for: "huge", cost: 101)
        XCTAssertEqual(cache.count, 0)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)
        cache.insert(3, for: "c", cost: 10)
        XCTAssertEqual(cache.count, 2)
        cache.trim(toCost: 0)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }
}

final class AsyncLimiterTests: XCTestCase {
    actor Counter {
        var current = 0, peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    func testNeverExceedsLimit() async throws {
        let limiter = AsyncLimiter(limit: 3)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await limiter.run {
                        await counter.enter()
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 3)
    }

    func testCancelledWaiterThrows() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let blocker = Task { try await limiter.run { try await Task.sleep(nanoseconds: 300_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await limiter.run { 42 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Deveria ter sido cancelado")
        } catch is CancellationError {}
        _ = try await blocker.value
        let after = try await limiter.run { 7 }
        XCTAssertEqual(after, 7, "A vaga não pode vazar após cancelamento")
    }
}
