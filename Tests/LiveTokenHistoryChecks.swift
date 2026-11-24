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
            rewriteDuringVerification, replaceAtLimit, removeAtLimit, rewriteAtLimit
    }

    struct Failure: Error { let message: String }

    static func main() throws {
        var failures: [String] = []
        for provider in Provider.allCases {
            for mutation in Mutation.allCases {
                for withSibling in mutation == .sustainedAppend ? [false, true] : [false] {
                    do {
                        try verify(provider, mutation, withSibling: withSibling)
                    } catch {
                        failures.append("\(provider) \(mutation) withSibling=\(withSibling): \(error)")
                    }
                }
            }
        }
        guard failures.isEmpty else { throw Failure(message: failures.joined(separator: "\n")) }
        print("Concurrent Claude and Codex transcript checks passed.")
    }

    static func verify(_ provider: Provider, _ mutation: Mutation, withSibling: Bool) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(provider == .claude ? "projects" : "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("session.jsonl")
        let cache = home.appendingPathComponent(provider == .claude ? "index.sqlite" : "index.json")
        let first = provider.row("first", 11)
        let second = provider.row("second", 22)
        let third = provider.row("third", 33)
        let sibling: Int64 = withSibling ? 5 : 0
        if withSibling {
            try Data(provider.row("stable", 5).utf8).write(to: directory.appendingPathComponent("stable.jsonl"))
        }
        // The sibling fixture also exercises Claude's sampled checkpoint for a larger transcript.
        let padding =
            withSibling ? "{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 64 * 1024) + "\"}\n" : ""
        try Data((first + padding).utf8).write(to: log)
        let stream = try FileHandle(forWritingTo: log)
        defer { try? stream.close() }
        try stream.seekToEnd()
        var change: (() throws -> Void)?
        var changeAfter = 0
        var writeError: Error?
        var bytesRead = 0
        var keepGrowing = false
        func readBytes(_ count: Int) {
            if keepGrowing {
                do { try stream.write(contentsOf: Data("{\"type\":\"user\"}\n".utf8)) } catch { writeError = error }
            }
            bytesRead += count
            guard bytesRead >= changeAfter, let action = change else { return }
            change = nil
            do { try action() } catch { writeError = error }
        }
        func reader(cacheURL: URL?) -> (Date) throws -> TokenTotals {
            switch provider {
            case .claude:
                return ClaudeTokenHistory(home: home, cacheURL: cacheURL, calendar: .current, didReadBytes: readBytes)
                    .read
            case .codex:
                return TokenHistory(home: home, cacheURL: cacheURL, calendar: .current, didReadBytes: readBytes).read
            }
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
        let read = reader(cacheURL: cache)
        let initial = try read(now)
        precondition(initial.allTime == 11 + sibling && !initial.partial)
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
            case .sustainedAppend:
                try stream.write(contentsOf: Data(third.utf8))
                keepGrowing = true
            case .repeatedAppend, .rewriteDuringVerification, .replaceAtLimit, .removeAtLimit, .rewriteAtLimit:
                try stream.write(contentsOf: Data(third.utf8))
                changeAfter = sampledSize * 2
                change = {
                    if mutation == .rewriteDuringVerification { return try rewritePrefixAndAppend("fourth") }
                    try stream.write(contentsOf: Data(provider.row("fourth", 44).utf8))
                    changeAfter += sampledSize
                    switch mutation {
                    case .replaceAtLimit: change = { try Data(third.utf8).write(to: log, options: .atomic) }
                    case .removeAtLimit: change = { try FileManager.default.removeItem(at: log) }
                    case .rewriteAtLimit: change = { try rewritePrefixAndAppend("fifth") }
                    default: break
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
        case .sustainedAppend:
            let totals = try snapshot.get()
            guard totals.allTime == initial.allTime, totals.today == initial.today, totals.week == initial.week,
                totals.month == initial.month, totals.peakDay == initial.peakDay, totals.spend == initial.spend,
                totals.partial
            else {
                throw Failure(message: "Lost the previous checkpoint during sustained appends: \(totals)")
            }
            let restarted = try reader(cacheURL: cache)(now)
            guard restarted == totals else { throw Failure(message: "Lost the on-disk checkpoint: \(restarted)") }
            let cold = Result { try reader(cacheURL: nil)(now) }
            keepGrowing = false
            if let writeError { throw writeError }
            if withSibling {
                let totals = try cold.get()
                guard totals.partial && totals.allTime == sibling else {
                    throw Failure(message: "Cold scan: \(totals)")
                }
            } else if case .success(let totals) = cold {
                throw Failure(message: "Cold scan accepted an unverified file: \(totals)")
            }
        case .replace, .truncate, .rewriteAndGrow, .rewriteDuringVerification, .replaceAtLimit, .removeAtLimit,
            .rewriteAtLimit:
            if case .success(let totals) = snapshot { throw Failure(message: "Accepted inconsistent file: \(totals)") }
        }
        let completed = try reader(cacheURL: cache)(now)
        let expected: Int64
        switch mutation {
        case .append, .finishFragment, .sustainedAppend: expected = 66
        case .repeatedAppend: expected = 110
        case .rewriteDuringVerification: expected = 165
        case .rewriteAndGrow: expected = 132
        case .replace, .truncate, .replaceAtLimit: expected = 33
        case .removeAtLimit: expected = 0
        case .rewriteAtLimit: expected = 209
        }
        precondition(completed.allTime == expected + sibling && !completed.partial)
        bytesRead = 0
        let unchanged = try reader(cacheURL: cache)(now)
        precondition(unchanged == completed && bytesRead == 0)
    }
}
