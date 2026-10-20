import Foundation

/// Limita quantas operações assíncronas rodam ao mesmo tempo (ex.: no máximo 4
/// miniaturas sendo geradas). Respeita cancelamento de quem espera na fila.
public actor AsyncLimiter {
    public let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Repassa a vaga diretamente para o próximo da fila.
            waiters.removeFirst().continuation.resume()
        }
    }
}
