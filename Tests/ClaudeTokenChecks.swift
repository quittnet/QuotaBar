import Darwin
import Foundation

@main
struct ClaudeTokenChecks {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        let history = ClaudeTokenHistory(home: home, calendar: calendar)
        try expectUnavailable(history, now: now)

        let statsCache = home.appendingPathComponent("stats-cache.json")
        let statsFixture = #"""
            {
                "version":5,
                "dailyModelTokensVersion":5,
                "lastComputedDate":"2026-11-18",
                "dailyModelTokens":[{"date":"2026-11-18","tokensByModel":{"claude-model":1000}}],
                "dailyActivity":[{"date":"2026-11-18","messageCount":1000,"toolCallCount":1000}],
                "modelUsage":{
                    "claude-model":{
                        "inputTokens":20,"outputTokens":2,
                        "cacheCreationInputTokens":100,"cacheReadInputTokens":900
                    },
                    "older-model":{
                        "inputTokens":1,"outputTokens":2,
                        "cacheCreationInputTokens":3,"cacheReadInputTokens":4,"costUSD":0.5
                    }
                }
            }
            """#
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try statsFixture.write(to: statsCache, atomically: true, encoding: .utf8)
        try expect(history, now: now, all: 0, month: 0, week: 0, today: 0, partial: true, retained: false, stats: 1032)

        let project = home.appendingPathComponent("projects/example")
        let agents = project.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try expect(history, now: now, all: 0, month: 0, week: 0, today: 0, retained: false, stats: 1032)

        let parent = project.appendingPathComponent("session.jsonl")
        let initial = [
            response("2026-10-20T03:59:59Z", id: "before-month", output: 9),
            response("2026-10-20T04:00:00Z", id: "month-start", output: 10),
            response("2026-11-12T04:59:59Z", id: "before-week", output: 11),
            response("2026-11-12T05:00:00Z", id: "week-start", output: 12),
            response("2026-11-18T04:59:59.999Z", id: "stream", output: 1, finished: false),
            response("2026-11-18T05:00:00Z", id: "stream", output: 13),
            response("2026-11-18T05:00:01Z", id: "stream", output: 100, finished: false),
            response("2026-11-18T05:00:00Z", id: "today-start", output: 14),
            response("2026-11-18T15:00:01Z", id: "future", output: 1_000),
            response("2026-11-18T15:00:01Z", id: "today-start", output: 1_000),
            #"{"type":"assistant","message":{"model":"<synthetic>"}}"#,
            #"{"type":"api-request-blob","message":{"role":"assistant","usage":{"input_tokens":1000}}}"#,
            #"{"type":"user","content":""# + String(repeating: "content ", count: 100_000) + #""}"#,
        ]
        try write(initial, to: parent)
        // The cache includes overlapping days, but carries a separate lifetime total.
        try expect(history, now: now, all: 75, month: 65, week: 42, yesterday: 14, today: 15, stats: 1032)
        for invalid in [
            "corrupt",
            statsFixture.replacingOccurrences(of: #""version":5"#, with: #""version":6"#),
            statsFixture.replacingOccurrences(of: #""cacheReadInputTokens":900"#, with: #""cacheReadInputTokens":-1"#),
            statsFixture.replacingOccurrences(
                of: #""cacheReadInputTokens":900"#, with: #""cacheReadInputTokens":1e999"#),
            statsFixture.replacingOccurrences(
                of: #""cacheReadInputTokens":900"#, with: "\"cacheReadInputTokens\":\(Int64.max)"),
            statsFixture.replacingOccurrences(of: #","cacheReadInputTokens":900"#, with: ""),
        ] {
            try invalid.write(to: statsCache, atomically: true, encoding: .utf8)
            try expect(history, now: now, all: 75, month: 65, week: 42, yesterday: 14, today: 15)
        }
        try FileManager.default.removeItem(at: statsCache)
        try expect(history, now: now, all: 75, month: 65, week: 42, yesterday: 14, today: 15)

        let agent = agents.appendingPathComponent("agent-example.jsonl")
        let cached =
            #"{"cache_read_input_tokens":24,"cache_creation_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":3},"iterations":[{"input_tokens":2,"output_tokens":6,"cache_read_input_tokens":24,"cache_creation_input_tokens":3}]}"#
        let withCache = response("2026-11-18T05:10:00Z", id: "subagent", input: 2, output: 6, extraUsage: cached)
        try write([withCache], to: agent)

        let fork = project.appendingPathComponent("fork.jsonl")
        try write(
            [
                response("2026-11-18T05:30:00Z", id: "before-month", output: 9),
                response("2026-11-18T05:30:01Z", id: "before-month", output: 9),
                response("2026-11-18T05:30:02Z", id: "fork-only", output: 15),
                withCache,
            ], to: fork)
        try expect(history, now: now, all: 126, month: 116, week: 93, yesterday: 14, today: 66)

        let outside = home.appendingPathComponent("outside.jsonl")
        try write([response("2026-11-18T05:30:00Z", id: "outside", output: 900)], to: outside)
        let alias = project.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        try expect(history, now: now, all: 126, month: 116, week: 93, yesterday: 14, today: 66)

        // A record spanning several chunks stays pending until Claude appends the newline.
        let splitRow = response(
            "2026-11-18T05:45:00Z", id: "appended", output: 16,
            content: String(repeating: "content ", count: 50_000))
        try append(splitRow, to: parent)
        try expect(history, now: now, all: 126, month: 116, week: 93, yesterday: 14, today: 66)
        try append("\n", to: parent)
        try expect(history, now: now, all: 143, month: 133, week: 110, yesterday: 14, today: 83)

        // A failed or malformed entry yields partial data when other transcripts remain readable.
        try append("{\"type\":\"assistant\",\"message\":{}}\n", to: parent)
        try append(response("missing-date", id: "undated", output: 17) + "\n", to: parent)
        try append(response("2026-11-18T05:45:00Z", id: "invalid-count", output: -5) + "\n", to: parent)
        try expect(history, now: now, all: 161, month: 133, week: 110, yesterday: 14, today: 83, partial: true)

        // An in-place rewrite that grows the file still invalidates the previous append cursor.
        let replacement = response("2026-11-18T05:50:00Z", id: "replacement", output: 18)
        try write(
            [replacement, #"{"type":"user","content":""# + String(repeating: "x", count: 1_300_000) + #""}"#],
            to: parent)
        try expect(history, now: now, all: 80, month: 80, week: 80, today: 80)
        try FileManager.default.removeItem(at: fork)
        try expect(history, now: now, all: 54, month: 54, week: 54, today: 54)

        if geteuid() != 0 {
            precondition(chmod(agent.path, 0) == 0)
            try expect(history, now: now, all: 19, month: 19, week: 19, today: 19, partial: true)
            precondition(chmod(parent.path, 0) == 0)
            try expectUnavailable(history, now: now)
            precondition(chmod(parent.path, 0o600) == 0)
            precondition(chmod(agent.path, 0o600) == 0)
            try expect(history, now: now, all: 54, month: 54, week: 54, today: 54)
        }
        try append("broken json\n", to: parent)
        try expect(history, now: now, all: 54, month: 54, week: 54, today: 54, partial: true)
        try FileManager.default.removeItem(at: agent)
        try write([#"{"type":"assistant","message":{}}"#], to: parent)
        try expect(history, now: now, all: 0, month: 0, week: 0, today: 0, partial: true, retained: false)
        let timestamp = "2026-11-18T07:00:00Z"
        try write([response(timestamp, id: "zero", input: 0, output: 0)], to: parent)
        try expect(history, now: now, all: 0, month: 0, week: 0, today: 0)
        try write([response(timestamp, id: "streaming", output: 5, finished: false)], to: parent)
        try expect(history, now: now, all: 6, month: 6, week: 6, today: 6, partial: true)
        try append(response(timestamp, id: "streaming", output: 8) + "\n", to: parent)
        try expect(history, now: now, all: 9, month: 9, week: 9, today: 9)
        try append(response(timestamp, id: "streaming", output: 12) + "\n", to: parent)
        try expect(history, now: now, all: 9, month: 9, week: 9, today: 9, partial: true)
        let padding = #"{"type":"user","content":""# + String(repeating: "x", count: 2048) + #""}"#
        let oldRow = response(timestamp, id: "edited", output: 4)
        let newRow = response(timestamp, id: "edited", output: 7)
        try write([padding, oldRow, padding, padding, padding, padding], to: parent)
        try expect(history, now: now, all: 5, month: 5, week: 5, today: 5)
        let edit = try FileHandle(forWritingTo: parent)
        try edit.seek(toOffset: UInt64(padding.utf8.count + 1))
        try edit.write(contentsOf: Data(newRow.utf8))
        try edit.close()
        try append(padding + "\n", to: parent)
        try expect(history, now: now, all: 8, month: 8, week: 8, today: 8)
        print("Claude Code token history checks passed.")
    }

    private static func expect(
        _ history: ClaudeTokenHistory, now: Date,
        all: Int64, month: Int64, week: Int64, yesterday: Int64 = 0, today: Int64, partial: Bool = false,
        retained: Bool = true,
        stats: Int64? = nil,
        line: UInt = #line
    ) throws {
        let expected = TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: partial,
            hasRetainedUsage: retained,
            claudeStatsLifetime: stats
        )
        let actual = try history.read(now: now)
        precondition(actual == expected, "Line \(line), expected \(expected) and received \(actual)")
    }

    private static func expectUnavailable(_ history: ClaudeTokenHistory, now: Date) throws {
        do {
            _ = try history.read(now: now)
            fatalError("An unavailable transcript directory should surface an error")
        } catch ClaudeTokenHistoryError.unavailable {}
    }

    private static func response(
        _ date: String, id: String, input: Int64 = 1, output: Int64, finished: Bool = true,
        extraUsage: String = "{}", content: String = ""
    ) -> String {
        let stop = finished ? "\"end_turn\"" : "null"
        let extra = extraUsage == "{}" ? "" : "," + extraUsage.dropFirst().dropLast()
        return
            #"{"parentUuid":"parent","isSidechain":false,"message":{"id":"\#(id)","model":"claude-model","stop_reason":\#(stop),"content":"\#(content)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(extra)}},"type":"assistant","timestamp":"\#(date)"}"#
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
