import Foundation

@main
struct LiveTokenHistoryChecks {
    enum Provider: CaseIterable {
        case claude, codex

        func row(_ id: String, _ count: Int) -> String {
            let date = "2026-11-18T12:00:00Z"
            switch self {
            case .claude:
                return
                    #"{"timestamp":"\#(date)","type":"assistant","message":{"id":"\#(id)","stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":\#(count)}}}"#
                    + "\n"
            case .codex:
                return
                    #"{"timestamp":"\#(date)","type":"token_usage_record","payload":{"thread_id":"test","response_id":"\#(id)","usage":{"total_tokens":\#(count)}}}"#
                    + "\n"
            }
        }
    }

    enum Mutation: CaseIterable {
        case append, repeatedAppend, sustainedAppend, finishFragment, replace, truncate, rewriteAndGrow,
            rewriteDuringVerification
    }

    struct Failure: Error { let message: String }

    static func main() throws {
        var failures: [String] = []
        for provider in Provider.allCases {
            for mutation in Mutation.allCases {
                do {
                    try verify(provider, mutation)
                } catch {
                    failures.append("\(provider) \(mutation): \(error)")
                }
            }
        }
        guard failures.isEmpty else { throw Failure(message: failures.joined(separator: "\n")) }
        print("Concurrent Claude and Codex transcript checks passed.")
    }

    static func verify(_ provider: Provider, _ mutation: Mutation) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(provider == .claude ? "projects" : "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("session.jsonl")
        let cache = home.appendingPathComponent(provider == .claude ? "index.sqlite" : "index.json")
        let first = provider.row("first", 11)
        let second = provider.row("second", 22)
        let third = provider.row("third", 33)
        try Data(first.utf8).write(to: log)
        let stream = try FileHandle(forWritingTo: log)
        defer { try? stream.close() }
        try stream.seekToEnd()
        var change: (() throws -> Void)?
        var changeAfter = 0
        var writeError: Error?
        var bytesRead = 0
        func readBytes(_ count: Int) {
            bytesRead += count
            guard bytesRead >= changeAfter, let action = change else { return }
            change = nil
            do { try action() } catch { writeError = error }
        }
        func reader() -> (Date) throws -> TokenTotals {
            switch provider {
            case .claude:
                return ClaudeTokenHistory(home: home, cacheURL: cache, calendar: .current, didReadBytes: readBytes).read
            case .codex:
                return TokenHistory(home: home, cacheURL: cache, calendar: .current, didReadBytes: readBytes).read
            }
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        let read = reader()
        let initial = try read(now)
        precondition(initial.allTime == 11)
        let tail = mutation == .finishFragment ? String(second.dropLast()) : second
        try stream.write(contentsOf: Data(tail.utf8))
        let sampledSize = first.utf8.count + tail.utf8.count
        if mutation == .append || mutation == .finishFragment { changeAfter = sampledSize }
        bytesRead = 0
        func rewritePrefixAndAppend(_ id: String) throws {
            try stream.seek(toOffset: 0)
            try stream.write(contentsOf: Data(provider.row("first", 77).utf8))
            try stream.seekToEnd()
            try stream.write(contentsOf: Data(provider.row(id, 33).utf8))
        }
        change = {
            switch mutation {
            case .append: try stream.write(contentsOf: Data(third.utf8))
            case .finishFragment: try stream.write(contentsOf: Data(("\n" + third).utf8))
            case .repeatedAppend, .sustainedAppend, .rewriteDuringVerification:
                try stream.write(contentsOf: Data(third.utf8))
                changeAfter = sampledSize * 2
                change = {
                    if mutation == .rewriteDuringVerification {
                        try rewritePrefixAndAppend("fourth")
                    } else {
                        try stream.write(contentsOf: Data(provider.row("fourth", 44).utf8))
                        if mutation == .sustainedAppend {
                            changeAfter += sampledSize
                            change = { try stream.write(contentsOf: Data(provider.row("fifth", 55).utf8)) }
                        }
                    }
                }
            case .replace: try Data(third.utf8).write(to: log, options: .atomic)
            case .truncate:
                try stream.truncate(atOffset: 0)
                try stream.write(contentsOf: Data(third.utf8))
            case .rewriteAndGrow: try rewritePrefixAndAppend("third")
            }
        }
        let snapshot = Result { try read(now) }
        if let writeError { throw writeError }
        precondition(change == nil, "Mutation did not run during the scan")
        switch mutation {
        case .append, .repeatedAppend, .finishFragment:
            let totals = try snapshot.get()
            let sampledTotal: Int64 = mutation == .finishFragment ? 11 : 33
            guard totals.allTime == sampledTotal else { throw Failure(message: "Lost verified prefix: \(totals)") }
        case .sustainedAppend, .replace, .truncate, .rewriteAndGrow, .rewriteDuringVerification:
            if case .success(let totals) = snapshot { throw Failure(message: "Accepted inconsistent file: \(totals)") }
        }
        let completed = try reader()(now)
        let expected: Int64
        switch mutation {
        case .append, .finishFragment: expected = 66
        case .repeatedAppend: expected = 110
        case .sustainedAppend: expected = 165
        case .rewriteDuringVerification: expected = 165
        case .rewriteAndGrow: expected = 132
        case .replace, .truncate: expected = 33
        }
        precondition(completed.allTime == expected && !completed.partial)
        bytesRead = 0
        let unchanged = try reader()(now)
        precondition(unchanged == completed && bytesRead == 0)
    }
}
