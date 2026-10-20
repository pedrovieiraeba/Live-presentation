import Diagnostics
import Foundation

/// Descobre fontes NDI periodicamente, fora da main thread. Entrega a lista
/// apenas quando ela muda.
public final class NDIDiscovery: @unchecked Sendable {
    private let finder: NDIFinder
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "app.livepresentation.ndi.discovery", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last: [NDISourceInfo] = []
    private let onChange: @Sendable ([NDISourceInfo]) -> Void

    public init(runtime: NDIRuntime, interval: TimeInterval = 1,
                onChange: @escaping @Sendable ([NDISourceInfo]) -> Void) throws {
        self.finder = try runtime.makeFinder()
        self.interval = interval
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Força uma consulta imediata (útil em testes).
    public func pollNow() { queue.sync { poll() } }

    private func poll() {
        let sources = finder.currentSources().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard sources != last else { return }
        last = sources
        onChange(sources)
    }
}

/// Envia a composição como saída NDI numa fila própria. Se o envio anterior
/// ainda não terminou, o quadro novo é descartado (e contado) — a renderização
/// nunca espera pela rede.
public final class NDIOutputSender: @unchecked Sendable {
    public struct Stats: Equatable, Sendable {
        public var name: String
        public var connections = 0
        public var framesSent = 0
        public var framesDropped = 0
    }

    public let name: String
    private let sender: NDISender
    private let queue = DispatchQueue(label: "app.livepresentation.ndi.send", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var stats: Stats
    private var lastConnectionPoll = Date.distantPast

    public init(runtime: NDIRuntime, name: String) throws {
        self.name = name
        self.sender = try runtime.makeSender(name: name)
        self.stats = Stats(name: name)
        AppLogger(category: "ndi").notice("Saída NDI publicada: \(name)")
    }

    /// Envia de forma assíncrona. `completion` é chamado quando a memória pode
    /// ser reutilizada (sempre, inclusive em descarte). Retorna `false` se descartou.
    @discardableResult
    public func submit(_ data: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                       framesPerSecond: Int, completion: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if busy {
            stats.framesDropped += 1
            lock.unlock()
            completion()
            return false
        }
        busy = true
        lock.unlock()

        let pointer = UInt(bitPattern: data)
        queue.async { [self] in
            let raw = UnsafeRawPointer(bitPattern: pointer)!
            sender.sendBGRA(raw, width: width, height: height, bytesPerRow: bytesPerRow,
                            frameRateN: Int32(framesPerSecond * 1000), frameRateD: 1000)
            let now = Date()
            var connections: Int?
            if now.timeIntervalSince(lastConnectionPoll) > 1 {
                lastConnectionPoll = now
                connections = sender.connectionCount()
            }
            lock.lock()
            busy = false
            stats.framesSent += 1
            if let connections { stats.connections = connections }
            lock.unlock()
            completion()
        }
        return true
    }

    public var currentStats: Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Espera os envios pendentes (encerramento controlado).
    public func drain() { queue.sync {} }
}
