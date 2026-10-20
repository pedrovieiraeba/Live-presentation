import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// `SQLITE_TRANSIENT` não é importado pelo Swift (é uma macro).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Envoltório mínimo sobre a API C do SQLite. Não é thread-safe: o dono
/// (`LibraryStore`, um actor) serializa todo acesso.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(code: rc, message: lastErrorMessage) }
        return Statement(stmt: stmt, db: self)
    }

    /// Executa `body` dentro de uma transação; desfaz tudo em caso de erro.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            let stmt = try prepare("PRAGMA user_version")
            _ = try stmt.step()
            return stmt.int(at: 0)
        }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: SQLiteDatabase

        fileprivate init(stmt: OpaquePointer, db: SQLiteDatabase) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        @discardableResult
        func bind(_ values: SQLiteValue...) throws -> Statement {
            try bind(values)
        }

        @discardableResult
        func bind(_ values: [SQLiteValue]) throws -> Statement {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(stmt, index)
                case .int(let v): rc = sqlite3_bind_int64(stmt, index, Int64(v))
                case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
                case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
                }
                guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: db.lastErrorMessage) }
            }
            return self
        }

        /// Avança uma linha. Retorna `false` quando não há mais linhas.
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError(code: rc, message: db.lastErrorMessage)
            }
        }

        func run() throws {
            while try step() {}
        }

        func int(at column: Int32) -> Int { Int(sqlite3_column_int64(stmt, column)) }
        func double(at column: Int32) -> Double { sqlite3_column_double(stmt, column) }
        func text(at column: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
            return String(cString: ptr)
        }
    }
}

enum SQLiteValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)
}
