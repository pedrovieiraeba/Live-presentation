import Diagnostics
import Foundation

/// Estatísticas observadas de uma fonte recebida.
public struct NDIReceiverStats: Equatable, Sendable {
    public var sourceName: String
    public var status: NDIConnectionStatus
    public var width = 0
    public var height = 0
    public var fourCC = ""
    public var nominalFrameRate: Double?
    public var measuredFrameRate = 0.0
    public var framesReceived = 0
    public var unsupportedFrames = 0
    public var receiverCreations = 0
}

/// Recebe uma fonte NDI numa thread própria (capture bloqueante com timeout),
/// aplica a política de reconexão e guarda apenas o quadro mais recente.
/// Nunca bloqueia a interface nem o render.
public final class NDIReceiverWorker: @unchecked Sendable {
    public let sourceName: String
    private let runtime: NDIRuntime
    private let receiverName: String
    private let now: @Sendable () -> Date
    private let captureTimeoutMs: UInt32
    private let log = AppLogger(category: "ndi")

    private let lock = NSLock()
    private var tracker: NDIConnectionTracker
    private var latest: NDIVideoFrame?
    private var generation: UInt64 = 0
    private var stats: NDIReceiverStats
    private var frameTimes: [Date] = []
    private var cancelled = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    public init(runtime: NDIRuntime, sourceName: String, receiverName: String = "Live Presentation",
                policy: NDIConnectionTracker.Policy = .init(), captureTimeoutMs: UInt32 = 100,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runtime = runtime
        self.sourceName = sourceName
        self.receiverName = receiverName
        self.captureTimeoutMs = captureTimeoutMs
        self.now = now
        self.tracker = NDIConnectionTracker(policy: policy)
        self.stats = NDIReceiverStats(sourceName: sourceName, status: .idle)
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "NDI recv: \(sourceName)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    /// Para e espera a thread terminar (no máximo ~1 timeout de captura).
    public func stop() {
        lock.lock()
        let running = thread != nil && !cancelled
        cancelled = true
        lock.unlock()
        if running { finished.wait() }
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// Quadro mais recente e um contador que muda a cada quadro novo.
    public func latestFrame() -> (frame: NDIVideoFrame, generation: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { ($0, generation) }
    }

    public var currentStats: NDIReceiverStats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.status = tracker.status
        return s
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func run() {
        var receiver: NDIReceiver?
        apply(locked { $0.start(now: now()) }, receiver: &receiver)

        while !isCancelled {
            if let receiver {
                switch receiver.capture(timeoutMs: captureTimeoutMs) {
                case .video(let frame):
                    handle(frame)
                case .nothing, .statusChange:
                    break
                case .error:
                    log.warning("Erro de captura em \(sourceName)", code: "W-NDI-CAPTURE")
                }
            } else {
                // Sem receptor (aguardando nova tentativa): espera curta.
                Thread.sleep(forTimeInterval: Double(captureTimeoutMs) / 1000)
            }
            let previous = currentStats.status
            let action = locked { $0.tick(now: now()) }
            apply(action, receiver: &receiver)
            let current = currentStats.status
            if current != previous { logTransition(current) }
        }
        receiver = nil
        lock.lock()
        _ = tracker.stop()
        lock.unlock()
        finished.signal()
    }

    private func handle(_ frame: NDIVideoFrame) {
        let time = now()
        lock.lock()
        let wasConnected = tracker.status.isConnected
        tracker.frameReceived(now: time)
        stats.framesReceived += 1
        stats.width = frame.width
        stats.height = frame.height
        stats.fourCC = NDIFourCC.name(frame.fourCC)
        stats.nominalFrameRate = frame.frameRate
        frameTimes.append(time)
        frameTimes.removeAll { time.timeIntervalSince($0) > 1 }
        stats.measuredFrameRate = Double(frameTimes.count)
        if frame.isBGRA {
            latest = frame          // o quadro anterior é devolvido ao SDK aqui
            generation &+= 1
        } else {
            stats.unsupportedFrames += 1
        }
        lock.unlock()
        if !wasConnected { log.notice("Fonte NDI \(sourceName) conectada (\(frame.width)×\(frame.height))") }
    }

    private func apply(_ action: NDIConnectionAction, receiver: inout NDIReceiver?) {
        switch action {
        case .none:
            break
        case .destroyReceiver:
            receiver = nil
        case .createReceiver:
            receiver = nil
            do {
                receiver = try runtime.makeReceiver(sourceName: sourceName, receiverName: receiverName)
                lock.lock(); stats.receiverCreations += 1; lock.unlock()
            } catch {
                log.warning("Não foi possível criar receptor para \(sourceName): \(error)", code: "W-NDI-RECV")
                locked { $0.creationFailed(now: now()) }
            }
        }
    }

    private func logTransition(_ status: NDIConnectionStatus) {
        switch status {
        case .lost:
            log.warning("Fonte NDI \(sourceName): \(status.label)", code: "W-NDI-LOST")
        case .connecting(let attempt) where attempt > 1:
            log.notice("Fonte NDI \(sourceName): \(status.label)")
        default:
            break
        }
    }

    @discardableResult
    private func locked<T>(_ body: (inout NDIConnectionTracker) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&tracker)
    }
}
