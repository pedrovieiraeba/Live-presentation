import Foundation

/// Cache LRU limitado por custo (bytes estimados) e por quantidade. Descartável
/// a qualquer momento — usado para miniaturas e texturas fora do ar.
public final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private var _totalCost = 0

    public let costLimit: Int
    public let countLimit: Int

    public init(costLimit: Int, countLimit: Int = .max) {
        precondition(costLimit > 0 && countLimit > 0)
        self.costLimit = costLimit
        self.countLimit = countLimit
    }

    public var totalCost: Int { lock.lock(); defer { lock.unlock() }; return _totalCost }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        tick &+= 1
        entry.lastAccess = tick
        entries[key] = entry
        return entry.value
    }

    /// Insere; itens maiores que o limite total não são guardados.
    public func insert(_ value: Value, for key: Key, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { _totalCost -= old.cost }
        guard cost <= costLimit else { return }
        tick &+= 1
        entries[key] = Entry(value: value, cost: cost, lastAccess: tick)
        _totalCost += cost
        evict(toCost: costLimit, count: countLimit)
    }

    public func remove(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { _totalCost -= old.cost }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        _totalCost = 0
    }

    /// Reduz o cache (ex.: aviso de pressão de memória).
    public func trim(toCost limit: Int) {
        lock.lock(); defer { lock.unlock() }
        evict(toCost: max(limit, 0), count: countLimit)
    }

    private func evict(toCost limit: Int, count: Int) {
        while (_totalCost > limit || entries.count > count),
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries.removeValue(forKey: oldest.key)
            _totalCost -= oldest.value.cost
        }
    }
}
