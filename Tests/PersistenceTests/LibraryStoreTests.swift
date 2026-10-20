import XCTest
@testable import Persistence
import PresentationCore

final class LibraryStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var dbPath: String { tempDir.appendingPathComponent("library.sqlite").path }

    func testSaveReopenAndLoadPresentation() async throws {
        let original = SampleContent.welcomePresentation(now: Date(timeIntervalSince1970: 1_700_000_000))
        do {
            let store = try LibraryStore(path: dbPath)
            try await store.save(original)
        }
        // Reabre do disco: simula fechar e abrir o app.
        let reopened = try LibraryStore(path: dbPath)
        let loaded = try await reopened.presentation(id: original.id)
        XCTAssertEqual(loaded, original)

        let summaries = try await reopened.summaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.slideCount, original.slideCount)
    }

    func testUpdateIsUpsertAndSummariesSortedByRecency() async throws {
        let store = try LibraryStore(path: ":memory:")
        var a = Presentation(name: "A", createdAt: Date(timeIntervalSince1970: 100))
        let b = Presentation(name: "B", createdAt: Date(timeIntervalSince1970: 200))
        try await store.save(a)
        try await store.save(b)
        a.name = "A renomeada"
        a.touch(Date(timeIntervalSince1970: 300))
        try await store.save(a)

        let names = try await store.summaries().map(\.name)
        XCTAssertEqual(names, ["A renomeada", "B"])
    }

    func testDuplicateAndDelete() async throws {
        let store = try LibraryStore(path: ":memory:")
        let original = SampleContent.welcomePresentation()
        try await store.save(original)
        let copy = try await store.duplicatePresentation(id: original.id)
        XCTAssertNotEqual(copy.id, original.id)
        var count = try await store.summaries().count
        XCTAssertEqual(count, 2)

        try await store.deletePresentation(id: original.id)
        count = try await store.summaries().count
        XCTAssertEqual(count, 1)
        do {
            _ = try await store.presentation(id: original.id)
            XCTFail("Deveria lançar notFound")
        } catch let error as PersistenceError {
            XCTAssertEqual(error, .notFound(original.id))
        }
    }

    func testThemesIncludeBuiltInsAndOverrides() async throws {
        let store = try LibraryStore(path: ":memory:")
        var initial = try await store.themes()
        XCTAssertEqual(initial.map(\.id), Theme.builtIn.map(\.id))

        var modified = Theme.standardLyrics
        modified.fontSize = 90
        let custom = Theme(name: "Natal", fontSize: 64)
        try await store.save(modified)
        try await store.save(custom)

        initial = try await store.themes()
        XCTAssertEqual(initial.count, Theme.builtIn.count + 1)
        XCTAssertEqual(initial.first { $0.id == Theme.standardLyrics.id }?.fontSize, 90)
        XCTAssertEqual(initial.last?.id, custom.id)

        try await store.deleteTheme(id: Theme.standardLyrics.id)
        initial = try await store.themes()
        XCTAssertEqual(initial.first { $0.id == Theme.standardLyrics.id }?.fontSize,
                       Theme.standardLyrics.fontSize, "Tema de fábrica volta ao padrão")
    }

    func testPlaylistsAndCascadeOnPresentationDelete() async throws {
        let store = try LibraryStore(path: ":memory:")
        let a = Presentation(name: "A")
        let b = Presentation(name: "B")
        try await store.save(a)
        try await store.save(b)

        var playlist = Playlist(name: "Domingo manhã", presentationIDs: [b.id, a.id])
        try await store.save(playlist)
        var loaded = try await store.playlists()
        XCTAssertEqual(loaded, [playlist])

        playlist.name = "Domingo"
        playlist.presentationIDs = [a.id]
        try await store.save(playlist)
        loaded = try await store.playlists()
        XCTAssertEqual(loaded, [playlist])

        try await store.deletePresentation(id: a.id)
        loaded = try await store.playlists()
        XCTAssertEqual(loaded.first?.presentationIDs, [])
    }

    func testSessionSnapshotRoundTripAndCorruptionTolerance() async throws {
        let store = try LibraryStore(path: dbPath)
        let none = await store.loadSession()
        XCTAssertNil(none)

        let snapshot = SessionSnapshot(
            activePresentationID: UUID(),
            showState: ShowState(preview: SlideAddress(itemID: UUID(), slideID: UUID())),
            outputScreenName: "DELL U2720Q",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.saveSession(snapshot)
        let loaded = await store.loadSession()
        XCTAssertEqual(loaded, snapshot)

        // Sessão corrompida não pode impedir a abertura do app.
        let raw = try SQLiteDatabase(path: dbPath)
        try raw.execute("UPDATE session_state SET value = '{not json' WHERE key = 'session'")
        let corrupt = await store.loadSession()
        XCTAssertNil(corrupt)
    }

    func testRejectsDatabaseFromNewerSchema() throws {
        do {
            let store = try LibraryStore(path: dbPath)
            _ = store
        }
        // Simula uma biblioteca criada por uma versão futura do app.
        let raw = try SQLiteDatabase(path: dbPath)
        try raw.setUserVersion(Migrations.latestVersion + 1)

        XCTAssertThrowsError(try LibraryStore(path: dbPath)) { error in
            XCTAssertEqual(error as? PersistenceError,
                           .databaseFromNewerVersion(found: Migrations.latestVersion + 1,
                                                     supported: Migrations.latestVersion))
        }
    }
}
