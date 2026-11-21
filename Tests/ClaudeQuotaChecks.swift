import Darwin
import Foundation

@main
struct ClaudeQuotaChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("quota.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let boot = UUID()
        func capture(_ payload: String, after seconds: Double = 0) throws {
            try ClaudeQuotaSource.capture(
                statusLine: Data(payload.utf8), file: file, order: nil,
                now: start.addingTimeInterval(seconds), currentDate: { start.addingTimeInterval(1_000) })
        }
        func reading(after seconds: Double = 0) -> QuotaReading? {
            try! ClaudeQuotaSource.read(file: file, now: start.addingTimeInterval(seconds))
        }
        func checkReadFailure(_ url: URL) {
            do {
                _ = try ClaudeQuotaSource.read(file: url, now: start)
                preconditionFailure("Expected an unreadable Claude cache")
            } catch {
                precondition(error.localizedDescription.contains("saved Claude limits"))
            }
        }

        let both = """
            {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800000100},
            "seven_day":{"used_percentage":100,"resets_at":1800000600}},
            "session_name":"private input","workspace":{"current_dir":"private input"}}
            """
        precondition(reading() == nil)
        try capture(#"{"context_window":{"remaining_percentage":72}}"#)
        precondition(reading() == nil)
        try capture(both)
        let first = reading()
        precondition(first?.windows.map(\.minutes) == [300, 10_080])
        precondition(first?.windows.map(\.remaining) == [76.5, 0])
        precondition(first?.windows.first?.resetsAt == start.addingTimeInterval(100))
        precondition(first?.resetCredits == nil)
        let saved = try String(contentsOf: file, encoding: .utf8)
        precondition(!saved.contains("private input") && !saved.contains("session_name"))
        var legacy = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: Any]
        legacy.removeValue(forKey: "recentSessions")
        legacy.removeValue(forKey: "lastRecordedAt")
        legacy.removeValue(forKey: "order")
        let persistedLimits = legacy["limits"] as! [String: Any]
        let persistedShort = persistedLimits["five_hour"] as! [String: Any]
        precondition(
            persistedShort["used_percentage"] as? Double == 23.5 && persistedShort["resets_at"] as? Int == 1_800_000_100
        )
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        precondition(reading()?.windows == first?.windows)
        try capture(both, after: 20)
        try capture(#"{"rate_limits":{}}"#, after: 25)
        precondition(reading(after: 25) == nil)

        let updated =
            #"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1800000100},"seven_day":{"used_percentage":100,"resets_at":1800000600}}}"#
        try capture(updated, after: 32)
        try capture(both, after: 31)
        precondition(reading(after: 35)?.windows.first?.remaining == 75)
        precondition(reading(after: 35)?.fetchedAt == start.addingTimeInterval(32))
        precondition(reading(after: 100)?.windows.map(\.minutes) == [300, 10_080])
        try capture(#"{"rate_limits":{"seven_day":{"used_percentage":100,"resets_at":1800000600}}}"#, after: 110)
        precondition(reading(after: 110)?.fetchedAt == start.addingTimeInterval(32))
        precondition(reading(after: 110)?.windows.map(\.minutes) == [10_080])
        precondition(reading(after: 600) == nil)

        try capture(
            #"{"rate_limits":{"five_hour":{"used_percentage":true,"resets_at":1800000700},"seven_day":{"used_percentage":0,"resets_at":1800000900}}}"#,
            after: 610)
        precondition(reading(after: 610) == nil)
        let partial = #"{"rate_limits":{"five_hour":null,"seven_day":{"used_percentage":0,"resets_at":1800000900}}}"#
        try capture(partial, after: 611)
        precondition(reading(after: 611)?.windows.map(\.remaining) == [100])
        try capture(#"{"session_id":"start-without-usage"}"#, after: 612)
        precondition(reading(after: 612) == nil)
        try capture(partial, after: 613)
        try capture(#"{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1800000050}}}"#, after: 614)
        precondition(reading(after: 614) == nil)
        for invalid in ["-0.1", "100.1", "null", #""24""#] {
            try capture(
                "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(invalid),\"resets_at\":1800000800}}}",
                after: 620)
        }
        try capture(#"{"rate_limits":{"five_hour":{"used_percentage":41,"resets_at":1800000800000}}}"#, after: 620)
        precondition(reading(after: 625) == nil)
        try Data("corrupt cache".utf8).write(to: file)
        checkReadFailure(file)
        checkReadFailure(directory)
        let linked = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        checkReadFailure(linked)
        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(count: 1024 * 1024 + 1).write(to: oversized)
        checkReadFailure(oversized)
        let fifo = directory.appendingPathComponent("pipe.json")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        checkReadFailure(fifo)
        try capture(both)
        precondition(reading()?.windows.count == 2)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let payload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(index),\"resets_at\":1800001000}}}"
            try! ClaudeQuotaSource.capture(
                statusLine: Data(payload.utf8), file: file, order: .init(boot: boot, ticks: UInt64(index + 1)),
                now: start.addingTimeInterval(Double(index + 1)), currentDate: { start.addingTimeInterval(32) })
        }
        precondition(reading(after: 32)?.fetchedAt == start.addingTimeInterval(32))
        precondition(reading(after: 32)?.windows.map(\.remaining) == [69])

        func session(_ id: String, _ used: Int, includeShort: Bool = true) -> String {
            let short = includeShort ? #""five_hour":{"used_percentage":12,"resets_at":1800000050},"# : ""
            return """
                {"session_id":"\(id)","rate_limits":{\(short)"seven_day":{"used_percentage":\(used),"resets_at":1800100000}}}
                """
        }
        try capture(session("private-terminal-a", 10), after: 40)
        try capture(session("private-terminal-b", 30), after: 41)
        try capture(session("private-terminal-a", 10), after: 42)
        // Terminal A redraws again after the short window has disappeared.
        try capture(session("private-terminal-a", 10, includeShort: false), after: 55)
        precondition(reading(after: 55)?.fetchedAt == start.addingTimeInterval(41))
        precondition(reading(after: 55)?.windows.map(\.remaining) == [88, 70])
        // A new terminal repeats the current balance, then a delayed older capture acquires the lock.
        try capture(session("private-terminal-c", 30, includeShort: false), after: 55)
        try capture(session("private-terminal-b", 28, includeShort: false), after: 54)
        precondition(reading(after: 55)?.windows.map(\.remaining) == [70], "An older capture replaced a later report")
        try capture(session("private-terminal-a", 33, includeShort: false), after: 56)
        precondition(reading(after: 56)?.windows.map(\.remaining) == [67])
        try capture(session("private-terminal-a", 33, includeShort: false), after: 60)
        try capture(session("other-terminal", 17, includeShort: false), after: 59)
        precondition(reading(after: 60)?.windows.map(\.remaining) == [67])
        precondition(reading(after: 60)?.fetchedAt == start.addingTimeInterval(56))
        // Repeated identical reports establish ordering, but cannot make an old balance current.
        try capture(session("private-terminal-a", 33, includeShort: false), after: 400)
        precondition(reading(after: 400)?.fetchedAt == start.addingTimeInterval(56))
        try capture(session("private-terminal-a", 34, includeShort: false), after: 401)
        precondition(reading(after: 401)?.fetchedAt == start.addingTimeInterval(401))
        try capture(session("private-terminal-a", 34, includeShort: false), after: 402)
        precondition(reading(after: 402)?.windows.map(\.remaining) == [66])
        try FileManager.default.removeItem(at: file)
        for broken in ["", "{", "[42]"] {
            try capture(partial, after: 61)
            precondition(reading(after: 61) != nil)
            do {
                try capture(broken, after: 61)
                preconditionFailure("A completely undecodable callback must fail")
            } catch is DecodingError {}
            precondition(reading(after: 61) == nil)
        }
        try capture(partial, after: 62)
        try ClaudeQuotaSource.invalidate(
            file: file, now: start.addingTimeInterval(63), currentDate: { start.addingTimeInterval(63) })
        precondition(reading(after: 63) == nil)
        let replayCache = try String(contentsOf: file, encoding: .utf8)
        precondition(!replayCache.contains("private-terminal"))
        let idleFile = directory.appendingPathComponent("idle-quota.json")
        let idleReport =
            #"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":null},"seven_day":{"used_percentage":1,"resets_at":1800000900}}}"#
        try ClaudeQuotaSource.capture(
            statusLine: Data(idleReport.utf8), file: idleFile, now: start, currentDate: { start })
        let idleReading = try ClaudeQuotaSource.read(file: idleFile, now: start)
        precondition(idleReading?.windows.map(\.remaining) == [100, 99])
        precondition(idleReading?.windows.first?.resetsAt == nil)
        let missingReset = idleReport.replacingOccurrences(of: #","resets_at":null"#, with: "")
        try ClaudeQuotaSource.capture(
            statusLine: Data(missingReset.utf8), file: idleFile, now: start.addingTimeInterval(1),
            currentDate: { start.addingTimeInterval(1) })
        let missingResetReading = try ClaudeQuotaSource.read(file: idleFile, now: start.addingTimeInterval(1))
        precondition(missingResetReading?.windows.count == 2)
        for badReset in [#""bad-date""#, "true", "-1", "1e999"] {
            let malformedReset = idleReport.replacingOccurrences(of: "null", with: badReset)
            try ClaudeQuotaSource.capture(
                statusLine: Data(malformedReset.utf8), file: idleFile, now: start.addingTimeInterval(2),
                currentDate: { start.addingTimeInterval(2) })
            let malformedReading = try ClaudeQuotaSource.read(file: idleFile, now: start.addingTimeInterval(2))
            precondition(malformedReading == nil)
        }
        try checkOverlappingClockCorrection(in: directory, start: start)
        try checkClockCorrection(in: directory, start: start)
        print("Claude quota fixtures passed")
    }

    private static func checkOverlappingClockCorrection(in directory: URL, start: Date) throws {
        let file = directory.appendingPathComponent("overlapping.json")
        let laterWallTime = start.addingTimeInterval(1)
        let lockedAt = start.addingTimeInterval(2)
        let boot = UUID()
        let report = Data(#"{"rate_limits":{"five_hour":{"used_percentage":26}}}"#.utf8)
        func capture(_ file: URL, boot: UUID, ticks: UInt64, at now: Date) throws {
            try ClaudeQuotaSource.capture(
                statusLine: report, file: file, order: .init(boot: boot, ticks: ticks), now: now,
                currentDate: { lockedAt })
        }
        // The clock has caught up to both sampled wall times before the pre-correction invalidation takes the lock.
        try capture(file, boot: boot, ticks: 2, at: start)
        try ClaudeQuotaSource.invalidate(
            file: file, order: .init(boot: boot, ticks: 1), now: laterWallTime, currentDate: { lockedAt })
        // Failure while decoding an older callback must invalidate using that callback's original order.
        do {
            try ClaudeQuotaSource.capture(
                statusLine: Data("{".utf8), file: file, order: .init(boot: boot, ticks: 1), now: laterWallTime,
                currentDate: { lockedAt })
            preconditionFailure("Invalid JSON should fail")
        } catch is DecodingError {}
        let saved = try ClaudeQuotaSource.read(file: file, now: lockedAt)
        precondition(saved?.windows.first?.remaining == 74, "A delayed pre-correction writer replaced a newer report")

        // In the opposite lock order the corrected capture must also win, including when the balance is identical.
        let inverse = directory.appendingPathComponent("inverse.json")
        try capture(inverse, boot: boot, ticks: 10, at: laterWallTime)
        try capture(inverse, boot: boot, ticks: 11, at: start)
        let corrected = try ClaudeQuotaSource.read(file: inverse, now: start)
        precondition(corrected?.fetchedAt == start && corrected?.windows.first?.remaining == 74)

        // A reboot resets the counter. The new boot can also have a corrected wall clock.
        try capture(inverse, boot: boot, ticks: 12, at: laterWallTime)
        try ClaudeQuotaSource.invalidate(
            file: inverse, order: .init(boot: UUID(), ticks: 1), now: start, currentDate: { lockedAt })
        let rebooted = try ClaudeQuotaSource.read(file: inverse, now: lockedAt)
        precondition(rebooted == nil)
    }

    private static func checkClockCorrection(in directory: URL, start: Date) throws {
        let file = directory.appendingPathComponent("clock.json")
        let future = start.addingTimeInterval(3_600)
        let report = Data(#"{"session_id":"clock","rate_limits":{"five_hour":{"used_percentage":26}}}"#.utf8)
        func capture(at date: Date, lockedAt: Date) throws {
            try ClaudeQuotaSource.capture(statusLine: report, file: file, now: date, currentDate: { lockedAt })
        }
        try capture(at: future, lockedAt: future)
        let hidden = try ClaudeQuotaSource.read(file: file, now: start)
        precondition(hidden == nil)
        try capture(at: start, lockedAt: start)
        let recovered = try ClaudeQuotaSource.read(file: file, now: start)
        precondition(recovered?.fetchedAt == start && recovered?.windows.first?.remaining == 74)
        try ClaudeQuotaSource.invalidate(file: file, now: future, currentDate: { start })
        let afterDelayedInvalidation = try ClaudeQuotaSource.read(file: file, now: start)
        precondition(afterDelayedInvalidation?.fetchedAt == start)
        try capture(at: future, lockedAt: future)
        try ClaudeQuotaSource.invalidate(file: file, now: start, currentDate: { start })
        let invalidated = try ClaudeQuotaSource.read(file: file, now: future)
        precondition(invalidated == nil)
    }
}
