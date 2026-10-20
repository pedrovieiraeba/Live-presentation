import Foundation

/// Estado de uma fonte NDI conectada a uma camada.
public enum NDIConnectionStatus: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    /// Sem quadros há algum tempo. O SDK pode reconectar sozinho; se não, o
    /// receptor é recriado em `retryAt`.
    case lost(since: Date, retryAt: Date, attempt: Int)
    case unavailable(String)

    public var label: String {
        switch self {
        case .idle: return "parada"
        case .connecting(let attempt): return attempt > 1 ? "conectando (tentativa \(attempt))" : "conectando"
        case .connected: return "conectada"
        case .lost(_, _, let attempt): return "perdida — nova tentativa \(attempt + 1) em breve"
        case .unavailable(let reason): return "indisponível: \(reason)"
        }
    }

    public var isConnected: Bool { self == .connected }
}

public enum NDIConnectionAction: Equatable, Sendable {
    case none
    case createReceiver
    case destroyReceiver
}

/// Política de conexão/reconexão, pura e testável. Nunca entra em ciclo
/// silencioso: cada tentativa é numerada e visível, com espera crescente.
public struct NDIConnectionTracker: Sendable {
    public struct Policy: Sendable {
        /// Sem quadros por este tempo com status "conectada" → "perdida".
        public var lossTimeout: TimeInterval = 2
        /// Tempo máximo esperando o primeiro quadro.
        public var connectTimeout: TimeInterval = 6
        public var initialBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 10

        public init() {}

        public func backoff(afterAttempt attempt: Int) -> TimeInterval {
            min(initialBackoff * pow(2, Double(max(attempt - 1, 0))), maxBackoff)
        }
    }

    public let policy: Policy
    public private(set) var status: NDIConnectionStatus = .idle
    public private(set) var lastFrameAt: Date?
    private var attemptStartedAt: Date?

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    public mutating func start(now: Date) -> NDIConnectionAction {
        status = .connecting(attempt: 1)
        attemptStartedAt = now
        lastFrameAt = nil
        return .createReceiver
    }

    public mutating func stop() -> NDIConnectionAction {
        let wasActive = status != .idle
        status = .idle
        return wasActive ? .destroyReceiver : .none
    }

    public mutating func frameReceived(now: Date) {
        lastFrameAt = now
        status = .connected
    }

    /// Falha de criação do receptor: agenda nova tentativa.
    public mutating func creationFailed(now: Date) {
        let attempt = currentAttempt
        status = .lost(since: lastFrameAt ?? now, retryAt: now.addingTimeInterval(policy.backoff(afterAttempt: attempt)),
                       attempt: attempt)
    }

    public mutating func tick(now: Date) -> NDIConnectionAction {
        switch status {
        case .idle, .unavailable:
            return .none
        case .connected:
            guard let last = lastFrameAt, now.timeIntervalSince(last) > policy.lossTimeout else { return .none }
            // Mantém o receptor: o SDK costuma reconectar sozinho quando a fonte volta.
            status = .lost(since: last, retryAt: now.addingTimeInterval(policy.backoff(afterAttempt: 1)), attempt: 1)
            return .none
        case .connecting(let attempt):
            guard let started = attemptStartedAt, now.timeIntervalSince(started) > policy.connectTimeout else {
                return .none
            }
            status = .lost(since: lastFrameAt ?? started,
                           retryAt: now.addingTimeInterval(policy.backoff(afterAttempt: attempt)), attempt: attempt)
            return .none
        case let .lost(_, retryAt, attempt):
            guard now >= retryAt else { return .none }
            status = .connecting(attempt: attempt + 1)
            attemptStartedAt = now
            return .createReceiver
        }
    }

    private var currentAttempt: Int {
        switch status {
        case .connecting(let a): return a
        case .lost(_, _, let a): return a
        default: return 1
        }
    }
}
