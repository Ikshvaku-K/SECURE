import Foundation
import SecureCore
import SQLCipher

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
    public var isConstraintViolation: Bool { code & 0xff == SQLITE_CONSTRAINT }
}

enum SQLValue {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null

    static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.integer) ?? .null }
    static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optional(_ value: Data?) -> SQLValue { value.map(SQLValue.blob) ?? .null }
}

/// One row of a result set, valid only inside the `query` closure.
struct SQLRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func optionalInt(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func optionalBlob(_ column: Int32) -> Data? { isNull(column) ? nil : blob(column) }
}

/// A single SQLCipher connection. Not thread-safe on its own: `WalletStore`, an actor, owns each one.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let cipherVersion: String

    /// Opens (or creates) the database at `path`. With a `key`, the file is encrypted by SQLCipher;
    /// a wrong key fails here rather than on first use.
    init(path: String, key: Data?) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        do {
            if let key {
                precondition(key.count == 32, "SQLCipher raw keys are 32 bytes")
                // Raw-key form: SQLCipher skips the passphrase KDF for x'…' keys.
                try Self.execute(db, "PRAGMA key = \"x'\(key.hexString)'\";")
            }
            guard let version = try Self.scalarText(db, "PRAGMA cipher_version;"), !version.isEmpty else {
                throw StoreError.sqlcipherMissing
            }
            cipherVersion = version
            // Touches the first page: fails with SQLITE_NOTADB when the key is wrong.
            _ = try Self.scalarText(db, "SELECT count(*) FROM sqlite_master;")
            try Self.execute(db, "PRAGMA foreign_keys = ON;")
        } catch {
            sqlite3_close_v2(db)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        try Self.execute(try connection(), sql)
    }

    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try withStatement(sql, bindings) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(rc) }
        }
    }

    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        try withStatement(sql, bindings) { statement in
            var rows: [T] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError(rc) }
                rows.append(try map(SQLRow(statement: statement)))
            }
            return rows
        }
    }

    func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64? {
        try query(sql, bindings) { $0.optionalInt(0) }.first ?? nil
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`, rolling back on any error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var userVersion: Int64 {
        get throws { try scalarInt("PRAGMA user_version;") ?? 0 }
    }

    // MARK: - Internals

    private func connection() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        return handle
    }

    private func withStatement<T>(_ sql: String, _ bindings: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        let db = try connection()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw lastError(rc) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .integer(let v): bound = sqlite3_bind_int64(statement, index, v)
            case .text(let v): bound = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .null: bound = sqlite3_bind_null(statement, index)
            case .blob(let v) where v.isEmpty: bound = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let v):
                bound = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard bound == SQLITE_OK else { throw lastError(bound) }
        }
        return try body(statement)
    }

    private func lastError(_ code: Int32) -> SQLiteError {
        guard let handle else { return SQLiteError(code: code, message: "database is closed") }
        return SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw SQLiteError(code: sqlite3_extended_errcode(db), message: message)
        }
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
