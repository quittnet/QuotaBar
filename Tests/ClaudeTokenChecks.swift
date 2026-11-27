import Darwin
import Foundation
import SQLite3

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
        try checkCacheRecovery(home: home, calendar: calendar, now: now)
        try checkTransientCacheFailure(home: home, calendar: calendar, now: now)
        try checkLockedCache(home: home, calendar: calendar, now: now)
        try checkLinkedProjects(home: home.appendingPathComponent("linked-projects"), calendar: calendar, now: now)
        try checkSpend(home: home.appendingPathComponent("spend"), calendar: calendar, now: now)
        try checkForkPrices(home: home.appendingPathComponent("fork-prices"), calendar: calendar, now: now)
        try checkIterationsAndRefusals(home: home.appendingPathComponent("iterations"), calendar: calendar, now: now)
        print("Claude Code token history checks passed.")
    }

    private static func checkLinkedProjects(home: URL, calendar: Calendar, now: Date) throws {
        let fm = FileManager.default
        let projects = home.appendingPathComponent("projects")
        let project = projects.appendingPathComponent("example")
        let outside = home.appendingPathComponent("outside")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let timestamp = "2026-11-18T07:00:00Z"
        try write([response(timestamp, id: "kept", output: 17)], to: project.appendingPathComponent("session.jsonl"))
        let outsideLog = outside.appendingPathComponent("ignored.jsonl")
        try write([response(timestamp, id: "ignored", output: 101)], to: outsideLog)
        try fm.createSymbolicLink(at: project.appendingPathComponent("ignored.jsonl"), withDestinationURL: outsideLog)
        try fm.createSymbolicLink(at: projects.appendingPathComponent("ignored-directory"), withDestinationURL: outside)

        var bytesRead = 0
        let cache = home.appendingPathComponent("history.sqlite")
        func reader() -> ClaudeTokenHistory {
            ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar) { bytesRead += $0 }
        }
        let directReader = reader()
        try expect(directReader, now: now, all: 18, month: 18, week: 18, today: 18)
        let direct = try directReader.read(now: now)
        bytesRead = 0
        let reused = try reader().read(now: now)
        precondition(reused == direct && bytesRead == 0, "Ordinary roots must reuse their saved checkpoints")

        let movedProjects = home.appendingPathComponent("relocated-projects")
        try fm.moveItem(at: projects, to: movedProjects)
        try fm.createSymbolicLink(atPath: projects.path, withDestinationPath: movedProjects.lastPathComponent)
        let linkedReader = reader()
        let linked = try linkedReader.read(now: now)
        precondition(linked == direct, "A linked projects root must match an ordinary root")
        bytesRead = 0
        let linkedCached = try reader().read(now: now)
        precondition(linkedCached == linked && bytesRead == 0, "Linked projects must reuse saved checkpoints")

        let replacement = home.appendingPathComponent("replacement-projects")
        let replacementProject = replacement.appendingPathComponent("example")
        try fm.createDirectory(at: replacementProject, withIntermediateDirectories: true)
        let replacementLog = replacementProject.appendingPathComponent("session.jsonl")
        try write([response(timestamp, id: "kept", output: 59)], to: replacementLog)
        try fm.removeItem(at: projects)
        try fm.createSymbolicLink(at: projects, withDestinationURL: replacement)
        try expect(linkedReader, now: now, all: 60, month: 60, week: 60, today: 60)
    }

    private static func checkSpend(home: URL, calendar: Calendar, now: Date) throws {
        let project = home.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("main.jsonl")
        let copy = project.appendingPathComponent("fork.jsonl")
        let model = "claude-sonnet-4-5"
        let today = "2026-11-18T06:00:00Z"
        let yesterday = "2026-11-18T04:00:00Z"
        let split =
            #"{"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":750,"ephemeral_1h_input_tokens":250}}"#
        let winner = response(today, id: "shared", input: 1000, output: 400, model: model, extraUsage: split)
        try write(
            [
                response(yesterday, id: "shared", input: 10, output: 9999, finished: false, model: model),
                winner,
                response(today, id: "shared", input: 0, output: 6000, model: model),
                response(today, id: "separate", input: 10, output: 20, model: model),
                response("2026-11-19T05:00:00Z", id: "separate", input: 20, output: 10, model: model),
                response("2026-11-19T05:00:00Z", id: "future", input: 999, output: 999, model: model),
            ], to: transcript)
        try write([winner], to: copy)
        let cache = home.appendingPathComponent("history.sqlite")
        var bytesRead = 0
        func reader() -> ClaudeTokenHistory {
            ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar, didReadBytes: { bytesRead += $0 })
        }
        let history = reader()
        let initial = try history.read(now: now)
        let sharedUSD = 0.0142125
        let separateUSD = 0.00033
        let expectedUSD = sharedUSD + separateUSD
        precondition(initial.yesterday == 5400 && initial.today == 30 && initial.partial)
        precondition(abs(initial.spend.yesterday.usd - sharedUSD) < 1e-12)
        precondition(abs(initial.spend.today.usd - separateUSD) < 1e-12)
        precondition(abs(initial.spend.allTime.usd - expectedUSD) < 1e-12)
        precondition(initial.spend.allTime.hasPricedUsage && !initial.spend.allTime.partial)
        bytesRead = 0
        let restart = try reader().read(now: now)
        precondition(restart == initial && bytesRead == 0)

        // The conflicting price becomes eligible tomorrow. The message keeps its earliest date.
        let tomorrow = try history.read(now: now.addingTimeInterval(86_400))
        precondition(tomorrow.yesterday == 30 && tomorrow.spend.yesterday.partial)
        precondition(!tomorrow.spend.yesterday.hasPricedUsage && tomorrow.spend.yesterday.usd == 0)

        let unsplit = #"{"cache_creation_input_tokens":400}"#
        let malformed = #"{"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":"invalid"}}"#
        try append(
            [
                response("2026-10-01T05:00:00Z", id: "unknown-model", output: 1),
                response("2026-10-30T05:00:00Z", id: "missing-ttl", output: 3, model: model, extraUsage: unsplit),
                response("2026-11-12T05:00:00Z", id: "bad-ttl", output: 5, model: model, extraUsage: malformed),
            ].joined(separator: "\n") + "\n", to: transcript)
        let mixed = try history.read(now: now)
        precondition(mixed.allTime == initial.allTime + 2 + 404 + 106)
        for period in [mixed.spend.allTime, mixed.spend.month, mixed.spend.week] {
            precondition(period.hasPricedUsage && period.partial && abs(period.usd - expectedUSD) < 1e-12)
        }
        precondition(!mixed.spend.today.partial && !mixed.spend.yesterday.partial)

        // An equally final, equal-count copy may fill in missing prices. A contradictory
        // breakdown for that same count makes this request unpriceable whichever file came first.
        let ties = project.appendingPathComponent("ties.jsonl")
        let priced = response(today, id: "same-count", input: 10, output: 20, model: model)
        try write([response(today, id: "same-count", input: 15, output: 15), priced], to: ties)
        let supplemented = try history.read(now: now)
        precondition(supplemented.today == mixed.today + 30 && !supplemented.spend.today.partial)
        precondition(abs(supplemented.spend.today.usd - 2 * separateUSD) < 1e-12)
        try append(response(today, id: "same-count", input: 20, output: 10, model: model) + "\n", to: ties)
        let conflicted = try history.read(now: now)
        precondition(conflicted.today == supplemented.today && conflicted.spend.today.partial)
        precondition(abs(conflicted.spend.today.usd - separateUSD) < 1e-12)

        // Reprice old rate tables and checkpoints parsed before per-step price reconciliation.
        for legacy in [
            "json_set(CAST(checkpoint AS TEXT), '$.pricingRevision', -1)",
            "json_remove(CAST(checkpoint AS TEXT), '$.usageRevision')",
        ] {
            var db: OpaquePointer?
            precondition(sqlite3_open(cache.path, &db) == SQLITE_OK)
            let stale = """
                UPDATE files SET checkpoint = CAST(\(legacy) AS BLOB);
                UPDATE samples SET usd = 987;
                """
            precondition(sqlite3_exec(db, stale, nil, nil, nil) == SQLITE_OK)
            precondition(sqlite3_close(db) == SQLITE_OK)
            bytesRead = 0
            let repriced = try reader().read(now: now)
            precondition(repriced == conflicted && bytesRead > 0)
            bytesRead = 0
            let warm = try reader().read(now: now)
            precondition(warm == conflicted && bytesRead == 0)
        }
    }

    private static func checkForkPrices(home: URL, calendar: Calendar, now: Date) throws {
        let project = home.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let parent = project.appendingPathComponent("main.jsonl")
        let fork = project.appendingPathComponent("fork.jsonl")
        let cache = home.appendingPathComponent("history.sqlite")
        let today = "2026-11-18T06:00:00Z"
        let model = "claude-sonnet-4-5"
        let iterations =
            #"{"iterations":[{"type":"message","input_tokens":30000,"output_tokens":500},{"type":"message","input_tokens":19500,"output_tokens":401}]}"#
        let plain = response(today, id: "shared", input: 49_500, output: 901, model: model)
        let detailed = response(today, id: "shared", input: 49_500, output: 901, model: model, extraUsage: iterations)
        let reader = ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar)
        try write([plain], to: parent)
        let initial = try reader.read(now: now)
        precondition(initial.today == 50_401 && abs(initial.spend.today.usd - 0.162015) < 1e-12)
        try write([detailed], to: fork)
        let copied = try reader.read(now: now)
        precondition(copied == initial)
        let restarted = try ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar).read(now: now)
        precondition(restarted == copied)

        // An actual five-nanodollar difference still makes a single request ambiguous.
        let cheap = "claude-haiku-5-5"
        let split =
            #"{"cache_read_input_tokens":2,"cache_creation_input_tokens":7,"cache_creation":{"ephemeral_5m_input_tokens":7}}"#
        try write([response(today, id: "small", input: 9, output: 0, model: cheap)], to: parent)
        try write([response(today, id: "small", input: 0, output: 0, model: cheap, extraUsage: split)], to: fork)
        let conflict = try reader.read(now: now)
        precondition(conflict.today == 9 && conflict.spend.today.partial && !conflict.spend.today.hasPricedUsage)
    }

    private static func checkIterationsAndRefusals(home: URL, calendar: Calendar, now: Date) throws {
        let projects = home.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("main.jsonl")
        let cache = home.appendingPathComponent("history.sqlite")
        let opus = "claude-opus-5-5"
        let fable = "claude-fable-5"
        let fallback = "claude-opus-4-8"

        func check(
            _ label: String, _ usage: [String: Any], model: String = "claude-opus-5-5",
            stop: String = "end_turn", metadata: [String: Any] = [:],
            tokens: Int64, usd: Double?, partial: Bool = false
        ) throws {
            var message = metadata
            message["id"] = label
            message["model"] = model
            message["stop_reason"] = stop
            message["usage"] = usage
            let row: [String: Any] = ["type": "assistant", "message": message, "timestamp": "2026-11-18T06:00:00Z"]
            // Two copies of the same complete response still represent one request.
            let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
            try (data + data).write(to: file, options: .atomic)
            for warm in [false, true] {
                var bytes = 0
                let reader = ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar) { bytes += $0 }
                let totals = try reader.read(now: now)
                let cost = totals.spend.today
                precondition(totals.allTime == tokens && totals.today == tokens && totals.partial == partial, label)
                precondition(cost.hasPricedUsage == (usd != nil) && cost.partial == (usd == nil), label)
                precondition(abs(cost.usd - (usd ?? 0)) < 1e-12 && (bytes == 0) == warm, label)
            }
        }

        let compact: [String: Any] = ["type": "compaction", "input_tokens": 180_000, "output_tokens": 3500]
        let reply: [String: Any] = ["type": "message", "input_tokens": 23_000, "output_tokens": 1000]
        try check(
            "threshold", ["input_tokens": 23_000, "output_tokens": 1000, "iterations": [compact, reply]],
            tokens: 207_500, usd: 0.902)
        let toolStep: [String: Any] = ["type": "message", "input_tokens": 3000, "output_tokens": 100]
        let smallCompaction: [String: Any] = ["type": "compaction", "input_tokens": 10_000, "output_tokens": 50]
        var aggregate: [String: Any] = [
            "input_tokens": 6000, "output_tokens": 200, "cache_read_input_tokens": 12_000,
            "iterations": [toolStep, smallCompaction, toolStep],
        ]
        try check("aggregate cache reads", aggregate, tokens: 28_250, usd: 0.0714)
        var aliasStep = toolStep
        aliasStep["model"] = "claude-sonnet-4-5"
        var snapshotStep = toolStep
        snapshotStep["model"] = "claude-sonnet-4-5-20250929"
        var aliases = aggregate
        aliases["iterations"] = [aliasStep, snapshotStep]
        try check("aggregate alias and snapshot", aliases, tokens: 18_200, usd: 0.0246)
        snapshotStep["model"] = "anthropic/claude-sonnet-4-5"
        aliases["iterations"] = [aliasStep, snapshotStep]
        try check("aggregate deployment prefix", aliases, tokens: 18_200, usd: nil)

        var fiveMinuteStep = toolStep
        fiveMinuteStep["cache_creation_input_tokens"] = 100
        fiveMinuteStep["cache_creation"] = ["ephemeral_5m_input_tokens": 100]
        var oneHourStep = toolStep
        oneHourStep["cache_creation_input_tokens"] = 200
        oneHourStep["cache_creation"] = ["ephemeral_1h_input_tokens": 200]
        var writes = aggregate
        writes["iterations"] = [fiveMinuteStep, oneHourStep]
        try check("aggregate reads with per-step write durations", writes, tokens: 18_500, usd: 0.0325)
        writes["cache_creation_input_tokens"] = 300
        writes["cache_creation"] = ["ephemeral_1h_input_tokens": 300]
        try check("contradictory aggregate write durations", writes, tokens: 18_500, usd: nil)
        fiveMinuteStep["cache_creation"] = ["ephemeral_5m_input_tokens": "unreadable"]
        writes["iterations"] = [fiveMinuteStep, oneHourStep]
        writes["cache_creation"] = ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200]
        try check("aggregate durations with an unreadable step split", writes, tokens: 18_500, usd: 0.0325)
        aggregate["cache_read_input_tokens"] = 100_000
        try check(
            "aggregate crosses possible price tier", aggregate, model: "claude-haiku-5-5", tokens: 116_250, usd: nil)
        var expensiveStep: [String: Any] = [
            "type": "message", "input_tokens": 100_000, "output_tokens": 100,
            "cache_read_input_tokens": 0,
        ]
        let smallStep: [String: Any] = ["type": "message", "input_tokens": 10, "output_tokens": 100]
        var oneMissing: [String: Any] = [
            "input_tokens": 100_010, "output_tokens": 200, "cache_read_input_tokens": 200,
            "iterations": [expensiveStep, smallStep],
        ]
        try check(
            "cache reads attributable to one step", oneMissing, model: "claude-haiku-5-5",
            tokens: 100_410, usd: 0.010103)
        expensiveStep["model"] = "claude-haiku-5-5"
        expensiveStep["cache_read_input_tokens"] = 100
        oneMissing["iterations"] = [smallStep, smallCompaction, expensiveStep]
        try check(
            "attributable cache reads across models and a compaction", oneMissing,
            tokens: 110_460, usd: 0.093315)
        expensiveStep["cache_creation_input_tokens"] = 10
        expensiveStep["cache_creation"] = ["ephemeral_5m_input_tokens": 10]
        oneMissing["iterations"] = [smallStep, expensiveStep]
        oneMissing["cache_creation_input_tokens"] = 10
        oneMissing["cache_creation"] = ["ephemeral_1h_input_tokens": 10]
        try check(
            "cache read allocation preserves conflicting write durations", oneMissing, tokens: 100_420,
            usd: nil)
        var first: [String: Any] = ["type": "message", "model": fable, "input_tokens": 20_000, "output_tokens": 100]
        let last: [String: Any] = [
            "type": "fallback_message", "model": fallback, "input_tokens": 20_000, "output_tokens": 500,
        ]
        func hops(_ first: [String: Any], _ last: [String: Any]) -> [String: Any] {
            ["input_tokens": 20_000, "output_tokens": last["output_tokens"]!, "iterations": [first, last]]
        }
        let boundary: [String: Any] = [
            "type": "fallback", "from": ["model": fable], "to": ["model": fallback],
            "trigger": ["type": "refusal", "category": NSNull()],
        ]
        let blocks: [String: Any] = ["content": [boundary, ["type": "text"]]]
        // A non-streaming handoff can drop partial text but retain the declined model's output count.
        try check("mid-stream", hops(first, last), model: fallback, metadata: blocks, tokens: 40_600, usd: 0.3175)
        var sparseLast = last
        sparseLast["model"] = nil
        try check(
            "streaming handoff model", hops(first, sparseLast), model: fable, metadata: blocks, tokens: 40_600,
            usd: 0.3175)
        sparseLast["type"] = nil
        var sparseFirst = first
        sparseFirst["model"] = nil
        try check(
            "handoff with sparse iterations", hops(sparseFirst, sparseLast), model: fallback, metadata: blocks,
            tokens: 40_600, usd: 0.3175)
        first["output_tokens"] = 0
        try check("free first hop", hops(first, last), model: fallback, metadata: blocks, tokens: 40_500, usd: 0.1125)
        try check("missing handoff", hops(first, last), model: fallback, tokens: 40_500, usd: nil)
        var cacheHop = first
        cacheHop["output_tokens"] = 100
        cacheHop["cache_creation_input_tokens"] = 150
        cacheHop["cache_creation"] = ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 50]
        var cacheReply = last
        cacheReply["cache_read_input_tokens"] = 300
        try check("per-model cache", hops(cacheHop, cacheReply), model: fallback, tokens: 41_050, usd: 0.3199)
        cacheHop["cache_creation"] = ["ephemeral_5m_input_tokens": "bad"]
        try check("invalid TTL", hops(cacheHop, cacheReply), model: fallback, tokens: 41_050, usd: nil)
        first["model"] = "unknown"
        first["output_tokens"] = 100
        try check("unknown earlier model", hops(first, last), model: fallback, tokens: 40_600, usd: nil)
        first["model"] = nil
        try check("missing earlier model", hops(first, last), model: fallback, tokens: 40_600, usd: nil)
        try check(
            "malformed iterations", ["input_tokens": 20_000, "output_tokens": 500, "iterations": [first, "bad"]],
            tokens: 20_500, usd: nil, partial: true)

        let refusal: [String: Any] = ["input_tokens": 50_000, "output_tokens": 0]
        for (category, cost): (Any, Double) in [
            (NSNull(), 0), ("cyber", 0), ("general_harms", 0),
            ("bio", 0.2), ("frontier_llm", 0.2), ("reasoning_extraction", 0.2),
        ] {
            try check(
                "refusal category " + String(describing: category), refusal, stop: "refusal",
                metadata: ["stop_details": ["category": category], "content": []], tokens: 50_000, usd: cost)
        }
        try check("missing category", refusal, stop: "refusal", metadata: ["content": []], tokens: 50_000, usd: nil)
        try check(
            "missing content", refusal, stop: "refusal", metadata: ["stop_details": ["category": NSNull()]],
            tokens: 50_000, usd: nil)
        try check(
            "partial refusal output", ["input_tokens": 50_000, "output_tokens": 10], model: opus, stop: "refusal",
            metadata: ["stop_details": ["category": NSNull()], "content": []], tokens: 50_010, usd: 0.2002)
        try check("ordinary zero output", refusal, tokens: 50_000, usd: 0.2)
    }

    private static func checkLockedCache(home: URL, calendar: Calendar, now: Date) throws {
        let cache = home.appendingPathComponent("healthy.sqlite")
        var bytesRead = 0
        func reader() -> ClaudeTokenHistory {
            ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar, didReadBytes: { bytesRead += $0 })
        }
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead > 0)
        bytesRead = 0

        let warm = reader()
        var writer: OpaquePointer?
        precondition(sqlite3_open(cache.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        precondition(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        do {
            _ = try warm.read(now: now)
            preconditionFailure("A busy index must defer the scan")
        } catch let error as ClaudeHistoryIndex.Failure where error.isContention {}
        precondition(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try expect(warm, now: now, all: 8, month: 8, week: 8, today: 8)
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "A temporary lock must not trigger another scan")

        try FileManager.default.removeItem(at: cache)
        try expect(warm, now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead > 0)
        bytesRead = 0
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "A rebuilt primary cache must be available after restart")

        let replacement = home.appendingPathComponent("replacement.sqlite")
        _ = try ClaudeHistoryIndex(url: replacement)
        precondition(rename(replacement.path, cache.path) == 0)
        try expect(warm, now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead > 0)
        bytesRead = 0
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "An atomically replaced index must be available after restart")
        precondition(!FileManager.default.fileExists(atPath: cache.appendingPathExtension("rebuilt").path))
    }

    private static func checkTransientCacheFailure(home: URL, calendar: Calendar, now: Date) throws {
        let cache = home.appendingPathComponent("transient.sqlite")
        var bytesRead = 0
        func reader() -> ClaudeTokenHistory {
            ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar, didReadBytes: { bytesRead += $0 })
        }
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        // Root can write a read-only file, so this stand-in failure needs an ordinary user.
        guard geteuid() != 0 else {
            try FileManager.default.removeItem(at: cache)
            return
        }
        // A read-only cache stands in for a full or failing disk. It must not be abandoned.
        precondition(chmod(cache.path, 0o400) == 0)
        let blocked = reader()
        bytesRead = 0
        try expect(blocked, now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead > 0, "A transient cache failure should count in memory")
        precondition(
            !FileManager.default.fileExists(atPath: cache.appendingPathExtension("rebuilt").path),
            "A transient cache failure must keep the main cache location")
        bytesRead = 0
        try expect(blocked, now: now.addingTimeInterval(60), all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "The in-memory index should be reused until the retry time")
        precondition(chmod(cache.path, 0o600) == 0)
        try expect(blocked, now: now.addingTimeInterval(16 * 60), all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "After the retry time the reader should return to the cached index")
        try FileManager.default.removeItem(at: cache)
    }

    private static func checkCacheRecovery(home: URL, calendar: Calendar, now: Date) throws {
        let cache = home.appendingPathComponent("damaged.sqlite")
        let damaged = Data("damaged cache".utf8)
        try damaged.write(to: cache)
        precondition(chmod(cache.path, 0o600) == 0)
        var bytesRead = 0
        func reader() -> ClaudeTokenHistory {
            ClaudeTokenHistory(home: home, cacheURL: cache, calendar: calendar, didReadBytes: { bytesRead += $0 })
        }
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead > 0)
        bytesRead = 0
        try expect(reader(), now: now, all: 8, month: 8, week: 8, today: 8)
        precondition(bytesRead == 0, "A damaged cache should only require one rebuild")
        let original = try Data(contentsOf: cache)
        precondition(original == damaged)
        let rebuilt = cache.appendingPathExtension("rebuilt")
        let content = try Data(contentsOf: rebuilt)
        for text in ["edited", "claude-model", "2026-11-18T07:00:00Z", home.path] {
            precondition(content.range(of: Data(text.utf8)) == nil, "Readable source data entered the token index")
        }
        var info = stat()
        precondition(stat(rebuilt.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    private static func expect(
        _ history: ClaudeTokenHistory, now: Date,
        all: Int64, month: Int64, week: Int64, yesterday: Int64 = 0, today: Int64, partial: Bool = false,
        retained: Bool = true,
        stats: Int64? = nil,
        line: UInt = #line
    ) throws {
        let actual = try history.read(now: now)
        let expected = TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: partial,
            hasRetainedUsage: retained,
            claudeStatsLifetime: stats, spend: actual.spend,
            peakDay: today > 0
                ? TokenPeakDay(date: ISO8601DateFormatter().date(from: "2026-11-18T05:00:00Z")!, tokens: today) : nil
        )
        // Legacy fixtures all use an unknown model. Stats-only totals have no priced request data.
        for (period, tokens) in [
            (actual.spend.allTime, all), (actual.spend.month, month), (actual.spend.week, week),
            (actual.spend.yesterday, yesterday), (actual.spend.today, today),
        ] {
            precondition(!period.hasPricedUsage && period.usd == 0 && period.partial == (tokens > 0))
        }
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
        model: String = "claude-model", extraUsage: String = "{}", content: String = ""
    ) -> String {
        let stop = finished ? "\"end_turn\"" : "null"
        let extra = extraUsage == "{}" ? "" : "," + extraUsage.dropFirst().dropLast()
        return
            #"{"parentUuid":"parent","isSidechain":false,"message":{"id":"\#(id)","model":"\#(model)","stop_reason":\#(stop),"content":"\#(content)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(extra)}},"type":"assistant","timestamp":"\#(date)"}"#
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
