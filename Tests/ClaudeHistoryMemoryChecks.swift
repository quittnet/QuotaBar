import Darwin
import Foundation

@main
struct ClaudeHistoryMemoryChecks {
    private enum Phase: String {
        case cold, restart, finalRestart
    }

    private enum Failure: Error {
        case worker(Phase, status: Int32)
    }

    private static let mebibyte = 1_024 * 1_024
    private static let memoryBudget = 64 * mebibyte
    private static let timestamp = "2026-11-18T05:30:00.000Z"

    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, let phase = Phase(rawValue: arguments[1]) {
            try verify(phase, home: URL(fileURLWithPath: arguments[2], isDirectory: true))
            return
        }
        precondition(arguments.count == 1)
        checkFileRevisions()
        try checkDailyFullCheck()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try prepare(home: home)

        // Fixture creation and earlier scans must not contribute to the cold worker's high-water mark.
        for phase in [Phase.cold, .restart, .finalRestart] {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: arguments[0])
            worker.arguments = [phase.rawValue, home.path]
            try worker.run()
            worker.waitUntilExit()
            guard worker.terminationReason == .exit, worker.terminationStatus == 0 else {
                throw Failure.worker(phase, status: worker.terminationStatus)
            }
        }
        print("Claude history memory and persistent restart checks passed.")
    }

    private static func checkFileRevisions() {
        func revision(_ size: Int64, _ modified: Int, inode: UInt64 = 1, birth: Int = 1) -> ClaudeTranscriptRevision {
            var info = stat()
            info.st_size = size
            info.st_mtimespec.tv_sec = modified
            info.st_ino = inode
            info.st_birthtimespec.tv_sec = birth
            return ClaudeTranscriptRevision(info)
        }
        let prior = revision(100, 1)
        let opened = revision(120, 3)
        precondition(opened.canReuseAfterGrowth(from: prior, observed: revision(115, 2)))
        precondition(opened.canReuseAfterGrowth(from: prior, observed: opened))
        for evidence in [
            revision(100, 2), revision(95, 2), revision(120, 2), revision(115, 2, inode: 2),
            revision(115, 2, birth: 2),
        ] {
            precondition(!opened.canReuseAfterGrowth(from: prior, observed: evidence))
        }
        print("Claude history: observed edits, truncation and identity changes invalidate the append checkpoint.")
    }

    /// An edit between the sample windows plus growth stays hidden until the daily full check.
    private static func checkDailyFullCheck() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = transcriptURL(home: home)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let filler = Data((#"{"type":"user","content":""# + String(repeating: "x", count: mebibyte) + "\"}\n").utf8)
        var fixture = response(id: "first", output: 1) + Data([10]) + filler
        fixture += response(id: "gap", output: 2) + Data([10]) + filler + response(id: "last", output: 4) + Data([10])
        try fixture.write(to: transcript)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var bytesRead = 0
        let history = ClaudeTokenHistory(
            home: home, cacheURL: home.appendingPathComponent("claude-history.sqlite"), calendar: calendar,
            didReadBytes: { bytesRead += $0 })
        let start = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        func read(after seconds: TimeInterval) throws -> Int64 {
            bytesRead = 0
            return try history.read(now: start.addingTimeInterval(seconds)).allTime
        }
        let total1 = try read(after: 0)
        precondition(total1 == 10)

        // Rewrite the middle row in place, then grow the file before QuotaBar observes it.
        let writer = try FileHandle(forUpdating: transcript)
        guard let edit = fixture.range(of: Data(#""output_tokens":2"#.utf8))?.lowerBound else {
            preconditionFailure("Fixture lacks the middle row.")
        }
        try writer.seek(toOffset: UInt64(edit))
        try writer.write(contentsOf: Data(#""output_tokens":9"#.utf8))
        try writer.close()
        let tail = response(id: "tail", output: 20) + Data([10])
        try append(tail, to: transcript)
        let size = try transcriptSize(home: home)
        let total2 = try read(after: 60)
        precondition(total2 == 31 && bytesRead <= 64 * 1024 + tail.count, "Gap edit was not sampled.")
        let total3 = try read(after: 120)
        precondition(total3 == 31 && bytesRead == 0)
        let total4 = try read(after: ClaudeTokenHistory.fullCheckInterval)
        precondition(total4 == 38 && bytesRead >= size)
        let rebuilt = bytesRead
        let total5 = try read(after: ClaudeTokenHistory.fullCheckInterval + 60)
        precondition(total5 == 38 && bytesRead == 0)
        try append(response(id: "later", output: 5) + Data([10]), to: transcript)
        let total6 = try read(after: ClaudeTokenHistory.fullCheckInterval + 120)
        precondition(total6 == 44 && bytesRead <= 128 * 1024)
        let total7 = try read(after: -3_600)
        precondition(total7 == 44 && bytesRead >= size, "A clock moved backward must force a full check.")
        print("Claude history gap edit: stale for one day, then corrected by a \(rebuilt)-byte full check.")
    }

    private static func prepare(home: URL) throws {
        let transcript = transcriptURL(home: home)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(FileManager.default.createFile(atPath: transcript.path, contents: nil))
        let stream = try FileHandle(forWritingTo: transcript)
        defer { try? stream.close() }
        let payload = String(repeating: "x", count: mebibyte)
        let ignored = Data((#"{"type":"user","content":"\#(payload)"}"# + "\n").utf8)
        try stream.write(contentsOf: response(id: "original", output: 10) + Data([10]))
        for _ in 0..<64 {
            try autoreleasepool { try stream.write(contentsOf: ignored) }
        }
    }

    private static func verify(_ phase: Phase, home: URL) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        var bytesRead = 0
        let history = ClaudeTokenHistory(
            home: home, cacheURL: home.appendingPathComponent("claude-history.sqlite"), calendar: calendar,
            didReadBytes: { bytesRead += $0 }
        )

        func expectTokens(_ total: Int64) throws {
            let actual = try history.read(now: now)
            var unpriced = TokenSpendTotals()
            unpriced.record(
                nil, tokens: total, date: now, now: now, days: TokenDayBoundaries(now: now, calendar: calendar))
            let expected = TokenTotals(
                allTime: total, month: total, week: total, yesterday: 0, today: total,
                partial: false, hasRetainedUsage: true, claudeStatsLifetime: nil, spend: unpriced,
                peakDay: TokenPeakDay(date: calendar.startOfDay(for: now), tokens: total)
            )
            precondition(actual == expected, "Expected \(expected), received \(actual).")
        }

        switch phase {
        case .cold:
            try expectTokens(11)
            let size = try transcriptSize(home: home)
            precondition(size > 64 * mebibyte && bytesRead == size, "Cold indexing must read each byte exactly once.")
            let peak = peakPhysicalFootprint()
            precondition(peak < memoryBudget, "Claude history cold scan reached \(peak) bytes of physical footprint.")
            print("Claude history cold worker: \(size)-byte fixture, \(peak)-byte peak physical footprint.")
        case .restart:
            try expectTokens(11)
            precondition(bytesRead == 0, "Restart reread \(bytesRead) transcript bytes.")
            print("Claude history unchanged restart: \(bytesRead) transcript bytes.")
            let transcript = transcriptURL(home: home)
            let row = response(id: "appended", output: 20) + Data([10])
            try append(row, to: transcript)
            try expectTokens(32)
            let budget = 64 * 1024 + row.count
            let count = "Claude history append: read \(bytesRead) bytes for a \(row.count)-byte row (budget \(budget))."
            FileHandle.standardOutput.write(Data((count + "\n").utf8))
            precondition(bytesRead <= budget, count)

            bytesRead = 0
            let writer = try FileHandle(forWritingTo: transcript)
            try writer.write(contentsOf: response(id: "original", output: 40))
            try writer.close()
            let pending = Data(#"{"type":"user"}"#.utf8)
            try append(pending, to: transcript)
            try expectTokens(62)
            let size = try transcriptSize(home: home)
            precondition(bytesRead >= size, "Earlier rewrite plus growth reused stale totals.")
            print("Claude history earlier rewrite plus growth rescanned \(bytesRead) bytes.")
            bytesRead = 0
            try append(Data([10]), to: transcript)
            try expectTokens(62)
            precondition(
                bytesRead <= 64 * 1024 + pending.count + 1, "Completing a fragment exceeded the append budget.")
            try (response(id: "replacement", output: 30) + Data([10])).write(to: transcript, options: .atomic)
            try expectTokens(31)
        case .finalRestart:
            try expectTokens(31)
            precondition(bytesRead == 0, "Restart after replacement reread \(bytesRead) transcript bytes.")
            let transcript = transcriptURL(home: home)
            try append(Data(repeating: 32, count: 17 * mebibyte), to: transcript)
            try expectTokens(31)
            bytesRead = 0
            try append(Data([32]), to: transcript)
            try expectTokens(31)
            precondition(bytesRead <= 64 * 1024 + 1)
            bytesRead = 0
            let tail = Data([10]) + response(id: "after-oversized", output: 5) + Data([10])
            try append(tail, to: transcript)
            let recovered = try history.read(now: now)
            precondition(recovered.allTime == 37 && recovered.partial && bytesRead <= 64 * 1024 + tail.count)
            print("Claude history: 17 MiB unfinished row skipped on growth, following complete row counted.")
        }
    }

    private static func transcriptSize(home: URL) throws -> Int {
        let properties = try transcriptURL(home: home).resourceValues(forKeys: [.fileSizeKey])
        guard let size = properties.fileSize else { throw CocoaError(.fileReadUnknown) }
        return size
    }

    private static func transcriptURL(home: URL) -> URL {
        home.appendingPathComponent("projects/example/transcript.jsonl")
    }

    private static func response(id: String, output: Int64) -> Data {
        Data(
            #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"id":"\#(id)","model":"claude-test","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
                .utf8
        )
    }

    private static func append(_ data: Data, to transcript: URL) throws {
        let stream = try FileHandle(forWritingTo: transcript)
        defer { try? stream.close() }
        try stream.seekToEnd()
        try stream.write(contentsOf: data)
    }

    private static func peakPhysicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { info in
            info.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        precondition(info.ledger_phys_footprint_peak > 0)
        return info.ledger_phys_footprint_peak
    }
}
