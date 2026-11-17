import Foundation
import SQLite3

/// A value that can be bound to a statement parameter.
protocol SQLBindable {}
extension Int: SQLBindable {}
extension Int64: SQLBindable {}
extension Double: SQLBindable {}
extension String: SQLBindable {}
extension Bool: SQLBindable {}
extension Data: SQLBindable {}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    let sql: String?
    var description: String { "SQLite error \(code): \(message)" + (sql.map { " [\($0.prefix(120))]" } ?? "") }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe: each connection is owned by a single serial queue.
final class SQLiteConnection {
    let handle: OpaquePointer
    private var statementCache: [String: OpaquePointer] = [:]

    init(path: String, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        statementCache.values.forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql) }
    }

    /// Runs a statement that returns no rows. Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ args: [SQLBindable?] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(stmt, args, sql)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return changes
    }

    /// Runs one prepared statement once per argument row (call inside `transaction`).
    func runBatch(_ sql: String, _ rows: [[SQLBindable?]]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for args in rows {
            try bind(stmt, args, sql)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    func query<T>(_ sql: String, _ args: [SQLBindable?] = [], _ map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(stmt, args, sql)
        let row = Row(stmt: stmt)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            out.append(try map(row))
        }
        return out
    }

    func first<T>(_ sql: String, _ args: [SQLBindable?] = [], _ map: (Row) throws -> T) throws -> T? {
        let isSelect = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT")
        let limited = isSelect && !sql.localizedCaseInsensitiveContains(" LIMIT ") ? sql + " LIMIT 1" : sql
        return try query(limited, args, map).first
    }

    func scalarInt(_ sql: String, _ args: [SQLBindable?] = []) throws -> Int {
        try first(sql, args) { $0.int(0) } ?? 0
    }

    func scalarString(_ sql: String, _ args: [SQLBindable?] = []) throws -> String? {
        try first(sql, args) { $0.string(0) } ?? nil
    }

    /// Commits if `body` returns normally, rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] { return cached }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLBindable?], _ sql: String) throws {
        for (offset, value) in args.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch value {
            case nil: rc = sqlite3_bind_null(stmt, i)
            case let v as Int: rc = sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, i, v)
            case let v as Bool: rc = sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Double: rc = sqlite3_bind_double(stmt, i, v)
            case let v as String: rc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: rc = sqlite3_bind_null(stmt, i)
            }
            guard rc == SQLITE_OK else { throw error(rc, sql) }
        }
    }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}

/// The current result row of a statement, read by column index or name.
struct Row {
    fileprivate let stmt: OpaquePointer

    private func index(_ name: String) -> Int32 {
        for i in 0..<sqlite3_column_count(stmt) where String(cString: sqlite3_column_name(stmt, i)) == name { return i }
        preconditionFailure("No column named \(name)")
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }

    func int(_ name: String) -> Int { int(index(name)) }
    func int64(_ name: String) -> Int64 { int64(index(name)) }
    func bool(_ name: String) -> Bool { bool(index(name)) }
    func string(_ name: String) -> String? { string(index(name)) }
    func optionalInt(_ name: String) -> Int? { optionalInt(index(name)) }
}
