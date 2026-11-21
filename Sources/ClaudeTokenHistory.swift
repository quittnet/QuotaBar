import CryptoKit
import Darwin
import Foundation

enum ClaudeTokenHistoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The local Claude Code session history could not be read."
    }
}

/// Confine the reader and its SQLite connection to the token reader actor.
final class ClaudeTokenHistory {
    /// Maximum time a sampled append check can hide an edit between its windows.
    static let fullCheckInterval: TimeInterval = 24 * 60 * 60
    private let projects: URL
    private let statsCache: URL
    private let calendar: Calendar?
    private let decoder = JSONDecoder()
    private let fractionalDates = ISO8601DateFormatter()
    private let wholeDates = ISO8601DateFormatter()
    private var cacheLocations: [URL]
    private let didReadBytes: ((Int) -> Void)?
    private var index: ClaudeHistoryIndex?

    convenience init(profile home: URL = ClaudeProfile.directory) {
        let homeID = SHA256.hash(data: Data(home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map {
            String(format: "%02x", $0)
        }
        .joined()
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.quotabar.QuotaBar", isDirectory: true)
            .appendingPathComponent("claude-history-v1-" + homeID + ".sqlite")
        self.init(home: home, cacheURL: cacheURL)
    }

    init(home: URL, cacheURL: URL? = nil, calendar: Calendar? = nil, didReadBytes: ((Int) -> Void)? = nil) {
        // A damaged main database can be rebuilt in a sibling without unlinking an open cache.
        cacheLocations = cacheURL.map { [$0, $0.appendingPathExtension("rebuilt")] } ?? []
        self.didReadBytes = didReadBytes
        projects = home.appendingPathComponent("projects", isDirectory: true)
        statsCache = home.appendingPathComponent("stats-cache.json")
        self.calendar = calendar
        fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(now: Date = Date()) throws -> TokenTotals {
        while true {
            let url = cacheLocations.first
            do {
                let current = try index ?? ClaudeHistoryIndex(url: url)
                index = current
                return try read(current, now: now)
            } catch let error as ClaudeHistoryIndex.Failure where error.isContention {
                throw error
            } catch {
                guard url != nil, index == nil || error is ClaudeHistoryIndex.Failure else { throw error }
                index = nil
                cacheLocations.removeFirst()
            }
        }
    }

    private func read(_ index: ClaudeHistoryIndex, now: Date) throws -> TokenTotals {
        var partial = false
        var candidates = 0
        var readable = 0
        var rootInfo = stat()
        guard stat(projects.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
            let entries = FileManager.default.enumerator(
                at: projects, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    partial = true
                    return true
                })
        else { return try statsOnly() }

        return try index.transaction {
            try index.resetVisible()
            for case let url as URL in entries where url.pathExtension == "jsonl" {
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    if errno != ENOENT { partial = true }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                candidates += 1
                let key = Self.identifier(url.path)
                let revision = ClaudeTranscriptRevision(info)
                do {
                    let filePartial = try autoreleasepool {
                        let previous = try index.checkpoint(key).flatMap {
                            try? decoder.decode(Transcript.self, from: $0)
                        }
                        if let previous, previous.isValid, previous.revision == revision,
                            !previous.needsFullCheck(at: now)
                        {
                            return previous.partial
                        }
                        return try index.withFileSavepoint {
                            let updated = try scan(
                                url, key: key, index: index, revision: revision, previous: previous, now: now)
                            try index.save(key: key, checkpoint: JSONEncoder().encode(updated))
                            return updated.partial
                        }
                    }
                    try index.include(key)
                    readable += 1
                    partial = partial || filePartial
                } catch let error as ClaudeHistoryIndex.Failure {
                    throw error
                } catch {
                    partial = true
                }
            }
            guard readable > 0 || (candidates == 0 && !partial) else { return try statsOnly() }
            try index.pruneInvisible()
            let days = TokenDayBoundaries(now: now, calendar: calendar ?? .current)
            return try index.totals(now: now, days: days, partial: partial, stats: readStatsLifetime())
        }
    }

    private static func identifier(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
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

    private func scan(
        _ url: URL, key: String, index: ClaudeHistoryIndex, revision listed: ClaudeTranscriptRevision,
        previous: Transcript?, now: Date
    ) throws -> Transcript {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClaudeTokenHistoryError.unavailable }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? stream.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            listed.sameFile(as: ClaudeTranscriptRevision(info)), info.st_size >= listed.size
        else {
            throw ClaudeTokenHistoryError.unavailable
        }

        let revision = ClaudeTranscriptRevision(info)
        var transcript = Transcript(revision: revision)
        var prefix = TokenLogPrefix()
        var verifyCachedPrefix: (() throws -> Bool)?
        var readStart: UInt64 = 0
        var fullyVerified = true
        if let previous, previous.isValid, revision.canReuseAfterGrowth(from: previous.revision, observed: listed) {
            let originalSize = UInt64(previous.revision.size)
            let matches: Bool
            if let samples = TranscriptSamples(length: originalSize) {
                // Build 38 saved only a full hash. Reindex its large checkpoint once on the first change.
                // Samples cannot see edits between windows, so rebuild from every byte at least once a day.
                if let digest = previous.samples, !previous.verificationExpired(at: now) {
                    let verify = { [didReadBytes] in
                        var check = samples
                        try check.readPrefix(in: stream, until: originalSize, didReadBytes: didReadBytes)
                        return check.digest == digest
                    }
                    matches = try verify()
                    if matches {
                        verifyCachedPrefix = verify
                        fullyVerified = false
                    }
                } else {
                    matches = false
                }
            } else {
                try prefix.extend(in: stream, to: previous.offset, didReadBytes: didReadBytes)
                matches = prefix.digest == previous.anchor
            }
            if matches {
                transcript = previous
                transcript.revision = revision
                readStart = previous.offset
                if verifyCachedPrefix != nil {
                    if originalSize - previous.offset > TokenLogLine.maximumSize {
                        // The uncommitted row already exceeds the decoder limit. Resume at its old EOF.
                        readStart = originalSize
                    }
                    prefix = TokenLogPrefix(start: readStart)
                }
            } else {
                prefix = TokenLogPrefix()
            }
        }

        if transcript.offset == 0 { try index.replace(key) }
        var samples = TranscriptSamples(length: UInt64(revision.size))
        try samples?.readPrefix(in: stream, until: readStart, didReadBytes: didReadBytes)
        let snapshot = try readTokenLogSnapshot(
            stream, at: url, opened: info, from: readStart, prefix: prefix, didReadBytes: didReadBytes,
            continuingOversizedLine: readStart > transcript.offset,
            observe: { bytes, offset in samples?.observe(bytes, at: offset) }, verifyCachedPrefix: verifyCachedPrefix,
            accept: { line in
                switch line {
                case .complete(let data):
                    try accept(data, key: key, index: index, transcript: &transcript)
                case .oversized: transcript.partial = true
                }
            })
        if snapshot.offset > readStart { transcript.offset = snapshot.offset }
        transcript.anchor = snapshot.anchor
        transcript.samples = samples?.digest
        if fullyVerified {
            transcript.verifiedAt = now
            transcript.sampled = nil
        } else {
            transcript.sampled = true
        }
        return transcript
    }

    private func accept(_ line: Data, key: String, index: ClaudeHistoryIndex, transcript: inout Transcript) throws {
        guard let row = try? decoder.decode(AssistantRow.self, from: line) else {
            transcript.partial = true
            return
        }
        guard let message = row.message, message.model != "<synthetic>" else { return }
        guard let id = message.id, !id.isEmpty, let usage = message.usage, let count = usage.total else {
            transcript.partial = true
            return
        }
        let date = row.timestamp.flatMap { fractionalDates.date(from: $0) ?? wholeDates.date(from: $0) }
        try index.append(
            key: key, id: Self.identifier(id.precomposedStringWithCanonicalMapping), date: date, count: count,
            finished: message.stopReason != nil)
    }
}

private struct Transcript: Codable {
    var revision: ClaudeTranscriptRevision
    var offset: UInt64 = 0
    var anchor = Data()
    var samples: Data?
    var partial = false
    /// When every indexed byte was last read or hashed. Older checkpoints decode as unverified.
    var verifiedAt: Date?
    /// Rows were reused after a sampled check, so an edit between the windows may be hidden.
    var sampled: Bool?

    var isValid: Bool { revision.size >= 0 && offset <= UInt64(revision.size) && anchor.count == 32 }

    func verificationExpired(at now: Date) -> Bool {
        // A clock moved backward also forces a full check instead of trusting a future timestamp.
        verifiedAt.map { $0 > now || now.timeIntervalSince($0) >= ClaudeTokenHistory.fullCheckInterval } ?? true
    }

    func needsFullCheck(at now: Date) -> Bool { sampled == true && verificationExpired(at: now) }
}

// A grow-only stat change cannot distinguish an append from an edit followed by an append.
// Check eight 4 KiB windows including both ends. A same-inode rewrite confined to the gaps
// followed by growth escapes this check until the daily full check rebuilds the file.
// Same-size edits and shrinking files are fully rescanned.
private struct TranscriptSamples {
    private static let width: UInt64 = 4096
    private static let count: UInt64 = 8
    private let ranges: [Range<UInt64>]
    private var hash = SHA256()
    var digest: Data { Data(hash.finalize()) }

    init?(length: UInt64) {
        guard length > Self.width * Self.count else { return nil }
        let span = length - Self.width
        let intervals = Self.count - 1
        ranges = (0..<Self.count).map { index in
            let start = (span / intervals) * index + (span % intervals) * index / intervals
            return start..<(start + Self.width)
        }
    }

    mutating func readPrefix(in stream: FileHandle, until end: UInt64, didReadBytes: ((Int) -> Void)?) throws {
        for range in ranges where range.lowerBound < end {
            try stream.seek(toOffset: range.lowerBound)
            var remaining = Int(min(end, range.upperBound) - range.lowerBound)
            while remaining > 0 {
                guard let data = try stream.read(upToCount: remaining), !data.isEmpty else {
                    throw ClaudeTokenHistoryError.unavailable
                }
                hash.update(data: data)
                remaining -= data.count
                didReadBytes?(data.count)
            }
        }
    }

    mutating func observe(_ data: Data, at offset: UInt64) {
        let chunk = offset..<(offset + UInt64(data.count))
        for range in ranges where range.overlaps(chunk) {
            let start = data.startIndex + Int(max(offset, range.lowerBound) - offset)
            let end = data.startIndex + Int(min(chunk.upperBound, range.upperBound) - offset)
            hash.update(data: data[start..<end])
        }
    }
}

struct ClaudeTranscriptRevision: Codable, Equatable {
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

    func canReuseAfterGrowth(from prior: Self, observed: Self) -> Bool {
        // An edit or truncation already observed by lstat remains evidence even if a writer appends before open.
        prior.sameFile(as: observed) && observed.size > prior.size
            && (self == observed || (sameFile(as: observed) && size > observed.size))
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
