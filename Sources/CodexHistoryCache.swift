import Darwin
import Foundation
import SQLite3

/// Derived checkpoints. Source logs remain authoritative when the database is busy or full.
final class CodexHistoryCache {
    private struct Failure: Error {
        let code: Int32
        var exceedsConfiguredLimit = false
        var requiresRebuild: Bool { code == SQLITE_NOTADB || code == SQLITE_CORRUPT || exceedsConfiguredLimit }
    }

    private let db: OpaquePointer
    private let lock: Int32
    private let home: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL, home: String, maximumBytes: Int, checkIntegrity: Bool = false) {
        guard maximumBytes >= 8192,
            let lockPath = try? PrivateFile.databasePath(url.appendingPathExtension("lock"))
        else { return nil }
        let lock = Darwin.open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { return nil }
        var keepLock = false
        defer { if !keepLock { close(lock) } }
        guard flock(lock, LOCK_SH | LOCK_NB) == 0 else { return nil }
        func connect() throws -> OpaquePointer {
            let path = try PrivateFile.databasePath(url)
            return try Self.open(path, maximumBytes: maximumBytes, checkIntegrity: checkIntegrity)
        }
        do {
            db = try connect()
        } catch let failure as Failure where failure.requiresRebuild {
            // All QuotaBar readers hold a shared lock for the lifetime of their SQLite connection.
            // Recheck under exclusive ownership in case another reader has already repaired it.
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
            do {
                db = try connect()
            } catch let confirmed as Failure where confirmed.requiresRebuild {
                for suffix in ["-journal", "-shm", "-wal", ""] {
                    guard unlink(url.path + suffix) == 0 || errno == ENOENT else { return nil }
                }
                guard let fresh = try? connect() else { return nil }
                db = fresh
            } catch { return nil }
            guard flock(lock, LOCK_SH) == 0 else {
                sqlite3_close(db)
                return nil
            }
        } catch { return nil }
        self.lock = lock
        self.home = home
        keepLock = true
    }

    deinit {
        sqlite3_close(db)
        close(lock)
    }

    var needsReopening: Bool { PrivateFile.databaseNeedsReopening(db) }

    private static func open(_ path: String, maximumBytes: Int, checkIntegrity: Bool) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw Failure(code: status)
        }
        var keep = false
        defer { if !keep { sqlite3_close(connection) } }
        let configured = sqlite3_exec(
            connection,
            """
            PRAGMA trusted_schema=OFF;
            PRAGMA page_size=4096;
            PRAGMA cache_size=-1024;
            """, nil, nil, nil)
        guard configured == SQLITE_OK else { throw Failure(code: configured) }
        func scalar(_ sql: String) throws -> Int {
            var query: OpaquePointer?
            let prepared = sqlite3_prepare_v2(connection, sql, -1, &query, nil)
            defer { sqlite3_finalize(query) }
            guard prepared == SQLITE_OK else { throw Failure(code: prepared) }
            let step = sqlite3_step(query)
            guard step == SQLITE_ROW else { throw Failure(code: step) }
            return Int(sqlite3_column_int64(query, 0))
        }
        let size = try scalar("PRAGMA page_size")
        let pages = maximumBytes / max(1, size)
        // SQLite cannot lower the page limit below the current allocation.
        guard pages >= 2, try scalar("PRAGMA max_page_count=\(pages)") <= pages else {
            throw Failure(code: SQLITE_FULL, exceedsConfiguredLimit: true)
        }
        if checkIntegrity {
            // A SELECT previously detected damage in a data page; check only on this recovery path.
            guard try scalar("SELECT count(*) FROM pragma_quick_check(1) WHERE quick_check != 'ok'") == 0 else {
                throw Failure(code: SQLITE_CORRUPT)
            }
        }
        let schema = sqlite3_exec(
            connection,
            """
            CREATE TABLE IF NOT EXISTS entries (
                home TEXT NOT NULL, path TEXT NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(home,path)
            ) WITHOUT ROWID;
            """, nil, nil, nil)
        guard schema == SQLITE_OK else { throw Failure(code: schema) }
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(min(maximumBytes, 16 * 1024 * 1024)))
        keep = true
        return connection
    }

    @discardableResult
    func load(_ consume: (String, Data) -> Void) -> Int32 {
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        let prepared = sqlite3_prepare_v2(db, "SELECT path,payload FROM entries WHERE home=?", -1, &query, nil)
        guard prepared == SQLITE_OK else { return prepared }
        let bound = sqlite3_bind_text(query, 1, home, -1, transient)
        guard bound == SQLITE_OK else { return bound }
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            if let path = sqlite3_column_text(query, 0), let bytes = sqlite3_column_blob(query, 1) {
                autoreleasepool {
                    consume(String(cString: path), Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1))))
                }
            }
            result = sqlite3_step(query)
        }
        return result
    }

    /// Acknowledge only durable transactions, except for rows that exceed the configured cache budget.
    /// Those rows are reconstructed on restart. A transient error leaves unacknowledged changes pending.
    func save(paths: [String], payload: (String) throws -> Data?, acknowledge: (ArraySlice<String>) -> Void) -> Int32 {
        func batch(_ paths: ArraySlice<String>) -> Int32 {
            let begin = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            guard begin == SQLITE_OK else { return begin }
            var status = SQLITE_OK
            for path in paths {
                do { status = try autoreleasepool { try update(path, data: payload(path)) } } catch {
                    status = SQLITE_ERROR
                }
                // The row is larger than SQLite's single-value budget. Its source still contributes to totals.
                if status == SQLITE_TOOBIG { status = SQLITE_OK }
                if status != SQLITE_OK { break }
            }
            if status == SQLITE_OK { status = sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            if status == SQLITE_OK {
                acknowledge(paths)
                return SQLITE_OK
            }
            if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            if status == SQLITE_FULL && paths.count > 1 {
                // Commit the prefix that fits. A FULL result may roll back the whole SQLite transaction.
                let middle = paths.startIndex + paths.count / 2
                let first = batch(paths[..<middle])
                if first == SQLITE_OK { return batch(paths[middle...]) }
                return first
            }
            return status
        }
        for start in stride(from: 0, to: paths.count, by: 64) {
            let status = batch(paths[start..<min(start + 64, paths.count)])
            if status == SQLITE_FULL {
                // Further inserts can wait for a new revision or restart. Removals were ordered first.
                acknowledge(paths[start...])
                return SQLITE_OK
            }
            if status != SQLITE_OK { return status }
        }
        return SQLITE_OK
    }

    private func update(_ path: String, data: Data?) -> Int32 {
        let sql =
            data == nil ? "DELETE FROM entries WHERE home=? AND path=?" : "INSERT OR REPLACE INTO entries VALUES(?,?,?)"
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        let prepared = sqlite3_prepare_v2(db, sql, -1, &query, nil)
        guard prepared == SQLITE_OK else { return prepared }
        var bound = sqlite3_bind_text(query, 1, home, -1, transient)
        if bound == SQLITE_OK { bound = sqlite3_bind_text(query, 2, path, -1, transient) }
        if bound == SQLITE_OK, let data {
            guard data.count < sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) else { return SQLITE_TOOBIG }
            bound = data.withUnsafeBytes { sqlite3_bind_blob(query, 3, $0.baseAddress, Int32(data.count), transient) }
        }
        guard bound == SQLITE_OK else { return bound }
        let result = sqlite3_step(query)
        return result == SQLITE_DONE ? SQLITE_OK : result
    }
}
