import Foundation

@main
struct TokenChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
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
                counter("2026-11-18T05:00:00Z", cumulative: 78, last: 15),
                counter("2026-11-18T05:01:00Z", cumulative: 78, last: 15),
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
        let cacheText = try String(contentsOf: cache, encoding: .utf8)
        precondition(!cacheText.contains("PRIVATE_FIXTURE_PROMPT"))

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
        try Data("corrupt".utf8).write(to: cache)
        let recovered = TokenHistory(home: root, cacheURL: cache, calendar: calendar)
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
