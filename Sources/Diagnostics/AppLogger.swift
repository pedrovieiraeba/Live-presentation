import Foundation
#if canImport(os)
import os
#endif

public enum LogLevel: Int, Comparable, Codable, Sendable, CaseIterable {
    case debug, info, notice, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// Uma entrada já redigida, mantida no buffer local do painel de diagnóstico.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let code: String?
    public let message: String
}

/// Identificador curto da execução atual, usado para correlacionar logs.
public enum DiagnosticsSession {
    public static let id: String = String(UUID().uuidString.prefix(8)).lowercased()
}

/// Buffer circular limitado: o painel de diagnóstico lê daqui sem depender de
/// arquivos de log nem de serviços externos.
public final class LogBuffer: @unchecked Sendable {
    public static let shared = LogBuffer(capacity: 500)

    private let lock = NSLock()
    private var storage: [LogEntry] = []
    private var nextID: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    func append(level: LogLevel, category: String, code: String?, message: String) {
        lock.lock(); defer { lock.unlock() }
        nextID &+= 1
        if storage.count == capacity { storage.removeFirst() }
        storage.append(LogEntry(id: nextID, date: Date(), level: level,
                                category: category, code: code, message: message))
    }

    public func entries(minimumLevel: LogLevel = .debug) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { $0.level >= minimumLevel }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }
}

/// Fachada de log. No macOS escreve no Unified Logging (os.Logger); em outras
/// plataformas, em stderr. Toda mensagem passa pelo `Redactor`.
public struct AppLogger: Sendable {
    public static let subsystem = "app.livepresentation"

    public let category: String
    private let buffer: LogBuffer
    #if canImport(os)
    private let osLogger: Logger
    #endif

    public init(category: String, buffer: LogBuffer = .shared) {
        self.category = category
        self.buffer = buffer
        #if canImport(os)
        self.osLogger = Logger(subsystem: Self.subsystem, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String, code: String? = nil) {
        log(.debug, message(), code: code)
    }
    public func info(_ message: @autoclosure () -> String, code: String? = nil) {
        log(.info, message(), code: code)
    }
    public func notice(_ message: @autoclosure () -> String, code: String? = nil) {
        log(.notice, message(), code: code)
    }
    public func warning(_ message: @autoclosure () -> String, code: String? = nil) {
        log(.warning, message(), code: code)
    }
    public func error(_ message: @autoclosure () -> String, code: String? = nil) {
        log(.error, message(), code: code)
    }

    public func log(_ level: LogLevel, _ message: String, code: String? = nil) {
        let safe = Redactor.redact(message)
        let prefix = code.map { "[\(DiagnosticsSession.id)] [\($0)] " } ?? "[\(DiagnosticsSession.id)] "
        let line = prefix + safe
        buffer.append(level: level, category: category, code: code, message: safe)
        #if canImport(os)
        switch level {
        case .debug: osLogger.debug("\(line, privacy: .public)")
        case .info: osLogger.info("\(line, privacy: .public)")
        case .notice: osLogger.notice("\(line, privacy: .public)")
        case .warning: osLogger.warning("\(line, privacy: .public)")
        case .error: osLogger.error("\(line, privacy: .public)")
        }
        #else
        if level >= .info {
            FileHandle.standardError.write(Data("\(level.label) \(category): \(line)\n".utf8))
        }
        #endif
    }
}
