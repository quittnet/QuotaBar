import Darwin
import Foundation
import SQLite3

@main
struct TokenChecks {
    static func main() throws {
        TokenPricingChecks.run()
        try slicedChunks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        try linkedHistoryRoots(in: root.appendingPathComponent("linked-roots"), now: now, calendar: calendar)
        try overlappingHistoryRoots(now: now, calendar: calendar)
        try reconcileCounters(in: root.appendingPathComponent("reconcile"), now: now, calendar: calendar)
        try costAttribution(in: root.appendingPathComponent("cost"), now: now, calendar: calendar)
        try legacyForkDates(in: root.appendingPathComponent("legacy-fork"), now: now, calendar: calendar)
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
        try expect(
            transitionHistory, now: transitionDay, all: 18, month: 18, week: 7, today: 0,
            peak: TokenPeakDay(date: ISO8601DateFormatter().date(from: "2024-08-10T04:00:00Z")!, tokens: 11))
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
        try expect(recovered, now: now, all: 37, month: 27, week: 27, today: 27, partial: true, undated: true)
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
        try expect(
            historyWithReorderedKeys, now: now, all: 13, month: 0, week: 0, today: 0, partial: true, undated: true)
        try append(counter(recordedAt, cumulative: 13, last: 13) + "\n", to: log)
        try expect(historyWithReorderedKeys, now: now, all: 13, month: 13, week: 13, today: 13, partial: true)
        try
            ([metadata("test"), response(recordedAt, thread: "test", response: "checkpoint", tokens: 13), checkpoint]
            .joined(separator: "\n") + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        try expect(historyWithReorderedKeys, now: now, all: 13, month: 13, week: 13, today: 13)
        print("Token history checks passed.")
    }

    private static func linkedHistoryRoots(in home: URL, now: Date, calendar: Calendar) throws {
        let fm = FileManager.default
        let sessions = home.appendingPathComponent("sessions")
        let archive = home.appendingPathComponent("archived_sessions")
        let outside = home.appendingPathComponent("outside")
        let nested = "2026/11/18"
        try fm.createDirectory(at: sessions.appendingPathComponent(nested), withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        func write(_ id: String, tokens: Int64, to url: URL) throws {
            let rows = [metadata(id), response("2026-11-18T12:00:00Z", thread: id, response: "one", tokens: tokens)]
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try write("live", tokens: 17, to: sessions.appendingPathComponent(nested + "/live.jsonl"))
        try write("archived", tokens: 23, to: archive.appendingPathComponent("archived.jsonl"))
        let outsideLog = outside.appendingPathComponent("ignored.jsonl")
        try write("outside", tokens: 101, to: outsideLog)
        try fm.createSymbolicLink(at: sessions.appendingPathComponent("ignored.jsonl"), withDestinationURL: outsideLog)
        try fm.createSymbolicLink(at: archive.appendingPathComponent("ignored-directory"), withDestinationURL: outside)

        var bytesRead = 0
        let cache = home.appendingPathComponent("history")
        func reader() -> TokenHistory {
            TokenHistory(home: home, cacheURL: cache, calendar: calendar) { bytesRead += $0 }
        }
        let directReader = reader()
        try expect(directReader, now: now, all: 40, month: 40, week: 40, today: 40)
        let direct = try directReader.read(now: now)
        bytesRead = 0
        let reused = try reader().read(now: now)
        precondition(reused == direct && bytesRead == 0, "Ordinary roots must reuse their saved checkpoints")

        let movedSessions = home.appendingPathComponent("relocated-sessions")
        let movedArchive = home.appendingPathComponent("relocated-archive")
        try fm.moveItem(at: sessions, to: movedSessions)
        try fm.moveItem(at: archive, to: movedArchive)
        try fm.createSymbolicLink(atPath: sessions.path, withDestinationPath: movedSessions.lastPathComponent)
        try fm.createSymbolicLink(atPath: archive.path, withDestinationPath: movedArchive.lastPathComponent)
        let linkedReader = reader()
        let linked = try linkedReader.read(now: now)
        precondition(linked == direct, "Linked active and archived roots must match ordinary roots")
        bytesRead = 0
        let linkedCached = try reader().read(now: now)
        precondition(linkedCached == linked && bytesRead == 0, "Linked roots must reuse their saved checkpoints")

        let replacement = home.appendingPathComponent("replacement-archive")
        try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
        try write("archived", tokens: 59, to: replacement.appendingPathComponent("archived.jsonl"))
        try fm.removeItem(at: archive)
        try fm.createSymbolicLink(at: archive, withDestinationURL: replacement)
        try expect(linkedReader, now: now, all: 76, month: 76, week: 76, today: 76)

        try fm.removeItem(at: archive)
        bytesRead = 0
        let singleRoot = try TokenHistory(home: home, calendar: calendar) { bytesRead += $0 }.read(now: now)
        let singleRootBytes = bytesRead
        try fm.createSymbolicLink(atPath: archive.path, withDestinationPath: sessions.lastPathComponent)
        bytesRead = 0
        let aliased = try TokenHistory(home: home, calendar: calendar) { bytesRead += $0 }.read(now: now)
        precondition(aliased == singleRoot && bytesRead == singleRootBytes, "Aliases must scan their shared root once")
    }

    private static func overlappingHistoryRoots(now: Date, calendar: Calendar) throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        let nested = sessions.appendingPathComponent("a-nested")
        let archived = home.appendingPathComponent("archived_sessions")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createSymbolicLink(atPath: archived.path, withDestinationPath: "sessions/a-nested")
        let plain = counter("2026-11-18T12:00:00Z", cumulative: 11, last: 11) + "\n"
        let log = nested.appendingPathComponent("counter.jsonl")
        try plain.write(to: log, atomically: true, encoding: .utf8)
        var bytes = 0
        let history = TokenHistory(home: home, calendar: calendar) { bytes += $0 }
        try expect(history, now: now, all: 11, month: 11, week: 11, today: 11)
        let plainBytesRead = bytes
        try fm.removeItem(at: log)

        let decoder = home.appendingPathComponent("decoder")
        try """
        #!/bin/sh
        IFS= read -r archive
        printf '%s\\n' "$archive" >> "$0.launches"
        exec /bin/cat
        """.write(to: decoder, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: decoder.path)
        let first = response("2026-11-18T12:00:00Z", thread: "a", response: "one", tokens: 17) + "\n"
        let second = response("2026-11-18T12:00:00Z", thread: "z", response: "one", tokens: 29) + "\n"
        let nestedArchive = nested.appendingPathComponent("a.jsonl.zst")
        let otherArchive = sessions.appendingPathComponent("z.jsonl.zst")
        try ("a\n" + first).write(to: nestedArchive, atomically: true, encoding: .utf8)
        try ("z\n" + second).write(to: otherArchive, atomically: true, encoding: .utf8)
        let configuration = CompressedLogConfiguration(
            maximumBytes: first.utf8.count + second.utf8.count, timeout: 1, executable: decoder)
        let compressed = TokenHistory(home: home, calendar: calendar, compression: configuration)
        try expect(compressed, now: now, all: 46, month: 46, week: 46, today: 46)
        let launches = try String(contentsOf: decoder.appendingPathExtension("launches"), encoding: .utf8)
        precondition(launches.split(separator: "\n") == ["a", "z"], "Each compressed archive must decode once")
        precondition(plainBytesRead == plain.utf8.count, "A nested transcript must scan once")

        try fm.removeItem(at: nestedArchive)
        try expect(compressed, now: now, all: 29, month: 29, week: 29, today: 29)
        let replacement = response("2026-11-18T12:00:00Z", thread: "a", response: "one", tokens: 61) + "\n"
        try ("a\n" + replacement).write(to: nestedArchive, atomically: true, encoding: .utf8)
        try expect(compressed, now: now, all: 90, month: 90, week: 90, today: 90)

        try fm.removeItem(at: otherArchive)
        try fm.removeItem(at: nestedArchive)
        // A hardlink with another suffix still has to use its declared reader.
        try (plain + first).write(to: log, atomically: true, encoding: .utf8)
        try fm.linkItem(at: log, to: nestedArchive)
        try expect(compressed, now: now, all: 28, month: 28, week: 28, today: 28)
        let finalLaunches = try String(contentsOf: decoder.appendingPathExtension("launches"), encoding: .utf8)
        precondition(finalLaunches.split(separator: "\n").last == plain.dropLast())
    }

    private static func slicedChunks() throws {
        // A chunk may be a nonzero-based Data slice, and a record can span more than one such slice.
        let chunks = ["\nA\0", "B\ncafé", " noir\npartial"].map { Data(("ignored" + $0).utf8).dropFirst(7) }
        var source = chunks.makeIterator()
        var lines: [Data] = []
        let read = { source.next() ?? Data() }
        let committed = try readTokenLogLines(read: read) { line in
            guard case .complete(let data) = line else { fatalError("Unexpected oversized line") }
            lines.append(data)
        }
        let expected = ["", "A\0B", "café noir"].map { Data($0.utf8) }
        precondition(lines == expected && committed == expected.reduce(0) { $0 + UInt64($1.count + 1) })
    }

    private static func expect(
        _ history: TokenHistory, now: Date,
        all: Int64, month: Int64, week: Int64, yesterday: Int64 = 0, today: Int64, partial: Bool = false,
        retained: Bool = true, undated: Bool = false, peak: TokenPeakDay? = nil,
        line: UInt = #line
    ) throws {
        func unpriced(_ tokens: Int64) -> TokenSpendAmount {
            var amount = TokenSpendAmount()
            if tokens > 0 || undated { amount.add(nil) }
            return amount
        }
        let actual = try history.read(now: now)
        // These New York fixtures peak today or yesterday unless an older peak is supplied.
        let peakDate = yesterday >= today ? "2026-11-17T05:00:00Z" : "2026-11-18T05:00:00Z"
        let recentPeak = max(yesterday, today)
        let expectedPeak =
            peak
            ?? (recentPeak > 0
                ? TokenPeakDay(date: ISO8601DateFormatter().date(from: peakDate)!, tokens: recentPeak) : nil)
        let expected = TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: partial,
            hasRetainedUsage: retained,
            spend: TokenSpendTotals(
                allTime: unpriced(all), month: unpriced(month), week: unpriced(week),
                yesterday: unpriced(yesterday), today: unpriced(today)), peakDay: expectedPeak)
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

    private static func legacyForkDates(in root: URL, now: Date, calendar: Calendar) throws {
        let fm = FileManager.default
        let sessions = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let fork = sessions.appendingPathComponent("fork.jsonl")
        let parent = sessions.appendingPathComponent("parent.jsonl")
        let cache = root.appendingPathComponent("cache.json")
        let yesterday = "2026-11-17T12:00:00Z"
        let today = "2026-11-18T12:00:00Z"
        let forkHeader =
            #"{"timestamp":"2026-11-18T11:00:00Z","type":"session_meta","payload":{"id":"fork","forked_from_id":"parent"}}"#
        func counters(at date: String) -> [String] {
            [counter(date, cumulative: 10, last: 10), counter(date, cumulative: 30, last: 20)]
        }
        func write(_ rows: [String], to file: URL) throws {
            try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }

        var bytes = 0
        func reader() -> TokenHistory {
            TokenHistory(home: root, cacheURL: cache, calendar: calendar) { bytes += $0 }
        }
        try write([forkHeader, metadata("parent")] + counters(at: today), to: fork)
        try write([metadata("parent")] + counters(at: yesterday), to: parent)
        let grandchild = sessions.appendingPathComponent("grandchild.jsonl")
        let grandchildHeader =
            #"{"timestamp":"2026-11-18T11:30:00Z","type":"session_meta","payload":{"id":"grandchild","forked_from_id":"fork"}}"#
        try write([grandchildHeader, forkHeader, metadata("parent")] + counters(at: today), to: grandchild)
        try expect(reader(), now: now, all: 30, month: 30, week: 30, yesterday: 30, today: 0)
        try fm.removeItem(at: parent)
        let orphan = try reader().read(now: now)
        precondition(
            orphan.allTime == 30 && orphan.month == 0 && orphan.week == 0 && orphan.yesterday == 0
                && orphan.today == 0 && orphan.partial && orphan.peakDay == nil)
        precondition(
            orphan.spend.allTime.partial && orphan.spend.month.partial && orphan.spend.week.partial
                && orphan.spend.yesterday.partial && orphan.spend.today.partial && !orphan.spend.today.hasPricedUsage)
        bytes = 0
        let warm = try reader().read(now: now)
        precondition(warm == orphan && bytes == 0)
        try fm.removeItem(at: grandchild)

        let dateRetained = [forkHeader] + counters(at: yesterday)
        try write(dateRetained, to: fork)
        try expect(reader(), now: now, all: 30, month: 30, week: 30, yesterday: 30, today: 0)

        // The child response proves the copied prefix is over. Subsequent counter-only requests have normal dates.
        try write(
            [forkHeader] + counters(at: today) + [
                response(today, thread: "fork", response: "own", tokens: 3),
                counter(today, cumulative: 33, last: 3),
                counter(today, cumulative: 38, last: 5),
            ], to: fork)
        try expect(reader(), now: now, all: 38, month: 8, week: 8, today: 8, partial: true, undated: true)
    }

    private static func reconcileCounters(in root: URL, now: Date, calendar: Calendar) throws {
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let log = sessions.appendingPathComponent("requests.jsonl")
        let cache = root.appendingPathComponent("history")
        let context = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#
        let today = "2026-11-18T06:00:00Z"
        let yesterday = "2026-11-18T04:00:00Z"  // November 17 in New York, November 18 in UTC.
        func native(_ tokens: Int, at date: String) -> String {
            let usage =
                #"{"input_tokens":\#(tokens),"output_tokens":0,"cached_input_tokens":0,"total_tokens":\#(tokens)}"#
            return
                #"{"type":"token_usage_record","timestamp":"\#(date)","payload":{"response_id":"r","thread_id":"t","usage":\#(usage)}}"#
        }
        func sample(_ total: Int64, _ last: Int64, at date: String) -> String {
            counter(date, cumulative: total, last: last)
                .replacingOccurrences(of: #""output_tokens":0"#, with: #""cached_input_tokens":0,"output_tokens":0"#)
        }
        func write(_ rows: [String]) throws {
            try (([context] + rows).joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        func verify(
            _ totals: TokenTotals, yesterday: Int64, today: Int64, partial: Bool = false, line: UInt = #line
        ) {
            precondition(
                totals.yesterday == yesterday && totals.today == today && totals.partial == partial, "At \(line)")
            precondition(
                totals.allTime == yesterday + today && totals.week == totals.allTime && totals.month == totals.allTime)
            for (amount, count) in [
                (totals.spend.today, today), (totals.spend.yesterday, yesterday),
                (totals.spend.allTime, totals.allTime),
            ] {
                precondition(!amount.partial && abs(amount.usd - Double(count) * 1.25e-6) < 1e-14, "Spend at \(line)")
            }
        }
        let history = TokenHistory(home: root, cacheURL: cache, calendar: calendar)
        try write([native(10, at: yesterday), sample(30, 20, at: today)])
        verify(try history.read(now: now), yesterday: 10, today: 20)
        try write([sample(100, 100, at: yesterday), native(10, at: today), sample(30, 20, at: today)])
        verify(try history.read(now: now), yesterday: 100, today: 30)
        try write([sample(100, 100, at: yesterday), sample(30, 20, at: today)])
        verify(try history.read(now: now), yesterday: 100, today: 20, partial: true)

        try write([sample(10, 10, at: yesterday), native(10, at: today)])
        verify(try history.read(now: now), yesterday: 10, today: 10)
        try append(sample(10, 10, at: today) + "\n", to: log)
        verify(try history.read(now: now), yesterday: 10, today: 10)
        let restarted = TokenHistory(home: root, cacheURL: cache, calendar: calendar)
        try append(sample(20, 10, at: today) + "\n", to: log)
        verify(try restarted.read(now: now), yesterday: 10, today: 10)
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var bytes = 0
        let afterMove = TokenHistory(home: root, cacheURL: cache, calendar: utc) { bytes += $0 }
        let moved = try afterMove.read(now: now)
        verify(moved, yesterday: 0, today: 20)
        precondition(moved.peakDay == TokenPeakDay(date: utc.startOfDay(for: now), tokens: 20))
        precondition(bytes == 0, "A warm checkpoint must rebucket when the timezone changes")

        try write([native(10, at: today), sample(10, 10, at: today)])
        verify(try history.read(now: now), yesterday: 0, today: 10)
        try write([sample(10, 10, at: today), native(10, at: today)])
        verify(try history.read(now: now), yesterday: 0, today: 10, partial: true)
        try append(sample(10, 10, at: today) + "\n", to: log)
        verify(try restarted.read(now: now), yesterday: 0, today: 10, partial: true)
        let another = native(10, at: today).replacingOccurrences(of: #""response_id":"r""#, with: #""response_id":"s""#)
        try append(
            [another, sample(10, 10, at: today), sample(20, 10, at: today)].joined(separator: "\n") + "\n", to: log)
        verify(try history.read(now: now), yesterday: 0, today: 20, partial: true)

        let expensive = context.replacingOccurrences(of: "gpt-5", with: "gpt-6.2-astra")
        try write([sample(10, 10, at: yesterday), expensive, native(10, at: yesterday), sample(20, 10, at: today)])
        let tied = try history.read(now: now)
        precondition(tied.allTime == 20 && tied.yesterday == 10 && tied.today == 0 && tied.partial)
        precondition(tied.week == 20 && tied.month == 20)
        let provenDay = TokenPeakDay(date: ISO8601DateFormatter().date(from: "2026-11-17T05:00:00Z")!, tokens: 10)
        precondition(tied.peakDay == provenDay)
        let rebucketed = try afterMove.read(now: now)
        precondition(rebucketed.peakDay == TokenPeakDay(date: utc.startOfDay(for: now), tokens: 20))
        precondition(tied.spend.allTime.partial && abs(tied.spend.allTime.usd - 0.00008) < 1e-14)

        try write([sample(10, 10, at: yesterday), native(10, at: yesterday), sample(20, 10, at: today)])
        let sameRate = try history.read(now: now)
        precondition(sameRate.week == 20 && sameRate.month == 20 && sameRate.today == 0 && sameRate.yesterday == 10)
        precondition(sameRate.peakDay == provenDay)
        precondition(sameRate.spend.week == sameRate.spend.month && sameRate.spend.month == sameRate.spend.allTime)
        precondition(!sameRate.spend.week.partial && abs(sameRate.spend.week.usd - 0.000025) < 1e-14)
        precondition(sameRate.spend.today.partial && sameRate.spend.yesterday.partial)

        let copy = sessions.appendingPathComponent("copy.jsonl")
        let ambiguous = [
            metadata("t"), sample(10, 10, at: yesterday), native(10, at: yesterday), sample(20, 10, at: today),
        ]
        let exact = [metadata("t"), sample(20, 10, at: yesterday)]
        for (first, second) in [(ambiguous, exact), (exact, ambiguous)] {
            try write(first)
            try (second.joined(separator: "\n") + "\n").write(to: copy, atomically: true, encoding: .utf8)
            let reconciled = try history.read(now: now)
            precondition(reconciled.peakDay == TokenPeakDay(date: provenDay.date, tokens: 20))
            precondition(reconciled.yesterday == 20 && reconciled.today == 0 && reconciled.allTime == 20)
        }
        try FileManager.default.removeItem(at: copy)

        let future = "2026-11-19T06:00:00Z"
        try write([sample(100, 100, at: yesterday), sample(5, 5, at: future), sample(105, 100, at: today)])
        verify(try history.read(now: now), yesterday: 100, today: 100)
        verify(try restarted.read(now: now), yesterday: 100, today: 100)
        let corrected = try history.read(now: now.addingTimeInterval(86_400))
        precondition(corrected.allTime == 205 && corrected.today == 5 && corrected.yesterday == 100)

        try write([native(20, at: yesterday), native(10, at: future)])
        verify(try restarted.read(now: now), yesterday: 20, today: 0)
        let later = try restarted.read(now: now.addingTimeInterval(86_400))
        precondition(later.allTime == 10 && later.today == 10 && later.partial)
    }

    private static func costAttribution(in root: URL, now: Date, calendar: Calendar) throws {
        let fm = FileManager.default
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("archived_sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let log = sessions.appendingPathComponent("primary.jsonl")
        let copy = archive.appendingPathComponent("duplicate.jsonl")
        let today = "2026-11-18T12:00:00Z"
        let yesterday = "2026-11-17T12:00:00Z"
        let usage =
            #"{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":60,"total_tokens":1100}"#
        let usd = 0.0018  // (600 * 1.25 + 400 * 0.125 + 100 * 10) per million
        let cache = root.appendingPathComponent("cache.json")
        var bytes = 0
        func reader() -> TokenHistory {
            TokenHistory(home: root, cacheURL: cache, calendar: calendar) { bytes += $0 }
        }
        let history = reader()
        func context(_ turn: String, _ model: String) -> String {
            #"{"type":"turn_context","payload":{"turn_id":"\#(turn)","model":"\#(model)"}}"#
        }
        func native(
            _ id: String, turn: String = "t", date: String = "2026-11-18T12:00:00Z", model: String? = nil
        ) -> String {
            let field = model.map { ",\"model\":\"\($0)\"" } ?? ""
            return
                #"{"type":"token_usage_record","timestamp":"\#(date)","payload":{"thread_id":"owner","turn_id":"\#(turn)","response_id":"\#(id)"\#(field),"usage":\#(usage)}}"#
        }
        func sample(_ total: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(today)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":\#(usage)}}}"#
        }
        func write(_ rows: [String], to url: URL) throws {
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        func amount(_ actual: TokenSpendAmount, _ expected: Double?, partial: Bool = false, line: UInt = #line) {
            precondition(actual.hasPricedUsage == (expected != nil), "Missing or unexpected estimate at \(line)")
            precondition(abs(actual.usd - (expected ?? 0)) < 1e-12 && actual.partial == partial, "Spend at \(line)")
        }

        let original = [
            metadata("owner"), context("t", "gpt-5-codex"), native("r", date: yesterday), sample(1100),
        ]
        try write(original, to: log)
        try write(original, to: copy)
        let single = try history.read(now: now)
        precondition(single.allTime == 1100)
        amount(single.spend.allTime, usd)
        amount(single.spend.yesterday, usd)
        amount(single.spend.today, nil)

        // A warm reader must retain both the price and the active turn's model across an append.
        let restarted = reader()
        bytes = 0
        let warm = try restarted.read(now: now)
        precondition(single == warm && bytes == 0)
        try append(native("next") + "\n", to: log)
        let added = try restarted.read(now: now)
        amount(added.spend.today, usd)
        amount(added.spend.week, usd * 2)
        try fm.removeItem(at: copy)

        let start = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"next"}}"#
        try write(
            [
                metadata("owner"), context("t", "gpt-5-codex"), native("model-override", model: "gpt-5-mini"),
                native("wrong-turn", turn: "other"), start, native("no-model", turn: "next"),
                context("next", "unknown-model"), native("unknown", turn: "next"),
                native("future", date: "2026-11-19T12:00:00Z", model: "gpt-5-codex"),
            ], to: log)
        let switched = try restarted.read(now: now)
        precondition(switched.allTime == 4400 && !switched.partial)
        amount(switched.spend.allTime, 0.00036, partial: true)
        amount(switched.spend.today, 0.00036, partial: true)
        amount(switched.spend.yesterday, nil)

        let sameTurnStart = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#
        func started(model: String) -> String {
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t","model":\#(model)}}"#
        }
        try write(
            [
                context("t", "gpt-5-codex"), started(model: #""gpt-5-mini""#), native("updated"),
                sameTurnStart, native("preserved"), started(model: "{}"), native("invalidated"),
            ], to: log)
        let markers = try restarted.read(now: now)
        precondition(markers.allTime == 3300 && !markers.partial)
        amount(markers.spend.today, 2 * 0.00036, partial: true)

        let direct = native("direct", model: "gpt-5-mini")
        func withUsageModel(_ row: String, _ json: String) -> String {
            row.replacingOccurrences(of: #""input_tokens":1000"#, with: #""model":\#(json),"input_tokens":1000"#)
        }
        let precedence: [(row: String, cost: Double?)] = [
            (withUsageModel(native("nested"), #""gpt-5-mini""#), 0.00036),
            (withUsageModel(direct, #""gpt-5-codex""#), 0.00036),
            (withUsageModel(native("malformed-nested"), "[]"), nil),
            (withUsageModel(direct.replacingOccurrences(of: #""gpt-5-mini""#, with: "{}"), #""gpt-5-codex""#), nil),
            (direct.replacingOccurrences(of: #""gpt-5-mini""#, with: "null"), nil),
        ]
        for (row, cost) in precedence {
            try write([context("t", "gpt-5-codex"), row], to: log)
            let result = try restarted.read(now: now)
            precondition(result.allTime == 1100 && !result.partial)
            amount(result.spend.today, cost, partial: cost == nil)
        }

        let padding = String(repeating: "A", count: TokenLogLine.maximumSize)
        let imageHeader =
            #"{"timestamp":"2026-11-18T12:00:00Z","type":"event_msg","payload": { "type" : "user_message", "images":["data:image/png;base64,"#
        let image = imageHeader + padding + #""]}}"#
        try write([context("t", "gpt-5-codex"), image, native("after-image")], to: log)
        let withImage = try restarted.read(now: now)
        precondition(withImage.allTime == 1100 && !withImage.partial)
        amount(withImage.spend.today, usd)
        bytes = 0
        let warmImage = try reader().read(now: now)
        precondition(warmImage == withImage && bytes == 0)

        let unknownImage = image.replacingOccurrences(of: #""user_message""#, with: #""model_reroute""#)
        try write([context("t", "gpt-5-codex"), unknownImage, native("after-unidentified-event")], to: log)
        let unknownEvent = try restarted.read(now: now)
        precondition(unknownEvent.allTime == 1100 && unknownEvent.partial)
        amount(unknownEvent.spend.today, nil, partial: true)

        try write([metadata("owner"), context("t", "gpt-5-codex"), sample(1100), sample(1100), sample(1650)], to: log)
        let clipped = try restarted.read(now: now)
        precondition(clipped.allTime == 1650)
        amount(clipped.spend.allTime, usd, partial: true)
        let checkpoint =
            #"{"type":"compacted","timestamp":"\#(today)","payload":{"latest_token_usage_record":{"thread_id":"owner","turn_id":"t","response_id":"r","usage":\#(usage)}}}"#
        try write([metadata("child", parent: "owner"), context("t", "gpt-5-codex"), native("r"), checkpoint], to: log)
        let foreign = try restarted.read(now: now)
        precondition(foreign.allTime == 1100 && foreign.today == 0)
        amount(foreign.spend.allTime, nil, partial: true)
        // A copied response's model and usage travel with its ID. The fork's date and turn model do not.
        let fork = [metadata("child", parent: "owner"), context("t", "gpt-5-mini")]
        let directCopy = native("r", model: "gpt-5-codex")
        let nestedCopy = withUsageModel(native("r"), #""gpt-5-codex""#)
        try write(fork + [directCopy, nestedCopy], to: log)
        let copied = try restarted.read(now: now)
        precondition(copied.allTime == 1100 && copied.today == 0 && copied.partial)
        amount(copied.spend.allTime, usd)
        amount(copied.spend.today, nil, partial: true)
        bytes = 0
        let warmCopy = try reader().read(now: now)
        precondition(warmCopy == copied && bytes == 0)

        try write([metadata("owner"), native("r", date: yesterday)], to: copy)
        let dated = try restarted.read(now: now)
        precondition(dated.allTime == 1100 && dated.yesterday == 1100 && !dated.partial)
        amount(dated.spend.yesterday, nil, partial: true)
        amount(dated.spend.today, nil)
        try write([metadata("owner"), native("r", date: yesterday, model: "unknown-model")], to: copy)
        let unknownOwner = try restarted.read(now: now)
        amount(unknownOwner.spend.yesterday, nil, partial: true)
        try write([metadata("owner"), native("r", date: yesterday, model: "gpt-5-mini")], to: copy)
        let authoritative = try restarted.read(now: now)
        amount(authoritative.spend.yesterday, 0.00036)
        try write([metadata("owner"), response(yesterday, thread: "owner", response: "r", tokens: 5)], to: copy)
        let differentCount = try restarted.read(now: now)
        precondition(differentCount.allTime == 5 && differentCount.yesterday == 5 && differentCount.partial)
        amount(differentCount.spend.allTime, nil, partial: true)
        try fm.removeItem(at: copy)

        // A file may establish its thread after the response. A preceding turn in the fork cannot price it.
        try write([context("t", "gpt-5-mini"), native("r"), metadata("child", parent: "owner")], to: log)
        let lateMetadata = try restarted.read(now: now)
        precondition(lateMetadata.allTime == 1100 && lateMetadata.today == 0)
        amount(lateMetadata.spend.allTime, nil, partial: true)
        try write([metadata("owner"), context("t", "gpt-5-codex"), checkpoint], to: log)
        let compacted = try restarted.read(now: now)
        amount(compacted.spend.allTime, nil, partial: true)
        try append(sample(1100) + "\n", to: log)
        let shadow = try restarted.read(now: now)
        precondition(shadow.allTime == 1100 && shadow.today == 1100)
        amount(shadow.spend.today, nil, partial: true)

        // An anonymous counter can overlap a single distinct compaction ID. A copied checkpoint
        // or an uncommitted tail cannot create another response or date its original request.
        let otherCheckpoint = checkpoint.replacingOccurrences(of: #""response_id":"r""#, with: #""response_id":"s""#)
        let prefix = [metadata("owner"), context("t", "gpt-5-codex"), sample(1100), checkpoint]
        try write(prefix, to: log)
        try write(prefix, to: copy)
        try append(otherCheckpoint, to: log)
        let tail = try restarted.read(now: now)
        precondition(tail.allTime == 1100 && tail.today == 1100)
        try append("\n" + otherCheckpoint + "\n", to: log)
        let multiple = try restarted.read(now: now)
        precondition(multiple.allTime == 2200 && multiple.today == 1100 && multiple.partial)
        amount(multiple.spend.today, nil, partial: true)
        bytes = 0
        let warmMultiple = try reader().read(now: now)
        precondition(warmMultiple == multiple && bytes == 0)

        // The shared turn makes the owner's counter eligible for both checkpoints. The other
        // thread also has a counter of its own. Each response can be explained exactly once.
        let otherThread = checkpoint.replacingOccurrences(of: #""thread_id":"owner""#, with: #""thread_id":"other""#)
        try write(prefix + [otherThread], to: log)
        try write([metadata("other"), context("separate", "gpt-5-mini"), sample(1100)], to: copy)
        let paired = try restarted.read(now: now)
        precondition(paired.allTime == 2200 && paired.today == 2200 && paired.partial)

        // Saturating one thread must neither use nor unprice another thread's free counter.
        let counters = (1...32).map { sample($0 * 1100) }
        let checkpoints = (1...64).map { index in
            checkpoint.replacingOccurrences(of: #""response_id":"r""#, with: #""response_id":"r-\#(index)""#)
                .replacingOccurrences(of: #""turn_id":"t""#, with: #""turn_id":"turn-\#(index)""#)
        }
        try write([metadata("owner"), context("t", "gpt-5-codex")] + counters + checkpoints, to: log)
        let saturated = try restarted.read(now: now)
        precondition(saturated.allTime == 65 * 1100 && saturated.today == 33 * 1100 && saturated.partial)
        amount(saturated.spend.today, 0.00036, partial: true)
        try append(otherThread + "\n", to: log)
        let remaining = try restarted.read(now: now)
        precondition(remaining.allTime == saturated.allTime && remaining.today == saturated.today)
        amount(remaining.spend.today, nil, partial: true)
        try fm.removeItem(at: copy)

        // A clipped counter can cover only the tokens it actually contributed. Both IDs
        // independently establish a lifetime lower bound even when their request dates differ.
        let smaller = response(yesterday, thread: "owner", response: "small", tokens: 550)
        try write([metadata("owner"), context("t", "gpt-5-codex"), smaller, sample(1100), checkpoint], to: log)
        let clippedOverlap = try restarted.read(now: now)
        precondition(clippedOverlap.allTime == 1650 && clippedOverlap.yesterday == 550 && clippedOverlap.today == 550)
        precondition(clippedOverlap.partial && clippedOverlap.spend.allTime.partial)

        let first = native("r", model: "gpt-5-mini")
        let second = native("r", model: "gpt-5-codex")
        for rows in [[first, second, first], [second, first, second]] {
            try write(rows, to: log)
            let conflict = try restarted.read(now: now)
            precondition(conflict.allTime == 1100)
            amount(conflict.spend.today, nil, partial: true)
        }
        let badCached = second.replacingOccurrences(
            of: "\"cached_input_tokens\":400", with: "\"cached_input_tokens\":[]")
        let badWrites = second.replacingOccurrences(
            of: "\"cached_input_tokens\":400", with: "\"cached_input_tokens\":400,\"cache_write_input_tokens\":\"bad\"")
        let badInput = second.replacingOccurrences(of: #""input_tokens":1000"#, with: #""input_tokens":"unknown""#)
        let badOutput = second.replacingOccurrences(of: #""output_tokens":100"#, with: #""output_tokens":{}"#)
        let missingInput = second.replacingOccurrences(of: #""input_tokens":1000,"#, with: "")
        let missingOutput = second.replacingOccurrences(of: #""output_tokens":100,"#, with: "")
        for row in [badCached, badWrites, badInput, badOutput, missingInput, missingOutput] {
            try write([row], to: log)
            let bad = try restarted.read(now: now)
            precondition(bad.allTime == 1100 && !bad.partial)
            amount(bad.spend.today, nil, partial: true)
        }
        // Repeated copies of a cumulative counter represent one request even if the
        // later copy supplies its cache breakdown or contradicts the earlier price.
        let emptyCache = sample(1100).replacingOccurrences(of: #""cached_input_tokens":400,"#, with: "")
        let otherCache = sample(1100).replacingOccurrences(
            of: #""cached_input_tokens":400"#, with: #""cached_input_tokens":0"#)
        let startRows = [metadata("owner"), context("t", "gpt-5-codex")]
        for rows in [[emptyCache, sample(1100)], [sample(1100), emptyCache]] {
            try write(startRows + rows, to: log)
            let supplemented = try restarted.read(now: now)
            precondition(supplemented.today == 1100 && !supplemented.partial)
            amount(supplemented.spend.today, usd)
        }
        for rows in [[sample(1100), otherCache], [otherCache, sample(1100), otherCache]] {
            try write(startRows + rows, to: log)
            let conflict = try restarted.read(now: now)
            precondition(conflict.today == 1100 && !conflict.partial)
            amount(conflict.spend.today, nil, partial: true)
        }
        let laterCounter = sample(1100).replacingOccurrences(of: today, with: "2026-11-18T13:00:00Z")
        try write(startRows + [emptyCache, context("t", "gpt-5-mini"), laterCounter], to: log)
        let laterContext = try restarted.read(now: now)
        amount(laterContext.spend.today, nil, partial: true)
        try write(startRows + [sample(1100), context("t", "gpt-5-mini"), sample(1100)], to: log)
        let sameTimeContext = try restarted.read(now: now)
        amount(sameTimeContext.spend.today, usd)
        try write(startRows + [emptyCache, context("t", "gpt-5-mini"), laterCounter], to: log)
        let directCounter = laterCounter.replacingOccurrences(
            of: #""cached_input_tokens":400"#, with: #""model":"gpt-5-codex","cached_input_tokens":400"#)
        try append(directCounter + "\n", to: log)
        let explicitPrice = try restarted.read(now: now)
        amount(explicitPrice.spend.today, usd)
        bytes = 0
        let retained = try reader().read(now: now)
        precondition(retained == explicitPrice && bytes == 0)

        // Simulate a stale SQLite price table with the same source fingerprint.
        try write([second], to: log)
        let before = try restarted.read(now: now)
        amount(before.spend.allTime, usd)
        let db = CodexHistoryCache(
            url: cache.appendingPathExtension("sqlite"), home: root.standardizedFileURL.path,
            maximumBytes: 128 * 1024 * 1024)!
        var stale: Data?
        var cachedPath: String?
        db.load { path, data in
            guard URL(fileURLWithPath: path).lastPathComponent == log.lastPathComponent else { return }
            cachedPath = path
            var entry = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            var file = entry["file"] as! [String: Any]
            file["priceRevision"] = TokenPricing.revision - 1
            entry["file"] = file
            stale = try! JSONSerialization.data(withJSONObject: entry)
        }
        guard let cachedPath, let stale else { fatalError("Missing price checkpoint") }
        precondition(db.save(paths: [cachedPath], payload: { _ in stale }, acknowledge: { _ in }) == SQLITE_OK)
        bytes = 0
        let repriced = try reader().read(now: now)
        precondition(bytes > 0 && repriced == before)

        // The earlier parser discarded this row and cached an empty, partial event list.
        try write([badInput], to: log)
        let recovered = try restarted.read(now: now)
        var oldParser: Data?
        db.load { path, data in
            guard path == cachedPath else { return }
            var entry = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            var file = entry["file"] as! [String: Any]
            file.removeValue(forKey: "parserRevision")
            file["events"] = []
            file["partial"] = true
            entry["file"] = file
            oldParser = try! JSONSerialization.data(withJSONObject: entry)
        }
        guard let oldParser else { fatalError("Missing parser checkpoint") }
        precondition(db.save(paths: [cachedPath], payload: { _ in oldParser }, acknowledge: { _ in }) == SQLITE_OK)
        bytes = 0
        let migrated = try reader().read(now: now)
        precondition(bytes > 0 && migrated.allTime == 1100 && migrated == recovered)
        bytes = 0
        let warmMigration = try reader().read(now: now)
        precondition(bytes == 0 && warmMigration == recovered)
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

        try fm.removeItem(at: dbURL)
        try check(current, 1)
        try check(reader(cache), 1)
        precondition(reads == 0, "A live reader must repopulate an evicted cache from memory")

        // Another process can publish a replacement at the same path while our connection is open.
        let replacement = root.appendingPathComponent("replacement.sqlite")
        precondition(CodexHistoryCache(url: replacement, home: root.path, maximumBytes: 128 * 1024 * 1024) != nil)
        precondition(rename(replacement.path, dbURL.path) == 0)
        try check(current, 1)
        try check(reader(cache), 1)
        precondition(reads == 0, "An atomically replaced database must receive the live checkpoints")

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

        // A pre-pricing checkpoint can have an identical fingerprint. Its source must still be replayed.
        var oldFiles: [String: Any] = [:]
        let db = CodexHistoryCache(url: dbURL, home: root.standardizedFileURL.path, maximumBytes: 128 * 1024 * 1024)!
        db.load { path, data in
            let entry = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            var oldFile = entry["file"] as! [String: Any]
            oldFile.removeValue(forKey: "priceRevision")
            oldFiles[path] = oldFile
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
        precondition(reads > 0, "A legacy count-only checkpoint must be rescanned")
        reads = 0
        try check(bridge, 2)
        precondition(!fm.fileExists(atPath: migrated.path))
        try check(reader(migrated), 2)
        precondition(reads == 0, "Rebuilt checkpoints must persist after a transient lock")

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
