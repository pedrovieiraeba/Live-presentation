import CNDI
import XCTest
@testable import NDIService

// MARK: Test doubles — NÃO são NDI real. Simulam o SDK para testar a lógica.

final class FakeNDIRuntime: NDIRuntime, @unchecked Sendable {
    let version = "fake-for-tests"
    let lock = NSLock()
    var sources: [NDISourceInfo] = []
    /// Quando falso, a "fonte" para de mandar quadros (cabo puxado).
    var producing = true
    var failCreation = false
    var receiversCreated = 0
    var framesReleased = 0
    var sent: [(width: Int, height: Int)] = []

    func makeFinder() throws -> NDIFinder { FakeFinder(runtime: self) }

    func makeReceiver(sourceName: String, receiverName: String) throws -> NDIReceiver {
        lock.lock(); defer { lock.unlock() }
        if failCreation { throw NDIError.creationFailed("receptor") }
        receiversCreated += 1
        return FakeReceiver(runtime: self)
    }

    func makeSender(name: String) throws -> NDISender { FakeSender(runtime: self) }

    var isProducing: Bool { lock.lock(); defer { lock.unlock() }; return producing }
    func set(_ body: (FakeNDIRuntime) -> Void) { lock.lock(); body(self); lock.unlock() }
}

final class FakeFinder: NDIFinder {
    let runtime: FakeNDIRuntime
    init(runtime: FakeNDIRuntime) { self.runtime = runtime }
    func currentSources() -> [NDISourceInfo] {
        runtime.lock.lock(); defer { runtime.lock.unlock() }
        return runtime.sources
    }
}

final class FakeReceiver: NDIReceiver {
    let runtime: FakeNDIRuntime
    static let pixels = UnsafeMutableRawPointer.allocate(byteCount: 16 * 4, alignment: 16)
    init(runtime: FakeNDIRuntime) { self.runtime = runtime }
    func capture(timeoutMs: UInt32) -> NDICaptureEvent {
        Thread.sleep(forTimeInterval: 0.01)
        guard runtime.isProducing else { return .nothing }
        let runtime = self.runtime
        return .video(NDIVideoFrame(width: 4, height: 4, bytesPerRow: 16, fourCC: NDIFourCC.bgra,
                                    frameRate: 30, data: UnsafeRawPointer(Self.pixels),
                                    release: { runtime.set { $0.framesReleased += 1 } }))
    }
}

final class FakeSender: NDISender {
    let runtime: FakeNDIRuntime
    init(runtime: FakeNDIRuntime) { self.runtime = runtime }
    func sendBGRA(_ data: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                  frameRateN: Int32, frameRateD: Int32) {
        Thread.sleep(forTimeInterval: 0.02)
        runtime.set { $0.sent.append((width, height)) }
    }
    func connectionCount() -> Int { 2 }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

// MARK: Política de conexão

final class NDIConnectionTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testConnectsOnFirstFrame() {
        var tracker = NDIConnectionTracker()
        XCTAssertEqual(tracker.start(now: t0), .createReceiver)
        XCTAssertEqual(tracker.status, .connecting(attempt: 1))
        tracker.frameReceived(now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(tracker.status, .connected)
    }

    func testLossKeepsReceiverThenRetriesWithGrowingBackoff() {
        var tracker = NDIConnectionTracker()
        _ = tracker.start(now: t0)
        tracker.frameReceived(now: t0)
        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(1.9)), .none)
        XCTAssertEqual(tracker.status, .connected)

        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(2.1)), .none, "Perda não destrói o receptor de imediato")
        guard case let .lost(_, retryAt, attempt) = tracker.status else { return XCTFail("deveria estar perdida") }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(retryAt.timeIntervalSince(t0), 3.1, accuracy: 0.001)

        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(3.2)), .createReceiver)
        XCTAssertEqual(tracker.status, .connecting(attempt: 2))

        // Segunda tentativa expira sem quadro → espera 2 s.
        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(3.2 + 6.1)), .none)
        guard case let .lost(_, retry2, attempt2) = tracker.status else { return XCTFail() }
        XCTAssertEqual(attempt2, 2)
        XCTAssertEqual(retry2.timeIntervalSince(t0), 3.2 + 6.1 + 2, accuracy: 0.001)
    }

    func testRecoversWhenFramesReturnWhileLost() {
        var tracker = NDIConnectionTracker()
        _ = tracker.start(now: t0)
        tracker.frameReceived(now: t0)
        _ = tracker.tick(now: t0.addingTimeInterval(3))
        tracker.frameReceived(now: t0.addingTimeInterval(3.5))
        XCTAssertEqual(tracker.status, .connected)
    }

    func testBackoffIsCapped() {
        let policy = NDIConnectionTracker.Policy()
        XCTAssertEqual(policy.backoff(afterAttempt: 1), 1)
        XCTAssertEqual(policy.backoff(afterAttempt: 3), 4)
        XCTAssertEqual(policy.backoff(afterAttempt: 20), 10)
    }

    func testCreationFailureSchedulesRetry() {
        var tracker = NDIConnectionTracker()
        _ = tracker.start(now: t0)
        tracker.creationFailed(now: t0)
        guard case .lost = tracker.status else { return XCTFail() }
        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(1.01)), .createReceiver)
    }

    func testStop() {
        var tracker = NDIConnectionTracker()
        XCTAssertEqual(tracker.stop(), .none)
        _ = tracker.start(now: t0)
        XCTAssertEqual(tracker.stop(), .destroyReceiver)
        XCTAssertEqual(tracker.status, .idle)
    }
}

// MARK: Worker com runtime falso

final class NDIReceiverWorkerTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private var fastPolicy: NDIConnectionTracker.Policy {
        var p = NDIConnectionTracker.Policy()
        p.lossTimeout = 0.2
        p.connectTimeout = 0.3
        p.initialBackoff = 0.1
        p.maxBackoff = 0.2
        return p
    }

    func testReceivesLosesAndReconnects() {
        let runtime = FakeNDIRuntime()
        let worker = NDIReceiverWorker(runtime: runtime, sourceName: "CAM 1", policy: fastPolicy, captureTimeoutMs: 20)
        worker.start()
        XCTAssertTrue(waitUntil { worker.currentStats.status == .connected })
        XCTAssertNotNil(worker.latestFrame())
        XCTAssertEqual(worker.currentStats.width, 4)

        runtime.set { $0.producing = false }
        XCTAssertTrue(waitUntil {
            if case .lost = worker.currentStats.status { return true }
            return false
        })
        XCTAssertNotNil(worker.latestFrame(), "Último quadro permanece (sem tela preta abrupta)")

        runtime.set { $0.producing = true }
        XCTAssertTrue(waitUntil { worker.currentStats.status == .connected })
        worker.stop()
        XCTAssertEqual(worker.currentStats.status, .idle)
    }

    func testFramesAreReleasedExactlyOnce() {
        let runtime = FakeNDIRuntime()
        let worker = NDIReceiverWorker(runtime: runtime, sourceName: "CAM", policy: fastPolicy, captureTimeoutMs: 20)
        worker.start()
        XCTAssertTrue(waitUntil { worker.currentStats.framesReceived >= 5 })
        worker.stop()
        let received = worker.currentStats.framesReceived
        XCTAssertTrue(waitUntil { runtime.lock.lock(); defer { runtime.lock.unlock() }; return runtime.framesReleased == received })
    }

    func testCreationFailureIsRetriedAndVisible() {
        let runtime = FakeNDIRuntime()
        runtime.failCreation = true
        let worker = NDIReceiverWorker(runtime: runtime, sourceName: "CAM", policy: fastPolicy, captureTimeoutMs: 20)
        worker.start()
        XCTAssertTrue(waitUntil {
            if case .lost = worker.currentStats.status { return true }
            return false
        })
        runtime.set { $0.failCreation = false }
        XCTAssertTrue(waitUntil { worker.currentStats.status == .connected })
        worker.stop()
    }

    func testStopIsPromptAndIdempotent() {
        let runtime = FakeNDIRuntime()
        let worker = NDIReceiverWorker(runtime: runtime, sourceName: "CAM", captureTimeoutMs: 20)
        worker.start()
        let start = Date()
        worker.stop()
        worker.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

// MARK: Descoberta e envio

final class NDIDiscoveryAndSenderTests: XCTestCase {
    func testDiscoveryReportsOnlyChanges() throws {
        let runtime = FakeNDIRuntime()
        let reports = LockedBox<[[String]]>([])
        let discovery = try NDIDiscovery(runtime: runtime) { sources in
            reports.mutate { $0.append(sources.map(\.name)) }
        }
        runtime.set { $0.sources = [NDISourceInfo(name: "B"), NDISourceInfo(name: "A")] }
        discovery.pollNow()
        discovery.pollNow()
        runtime.set { $0.sources = [] }
        discovery.pollNow()
        XCTAssertEqual(reports.value, [["A", "B"], []])
    }

    func testSenderDropsWhenBusyAndAlwaysCompletes() throws {
        let runtime = FakeNDIRuntime()
        let sender = try NDIOutputSender(runtime: runtime, name: "Live Presentation")
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { buffer.deallocate() }
        let completions = LockedBox(0)
        var accepted = 0
        for _ in 0..<5 {
            if sender.submit(buffer, width: 4, height: 4, bytesPerRow: 16, framesPerSecond: 30,
                             completion: { completions.mutate { $0 += 1 } }) {
                accepted += 1
            }
        }
        sender.drain()
        XCTAssertEqual(completions.value, 5)
        XCTAssertEqual(accepted, 1, "Envio é síncrono e leva 20 ms: os demais são descartados")
        XCTAssertEqual(sender.currentStats.framesDropped, 4)
        XCTAssertEqual(sender.currentStats.framesSent, 1)
        XCTAssertEqual(sender.currentStats.connections, 2)
    }
}

// MARK: Runtime real (carregamento dinâmico)

final class DynamicNDIRuntimeTests: XCTestCase {
    func testMissingLibraryIsReportedNotCrashing() {
        let result = DynamicNDIRuntime.load(searchPaths: ["/caminho/inexistente/libndi.dylib"])
        guard case .failure(let error) = result else { return XCTFail("não deveria carregar") }
        XCTAssertEqual(error, .libraryNotFound(searched: ["/caminho/inexistente/libndi.dylib"]))
    }

    func testNonNDILibraryFailsWithMissingSymbol() {
        // libc existe em todo sistema, mas não exporta NDIlib_*. No macOS ela vive
        // no cache compartilhado do dyld (não existe como arquivo), por isso o nome
        // sem caminho absoluto.
        #if os(macOS)
        let path = "libSystem.B.dylib"
        #else
        let path = "libc.so.6"
        #endif
        guard case .failure(.libraryLoadFailed(let reason)) = DynamicNDIRuntime.load(searchPaths: [path]) else {
            return XCTFail("deveria falhar por símbolo ausente")
        }
        XCTAssertTrue(reason.contains("NDIlib_initialize"), reason)
    }

    func testFourCCAndStructLayout() {
        XCTAssertEqual(NDIFourCC.bgra, cndi_fourcc(66, 71, 82, 65))
        XCTAssertEqual(NDIFourCC.name(NDIFourCC.uyvy), "UYVY")
        // Layout esperado em 64 bits, derivado da ordem de campos documentada pelo SDK.
        if MemoryLayout<Int>.size == 8 {
            XCTAssertEqual(cndi_sizeof_video_frame(), 72)
            XCTAssertEqual(cndi_sizeof_recv_create(), 40)
        }
    }
}
