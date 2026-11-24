import Foundation

@main
struct DataStressChecks {
    static func main() throws {
        let started = Date()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try quotaReadings(now: now)
        try tokenHistories()
        print(
            String(
                format:
                    "Data stress passed in %.2f seconds: 4,000 provider reports, 8,192 token records, duplicate files, split appends, restart and date ranges.",
                Date().timeIntervalSince(started)))
    }

    private static func quotaReadings(now: Date) throws {
        let decoder = JSONDecoder()
        for index in 0..<2_000 {
            let session = Double((index * 37) % 10_001) / 100
            let week = Double((index * 91) % 10_001) / 100
            let codexJSON = """
                {"rateLimits":{"primary":{"usedPercent":\(session),"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":\(week),"windowDurationMins":10080,"resetsAt":1800086400}}}
                """
            let codex = try decoder.decode(RateLimitsResponse.self, from: Data(codexJSON.utf8)).reading(fetchedAt: now)
            let reset = index % 2 == 0 ? ",\"resets_at\":null" : ""
            let claudeJSON = """
                {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":\(session)\(reset)},"seven_day":{"utilization":\(week)\(reset)}}}
                """
            let claude = try ClaudeUsageClient.parse(Data(claudeJSON.utf8), now: now)
            for (provider, reading) in [(UsageProvider.codex, codex), (.claude, claude)] {
                let peak = max(session, week)
                for mode in PercentageMode.allCases {
                    let display = QuotaDisplay(
                        reading: reading, now: now, failed: false, refreshing: false,
                        provider: provider, percentageMode: mode)
                    precondition(display.hasCurrentPercentage && display.title != "–%")
                    precondition(display.limitingWindow?.used == peak)
                    let expected = mode == .used ? peak : max(0, 100 - peak)
                    precondition(display.percentage(for: display.limitingWindow!) == expected)
                    let stale = QuotaDisplay(
                        reading: reading, now: now.addingTimeInterval(QuotaDisplay.maximumAge),
                        failed: false, refreshing: false, provider: provider, percentageMode: mode)
                    precondition(!stale.hasCurrentPercentage && stale.title == "–%")
                    let failed = QuotaDisplay(
                        reading: reading, now: now, failed: true, refreshing: false,
                        provider: provider, percentageMode: mode)
                    precondition(!failed.hasCurrentPercentage && failed.title == "–%")
                }
            }
            if index % 20 == 0 {
                for invalid in ["true", "null", "-1", "\"37\"", "1e999"] {
                    let bad = codexJSON.replacingOccurrences(
                        of: "\"usedPercent\":\(session)", with: "\"usedPercent\":\(invalid)")
                    do {
                        _ = try decoder.decode(RateLimitsResponse.self, from: Data(bad.utf8)).reading(fetchedAt: now)
                        preconditionFailure("Malformed supplied Codex window was accepted")
                    } catch {}
                }
                for invalid in ["true", "null", "-1", "101", "\"37\""] {
                    let bad = claudeJSON.replacingOccurrences(
                        of: "\"utilization\":\(session)", with: "\"utilization\":\(invalid)")
                    do {
                        _ = try ClaudeUsageClient.parse(Data(bad.utf8), now: now)
                        preconditionFailure("Malformed supplied Claude window was accepted")
                    } catch ClaudeUsageClient.Failure.invalidResponse {}
                }
            }
        }
    }

    private struct Ledger {
        let todayStart: Date
        let calendar: Calendar
        var days: [Int: Int64] = [:]
        var all: Int64 = 0
        var month: Int64 = 0
        var week: Int64 = 0
        var yesterday: Int64 = 0
        var today: Int64 = 0

        mutating func add(_ count: Int64, age: Int) {
            days[age, default: 0] += count
            all += count
            if age < 30 { month += count }
            if age < 7 { week += count }
            if age == 1 { yesterday += count }
            if age == 0 { today += count }
        }

        var totals: TokenTotals {
            // Both generators omit priceable model usage. Every nonempty period must disclose that.
            func unpriced(_ count: Int64) -> TokenSpendAmount {
                var amount = TokenSpendAmount()
                if count > 0 { amount.add(nil) }
                return amount
            }
            let peak = days.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }.map {
                TokenPeakDay(date: calendar.date(byAdding: .day, value: -$0.key, to: todayStart)!, tokens: $0.value)
            }
            return TokenTotals(
                allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: false,
                spend: TokenSpendTotals(
                    allTime: unpriced(all), month: unpriced(month), week: unpriced(week),
                    yesterday: unpriced(yesterday), today: unpriced(today)), peakDay: peak)
        }
    }

    private static func tokenHistories() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("quotabar-data-stress-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T17:00:00Z")!
        let codexRoot = root.appendingPathComponent("codex")
        let sessions = codexRoot.appendingPathComponent("sessions")
        let archive = codexRoot.appendingPathComponent("archived_sessions")
        let claudeRoot = root.appendingPathComponent("claude")
        let projects = claudeRoot.appendingPathComponent("projects/stress")
        for directory in [sessions, archive, projects] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let cache = root.appendingPathComponent("tokens.json")
        let codex = TokenHistory(home: codexRoot, cacheURL: cache, calendar: calendar)
        let claude = ClaudeTokenHistory(home: claudeRoot, calendar: calendar)
        let formatter = ISO8601DateFormatter()
        var expected = Ledger(todayStart: calendar.startOfDay(for: now), calendar: calendar)
        for fileIndex in 0..<64 {
            var codexRows = [#"{"type":"session_meta","payload":{"id":"thread-\#(fileIndex)"}}"#]
            var claudeRows: [String] = []
            for rowIndex in 0..<64 {
                let id = fileIndex * 64 + rowIndex
                let age = id % 45
                let tokens = Int64(id % 499 + 1)
                let date = calendar.date(byAdding: .day, value: -age, to: now)!
                let timestamp = formatter.string(from: date)
                codexRows.append(codexRow(timestamp, id: id, thread: fileIndex, tokens: tokens))
                claudeRows.append(claudeRow(timestamp, id: id, tokens: tokens))
                expected.add(tokens, age: age)
            }
            try write(codexRows, to: sessions.appendingPathComponent("\(fileIndex).jsonl"))
            try write(claudeRows, to: projects.appendingPathComponent("\(fileIndex).jsonl"))
        }
        try expect(codex, claude, now: now, expected: expected)
        for index in 0..<64 {
            try files.copyItem(
                at: sessions.appendingPathComponent("\(index).jsonl"),
                to: archive.appendingPathComponent("\(index).jsonl"))
            try files.copyItem(
                at: projects.appendingPathComponent("\(index).jsonl"),
                to: projects.appendingPathComponent("copy-\(index).jsonl"))
        }
        try expect(codex, claude, now: now, expected: expected)
        let codexAppend = sessions.appendingPathComponent("append.jsonl")
        let claudeAppend = projects.appendingPathComponent("append.jsonl")
        try write([#"{"type":"session_meta","payload":{"id":"thread-999"}}"#], to: codexAppend)
        try Data().write(to: claudeAppend)
        for index in 0..<40 {
            let id = 10_000 + index
            let age = index % 45
            let count = Int64(index + 1)
            let timestamp = formatter.string(from: calendar.date(byAdding: .day, value: -age, to: now)!)
            try append(codexRow(timestamp, id: id, thread: 999, tokens: count), to: codexAppend)
            try append(claudeRow(timestamp, id: id, tokens: count), to: claudeAppend)
            try expect(codex, claude, now: now, expected: expected)
            try append("\n", to: codexAppend)
            try append("\n", to: claudeAppend)
            expected.add(count, age: age)
            try expect(codex, claude, now: now, expected: expected)
        }
        let restarted = TokenHistory(home: codexRoot, cacheURL: cache, calendar: calendar)
        try expect(restarted, ClaudeTokenHistory(home: claudeRoot, calendar: calendar), now: now, expected: expected)
        for index in 0..<64 {
            try files.removeItem(at: sessions.appendingPathComponent("\(index).jsonl"))
            try files.removeItem(at: projects.appendingPathComponent("copy-\(index).jsonl"))
        }
        try expect(restarted, claude, now: now, expected: expected)
        // Two equal records outside every rolling period choose the older local date.
        // A later append on the newer day must replace the record immediately.
        for (index, age, tokens) in [(0, 90, Int64(100_000)), (1, 100, 100_000), (2, 90, 1)] {
            let timestamp = formatter.string(from: calendar.date(byAdding: .day, value: -age, to: now)!)
            try append(codexRow(timestamp, id: 20_000 + index, thread: 999, tokens: tokens) + "\n", to: codexAppend)
            try append(claudeRow(timestamp, id: 20_000 + index, tokens: tokens) + "\n", to: claudeAppend)
            expected.add(tokens, age: age)
            try expect(restarted, claude, now: now, expected: expected)
        }
        let older = calendar.date(byAdding: .day, value: -100, to: now)!
        let timestamp = formatter.string(from: older)
        try append(codexRow(timestamp, id: 30_000, thread: 999, tokens: .max) + "\n", to: codexAppend)
        try append(claudeRow(timestamp, id: 30_000, tokens: .max) + "\n", to: claudeAppend)
        for totals in [try restarted.read(now: now), try claude.read(now: now)] {
            precondition(totals.partial && totals.allTime == .max)
            precondition(totals.peakDay == TokenPeakDay(date: calendar.startOfDay(for: older), tokens: .max))
        }
        let cached = try Data(contentsOf: cache.appendingPathExtension("sqlite"))
        precondition(cached.starts(with: "SQLite format 3".utf8))
        precondition(cached.range(of: Data("PRIVATE_STRESS_TEXT".utf8)) == nil)
    }

    private static func expect(_ codex: TokenHistory, _ claude: ClaudeTokenHistory, now: Date, expected: Ledger) throws
    {
        let codexTotals = try codex.read(now: now)
        let claudeTotals = try claude.read(now: now)
        precondition(codexTotals == expected.totals, "Codex totals differed from the independent ledger")
        precondition(
            claudeTotals == expected.totals, "Claude totals \(claudeTotals) differed from ledger \(expected.totals)")
    }

    private static func codexRow(_ timestamp: String, id: Int, thread: Int, tokens: Int64) -> String {
        #"{"timestamp":"\#(timestamp)","type":"token_usage_record","payload":{"thread_id":"thread-\#(thread)","response_id":"response-\#(id)","usage":{"total_tokens":\#(tokens)}}}"#
    }

    private static func claudeRow(_ timestamp: String, id: Int, tokens: Int64) -> String {
        #"{"timestamp":"\#(timestamp)","type":"assistant","message":{"id":"message-\#(id)","model":"claude-test","stop_reason":"end_turn","content":"PRIVATE_STRESS_TEXT","usage":{"input_tokens":1,"output_tokens":\#(tokens - 1)}}}"#
    }

    private static func write(_ rows: [String], to file: URL) throws {
        try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func append(_ text: String, to file: URL) throws {
        let stream = try FileHandle(forWritingTo: file)
        defer { try? stream.close() }
        try stream.seekToEnd()
        try stream.write(contentsOf: Data(text.utf8))
    }
}
