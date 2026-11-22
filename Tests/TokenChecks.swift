import Darwin
import Foundation
import SQLite3

@main
struct TokenChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        try compressedLimits(in: root.appendingPathComponent("limits"), now: now, calendar: calendar)
        try cacheLifecycle(in: root.appendingPathComponent("cache-lifecycle"), now: now, calendar: calendar)
        let cache = root.appendingPathComponent("derived-history.json")
        let history = TokenHistory(home: root, cacheURL: cache, calendar: calendar)
        do {
            _ = try history.read(now: now)
            fatalError("A missing store should be unavailable")
        } catch TokenHistoryError.unavailable {}

        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try expect(history, now: now, all: 0, month: 0, week: 0, today: 0, retained: false)

        // Santiago advanced its clocks at midnight on September 8, 2024.
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let transitionDay = ISO8601DateFormatter().date(from: "2024-09-08T16:00:00Z")!
        let transitionHistory = TokenHistory(home: root, calendar: santiago)
        let transitionLog = sessions.appendingPathComponent("rollout-transition.jsonl")
        let transitionRows = [
            metadata("transition"),
            response("2024-08-10T04:30:00Z", thread: "transition", response: "month", tokens: 11),
            response("2024-09-02T04:30:00Z", thread: "transition", response: "week", tokens: 7),
        ]
        try (transitionRows.joined(separator: "\n") + "\n").write(to: transitionLog, atomically: true, encoding: .utf8)
        try expect(transitionHistory, now: transitionDay, all: 18, month: 18, week: 7, today: 0)
        try FileManager.default.removeItem(at: transitionLog)

        let parent = sessions.appendingPathComponent("rollout-parent.jsonl")
        let parentRows =
            [
                metadata("parent"),
                response("2026-10-20T03:59:59Z", thread: "parent", response: "before-30", tokens: 10),
                counter("2026-10-20T03:59:59Z", cumulative: 10, last: 10),
                response("2026-10-20T04:00:00Z", thread: "parent", response: "day-30", tokens: 11),
                counter("2026-10-20T04:00:00Z", cumulative: 21, last: 11),
                response("2026-11-12T04:59:59Z", thread: "parent", response: "before-7", tokens: 12),
                response("2026-11-12T05:00:00Z", thread: "parent", response: "day-7", tokens: 13),
                counter("2026-11-12T05:00:00Z", cumulative: 46, last: 13),
                response("2026-11-18T04:59:59Z", thread: "parent", response: "yesterday", tokens: 14),
                counter("2026-11-18T04:59:59Z", cumulative: 60, last: 14),
                response("2026-11-18T05:00:00Z", thread: "parent", response: "today", tokens: 15),
                counter("2026-11-18T05:00:00Z", cumulative: 75, last: 15),
                counter("2026-11-18T05:01:00Z", cumulative: 75, last: 15),
                counter("2026-11-18T05:02:00Z", cumulative: 90, last: 12, estimated: true),
                response("2026-11-18T15:00:01Z", thread: "parent", response: "in-the-future", tokens: 100),
                #"{ "type": "event_msg", "payload":{"type":"agent_message","text":"token_count token_usage_record PRIVATE_FIXTURE_PROMPT"} }"#,
                #"{"type":"response_item","payload":{"type":"message","content":""#
                    + String(repeating: "PRIVATE_FIXTURE_PROMPT ", count: 30_000) + #""}}"#,
            ].joined(separator: "\n") + "\n"
        try parentRows.write(to: parent, atomically: false, encoding: .utf8)
        try expect(history, now: now, all: 75, month: 65, week: 42, yesterday: 14, today: 15)

        let child = sessions.appendingPathComponent("rollout-child.jsonl")
        let childRows =
            [
                metadata("child", parent: "parent", inheritedUntil: 5),
                counter("2026-11-18T06:00:00Z", cumulative: 75, last: 15, ordinal: 3),
                response("2026-11-18T06:00:01Z", thread: "parent", response: "before-30", tokens: 10),
                response("2026-11-18T06:00:02Z", thread: "child", response: "day-30", tokens: 16),
                counter("2026-11-18T06:00:02Z", cumulative: 91, last: 16, ordinal: 6),
            ].joined(separator: "\n") + "\n"
        try childRows.write(to: child, atomically: false, encoding: .utf8)
        let archivedParent = archive.appendingPathComponent(parent.lastPathComponent)
        try FileManager.default.copyItem(at: parent, to: archivedParent)
        try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31)
        // The copied parent response cannot explain a gap in the child's usage after the inherited counter.
        let lastChildCounter = counter("2026-11-18T06:00:02Z", cumulative: 91, last: 16, ordinal: 6)
        let largerChildCounter = counter("2026-11-18T06:00:02Z", cumulative: 95, last: 16, ordinal: 6)
        try childRows.replacingOccurrences(of: lastChildCounter, with: largerChildCounter)
            .write(to: child, atomically: true, encoding: .utf8)
        try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31, partial: true)
        try childRows.write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: parent)
        try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31)
        let compressedParent = try compress(archivedParent)
        if compressedParent {
            try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31)
            try FileManager.default.removeItem(at: archivedParent)
            try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31)
        }

        // A split line is read exactly once when the writer commits its newline.
        let next = response("2026-11-18T06:10:00Z", thread: "child", response: "append", tokens: 17)
        let split = next.index(next.startIndex, offsetBy: 70)
        try append(String(next[..<split]), to: child)
        try expect(history, now: now, all: 91, month: 81, week: 58, yesterday: 14, today: 31)
        try append(String(next[split...]) + "\n", to: child)
        try expect(history, now: now, all: 108, month: 98, week: 75, yesterday: 14, today: 48)

        let restarted = TokenHistory(home: root, cacheURL: cache, calendar: calendar)
        try expect(restarted, now: now, all: 108, month: 98, week: 75, yesterday: 14, today: 48)
        let database = cache.appendingPathExtension("sqlite")
        let saved = try Data(contentsOf: database)
        precondition(saved.range(of: Data("PRIVATE_FIXTURE_PROMPT".utf8)) == nil)
        var permissions = stat()
        precondition(lstat(database.path, &permissions) == 0 && permissions.st_mode & 0o777 == 0o600)

        // Replace the child in place. The old byte cursor must not be reused.
        try
            (metadata("child") + "\n"
            + response("2026-11-18T06:10:00Z", thread: "child", response: "replacement", tokens: 18) + "\n")
            .write(to: child, atomically: false, encoding: .utf8)
        try expect(restarted, now: now, all: 93, month: 83, week: 60, yesterday: 14, today: 33)

        let legacy = sessions.appendingPathComponent("rollout-legacy.jsonl")
        let legacyRows =
            [
                metadata("old"),
                counter("2026-11-18T06:30:00Z", cumulative: 20, last: 20),
                counter("2026-11-18T06:31:00Z", cumulative: 20, last: 20),
                counter("2026-11-18T06:32:00Z", cumulative: 23, last: 3),
                counter("2026-11-18T06:33:00Z", cumulative: 4, last: 4),
                #"{ "type": "event_msg", "payload": { "type": "token_count", "info": null } }"#,
            ].joined(separator: "\n") + "\n"
        try legacyRows.write(to: legacy, atomically: false, encoding: .utf8)
        try FileManager.default.copyItem(at: legacy, to: archive.appendingPathComponent(legacy.lastPathComponent))
        try expect(restarted, now: now, all: 120, month: 110, week: 87, yesterday: 14, today: 60)

        // Corrupt cache files can be discarded without affecting the source logs.
        let badCache = root.appendingPathComponent("bad-cache")
        try Data("corrupt".utf8).write(to: badCache.appendingPathExtension("sqlite"))
        precondition(chmod(badCache.appendingPathExtension("sqlite").path, 0o600) == 0)
        let recovered = TokenHistory(home: root, cacheURL: badCache, calendar: calendar)
        try expect(recovered, now: now, all: 120, month: 110, week: 87, yesterday: 14, today: 60)
        try append("{\"type\":\"token_usage_record\",\"payload\":{}}\n", to: legacy)
        try expect(recovered, now: now, all: 120, month: 110, week: 87, yesterday: 14, today: 60, partial: true)

        // A copied response preserves spend even if the owner's rollout disappears.
        try FileManager.default.removeItem(at: legacy)
        try expect(recovered, now: now, all: 120, month: 110, week: 87, yesterday: 14, today: 60)
        try FileManager.default.removeItem(
            at: compressedParent ? archivedParent.appendingPathExtension("zst") : archivedParent)
        try
            (metadata("child", parent: "parent") + "\n"
            + response("2026-11-18T06:00:00Z", thread: "parent", response: "before-30", tokens: 10) + "\n")
            .write(to: child, atomically: false, encoding: .utf8)
        try expect(recovered, now: now, all: 37, month: 27, week: 27, today: 27, partial: true)
        let isolated = root.appendingPathComponent("reordered")
        let directory = isolated.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("sample.jsonl")
        let historyWithReorderedKeys = TokenHistory(home: isolated, calendar: calendar)
        let recordedAt = "2026-11-18T07:00:00Z"
        let reordered = [
            metadata("test"),
            #"{"payload":{"info":{"total_token_usage":{"total_tokens":20},"last_token_usage":{"total_tokens":20,"input_tokens":20,"output_tokens":0}},"type":"token_count"},"type":"event_msg","timestamp":"\#(recordedAt)"}"#,
            #"{"payload":{"padding":""# + String(repeating: " ", count: 300)
                + #"","response_id":"r","thread_id":"test","usage":{"total_tokens":7}},"type":"token_usage_record","timestamp":"\#(recordedAt)"}"#,
        ]
        try (reordered.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 27, month: 27, week: 27, today: 27)
        let largeOutput =
            #"{"timestamp":"2026-11-18T07:00:00Z","type":"response_item","payload":{"output":""#
            + String(repeating: "x", count: 17 * 1024 * 1024) + #""}}"#
        try append(largeOutput + "\n", to: log)
        try expect(historyWithReorderedKeys, now: now, all: 27, month: 27, week: 27, today: 27)
        try append("broken json\n", to: log)
        try expect(historyWithReorderedKeys, now: now, all: 27, month: 27, week: 27, today: 27, partial: true)
        if geteuid() != 0 {
            precondition(chmod(log.path, 0) == 0)
            do {
                _ = try historyWithReorderedKeys.read(now: now)
                fatalError("Unreadable cached files must report unavailable")
            } catch TokenHistoryError.unavailable {}
            precondition(chmod(log.path, 0o600) == 0)
        }
        // A retained copy may have only a snapshot for a response identified in the other copy.
        let archived = isolated.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let sameSnapshot = counter(recordedAt, cumulative: 27, last: 7)
        try append(sameSnapshot + "\n", to: log)
        try
            ([metadata("test"), counter(recordedAt, cumulative: 20, last: 20), sameSnapshot]
            .joined(separator: "\n") + "\n")
            .write(to: archived.appendingPathComponent("copy.jsonl"), atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 27, month: 27, week: 27, today: 27, partial: true)
        // No committed, known usage and a confirmed zero are different states.
        try "invalid usage row\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: archived)
        try expect(
            historyWithReorderedKeys, now: now, all: 0, month: 0, week: 0, today: 0, partial: true, retained: false)
        try (response(recordedAt, thread: "test", response: "zero", tokens: 0) + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 0, month: 0, week: 0, today: 0)
        try (metadata("test") + "\n" + counter(recordedAt, cumulative: 100, last: 7) + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 7, month: 7, week: 7, today: 7, partial: true)

        for cumulative: Int64 in [105, 110] {
            for hasEstimate in [false, true] {
                var rows = [
                    metadata("mixed"), counter(recordedAt, cumulative: 100, last: 100),
                    response(recordedAt, thread: "mixed", response: "final", tokens: 5),
                ]
                if hasEstimate {
                    rows.append(counter(recordedAt, cumulative: cumulative, last: 4, estimated: true))
                }
                rows.append(counter(recordedAt, cumulative: cumulative, last: 5))
                try (rows.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
                try expect(
                    historyWithReorderedKeys, now: now, all: 105, month: 105, week: 105, today: 105,
                    partial: cumulative == 110)
            }
        }

        // A paginated history can inherit its opening counter without a logical fork parent.
        let paginated =
            #"{"type":"session_meta","payload":{"id":"branch","history_base":{"thread_id":"base","end_ordinal_exclusive":20,"end_byte_offset":1500}}}"#
        try
            ([paginated, counter(recordedAt, cumulative: 100, last: 7), counter(recordedAt, cumulative: 105, last: 5)]
            .joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 5, month: 5, week: 5, today: 5)

        // Conflicting original copies do not silently change the result with directory order.
        let conflicting = [
            response(recordedAt, thread: "test", response: "same", tokens: 7),
            response(recordedAt, thread: "test", response: "same", tokens: 70),
        ]
        for rows in [conflicting, Array(conflicting.reversed())] {
            try (rows.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
            try expect(historyWithReorderedKeys, now: now, all: 7, month: 7, week: 7, today: 7, partial: true)
        }
        // Changing an interior committed row and then appending must invalidate the index.
        let padding = #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: 2048) + #""}}"#
        let oldRow = response(recordedAt, thread: "test", response: "edited", tokens: 7)
        let newRow = response(recordedAt, thread: "test", response: "edited", tokens: 9)
        try ([padding, oldRow, padding, padding, padding, padding].joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 7, month: 7, week: 7, today: 7)
        let edit = try FileHandle(forWritingTo: log)
        try edit.seek(toOffset: UInt64(padding.utf8.count + 1))
        try edit.write(contentsOf: Data(newRow.utf8))
        try edit.close()
        try append(padding + "\n", to: log)
        try expect(historyWithReorderedKeys, now: now, all: 9, month: 9, week: 9, today: 9)
        let checkpoint =
            #"{"type":"compacted","timestamp":"2026-11-18T08:00:00Z","payload":{"latest_token_usage_record":{"thread_id":"test","response_id":"checkpoint","usage":{"total_tokens":13}}}}"#
        try ([metadata("test"), checkpoint, checkpoint].joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 13, month: 0, week: 0, today: 0, partial: true)
        try append(counter(recordedAt, cumulative: 13, last: 13) + "\n", to: log)
        try expect(historyWithReorderedKeys, now: now, all: 13, month: 13, week: 13, today: 13, partial: true)
        try
            ([metadata("test"), response(recordedAt, thread: "test", response: "checkpoint", tokens: 13), checkpoint]
            .joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 13, month: 13, week: 13, today: 13)
        print("Token history checks passed.")
    }

    private static func expect(
        _ history: TokenHistory, now: Date,
        all: Int64, month: Int64, week: Int64, yesterday: Int64 = 0, today: Int64, partial: Bool = false,
        retained: Bool = true,
        line: UInt = #line
    ) throws {
        let expected = TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: partial,
            hasRetainedUsage: retained)
        let actual = try history.read(now: now)
        precondition(actual == expected, "Line \(line), expected \(expected) and received \(actual)")
    }

    private static func metadata(_ id: String, parent: String? = nil, inheritedUntil: Int = 0) -> String {
        let inherited =
            parent.map { ",\"parent_thread_id\":\"\($0)\",\"subagent_history_start_ordinal\":\(inheritedUntil)" } ?? ""
        return #"{ "type":"session_meta", "payload":{"id":"\#(id)"\#(inherited)} }"#
    }

    private static func response(_ date: String, thread: String, response: String, tokens: Int64) -> String {
        #"{"timestamp":"\#(date)","type":"token_usage_record","payload":{"thread_id":"\#(thread)","response_id":"\#(response)","usage":{"total_tokens":\#(tokens)}}}"#
    }

    private static func counter(
        _ date: String, cumulative: Int64, last: Int64, estimated: Bool = false, ordinal: Int = 0
    ) -> String {
        #"{"timestamp":"\#(date)","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(cumulative)},"last_token_usage":{"input_tokens":\#(estimated ? 0 : last),"output_tokens":0,"total_tokens":\#(last)}}}}"#
    }

    private static func cacheLifecycle(in root: URL, now: Date, calendar: Calendar) throws {
        let fm = FileManager.default
        let sessions = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache.json")
        let dbURL = cache.appendingPathExtension("sqlite")
        let log = sessions.appendingPathComponent("0.jsonl")
        func row(_ id: Int) -> String {
            response("2026-11-18T12:00:00Z", thread: "t", response: String(id), tokens: 1) + "\n"
        }
        try row(0).write(to: log, atomically: false, encoding: .utf8)
        var reads = 0
        func reader(_ cache: URL, cap: Int = 128 * 1024 * 1024) -> TokenHistory {
            TokenHistory(home: root, cacheURL: cache, calendar: calendar, maximumCacheBytes: cap) { reads += $0 }
        }
        func check(_ history: TokenHistory, _ count: Int64) throws {
            try expect(history, now: now, all: count, month: count, week: count, today: count)
        }
        func locked(_ url: URL, _ lock: String, _ operation: () throws -> Void) throws {
            var connection: OpaquePointer?
            precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
            defer { sqlite3_close(connection) }
            precondition(sqlite3_exec(connection, "BEGIN " + lock, nil, nil, nil) == SQLITE_OK)
            defer { precondition(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) == SQLITE_OK) }
            try operation()
        }
        try Data("malformed database".utf8).write(to: dbURL)
        precondition(chmod(dbURL.path, 0o600) == 0)
        let current = reader(cache)
        try check(current, 1)
        reads = 0
        try check(reader(cache), 1)
        precondition(reads == 0, "A repaired database must serve a warm restart")

        try locked(dbURL, "IMMEDIATE") {
            try append(row(1), to: log)
            try check(current, 2)
            // Validating another SQLite path in this process must preserve the existing OS lock.
            _ = try PrivateFile.databasePath(dbURL)
            let observer = Process()
            observer.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            observer.arguments = [dbURL.path, "BEGIN IMMEDIATE; ROLLBACK"]
            observer.standardError = FileHandle.nullDevice
            try observer.run()
            observer.waitUntilExit()
            precondition(observer.terminationStatus != 0)
        }
        reads = 0
        try check(current, 2)
        try check(reader(cache), 2)
        precondition(reads == 0, "A transient write lock must not lose dirty checkpoints")

        // Use the legacy v3 envelope and checkpoint format against unchanged real fixture files.
        var oldFiles: [String: Any] = [:]
        let db = CodexHistoryCache(url: dbURL, home: root.standardizedFileURL.path, maximumBytes: 128 * 1024 * 1024)!
        db.load { path, data in
            let entry = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            oldFiles[path] = entry["file"]
        }
        precondition(oldFiles.count == 1)
        let migrated = root.appendingPathComponent("migration.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 3, "home": root.standardizedFileURL.path, "files": oldFiles,
        ])
        .write(to: migrated)
        let migrationDB = migrated.appendingPathExtension("sqlite")
        _ = try PrivateFile.databasePath(migrationDB)
        let bridge = reader(migrated)
        reads = 0
        try locked(migrationDB, "EXCLUSIVE") {
            try check(bridge, 2)
            precondition(fm.fileExists(atPath: migrated.path))
        }
        try check(bridge, 2)
        precondition(!fm.fileExists(atPath: migrated.path))
        try check(reader(migrated), 2)
        precondition(reads == 0, "Migration must retain valid checkpoints across transient locks")

        let limited = root.appendingPathComponent("limited.json")
        let cap = 16384
        for id in 2...81 {
            try row(id).write(to: sessions.appendingPathComponent("\(id).jsonl"), atomically: false, encoding: .utf8)
        }
        let bounded = reader(limited, cap: cap)
        reads = 0
        try check(bounded, 82)
        let coldBytes = reads
        reads = 0
        try check(bounded, 82)
        precondition(reads == 0)
        try check(reader(limited, cap: cap), 82)
        precondition(reads > 0 && reads < coldBytes, "A full database must retain the checkpoints that fit")
        var info = stat()
        precondition(lstat(limited.appendingPathExtension("sqlite").path, &info) == 0 && info.st_size <= cap)
        let lowered = root.appendingPathComponent("lowered.json")
        try check(reader(lowered), 82)
        precondition(lstat(lowered.appendingPathExtension("sqlite").path, &info) == 0 && info.st_size > cap)
        try check(reader(lowered, cap: cap), 82)
        precondition(lstat(lowered.appendingPathExtension("sqlite").path, &info) == 0 && info.st_size <= cap)

    }

    private static func compressedLimits(in root: URL, now: Date, calendar: Calendar) throws {
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let decoder = root.appendingPathComponent("decoder")
        try """
        #!/bin/sh
        echo $$ > "$0.pid"
        IFS= read -r mode
        printf '%s\\n' "$mode" >> "$0.launches"
        case "$mode" in
            read-stall) exec /bin/sleep 5 ;;
            exit-stall) exec 1>&-; exec /bin/sleep 5 ;;
            overflow) IFS= read -r row; printf 'x%s\\n' "$row"; exec /bin/sleep 5 ;;
            failed) /bin/cat; exit 1 ;;
            rotate)
                base=${0%/*}
                /bin/mv "$base/archived_sessions" "$base/previous"
                /bin/mv "$base/replacement" "$base/archived_sessions"
                exec /bin/cat ;;
            *) exec /bin/cat ;;
        esac
        """.write(to: decoder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: decoder.path)
        let row = response("2026-11-18T12:00:00Z", thread: "archive", response: "sample", tokens: 7) + "\n"
        let configuration = CompressedLogConfiguration(maximumBytes: row.utf8.count, timeout: 0.4, executable: decoder)
        let cache = root.appendingPathComponent("cache.json")
        let history = TokenHistory(home: root, cacheURL: cache, calendar: calendar, compression: configuration)
        let first = archive.appendingPathComponent("a.jsonl.zst")
        func expectUnavailable(_ reader: TokenHistory) throws {
            do {
                _ = try reader.read(now: now)
                fatalError("An unreadable archive alone must produce an unavailable result")
            } catch TokenHistoryError.unavailable {}
        }
        func expectLaunches(_ expected: Int) throws {
            let launches = try String(contentsOf: decoder.appendingPathExtension("launches"), encoding: .utf8)
            precondition(launches.split(separator: "\n").count == expected, "Unexpected decoder launches: \(launches)")
        }
        for mode in ["read-stall", "exit-stall", "overflow", "failed"] {
            try (mode + "\n" + row).write(to: first, atomically: true, encoding: .utf8)
            let start = ProcessInfo.processInfo.systemUptime
            try expectUnavailable(history)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            precondition(elapsed < 3, "Decoder exceeded its deadline: \(elapsed)")
            let pidText = try String(contentsOf: decoder.appendingPathExtension("pid"), encoding: .utf8)
            guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                fatalError("Missing decoder process ID")
            }
            precondition(kill(pid, 0) == -1 && errno == ESRCH, "Decoder still running after \(mode)")
            print("Compressed history \(mode) returned in \(Int(elapsed * 1000)) ms, child reaped.")
            if mode != "overflow" { try expectUnavailable(history) }
        }
        try expectLaunches(6)
        // Remember a confirmed overflow even when there is no readable history to report.
        try ("copy\n" + row + "x").write(to: first, atomically: true, encoding: .utf8)
        try expectUnavailable(history)
        try expectUnavailable(history)
        let restarted = TokenHistory(home: root, cacheURL: cache, calendar: calendar, compression: configuration)
        try expectUnavailable(restarted)
        try expectLaunches(7)

        var higherLimit = configuration
        higherLimit.maximumBytes += 1
        let expanded = TokenHistory(home: root, cacheURL: cache, calendar: calendar, compression: higherLimit)
        try expect(expanded, now: now, all: 7, month: 7, week: 7, today: 7)
        try expectLaunches(8)

        // The first archive exceeds the output budget by one byte. The second fits exactly.
        try ("copy\n" + row + "x").write(to: first, atomically: true, encoding: .utf8)
        let second = archive.appendingPathComponent("b.jsonl.zst")
        try ("copy\n" + row).write(to: second, atomically: true, encoding: .utf8)
        let plain = archive.appendingPathComponent("c.jsonl")
        let known = response("2026-11-18T12:00:00Z", thread: "plain", response: "sample", tokens: 2) + "\n"
        try known.write(to: plain, atomically: true, encoding: .utf8)
        try expect(history, now: now, all: 2, month: 2, week: 2, today: 2, partial: true)
        try expect(history, now: now, all: 9, month: 9, week: 9, today: 9, partial: true)
        try expect(history, now: now, all: 9, month: 9, week: 9, today: 9, partial: true)
        try expectLaunches(10)
        try FileManager.default.removeItem(at: first)
        try expect(history, now: now, all: 9, month: 9, week: 9, today: 9)
        var cachedPaths: [String] = []
        let index = CodexHistoryCache(
            url: cache.appendingPathExtension("sqlite"), home: root.standardizedFileURL.path,
            maximumBytes: 128 * 1024 * 1024)
        index?.load { path, _ in cachedPaths.append(URL(fileURLWithPath: path).lastPathComponent) }
        precondition(!cachedPaths.contains(first.lastPathComponent) && cachedPaths.contains(second.lastPathComponent))
        // A failed decoder still charges its byte. Retry the interrupted second file with a fresh budget.
        try "failed\nx".write(to: first, atomically: true, encoding: .utf8)
        let revised = response("2026-11-18T12:00:00Z", thread: "archive", response: "sample", tokens: 8) + "\n"
        try ("copy\n" + revised).write(to: second, atomically: true, encoding: .utf8)
        try expect(history, now: now, all: 2, month: 2, week: 2, today: 2, partial: true)
        try expect(history, now: now, all: 10, month: 10, week: 10, today: 10, partial: true)
        try expectLaunches(13)
        try FileManager.default.removeItem(at: first)
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: plain, to: replacement.appendingPathComponent(plain.lastPathComponent))
        try ("copy\n" + revised).write(
            to: replacement.appendingPathComponent(second.lastPathComponent), atomically: true, encoding: .utf8)
        try ("rotate\n" + row).write(to: second, atomically: true, encoding: .utf8)
        try expect(history, now: now, all: 2, month: 2, week: 2, today: 2, partial: true)
        try expect(history, now: now, all: 10, month: 10, week: 10, today: 10)

        let retryRoot = root.appendingPathComponent("retry")
        let retrySessions = retryRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: retrySessions, withIntermediateDirectories: true)
        let rejected = retrySessions.appendingPathComponent("bad.jsonl.zst")
        try "failed\n".write(to: rejected, atomically: true, encoding: .utf8)
        let counter = decoder.appendingPathExtension("launches")
        let prior = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        func rejectedAt(_ date: Date) throws {
            let fresh = TokenHistory(
                home: retryRoot, cacheURL: retryRoot.appendingPathComponent("cache.json"),
                calendar: calendar, compression: configuration)
            do {
                _ = try fresh.read(now: date)
                fatalError("Expected decoder rejection")
            } catch TokenHistoryError.unavailable {}
        }
        try rejectedAt(now)
        try rejectedAt(now.addingTimeInterval(86_399))
        try expectLaunches(prior + 1)
        let later = now.addingTimeInterval(86_400)
        try rejectedAt(later)
        try expectLaunches(prior + 2)
        try append("\n# Synthetic decoder revision\n", to: decoder)
        try rejectedAt(later)
        try expectLaunches(prior + 3)
        try "failed\nnew revision".write(to: rejected, atomically: true, encoding: .utf8)
        try rejectedAt(later)
        try expectLaunches(prior + 4)
    }

    private static func compress(_ url: URL) throws -> Bool {
        guard
            let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-q", "-o", url.appendingPathExtension("zst").path, "--", url.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return true
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
