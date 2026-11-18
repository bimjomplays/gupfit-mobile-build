import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A value going into or coming out of SQLite.
enum SQLValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

protocol SQLConvertible {
    var sqlValue: SQLValue { get }
}

extension SQLValue: SQLConvertible { var sqlValue: SQLValue { self } }
extension String: SQLConvertible { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLConvertible { var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLConvertible { var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLConvertible { var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Data: SQLConvertible { var sqlValue: SQLValue { .blob(self) } }
/// dates as seconds since 2001-01-01 (Date's own representation, so they read back exactly)
extension Date: SQLConvertible { var sqlValue: SQLValue { .real(timeIntervalSinceReferenceDate) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible, Sendable {
    let code: Int32
    let message: String
    let sql: String?

    var description: String { "SQLite error \(code): \(message)" + (sql.map { " (in: \($0.prefix(120)))" } ?? "") }
}

/// One result row, read by column name.
struct SQLRow {
    let values: [String: SQLValue]

    subscript(_ column: String) -> SQLValue { values[column] ?? .null }

    func string(_ column: String) -> String? {
        switch self[column] {
        case .text(let s): s
        case .integer(let i): String(i)
        case .real(let d): String(d)
        case .blob(let b): String(data: b, encoding: .utf8)
        case .null: nil
        }
    }

    func double(_ column: String) -> Double? {
        switch self[column] {
        case .real(let d): d
        case .integer(let i): Double(i)
        case .text(let s): Double(s)
        default: nil
        }
    }

    func int(_ column: String) -> Int? {
        switch self[column] {
        case .integer(let i): Int(i)
        case .real(let d): Int(d)
        case .text(let s): Int(s)
        default: nil
        }
    }

    func bool(_ column: String) -> Bool? { int(column).map { $0 != 0 } }

    func date(_ column: String) -> Date? { double(column).map(Date.init(timeIntervalSinceReferenceDate:)) }
}

/// A thin wrapper over one SQLite connection. Not thread-safe by itself: its owner serializes access (SQLiteStore
/// holds a lock around every call). Statements bind their values; SQL text never contains user data.
final class SQLiteDatabase {
    enum Mode {
        case readWrite
        /// read-only, and the file is promised not to change (the bundled catalog): no locks, no journal
        case readOnlyImmutable
    }

    private(set) var handle: OpaquePointer?
    let path: String
    private var transactionDepth = 0

    init(path: String, mode: Mode = .readWrite) throws {
        self.path = path
        var flags: Int32
        var name = path
        switch mode {
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            #if os(iOS)
            // encrypted with the device key; readable once the phone was unlocked after a restart, so a background
            // task (the AI chat's tool calls) can still write while the screen is locked
            flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
            #endif
        case .readOnlyImmutable:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#")
            name = "file:\(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)?immutable=1"
        }
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(name, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: "\(message): \(path)", sql: nil)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private var db: OpaquePointer {
        get throws {
            guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: nil) }
            return handle
        }
    }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return SQLiteError(code: rc, message: message, sql: sql)
    }

    /// one or more statements without parameters or results (schema, pragmas)
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(try db, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "error"
            sqlite3_free(message)
            throw SQLiteError(code: rc, message: text, sql: sql)
        }
    }

    /// one statement; its result rows (none for INSERT, UPDATE, DELETE)
    @discardableResult
    func query(_ sql: String, _ args: [SQLConvertible] = []) throws -> [SQLRow] {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        defer { sqlite3_finalize(stmt) }

        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == args.count else {
            throw SQLiteError(code: SQLITE_RANGE, message: "\(args.count) values for \(expected) parameters", sql: sql)
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch arg.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
            }
            guard rc == SQLITE_OK else { throw error(rc, sql) }
        }

        let columns = (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var values: [String: SQLValue] = [:]
            for (i, name) in columns.enumerated() {
                let c = Int32(i)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    values[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n))
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    func run(_ sql: String, _ args: SQLConvertible...) throws { try query(sql, args) }

    /// the first column of the first row
    func scalar(_ sql: String, _ args: [SQLConvertible] = []) throws -> SQLValue {
        guard let row = try query(sql, args).first, let first = row.values.first else { return .null }
        return row.values.count == 1 ? first.value : .null
    }

    /// rows the last INSERT, UPDATE or DELETE changed
    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    /// PRAGMA user_version: the schema version the migrations reached
    var userVersion: Int {
        get throws {
            if case .integer(let v) = try query("PRAGMA user_version").first?["user_version"] ?? .null { return Int(v) }
            return 0
        }
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    var isInTransaction: Bool { transactionDepth > 0 }

    /// Runs `body` in a transaction: all of its writes commit together, or none do when it throws. Nested calls
    /// become savepoints, so an inner failure the outer code catches only undoes the inner part.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let savepoint = "sp\(transactionDepth)"
        let outer = transactionDepth == 0
        try execute(outer ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            // a COMMIT that fails (disk full, I/O) lands in the catch below with the depth still counted once
            try execute(outer ? "COMMIT" : "RELEASE \(savepoint)")
            transactionDepth -= 1
            return result
        } catch {
            transactionDepth -= 1
            if outer {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
            }
            throw error
        }
    }
}

/// SQLITE_TRANSIENT: SQLite copies the bound text or blob before the call returns
private var sqliteTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
