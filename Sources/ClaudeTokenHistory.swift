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
        self.init(home: home, cacheURL: Self.cacheFile(for: home))
    }

    static func cacheFile(for home: URL) -> URL? {
        let homeID = SHA256.hash(data: Data(home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map {
            String(format: "%02x", $0)
        }
        .joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.quotabar.QuotaBar", isDirectory: true)
            .appendingPathComponent("claude-history-v2-" + homeID + ".sqlite")
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
        if !cacheLocations.isEmpty, index?.needsReopening == true { index = nil }
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
            return try index.totals(
                now: now, calendar: calendar ?? .current, partial: partial, stats: readStatsLifetime())
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
        guard let id = message.id, !id.isEmpty, let sample = message.sample else {
            transcript.partial = true
            return
        }
        if sample.partial { transcript.partial = true }
        let date = row.timestamp.flatMap { fractionalDates.date(from: $0) ?? wholeDates.date(from: $0) }
        try index.append(
            key: key, id: Self.identifier(id.precomposedStringWithCanonicalMapping), date: date, count: sample.count,
            finished: message.stopReason != nil, usd: sample.usd)
    }
}

private struct Transcript: Codable {
    static let currentUsageRevision = 2
    var usageRevision: Int? = Self.currentUsageRevision
    var revision: ClaudeTranscriptRevision
    var pricingRevision: Int? = TokenPricing.revision
    var offset: UInt64 = 0
    var anchor = Data()
    var samples: Data?
    var partial = false
    /// When every indexed byte was last read or hashed. Older checkpoints decode as unverified.
    var verifiedAt: Date?
    /// Rows were reused after a sampled check, so an edit between the windows may be hidden.
    var sampled: Bool?

    var isValid: Bool {
        usageRevision == Self.currentUsageRevision && pricingRevision == TokenPricing.revision && revision.size >= 0
            && offset <= UInt64(revision.size) && anchor.count == 32
    }

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
            case id, model, usage, content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }

        let id: String?
        let model: String?
        let stopReason: String?
        let sample: (count: Int64, usd: Double?, partial: Bool)?

        init(from decoder: Decoder) throws {
            let message = try decoder.container(keyedBy: CodingKeys.self)
            id = try message.decodeIfPresent(String.self, forKey: .id)
            model = try message.decodeIfPresent(String.self, forKey: .model)
            stopReason = try message.decodeIfPresent(String.self, forKey: .stopReason)
            guard model != "<synthetic>", message.contains(.usage) else {
                sample = nil
                return
            }
            let usage = try message.superDecoder(forKey: .usage)
            let top = try? Usage(from: usage)
            let fields = try usage.container(keyedBy: UsageKeys.self)
            var iterations: [Iteration]
            do {
                iterations = try fields.decodeIfPresent([Iteration].self, forKey: .iterations) ?? []
            } catch {
                // The top-level counters still describe retained usage, but can omit other attempts.
                sample = top?.total.map { ($0, nil, true) }
                return
            }
            let messageIndices = iterations.indices.filter { iterations[$0].type != "compaction" }
            let hasFallbackStep = iterations.contains { $0.type == "fallback_message" }
            let inspectContent = stopReason == "refusal" || hasFallbackStep || messageIndices.count > 1
            let content = inspectContent ? try? message.decode(RefusalContent.self, forKey: .content) : nil
            let handoffs = content?.handoffs ?? []
            let fallback = hasFallbackStep || !handoffs.isEmpty
            // The streaming message_start can name the declined model. Ordered handoffs identify
            // the models that actually ran, even if the saved iteration fields are sparse.
            let hopModels = handoffs.map(\.from) + handoffs.suffix(1).map(\.to)
            let hasHopModels = !handoffs.isEmpty && hopModels.count == messageIndices.count
            var hop = 0
            let details = try? message.decode(RefusalDetails.self, forKey: .stopDetails)
            let finalRefusal =
                stopReason == "refusal"
                ? Refusal(billedBeforeOutput: details?.billedBeforeOutput, hasContent: content?.trailingOutput) : nil
            guard !iterations.isEmpty else {
                if let top, let count = top.total {
                    sample = (count, top.estimatedUSD(model: model, refusal: finalRefusal), false)
                } else {
                    sample = nil
                }
                return
            }

            // Each entry is a distinct sampling step. Top-level usage overlaps the returned message.
            var count: Int64 = 0
            var usd: Double? = 0
            // Top-level usage aggregates non-compaction sampling steps when server tools run.
            // Recover any cache totals retained only at the top level, once across those steps.
            if !fallback, messageIndices.count > 1, let top {
                top.attributeCacheReads(in: &iterations, messageIndices: messageIndices)
            }
            let messageSteps = messageIndices.map { iterations[$0] }
            let aggregate = !fallback && messageSteps.count > 1 ? top?.reconcilingCache(in: messageSteps) : nil
            if let aggregate {
                guard let tokens = aggregate.usage.total else {
                    sample = nil
                    return
                }
                count = tokens
                let responseModel = model
                let models = Set(
                    messageSteps.map { ($0.model ?? responseModel).map(TokenPricing.canonicalClaudeModel) })
                usd =
                    models.count == 1 && finalRefusal == nil
                    ? aggregate.usage.estimatedUSD(
                        model: models.first ?? nil, refusal: nil, promptRange: aggregate.prompts)
                    : nil
            }
            for (i, iteration) in iterations.enumerated() {
                if aggregate != nil && iteration.type != "compaction" { continue }
                let last = i == iterations.count - 1
                let matchesReturnedUsage = iteration.type != "compaction" && (fallback ? last : messageSteps.count == 1)
                var counters = iteration.usage
                if matchesReturnedUsage, let top { counters.fillMissingCache(from: top) }
                guard let tokens = counters.total, let sum = tokenTotal([count, tokens]) else {
                    sample = top?.total.map { ($0, nil, true) }
                    return
                }
                count = sum
                let boundaryModel = hasHopModels && iteration.type != "compaction" ? hopModels[hop] : nil
                if iteration.type != "compaction" { hop += 1 }
                let inferredModel = fallback && messageSteps.count > 1 ? boundaryModel : model
                let attemptModel = iteration.model ?? inferredModel
                var refusal: Refusal?
                if iteration.type != "compaction" {
                    if last {
                        refusal = finalRefusal
                    } else if fallback {
                        refusal = attemptModel.flatMap { content?.declines[$0] } ?? Refusal()
                    }
                }
                if let known = usd, let cost = counters.estimatedUSD(model: attemptModel, refusal: refusal) {
                    usd = known + cost
                } else {
                    usd = nil
                }
            }
            sample = (count, usd, false)
        }
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

private enum UsageKeys: String, CodingKey { case iterations }

private struct Iteration: Decodable {
    enum CodingKeys: String, CodingKey { case type, model }
    let type: String?
    let model: String?
    var usage: Usage

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decodeIfPresent(String.self, forKey: .type)
        model = try fields.decodeIfPresent(String.self, forKey: .model)
        usage = try Usage(from: decoder)
    }
}

private struct Refusal {
    var billedBeforeOutput: Bool?
    var hasContent: Bool?
}

private struct RefusalDetails: Decodable {
    enum CodingKeys: String, CodingKey { case category, type }
    let billedBeforeOutput: Bool?
    let type: String?

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decodeIfPresent(String.self, forKey: .type)
        // An explicit null is an unbilled category. An absent category carries no billing evidence.
        if let category = try fields.decodeIfPresent(String.self, forKey: .category) {
            billedBeforeOutput = ["bio", "frontier_llm", "reasoning_extraction"].contains(category)
        } else {
            billedBeforeOutput = fields.contains(.category) ? false : nil
        }
    }
}

private struct RefusalContent: Decodable {
    enum CodingKeys: String, CodingKey { case type, from, to, trigger }
    private struct Source: Decodable { let model: String }
    var handoffs = [(from: String, to: String?)]()
    var declines = [String: Refusal]()
    var trailingOutput = false

    init(from decoder: Decoder) throws {
        var blocks = try decoder.unkeyedContainer()
        while !blocks.isAtEnd {
            let block = try blocks.nestedContainer(keyedBy: CodingKeys.self)
            if try block.decode(String.self, forKey: .type) == "fallback" {
                let model = try block.decode(Source.self, forKey: .from).model
                let next = try block.decodeIfPresent(Source.self, forKey: .to)?.model
                handoffs.append((model, next))
                let trigger = try block.decode(RefusalDetails.self, forKey: .trigger)
                if trigger.type == "refusal" {
                    declines[model] = Refusal(
                        billedBeforeOutput: trigger.billedBeforeOutput, hasContent: trailingOutput)
                }
                trailingOutput = false
            } else {
                trailingOutput = true
            }
        }
    }
}

private struct Usage: Decodable {
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreation = "cache_creation"
    }

    let inputTokens: Int64
    var cacheCreationInputTokens: Int64?
    var cacheReadInputTokens: Int64?
    let outputTokens: Int64

    private var cacheCreation: CacheCreation?

    private struct CacheCreation: Decodable {
        struct Breakdown: Decodable {
            enum CodingKeys: String, CodingKey {
                case fiveMinute = "ephemeral_5m_input_tokens"
                case oneHour = "ephemeral_1h_input_tokens"
            }

            let fiveMinute: Int64?
            let oneHour: Int64?
        }

        let breakdown: Breakdown?

        init?(reconciling steps: [Usage], total: Int64, reported: CacheCreation?) {
            var shortTotal: Int64 = 0
            var longTotal: Int64 = 0
            for step in steps {
                // A readable aggregate can supply a split omitted or unreadable on this step.
                guard let split = step.cacheCreation?.breakdown else { continue }
                let writes = step.cacheCreationInputTokens ?? 0
                let short = split.fiveMinute ?? 0
                let long = split.oneHour ?? 0
                guard short >= 0, short <= writes, writes - short == long else { return nil }
                // Each duration is bounded by the checked sum of all step writes.
                shortTotal += short
                longTotal += long
            }
            if let reported {
                guard let split = reported.breakdown, (split.fiveMinute ?? 0) >= shortTotal,
                    (split.oneHour ?? 0) >= longTotal
                else { return nil }
                breakdown = split
            } else {
                guard total - shortTotal == longTotal else { return nil }
                breakdown = Breakdown(fiveMinute: shortTotal, oneHour: longTotal)
            }
        }

        init(from decoder: Decoder) {
            // A malformed optional pricing detail must not discard an otherwise countable response.
            breakdown = try? Breakdown(from: decoder)
        }
    }

    mutating func fillMissingCache(from top: Usage) {
        guard inputTokens == top.inputTokens, outputTokens == top.outputTokens else { return }
        cacheReadInputTokens = cacheReadInputTokens ?? top.cacheReadInputTokens
        cacheCreationInputTokens = cacheCreationInputTokens ?? top.cacheCreationInputTokens
        if cacheCreationInputTokens == top.cacheCreationInputTokens {
            cacheCreation = cacheCreation ?? top.cacheCreation
        }
    }

    // When exactly one server-tool step omits cache reads, the aggregate determines
    // its count. Keep the individual prompts and models for tiered per-step pricing.
    func attributeCacheReads(in iterations: inout [Iteration], messageIndices: [Int]) {
        guard let totalReads = cacheReadInputTokens, totalReads > 0 else { return }
        let missing = messageIndices.filter { iterations[$0].usage.cacheReadInputTokens == nil }
        guard missing.count == 1, let index = missing.first,
            tokenTotal(messageIndices.map { iterations[$0].usage.inputTokens }) == inputTokens,
            tokenTotal(messageIndices.map { iterations[$0].usage.outputTokens }) == outputTokens,
            let known = tokenTotal(messageIndices.map { iterations[$0].usage.cacheReadInputTokens ?? 0 }),
            totalReads > known
        else { return }
        if let reported = cacheCreation {
            // Preserve aggregate write-duration evidence when allocating reads would otherwise
            // bypass reconciliation. Every recorded per-step duration must explain that split.
            let steps = messageIndices.map { iterations[$0].usage }
            guard let writes = tokenTotal(steps.map { $0.cacheCreationInputTokens ?? 0 }),
                writes == cacheCreationInputTokens ?? 0, let split = reported.breakdown,
                let recorded = CacheCreation(reconciling: steps, total: writes, reported: nil)?.breakdown,
                (split.fiveMinute ?? 0) == (recorded.fiveMinute ?? 0),
                (split.oneHour ?? 0) == (recorded.oneHour ?? 0)
            else { return }
        }
        iterations[index].usage.cacheReadInputTokens = totalReads - known
    }

    func reconcilingCache(in steps: [Iteration]) -> (usage: Usage, prompts: ClosedRange<Int64>)? {
        let usages = steps.map(\.usage)
        guard tokenTotal(usages.map(\.inputTokens)) == inputTokens,
            tokenTotal(usages.map(\.outputTokens)) == outputTokens,
            let reads = tokenTotal(usages.map { $0.cacheReadInputTokens ?? 0 }),
            let writes = tokenTotal(usages.map { $0.cacheCreationInputTokens ?? 0 })
        else { return nil }
        let allReads = max(cacheReadInputTokens ?? 0, reads)
        let allWrites = max(cacheCreationInputTokens ?? 0, writes)
        let missingTTL =
            cacheCreation != nil
            && usages.contains {
                ($0.cacheCreationInputTokens ?? 0) > 0 && $0.cacheCreation == nil
            }
        guard allReads > reads || allWrites > writes || missingTTL else { return nil }
        let knownPrompts = usages.compactMap {
            tokenTotal([$0.inputTokens, $0.cacheReadInputTokens ?? 0, $0.cacheCreationInputTokens ?? 0])
        }
        guard knownPrompts.count == usages.count, let smallest = knownPrompts.min(),
            let largest = knownPrompts.max(),
            let upper = tokenTotal([largest, allReads - reads, allWrites - writes])
        else { return nil }
        var aggregate = self
        aggregate.cacheReadInputTokens = allReads
        aggregate.cacheCreationInputTokens = allWrites
        if allWrites > 0 {
            // Aggregate-only reads can coexist with write durations recorded exclusively on each step.
            let reported = cacheCreationInputTokens == allWrites ? cacheCreation : nil
            aggregate.cacheCreation = CacheCreation(reconciling: usages, total: allWrites, reported: reported)
        }
        return (aggregate, smallest...upper)
    }

    func estimatedUSD(model: String?, refusal: Refusal?, promptRange: ClosedRange<Int64>? = nil) -> Double? {
        // A mid-stream refusal bills normal input/output rates, even if partial output was omitted.
        if let refusal, outputTokens == 0, refusal.hasContent != true, refusal.billedBeforeOutput != true {
            return refusal.hasContent == false && refusal.billedBeforeOutput == false ? 0 : nil
        }
        if let cacheCreation, cacheCreation.breakdown == nil { return nil }
        return TokenPricing.claude(
            model: model, input: inputTokens, cacheRead: cacheReadInputTokens ?? 0,
            cacheWrite: cacheCreationInputTokens ?? 0,
            write5m: cacheCreation?.breakdown?.fiveMinute,
            write1h: cacheCreation?.breakdown?.oneHour, output: outputTokens, promptRange: promptRange)
    }

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
