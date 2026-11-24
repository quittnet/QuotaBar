import Darwin
import Foundation
import SQLite3

/// Used by the token reader's serial executor. Each refresh publishes its file checkpoints and samples together.
final class ClaudeHistoryIndex {
    struct Failure: Error {
        let code: Int32

        var isContention: Bool {
            let primaryCode = code & 0xff
            return primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
        }
    }

    private let database: OpaquePointer
    private var insertSample: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL?) throws {
        let path = try url.map(PrivateFile.databasePath) ?? ""

        var connection: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_PRIVATECACHE
        // SQLite chooses the private temporary file itself for an empty name. NOFOLLOW on that open
        // rejects macOS's /var symlink when the temporary database spills to disk.
        if url != nil { flags |= SQLITE_OPEN_NOFOLLOW }
        let code = sqlite3_open_v2(path, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw Failure(code: code)
        }
        database = connection
        // Keys are fixed-size hashes and checkpoints are small. Reject corrupt oversized fields inside SQLite.
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 128 * 1024)
        try check(sqlite3_busy_timeout(database, 5_000))
        try execute(
            """
            PRAGMA trusted_schema = OFF;
            PRAGMA mmap_size = 0;
            PRAGMA cache_size = -2048;
            PRAGMA temp_store = FILE;
            PRAGMA temp.cache_size = -1024;
            """)
        try transaction {
            let version = try integer("PRAGMA user_version")
            switch version {
            case 0:
                guard try integer("SELECT COUNT(*) FROM sqlite_master") == 0 else {
                    throw Failure(code: SQLITE_SCHEMA)
                }
                try execute(
                    """
                    CREATE TABLE files (key TEXT PRIMARY KEY, checkpoint BLOB NOT NULL) WITHOUT ROWID;
                    CREATE TABLE samples (file TEXT NOT NULL, message TEXT NOT NULL, date REAL,
                                          count INTEGER NOT NULL, finished INTEGER NOT NULL, usd REAL);
                    CREATE INDEX samples_file ON samples(file);
                    CREATE INDEX samples_message ON samples(message, finished, count, date, file, usd);
                    PRAGMA user_version = 2;
                    """)
            case 2: break
            default: throw Failure(code: SQLITE_SCHEMA)
            }
        }
        try execute("CREATE TEMP TABLE visible (key TEXT PRIMARY KEY) WITHOUT ROWID")
        insertSample = try prepare(
            "INSERT INTO samples(file, message, date, count, finished, usd) VALUES (?, ?, ?, ?, ?, ?)")
    }

    deinit {
        sqlite3_finalize(insertSample)
        sqlite3_close(database)
    }

    var needsReopening: Bool { PrivateFile.databaseNeedsReopening(database) }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func withFileSavepoint<T>(_ operation: () throws -> T) throws -> T {
        try execute("SAVEPOINT scan_file")
        do {
            let result = try operation()
            try execute("RELEASE scan_file")
            return result
        } catch {
            try execute("ROLLBACK TO scan_file; RELEASE scan_file")
            throw error
        }
    }

    func resetVisible() throws { try execute("DELETE FROM visible") }

    func include(_ key: String) throws {
        try run("INSERT OR IGNORE INTO visible(key) VALUES (?)", key: key)
    }

    func checkpoint(_ key: String) throws -> Data? {
        try statement("SELECT checkpoint FROM files WHERE key = ?") { query in
            try bind(key, at: 1, to: query)
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            try check(result, expecting: SQLITE_ROW)
            let length = Int(sqlite3_column_bytes(query, 0))
            guard length > 0, length <= 64 * 1024, let bytes = sqlite3_column_blob(query, 0) else { return nil }
            return Data(bytes: bytes, count: length)
        }
    }

    func replace(_ key: String) throws {
        try run("DELETE FROM samples WHERE file = ?", key: key)
        try run("DELETE FROM files WHERE key = ?", key: key)
    }

    func append(key: String, id: String, date: Date?, count: Int64, finished: Bool, usd: Double?) throws {
        guard let insertSample else { throw Failure(code: SQLITE_MISUSE) }
        defer {
            sqlite3_reset(insertSample)
            sqlite3_clear_bindings(insertSample)
        }
        try bind(key, at: 1, to: insertSample)
        try bind(id, at: 2, to: insertSample)
        if let date {
            try check(sqlite3_bind_double(insertSample, 3, date.timeIntervalSinceReferenceDate))
        } else {
            try check(sqlite3_bind_null(insertSample, 3))
        }
        try check(sqlite3_bind_int64(insertSample, 4, count))
        try check(sqlite3_bind_int(insertSample, 5, finished ? 1 : 0))
        if let usd { try check(sqlite3_bind_double(insertSample, 6, usd)) }
        try check(sqlite3_step(insertSample), expecting: SQLITE_DONE)
    }

    func save(key: String, checkpoint: Data) throws {
        try statement("INSERT OR REPLACE INTO files(key, checkpoint) VALUES (?, ?)") { query in
            try bind(key, at: 1, to: query)
            guard !checkpoint.isEmpty, checkpoint.count <= 64 * 1024 else { throw Failure(code: SQLITE_TOOBIG) }
            try checkpoint.withUnsafeBytes {
                try check(sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), transient))
            }
            try check(sqlite3_step(query), expecting: SQLITE_DONE)
        }
    }

    func pruneInvisible() throws {
        // Use the file index for each missing checkpoint so unchanged refreshes skip the samples table.
        try execute(
            """
            DELETE FROM samples WHERE file IN (SELECT key FROM files WHERE key NOT IN visible);
            DELETE FROM files WHERE key NOT IN visible;
            """)
    }

    func totals(now: Date, calendar: Calendar, partial: Bool, stats: Int64?) throws -> TokenTotals {
        let days = TokenDayBoundaries(now: now, calendar: calendar)
        var daily = TokenDailyUsage(calendar: calendar)
        var incomplete = partial
        var retained = false
        var spend = TokenSpendTotals()
        var all: Int64 = 0
        var month: Int64 = 0
        var week: Int64 = 0
        var yesterday: Int64 = 0
        var today: Int64 = 0

        func add(_ count: Int64, to total: inout Int64) {
            let (sum, overflow) = total.addingReportingOverflow(count)
            if overflow { incomplete = true }
            total = overflow ? .max : sum
        }

        // The first pass keeps the earliest eligible date and selects the smallest final count
        // (or largest in-progress count). Only copies matching that choice may supply its price.
        // A matching copy can fill in missing details, but conflicting known prices stay unpriced.
        // Summing steps can round differently from pricing their aggregate. Half a nanodollar
        // is below the smallest charge difference in the bundled rates.
        // With one eligible copy, its own price needs no second index lookup.
        let sql = """
            WITH messages AS (
                SELECT message, MIN(date) AS firstDate, MIN(count) FILTER (WHERE finished) AS smallestFinal,
                       MAX(count) FILTER (WHERE finished) AS largestFinal, MAX(count) AS largestCount,
                       COUNT(*) AS copies, CASE WHEN finished IN (0, 1) THEN usd END AS singlePrice
                FROM samples INDEXED BY samples_message
                WHERE (date <= ?1 OR date IS NULL) AND file IN visible
                GROUP BY message
            )
            SELECT firstDate, COALESCE(smallestFinal, largestCount),
                   CASE WHEN copies = 1 THEN singlePrice ELSE
                       (SELECT CASE WHEN MAX(usd) - MIN(usd) < 5e-10 THEN MIN(usd) END
                        FROM samples WHERE message = messages.message AND finished = (smallestFinal IS NOT NULL)
                                      AND count = COALESCE(smallestFinal, largestCount)
                                      AND (date <= ?1 OR date IS NULL) AND file IN visible)
                   END,
                   smallestFinal IS NOT NULL, largestFinal
            FROM messages
            """
        try statement(sql) { query in
            try check(sqlite3_bind_double(query, 1, now.timeIntervalSinceReferenceDate))
            while true {
                let step = sqlite3_step(query)
                if step == SQLITE_DONE { break }
                try check(step, expecting: SQLITE_ROW)
                retained = true
                let count = sqlite3_column_int64(query, 1)
                let usd = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : sqlite3_column_double(query, 2)
                let finished = sqlite3_column_int(query, 3) != 0
                if !finished || count != sqlite3_column_int64(query, 4) { incomplete = true }
                let date =
                    sqlite3_column_type(query, 0) == SQLITE_NULL
                    ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 0))
                spend.record(usd, tokens: count, date: date, now: now, days: days)
                add(count, to: &all)
                guard let date else {
                    incomplete = true
                    continue
                }
                daily.add(count, on: date, partial: &incomplete)
                if date >= days.month { add(count, to: &month) }
                if date >= days.week { add(count, to: &week) }
                if date >= days.today {
                    add(count, to: &today)
                } else if date >= days.yesterday {
                    add(count, to: &yesterday)
                }
            }
        }
        return TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today,
            partial: incomplete, hasRetainedUsage: retained, claudeStatsLifetime: stats, spend: spend,
            peakDay: daily.peak)
    }

    private func check(_ code: Int32, expecting: Int32 = SQLITE_OK) throws {
        guard code == expecting else { throw Failure(code: code) }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &prepared, nil))
        guard let prepared else { throw Failure(code: SQLITE_ERROR) }
        return prepared
    }

    private func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        let query = try prepare(sql)
        defer { sqlite3_finalize(query) }
        return try operation(query)
    }

    private func integer(_ sql: String) throws -> Int32 {
        try statement(sql) {
            try check(sqlite3_step($0), expecting: SQLITE_ROW)
            return sqlite3_column_int($0, 0)
        }
    }

    private func bind(_ text: String, at index: Int32, to query: OpaquePointer) throws {
        try text.withCString {
            try check(sqlite3_bind_text(query, index, $0, Int32(text.utf8.count), transient))
        }
    }

    private func run(_ sql: String, key: String) throws {
        try statement(sql) {
            try bind(key, at: 1, to: $0)
            try check(sqlite3_step($0), expecting: SQLITE_DONE)
        }
    }
}
