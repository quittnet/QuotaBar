import Darwin
import Foundation

enum ClaudeTokenHistoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The local Claude Code session history could not be read."
    }
}

/// Read this instance on a serial executor. The index of usage and file cursors stays in memory.
final class ClaudeTokenHistory {
    private let projects: URL
    private let statsCache: URL
    private let calendar: Calendar?
    private let decoder = JSONDecoder()
    private let fractionalDates = ISO8601DateFormatter()
    private let wholeDates = ISO8601DateFormatter()
    private var files: [URL: Transcript] = [:]

    convenience init() {
        let configuredHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let home =
            configuredHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        self.init(home: home)
    }

    init(home: URL, calendar: Calendar? = nil) {
        projects = home.appendingPathComponent("projects", isDirectory: true)
        statsCache = home.appendingPathComponent("stats-cache.json")
        self.calendar = calendar
        fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(now: Date = Date()) throws -> TokenTotals {
        var partial = false
        var candidates = 0
        var next: [URL: Transcript] = [:]
        var rootInfo = stat()
        guard stat(projects.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
            let entries = FileManager.default.enumerator(
                at: projects, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    partial = true
                    return true
                })
        else { return try statsOnly() }

        for case let url as URL in entries where url.pathExtension == "jsonl" {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno != ENOENT { partial = true }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
            candidates += 1
            let revision = FileRevision(info)
            let previous = files[url]
            do {
                if let previous, previous.revision == revision {
                    next[url] = previous
                } else {
                    next[url] = try scan(url, revision: revision, previous: previous)
                }
            } catch {
                partial = true
            }
        }

        guard !next.isEmpty || (candidates == 0 && !partial) else { return try statsOnly() }
        files = next
        return totals(now: now, partial: partial)
    }

    private func statsOnly() throws -> TokenTotals {
        guard let lifetime = readStatsLifetime() else { throw ClaudeTokenHistoryError.unavailable }
        return TokenTotals(
            allTime: 0, month: 0, week: 0, yesterday: 0, today: 0, partial: true, hasRetainedUsage: false,
            claudeStatsLifetime: lifetime)
    }

    private func readStatsLifetime() -> Int64? {
        let descriptor = open(statsCache.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? stream.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0, info.st_size <= 4 * 1024 * 1024,
            let data = try? stream.read(upToCount: Int(info.st_size)),
            let stats = try? decoder.decode(StatsCache.self, from: data), stats.version == 5, !stats.modelUsage.isEmpty
        else { return nil }
        return tokenTotal(stats.modelUsage.values.flatMap(\.counts))
    }

    private func scan(_ url: URL, revision: FileRevision, previous: Transcript?) throws -> Transcript {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClaudeTokenHistoryError.unavailable }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? stream.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            revision.sameFile(as: FileRevision(info)), info.st_size >= revision.size
        else {
            throw ClaudeTokenHistoryError.unavailable
        }

        var transcript = Transcript(revision: revision)
        var prefix = TokenLogPrefix()
        if let previous, revision.sameFile(as: previous.revision), revision.size > previous.revision.size {
            try prefix.extend(in: stream, to: previous.offset)
            if prefix.digest == previous.anchor {
                transcript = previous
                transcript.revision = revision
            } else {
                prefix = TokenLogPrefix()
            }
        }

        try stream.seek(toOffset: transcript.offset)
        var remaining = UInt64(revision.size) - transcript.offset
        let committed = try readTokenLogLines(
            read: {
                guard remaining > 0 else { return Data() }
                let data = try stream.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
                guard !data.isEmpty else { throw ClaudeTokenHistoryError.unavailable }
                remaining -= UInt64(data.count)
                return data
            },
            accept: { line in
                switch line {
                case .complete(let data): accept(data, into: &transcript)
                case .oversized: transcript.partial = true
                }
            })
        transcript.offset += committed

        // Re-read an uncommitted final line on the next append.
        try prefix.extend(in: stream, to: transcript.offset)
        transcript.anchor = prefix.digest
        var endInfo = stat()
        guard fstat(descriptor, &endInfo) == 0, FileRevision(endInfo) == FileRevision(info) else {
            throw ClaudeTokenHistoryError.unavailable
        }
        return transcript
    }

    private func accept(_ line: Data, into transcript: inout Transcript) {
        do {
            let row = try decoder.decode(AssistantRow.self, from: line)
            guard let message = row.message, message.model != "<synthetic>" else { return }
            guard let id = message.id, !id.isEmpty, let usage = message.usage, let count = usage.total else {
                transcript.partial = true
                return
            }
            let date = row.timestamp.flatMap { fractionalDates.date(from: $0) ?? wholeDates.date(from: $0) }
            transcript.usage.append(Sample(id: id, date: date, count: count, finished: message.stopReason != nil))
        } catch {
            transcript.partial = true
        }
    }

    private func totals(now: Date, partial incomplete: Bool) -> TokenTotals {
        var partial = incomplete
        var byMessage: [String: Contribution] = [:]
        for transcript in files.values {
            partial = partial || transcript.partial
            for sample in transcript.usage {
                guard sample.date.map({ $0 <= now }) ?? true else { continue }
                byMessage[sample.id, default: Contribution()].add(sample)
            }
        }

        let days = TokenDayBoundaries(now: now, calendar: calendar ?? .current)
        var all: Int64 = 0
        var month: Int64 = 0
        var week: Int64 = 0
        var yesterday: Int64 = 0
        var today: Int64 = 0

        func add(_ count: Int64, to accumulator: inout Int64) {
            let (value, overflow) = accumulator.addingReportingOverflow(count)
            partial = partial || overflow
            accumulator = overflow ? .max : value
        }

        for value in byMessage.values {
            partial = partial || !value.finished || value.conflicting
            add(value.count, to: &all)
            guard let date = value.date else {
                partial = true
                continue
            }
            if date >= days.month { add(value.count, to: &month) }
            if date >= days.week { add(value.count, to: &week) }
            if date >= days.today {
                add(value.count, to: &today)
            } else if date >= days.yesterday {
                add(value.count, to: &yesterday)
            }
        }
        return TokenTotals(
            allTime: all, month: month, week: week, yesterday: yesterday, today: today, partial: partial,
            hasRetainedUsage: !byMessage.isEmpty,
            // The Stats aggregate has no response identities or date coverage to reconcile with transcripts.
            claudeStatsLifetime: readStatsLifetime()
        )
    }
}

private struct Transcript {
    var revision: FileRevision
    var offset: UInt64 = 0
    var anchor = Data()
    var usage: [Sample] = []
    var partial = false
}

private struct FileRevision: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Int
    let modifiedNanos: Int
    let changed: Int
    let changedNanos: Int
    let created: Int
    let createdNanos: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
        created = info.st_birthtimespec.tv_sec
        createdNanos = info.st_birthtimespec.tv_nsec
    }

    func sameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode && created == other.created && createdNanos == other.createdNanos
    }
}

private struct AssistantRow: Decodable {
    struct Message: Decodable {
        enum CodingKeys: String, CodingKey {
            case id
            case model
            case stopReason = "stop_reason"
            case usage
        }

        let id: String?
        let model: String?
        let stopReason: String?
        let usage: Usage?
    }

    enum CodingKeys: String, CodingKey { case type, timestamp, message }

    let timestamp: String?
    let message: Message?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "assistant" {
            timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
            message = try container.decode(Message.self, forKey: .message)
        } else {
            timestamp = nil
            message = nil
        }
    }
}

private struct Usage: Decodable {
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
    }

    let inputTokens: Int64
    let cacheCreationInputTokens: Int64?
    let cacheReadInputTokens: Int64?
    let outputTokens: Int64

    var total: Int64? {
        // Cache breakdowns and output details describe tokens already counted in these four fields.
        tokenTotal([inputTokens, cacheCreationInputTokens ?? 0, cacheReadInputTokens ?? 0, outputTokens])
    }
}

private struct StatsCache: Decodable {
    struct ModelUsage: Decodable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationInputTokens: Int64
        let cacheReadInputTokens: Int64

        var counts: [Int64] { [inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens] }
    }

    let version: Int
    let modelUsage: [String: ModelUsage]
}

private func tokenTotal(_ counts: [Int64]) -> Int64? {
    var total: Int64 = 0
    for count in counts {
        let (sum, overflow) = total.addingReportingOverflow(count)
        guard count >= 0, !overflow else { return nil }
        total = sum
    }
    return total
}

private struct Sample {
    let id: String
    let date: Date?
    let count: Int64
    let finished: Bool
}

private struct Contribution {
    var count: Int64 = 0
    var date: Date?
    private(set) var finished = false
    private(set) var conflicting = false

    mutating func add(_ sample: Sample) {
        // One message ID can occur in several streamed blocks and in copies of a transcript.
        if sample.finished != finished {
            if sample.finished {
                count = sample.count
                finished = true
            }
        } else if finished && sample.count != count {
            conflicting = true
            count = min(count, sample.count)
        } else {
            count = max(count, sample.count)
        }
        if let observed = sample.date, date.map({ observed < $0 }) ?? true { date = observed }
    }
}
