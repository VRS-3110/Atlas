import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A minimal wrapper around the system SQLite library, storing each record as a JSON blob
/// keyed by kind and id. WAL journaling plus full sync means a crash never corrupts the
/// file and never loses a committed save.
final class SQLiteDatabase {
    static let schemaVersion = 1

    private var handle: OpaquePointer?
    let url: URL

    struct Row {
        let kind: String
        let id: String
        let data: Data
    }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("""
            CREATE TABLE IF NOT EXISTS records (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID
            """)
        try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if try metaValue("schemaVersion") == nil {
            try setMetaValue("schemaVersion", String(Self.schemaVersion))
            try setMetaValue("createdAt", ISO8601DateFormatter().string(from: Date()))
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: Records

    func loadAll() throws -> [Row] {
        let statement = try prepare("SELECT kind, id, data FROM records")
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(step) }
            let kind = String(cString: sqlite3_column_text(statement, 0))
            let id = String(cString: sqlite3_column_text(statement, 1))
            let count = Int(sqlite3_column_bytes(statement, 2))
            let data = count > 0 ? Data(bytes: sqlite3_column_blob(statement, 2), count: count) : Data()
            rows.append(Row(kind: kind, id: id, data: data))
        }
        return rows
    }

    /// Writes upserts and deletes in one transaction: all of it lands, or none of it.
    func write(upserts: [(kind: String, id: String, data: Data)], deletes: [(kind: String, id: String)],
               replacingEverything: Bool = false) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if replacingEverything { try execute("DELETE FROM records") }
            if !upserts.isEmpty {
                let insert = try prepare("INSERT OR REPLACE INTO records (kind, id, data) VALUES (?, ?, ?)")
                defer { sqlite3_finalize(insert) }
                for row in upserts {
                    sqlite3_reset(insert)
                    sqlite3_bind_text(insert, 1, row.kind, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insert, 2, row.id, -1, SQLITE_TRANSIENT)
                    _ = row.data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(insert, 3, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                    }
                    let step = sqlite3_step(insert)
                    guard step == SQLITE_DONE else { throw error(step) }
                }
            }
            if !deletes.isEmpty {
                let delete = try prepare("DELETE FROM records WHERE kind = ? AND id = ?")
                defer { sqlite3_finalize(delete) }
                for row in deletes {
                    sqlite3_reset(delete)
                    sqlite3_bind_text(delete, 1, row.kind, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(delete, 2, row.id, -1, SQLITE_TRANSIENT)
                    let step = sqlite3_step(delete)
                    guard step == SQLITE_DONE else { throw error(step) }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Meta

    func metaValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW { return String(cString: sqlite3_column_text(statement, 0)) }
        if step == SQLITE_DONE { return nil }
        throw error(step)
    }

    func setMetaValue(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw error(step) }
    }

    /// Copies the live database (including un-checkpointed WAL pages) into a single file.
    func backup(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try execute("VACUUM INTO '\(destination.path.replacingOccurrences(of: "'", with: "''"))'")
    }

    // MARK: Low level

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        if status != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError(code: status, message: text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw error(status) }
        return statement
    }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "")
    }
}

/// Tells SQLite to copy bound values immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
