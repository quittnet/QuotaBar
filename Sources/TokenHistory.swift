import CryptoKit
import Darwin
import Foundation
import SQLite3

struct TokenDayBoundaries {
    let today: Date
    let yesterday: Date
    let week: Date
    let month: Date

    init(now: Date, calendar: Calendar) {
        today = calendar.startOfDay(for: now)
        yesterday = calendar.date(byAdding: .day, value: -1, to: today).map(calendar.startOfDay(for:)) ?? today
        week = calendar.date(byAdding: .day, value: -6, to: today).map(calendar.startOfDay(for:)) ?? today
        month = calendar.date(byAdding: .day, value: -29, to: today).map(calendar.startOfDay(for:)) ?? today
    }
}

struct TokenPeakDay: Sendable, Equatable {
    let date: Date
    let tokens: Int64
}

struct TokenDailyUsage {
    private let calendar: Calendar
    private var intervals: [Double: [DateInterval]] = [:]
    private var totals: [Date: Int64] = [:]

    init(calendar: Calendar) { self.calendar = calendar }

    mutating func add(_ tokens: Int64, on date: Date, latestDate: Date? = nil, partial: inout Bool) {
        guard tokens > 0 else { return }
        // A UTC day is only a lookup key. Its records can belong to different local days,
        // including days shortened or extended by a clock change.
        let key = floor(date.timeIntervalSinceReferenceDate / 86_400)
        let interval: DateInterval
        if let known = intervals[key]?.first(where: { $0.start <= date && date < $0.end }) {
            interval = known
        } else {
            guard let day = calendar.dateInterval(of: .day, for: date) else {
                partial = true
                return
            }
            intervals[key, default: []].append(day)
            interval = day
        }
        if let latestDate, latestDate >= interval.end { return }
        totals[interval.start] = cappedSum(totals[interval.start, default: 0], tokens, partial: &partial)
    }

    var peak: TokenPeakDay? {
        totals.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }.map { TokenPeakDay(date: $0.key, tokens: $0.value) }
    }
}

struct TokenTotals: Sendable, Equatable {
    let allTime: Int64
    let month: Int64
    let week: Int64
    let yesterday: Int64
    let today: Int64
    let partial: Bool
    var hasRetainedUsage: Bool = true
    var claudeStatsLifetime: Int64? = nil
    var spend = TokenSpendTotals()
    var peakDay: TokenPeakDay? = nil
}

enum TokenHistoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The local Codex session history could not be read."
    }
}

func resolveTokenHistoryRoot(_ url: URL, info: inout stat) -> URL? {
    guard lstat(url.path, &info) == 0 else { return nil }
    // Foundation skips a symlink used as the enumeration root. Keep the original path for ordinary roots.
    guard (info.st_mode & S_IFMT) == S_IFLNK else { return url }
    guard let path = realpath(url.path, nil) else { return nil }
    defer { free(path) }
    let resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true)
    guard lstat(resolved.path, &info) == 0 else { return nil }
    return resolved
}

/// The cache stores only file identities, offsets and token-accounting fields.
/// Keep an instance on the serial queue that reads local history.
final class TokenHistory {
    private struct RootIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct TranscriptVisit: Hashable {
        let fingerprint: LogFingerprint
        let compressed: Bool
    }

    private let home: URL
    private let cacheURL: URL?
    private let calendar: Calendar?
    private let didReadBytes: ((Int) -> Void)?
    private let compression: CompressedLogConfiguration
    private var nextCompressedPath: String?
    private let decoder = JSONDecoder()
    private let dates = ISO8601DateFormatter()
    private let wholeSecondDates = ISO8601DateFormatter()
    private var files: [String: HistoryFile] = [:]
    private var skips: [String: ArchiveSkip] = [:]
    private var diskCache: CodexHistoryCache?
    private var maximumCacheBytes = 128 * 1024 * 1024
    private var pendingWrites = Set<String>()
    private var checkCacheIntegrity = false
    private var checkedLegacy = false
    private var legacyRevision: LogFingerprint?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let configuredHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        home =
            configuredHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.quotabar.QuotaBar", isDirectory: true)
            .appendingPathComponent("token-history.json")
        didReadBytes = nil
        calendar = nil
        compression = CompressedLogConfiguration()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    init(
        home: URL, cacheURL: URL? = nil, calendar: Calendar,
        compression: CompressedLogConfiguration = CompressedLogConfiguration(),
        maximumCacheBytes: Int = 128 * 1024 * 1024, didReadBytes: ((Int) -> Void)? = nil
    ) {
        self.home = home
        self.cacheURL = cacheURL
        self.calendar = calendar
        self.didReadBytes = didReadBytes
        self.compression = compression
        self.maximumCacheBytes = maximumCacheBytes
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(now: Date = Date()) throws -> TokenTotals {
        loadCache()
        var changed = Set<String>()
        let decoderFile = compression.binary.flatMap(DecoderRevision.init)
        let fm = FileManager.default
        var foundRoot = false
        var visitedRoots = Set<RootIdentity>()
        var visitedFiles = Set<TranscriptVisit>()
        var enumerationFailed = false
        var readable = 0
        var candidates = 0
        var next: [String: HistoryFile] = [:]
        var nextSkips: [String: ArchiveSkip] = [:]
        var archives: [(url: URL, fingerprint: LogFingerprint)] = []
        var roots: [(url: URL, identity: RootIdentity, linked: Bool)] = []

        for directory in ["sessions", "archived_sessions"] {
            let configuredRoot = home.appendingPathComponent(directory, isDirectory: true)
            var rootStat = stat()
            guard let root = resolveTokenHistoryRoot(configuredRoot, info: &rootStat) else {
                if errno != ENOENT { enumerationFailed = true }
                continue
            }
            guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
                enumerationFailed = true
                continue
            }
            let identity = RootIdentity(device: rootStat.st_dev, inode: rootStat.st_ino)
            roots.append((root, identity, root != configuredRoot))
        }
        let deduplicateFiles = roots.count > 1 && roots.contains { $0.linked }
        for (root, identity, _) in roots {
            guard !visitedRoots.contains(identity) else { continue }
            guard
                let entries = fm.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    errorHandler: { _, error in
                        let error = error as NSError
                        if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                            enumerationFailed = true
                        }
                        return true
                    })
            else {
                enumerationFailed = true
                continue
            }
            foundRoot = true
            visitedRoots.insert(identity)
            for case let url as URL in entries {
                let compressed = url.lastPathComponent.hasSuffix(".jsonl.zst")
                guard url.pathExtension == "jsonl" || compressed else { continue }
                let path = url.path
                var info = stat()
                guard lstat(path, &info) == 0 else {
                    if errno != ENOENT { enumerationFailed = true }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let fingerprint = LogFingerprint(info)
                // Linked roots can overlap. Account for each unchanged physical transcript once per refresh.
                if deduplicateFiles,
                    !visitedFiles.insert(TranscriptVisit(fingerprint: fingerprint, compressed: compressed)).inserted
                {
                    continue
                }
                candidates += 1
                do {
                    if let previous = files[path], previous.fingerprint == fingerprint {
                        next[path] = previous
                    } else if compressed {
                        if let skip = skips[path],
                            skip.applies(
                                to: fingerprint, decoder: decoderFile, budget: compression.maximumBytes, at: now)
                        {
                            nextSkips[path] = skip
                            enumerationFailed = true
                        } else {
                            archives.append((url, fingerprint))
                        }
                        continue
                    } else {
                        next[path] = try scan(
                            url, fingerprint: fingerprint, previous: files[path])
                        changed.insert(path)
                    }
                    readable += 1
                } catch TokenLogSnapshotError.verifiedPreviousCheckpoint {
                    next[path] = files[path]
                    readable += 1
                    enumerationFailed = true
                } catch {
                    enumerationFailed = true
                }
            }
        }
        // Rotate after reaching the shared budget so one slow or oversized archive cannot starve later ones.
        archives.sort { $0.url.path < $1.url.path }
        let start = nextCompressedPath.flatMap { path in archives.firstIndex { $0.url.path >= path } } ?? 0
        nextCompressedPath = nil
        let budget = CompressedLogBudget(compression)
        for step in archives.indices {
            let index = (start + step) % archives.count
            let archive = archives[index]
            if budget.exhausted {
                nextCompressedPath = archive.url.path
                enumerationFailed = true
                break
            }
            let startedWithFullBudget = budget.remainingBytes == compression.maximumBytes
            do {
                next[archive.url.path] = try scan(archive.url, fingerprint: archive.fingerprint, budget: budget)
                readable += 1
                changed.insert(archive.url.path)
            } catch {
                enumerationFailed = true
                if case CompressedLogError.byteLimitExceeded = error, startedWithFullBudget {
                    nextSkips[archive.url.path] = ArchiveSkip(
                        fingerprint: archive.fingerprint, limit: compression.maximumBytes)
                } else if case CompressedLogError.decoderRejected = error, let decoderFile {
                    nextSkips[archive.url.path] = ArchiveSkip(
                        fingerprint: archive.fingerprint, decoder: decoderFile, failedAt: now)
                }
                if budget.exhausted && step > 0 {
                    // Give an interrupted archive one attempt with a full budget on the next refresh.
                    nextCompressedPath = archive.url.path
                    break
                }
            }
        }
        let oldKeys = Set(files.keys).union(skips.keys)
        let newKeys = Set(next.keys).union(nextSkips.keys)
        let removed = oldKeys.subtracting(newKeys)
        for (path, skip) in nextSkips where skips[path] != skip { changed.insert(path) }
        files = next
        skips = nextSkips
        if cacheURL != nil {
            pendingWrites.formUnion(removed)
            pendingWrites.formUnion(changed)
            persistChanges()
        }
        guard foundRoot, readable > 0 || (candidates == 0 && !enumerationFailed) else {
            throw TokenHistoryError.unavailable
        }
        return totals(now: now, partial: enumerationFailed)
    }

    private struct DiskEntry: Codable {
        let file: HistoryFile?
        let skip: ArchiveSkip?
    }

    private func loadCache() {
        guard let cacheURL else { return }
        let homePath = home.standardizedFileURL.path
        if diskCache?.needsReopening == true {
            // A cache cleanup can unlink an open database. Repopulate its replacement from memory.
            diskCache = nil
            pendingWrites.formUnion(files.keys)
            pendingWrites.formUnion(skips.keys)
        }
        if diskCache == nil,
            let db = CodexHistoryCache(
                url: cacheURL.appendingPathExtension("sqlite"), home: homePath,
                maximumBytes: maximumCacheBytes, checkIntegrity: checkCacheIntegrity)
        {
            var added = Set<String>()
            let status = db.load { path, data in
                guard files[path] == nil, skips[path] == nil, !pendingWrites.contains(path),
                    let entry = try? decoder.decode(DiskEntry.self, from: data)
                else { return }
                if let file = entry.file, file.valid(for: path) {
                    files[path] = file
                    added.insert(path)
                } else if let skip = entry.skip {
                    skips[path] = skip
                    added.insert(path)
                }
            }
            if status == SQLITE_DONE {
                diskCache = db
                checkCacheIntegrity = false
            } else {
                for path in added {
                    files[path] = nil
                    skips[path] = nil
                }
                if status == SQLITE_CORRUPT || status == SQLITE_NOTADB { checkCacheIntegrity = true }
            }
        }
        guard !checkedLegacy else { return }
        checkedLegacy = true
        var info = stat()
        guard lstat(cacheURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
            let data = try? PrivateFile.read(cacheURL, maximumBytes: 128 * 1024 * 1024),
            let cache = try? decoder.decode(HistoryCache.self, from: data),
            cache.version == HistoryCache.currentVersion, cache.home == homePath
        else { return }
        legacyRevision = LogFingerprint(info)
        for (path, file) in cache.files where files[path] == nil && skips[path] == nil && file.valid(for: path) {
            files[path] = file
            pendingWrites.insert(path)
        }
        if let old = cache.archiveOverflows {
            for (path, revision) in old.fingerprints where files[path] == nil && skips[path] == nil {
                skips[path] = ArchiveSkip(fingerprint: revision, limit: old.maximumBytes)
                pendingWrites.insert(path)
            }
        }
    }

    private func persistChanges() {
        guard let diskCache else { return }
        // Free pages first, even when a new log is too large to fit the cache.
        let removed = pendingWrites.filter { files[$0] == nil && skips[$0] == nil }
        let paths = Array(removed) + pendingWrites.subtracting(removed).sorted()
        let encoder = JSONEncoder()
        let status = diskCache.save(paths: paths) { path in
            guard files[path] != nil || skips[path] != nil else { return nil }
            return try encoder.encode(DiskEntry(file: files[path], skip: skips[path]))
        } acknowledge: { completed in
            pendingWrites.subtract(completed)
        }
        if status == SQLITE_CORRUPT || status == SQLITE_NOTADB {
            self.diskCache = nil
            checkCacheIntegrity = true
            pendingWrites.formUnion(files.keys)
            pendingWrites.formUnion(skips.keys)
        }
        if status == SQLITE_OK, let legacyRevision, pendingWrites.isEmpty, let cacheURL {
            var info = stat()
            if lstat(cacheURL.path, &info) == 0, LogFingerprint(info) == legacyRevision {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            self.legacyRevision = nil
        }
    }

    private func scan(
        _ url: URL, fingerprint: LogFingerprint, previous: HistoryFile? = nil, budget: CompressedLogBudget? = nil
    ) throws -> HistoryFile {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw TokenHistoryError.unavailable }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? stream.close() }
        var info = stat()
        guard fstat(stream.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            fingerprint.sameFile(as: LogFingerprint(info)), info.st_size >= fingerprint.size
        else {
            throw TokenHistoryError.unavailable
        }

        if let budget {
            let decoder = try CompressedLog(input: stream, configuration: compression, budget: budget)
            defer { decoder.close() }
            let result = Result {
                var file = HistoryFile(fingerprint: fingerprint)
                file.offset = try readTokenLogLines(read: decoder.read) { accept($0, into: &file) }
                try decoder.finish()
                return file
            }
            var endInfo = stat()
            guard lstat(url.path, &endInfo) == 0, LogFingerprint(endInfo) == fingerprint else {
                throw TokenHistoryError.unavailable
            }
            return try result.get()
        }

        let opened = LogFingerprint(info)
        var file = HistoryFile(fingerprint: opened)
        var prefix = TokenLogPrefix()
        if let previous, previous.fingerprint.sameFile(as: opened),
            previous.fingerprint.size >= 0, previous.offset <= UInt64(previous.fingerprint.size),
            opened.size > previous.fingerprint.size
        {
            try prefix.extend(in: stream, to: previous.offset, didReadBytes: didReadBytes)
            if prefix.digest == previous.anchor {
                file = previous
                file.fingerprint = opened
                file.parserRevision = HistoryFile.currentParserRevision
            } else {
                prefix = TokenLogPrefix()
            }
        }
        let snapshot = try readTokenLogSnapshot(
            stream, at: url, opened: info, from: file.offset, prefix: prefix, didReadBytes: didReadBytes
        ) { accept($0, into: &file) }
        file.offset = snapshot.offset
        file.anchor = snapshot.anchor
        return file
    }

    private func accept(_ line: TokenLogLine, into file: inout HistoryFile) {
        switch line {
        case .complete(let data):
            accept(data, into: &file)
        case .oversized(let prefix):
            // Codex normally writes its outer discriminator ahead of the payload. Large tool
            // output and image records can safely be skipped once that header is established.
            struct Header: Decodable { let type: String }
            let marker = Data(#""payload""#.utf8)
            if let key = prefix.range(of: marker) {
                let header = prefix[..<key.lowerBound] + Data(#""payload":null}"#.utf8)
                if let type = try? decoder.decode(Header.self, from: header).type {
                    if type == "response_item" || type == "dynamic_tools_updated" { return }
                    if type == "event_msg" {
                        // Codex writes the user-message discriminator before its inline images.
                        let payload = String(decoding: prefix[key.upperBound...], as: UTF8.self)
                        if payload.range(
                            of: #"^\s*:\s*\{\s*"type"\s*:\s*"user_message"\s*[,}]"#,
                            options: .regularExpression
                        ) != nil {
                            return
                        }
                    }
                }
            }
            file.partial = true
            file.turnModel = nil
        }
    }

    private func accept(_ line: Data, into file: inout HistoryFile) {
        do {
            let row = try decoder.decode(RolloutRow.self, from: line)
            switch row.payload {
            case .ignored:
                return
            case .metadata(let metadata):
                if file.metadata == nil {
                    file.metadata = metadata
                    file.sessionStartedAt = date(row.timestamp)
                } else if (file.replayMetadata ?? file.metadata)?.inlineForkParent == metadata.id {
                    file.replayMetadata = metadata
                }
                file.turnModel = nil
            case .turn(let marker, let startsTurn):
                // A start marker often has just an ID. Preserve context only for the same named turn.
                let sameTurn = startsTurn && marker.turnID != nil && marker.turnID == file.modelTurn
                let model = marker.model.resolved(or: sameTurn ? file.turnModel : nil)
                file.turnModel = file.inherited(ordinal: row.ordinal) ? nil : model
                file.modelTurn = marker.turnID
                if let turn = marker.turnID { file.turn = turn }
            case .clearTurnModel:
                file.turnModel = nil
            case .response(let response, let checkpoint):
                guard !response.responseID.isEmpty, !response.threadID.isEmpty, response.usage.totalTokens >= 0 else {
                    file.partial = true
                    return
                }
                let sameThread = file.metadata.map { $0.id == response.threadID } ?? true
                let sameTurn = response.turnID == nil || response.turnID == file.modelTurn
                let contextModel = sameTurn && sameThread ? file.turnModel : nil
                let model = response.model.resolved(or: response.usage.model.resolved(or: contextModel))
                // A fork may rewrite the timestamp and surrounding turn, but the response carries its own model.
                let needsCopyPrice = !checkpoint && (!sameThread || file.metadata == nil)
                let directModel =
                    needsCopyPrice ? response.model.resolved(or: response.usage.model.resolved(or: nil)) : nil
                file.events.append(
                    UsageEvent(
                        date: date(row.timestamp), turn: response.turnID ?? file.turn,
                        total: response.usage.totalTokens, counter: nil, response: response.responseID,
                        owner: response.threadID, checkpoint: checkpoint,
                        usd: checkpoint || !sameThread ? nil : response.usage.cost(model: model),
                        copiedUSD: directModel.flatMap { response.usage.cost(model: $0) }
                    ))
            case .counter(let info):
                guard info.totalTokenUsage.totalTokens >= 0, info.lastTokenUsage.totalTokens >= 0,
                    let quantities = info.lastTokenUsage.quantities
                else {
                    file.partial = true
                    return
                }
                let carried = file.inherited(ordinal: row.ordinal)
                let contextModel: String?
                if case .absent = info.lastTokenUsage.model {
                    contextModel = file.turnModel
                } else {
                    contextModel = nil
                }
                file.events.append(
                    UsageEvent(
                        date: date(row.timestamp), turn: file.turn, total: info.totalTokenUsage.totalTokens,
                        counter: CounterSample(
                            last: info.lastTokenUsage.totalTokens,
                            estimated: quantities.input == 0 && quantities.output == 0,
                            inherited: carried, contextModel: contextModel
                        ),
                        response: nil, owner: file.replayMetadata?.id,
                        usd: carried
                            ? nil
                            : info.lastTokenUsage.cost(model: info.lastTokenUsage.model.resolved(or: file.turnModel))
                    ))
            }
        } catch {
            file.partial = true
            file.turnModel = nil
        }
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dates.date(from: text) ?? wholeSecondDates.date(from: text)
    }

    private func totals(now: Date, partial incomplete: Bool) -> TokenTotals {
        let calendar = calendar ?? .current
        var partial = incomplete
        var responses: [ResponseKey: Contribution] = [:]
        var checkpoints: [ResponseKey: UsageEvent] = [:]
        var hasRetainedUsage = false
        var snapshots: [SnapshotKey: Contribution] = [:]
        var identifiedSnapshots: Set<SnapshotKey> = []
        for (path, file) in files {
            partial = partial || file.partial
            let fileID = file.metadata?.id ?? path
            var counter: Int64?
            var generation = 0
            var pending: [(tokens: Int64, original: Bool, date: Date?)] = []
            var counterDate: Date?
            var unmatchedSnapshot:
                (key: SnapshotKey, turn: String?, usage: Contribution, canPrice: Bool, model: String?)?
            var reverseMatch: Contribution?
            var observed: Set<ResponseKey> = []
            var hasLocalResponse = false
            for event in file.events {
                let future = event.date.map { $0 > now } ?? false
                if let response = event.response, let owner = event.owner {
                    guard !future else { continue }
                    let key = ResponseKey(thread: owner, response: response)
                    if event.checkpoint == true {
                        if let previous = checkpoints[key], previous.total != event.total {
                            partial = true
                            if previous.total < event.total { continue }
                        }
                        checkpoints[key] = event
                        continue
                    }
                    let original = file.metadata.map { $0.id == owner } ?? true
                    hasLocalResponse = hasLocalResponse || original
                    // A copying fork can rewrite the rollout timestamp. The native ID
                    // still proves spend even if its original timestamp is no longer present.
                    let contribution = Contribution(
                        tokens: event.total, date: original ? event.date : nil, original: original,
                        usd: original ? event.usd : event.copiedUSD)
                    if let previous = responses[key], previous.tokens != contribution.tokens { partial = true }
                    responses[key] = contribution.preferred(over: responses[key])
                    if observed.insert(key).inserted {
                        if original, let previous = unmatchedSnapshot, let date = event.date,
                            date == counterDate, previous.turn == event.turn, previous.key.last == event.total
                        {
                            // A same-instant counter preceding its native response has no response ID.
                            // The native amount is certain; the counter cannot prove an additional request.
                            identifiedSnapshots.insert(previous.key)
                            reverseMatch = previous.usage
                            unmatchedSnapshot = nil
                            partial = true
                        } else {
                            pending.append((event.total, original, original ? event.date : nil))
                        }
                    }
                    continue
                }
                // Context estimates can change both counts without proving spend.
                guard let sample = event.counter, !sample.estimated else { continue }
                let last = sample.last
                if let counter, event.total < counter { generation += 1 }
                if future {
                    // A clock correction can put a later row back before the cutoff. Keep the
                    // cumulative baseline in file order, while excluding this request from totals.
                    if counter != event.total {
                        counter = event.total
                        counterDate = event.date
                        unmatchedSnapshot = nil
                        reverseMatch = nil
                        pending.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                if event.total == 0, last == 0, !sample.inherited {
                    hasRetainedUsage = true
                }
                let matched = pending.contains { $0.tokens == last }
                // Inline legacy forks can replay the parent prefix with fresh rollout timestamps.
                // Counters written before the fork, or seen after a child-owned response, have dated evidence.
                let inlineForkParent = hasLocalResponse ? nil : file.metadata?.inlineForkParent
                let predatesFork = event.date.flatMap { stamp in file.sessionStartedAt.map { stamp < $0 } } == true
                let rewrittenDate = inlineForkParent != nil && !predatesFork
                let counterOwner = inlineForkParent.map { event.owner ?? $0 } ?? fileID
                let key = SnapshotKey(
                    turnOrThread: event.turn ?? counterOwner,
                    generation: generation, total: event.total, last: last)
                if counter == event.total {
                    // A rate-limit update can repeat an old counter after a new response of the same size.
                    // Only responses that could already have existed at the original snapshot can match it.
                    func couldPrecedeSnapshot(_ date: Date?) -> Bool {
                        guard let date, let counterDate else { return true }
                        return date <= counterDate
                    }
                    if let previous = unmatchedSnapshot, previous.key == key,
                        pending.contains(where: { $0.tokens == last && couldPrecedeSnapshot($0.date) })
                    {
                        identifiedSnapshots.insert(key)
                        unmatchedSnapshot = nil
                        pending.removeAll { couldPrecedeSnapshot($0.date) }
                    } else if let previous = unmatchedSnapshot, previous.key == key, previous.canPrice,
                        !sample.inherited, !rewrittenDate
                    {
                        // A repeat can report its own model or reuse the original model context.
                        // A new turn context alone cannot reprice an already recorded request.
                        if let price = event.usd, sample.contextModel == nil || sample.contextModel == previous.model {
                            var copy = previous.usage
                            copy.usd = price
                            let reconciled = copy.preferred(over: previous.usage)
                            snapshots[key] = reconciled.preferred(over: snapshots[key])
                            unmatchedSnapshot?.usage = reconciled
                        }
                    }
                    continue
                }
                if matched && !sample.inherited {
                    // The same snapshot in an archived or forked copy may lack the response record.
                    identifiedSnapshots.insert(key)
                }

                let increment: Int64
                if let counter, event.total >= counter {
                    increment = event.total - counter
                } else {
                    // A reset starts a new cumulative epoch, just like the opening counter.
                    increment = event.total
                }

                let first = counter == nil
                counter = event.total
                counterDate = event.date
                unmatchedSnapshot = nil
                let alternative = reverseMatch
                reverseMatch = nil
                let reported = pending.reduce(into: (all: Int64(0), local: Int64(0))) { counts, response in
                    counts.all = cappedSum(counts.all, response.tokens, partial: &partial)
                    if response.original { counts.local = cappedSum(counts.local, response.tokens, partial: &partial) }
                }
                pending.removeAll(keepingCapacity: true)
                guard !sample.inherited else { continue }
                let inheritedOpening = first && file.metadata?.hasParent == true
                // Copied responses can match a snapshot for deduplication, but cannot prove new spend in this file.
                let attributed = inheritedOpening ? reported.all : reported.local
                if matched {
                    let rise = inheritedOpening ? min(event.total, last) : increment
                    if rise > attributed { partial = true }
                    continue
                }
                if inheritedOpening, reported.all == 0, event.total > last { continue }
                let available = inheritedOpening ? min(event.total, last) : increment
                let unpaired = min(last, max(0, available - reported.all))
                if increment - min(attributed, increment) > unpaired {
                    // Only the final request has a dated counter contribution. Other spend is unaccounted for.
                    partial = true
                }
                guard unpaired > 0 else { continue }
                var date = rewrittenDate ? nil : event.date
                var latestDate: Date?
                var usd = unpaired == last && !inheritedOpening && !rewrittenDate ? event.usd : nil
                if let alternative, alternative.tokens == last, unpaired == last {
                    // The native response could instead explain this advance. Keep both possible
                    // dates so each rolling period can independently include the proven extra usage.
                    if let first = alternative.date, let second = date {
                        date = min(first, second)
                        latestDate = max(first, second)
                    } else {
                        date = nil
                    }
                    if alternative.usd != usd { usd = nil }
                }
                let contribution = Contribution(
                    tokens: unpaired, date: date, original: file.metadata?.hasParent != true,
                    owner: file.metadata?.id, usd: usd, latestDate: latestDate)
                snapshots[key] = contribution.preferred(over: snapshots[key])
                if unpaired == last && !rewrittenDate && latestDate == nil {
                    unmatchedSnapshot = (key, event.turn, contribution, !inheritedOpening, sample.contextModel)
                }
            }
        }

        for key in identifiedSnapshots { snapshots.removeValue(forKey: key) }
        if !checkpoints.isEmpty {
            let amounts = Set(checkpoints.values.map(\.total))
            var buckets: [Int64: CheckpointCounters] = [:]
            for (key, usage) in snapshots where amounts.contains(key.last) {
                buckets[key.last, default: CheckpointCounters()].add(key, owner: usage.owner)
            }
            for (key, checkpoint) in checkpoints {
                if let response = responses[key] {
                    if response.tokens != checkpoint.total { partial = true }
                    continue
                }
                // A compaction dates the checkpoint, not the original response. One dated counter
                // can explain at most one distinct response ID, and only its retained token amount.
                partial = true
                let scope = CheckpointScope(thread: key.thread, turn: checkpoint.turn)
                let overlap = buckets[checkpoint.total]?.reserve(for: scope, snapshots: &snapshots) ?? 0
                if checkpoint.total == 0 || checkpoint.total > overlap {
                    responses[key] = Contribution(tokens: checkpoint.total - overlap, date: nil, original: false)
                }
            }
        }
        let days = TokenDayBoundaries(now: now, calendar: calendar)

        var spend = TokenSpendTotals()
        var daily = TokenDailyUsage(calendar: calendar)
        var allTokens: Int64 = 0
        var monthTokens: Int64 = 0
        var weekTokens: Int64 = 0
        var yesterdayTokens: Int64 = 0
        var todayTokens: Int64 = 0
        for entry in Array(responses.values) + Array(snapshots.values) {
            guard entry.date.map({ $0 <= now }) ?? true else { continue }
            hasRetainedUsage = true
            spend.record(
                entry.usd, tokens: entry.tokens, date: entry.date, latestDate: entry.latestDate, now: now, days: days)
            guard entry.tokens > 0 else { continue }
            allTokens = cappedSum(allTokens, entry.tokens, partial: &partial)
            guard let date = entry.date else {
                partial = true
                continue
            }
            daily.add(entry.tokens, on: date, latestDate: entry.latestDate, partial: &partial)
            if date >= days.month { monthTokens = cappedSum(monthTokens, entry.tokens, partial: &partial) }
            if date >= days.week { weekTokens = cappedSum(weekTokens, entry.tokens, partial: &partial) }
            if date >= days.today {
                todayTokens = cappedSum(todayTokens, entry.tokens, partial: &partial)
            } else if date >= days.yesterday, (entry.latestDate ?? date) < days.today {
                yesterdayTokens = cappedSum(yesterdayTokens, entry.tokens, partial: &partial)
            }
        }
        return TokenTotals(
            allTime: allTokens, month: monthTokens, week: weekTokens, yesterday: yesterdayTokens, today: todayTokens,
            partial: partial,
            hasRetainedUsage: hasRetainedUsage, spend: spend, peakDay: daily.peak)
    }
}

private struct HistoryCache: Codable {
    static let currentVersion = 3
    let version: Int
    let home: String
    let files: [String: HistoryFile]
    let archiveOverflows: ArchiveOverflowCache?
}

private struct ArchiveOverflowCache: Codable {
    let maximumBytes: Int
    let fingerprints: [String: LogFingerprint]
}

private struct DecoderRevision: Codable, Equatable {
    let path: String
    let fingerprint: LogFingerprint

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        path = url.path
        fingerprint = LogFingerprint(info)
    }
}

private struct ArchiveSkip: Codable, Equatable {
    let fingerprint: LogFingerprint
    var limit: Int?
    var decoder: DecoderRevision?
    var failedAt: Date?

    func applies(to revision: LogFingerprint, decoder current: DecoderRevision?, budget: Int, at now: Date) -> Bool {
        guard fingerprint == revision else { return false }
        if let limit { return limit == budget }
        guard let decoder, decoder == current, let failedAt else { return false }
        return (0..<86_400).contains(now.timeIntervalSince(failedAt))
    }
}

private struct HistoryFile: Codable {
    func inherited(ordinal: UInt64?) -> Bool {
        guard let ordinal, let start = metadata?.subagentHistoryStartOrdinal else { return false }
        return ordinal < start
    }

    func valid(for path: String) -> Bool {
        let current = parserRevision == Self.currentParserRevision
        // Older counter checkpoints do not distinguish an explicitly reported price from turn context.
        let reusable =
            (parserRevision == 1 || parserRevision == 2)
            && events.allSatisfy {
                $0.counter == nil
                    && (parserRevision == 2 || $0.checkpoint == true
                        || (metadata != nil && $0.owner == metadata?.id))
            }
        return (current || reusable) && priceRevision == TokenPricing.revision && fingerprint.size >= 0
            && (path.hasSuffix(".jsonl.zst") || offset <= UInt64(fingerprint.size))
            && events.allSatisfy { $0.total >= 0 && ($0.counter?.last ?? 0) >= 0 }
    }

    static let currentParserRevision = 3
    var parserRevision: Int? = currentParserRevision
    // Older checkpoints store only counts. Missing or obsolete prices require replaying the source.
    var priceRevision: Int? = TokenPricing.revision
    var fingerprint: LogFingerprint
    var offset: UInt64 = 0
    var anchor = Data()
    var metadata: SessionMetadata?
    var replayMetadata: SessionMetadata?
    var sessionStartedAt: Date?
    var turn: String?
    var turnModel: String?
    var modelTurn: String?
    var events: [UsageEvent] = []
    var partial = false
}

private struct LogFingerprint: Codable, Hashable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Int
    let modifiedNanoseconds: Int
    let changed: Int
    let changedNanoseconds: Int
    let created: Int
    let createdNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
        created = info.st_birthtimespec.tv_sec
        createdNanoseconds = info.st_birthtimespec.tv_nsec
    }

    func grew(from earlier: Self) -> Bool {
        sameFile(as: earlier) && size > earlier.size
    }

    func sameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
            && created == other.created && createdNanoseconds == other.createdNanoseconds
    }
}

// A growing JSONL file may also have been edited in place. Verify every committed byte
// before reusing parsed events.
struct TokenLogPrefix {
    private var hash = SHA256()
    let start: UInt64
    private var offset: UInt64
    init(start: UInt64 = 0) {
        self.start = start
        offset = start
    }
    var digest: Data { Data(hash.finalize()) }

    mutating func update(_ bytes: Data) {
        hash.update(data: bytes)
        offset += UInt64(bytes.count)
    }

    mutating func extend(in stream: FileHandle, to end: UInt64, didReadBytes: ((Int) -> Void)? = nil) throws {
        try stream.seek(toOffset: offset)
        while offset < end {
            let limit = Int(min(end - offset, 256 * 1024))
            guard let bytes = try autoreleasepool(invoking: { try stream.read(upToCount: limit) }), !bytes.isEmpty
            else {
                throw TokenHistoryError.unavailable
            }
            update(bytes)
            didReadBytes?(bytes.count)
        }
    }
}

enum TokenLogSnapshotError: Error {
    case verifiedPreviousCheckpoint
}

// Sample a fixed length so an active writer cannot indefinitely extend this refresh.
func readTokenLogSnapshot(
    _ stream: FileHandle, at url: URL, opened: stat, from offset: UInt64, prefix initial: TokenLogPrefix,
    didReadBytes: ((Int) -> Void)?, continuingOversizedLine: Bool = false,
    observe: ((Data, UInt64) -> Void)? = nil, verifyCachedPrefix: (() throws -> Bool)? = nil,
    accept: (TokenLogLine) throws -> Void
) throws -> (offset: UInt64, anchor: Data) {
    var remaining = UInt64(opened.st_size) - offset
    var prefix = initial
    var committedPrefix = initial
    try stream.seek(toOffset: offset)
    let committed = try readTokenLogLines(
        read: {
            guard remaining > 0 else { return Data() }
            let bytes = try stream.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            guard !bytes.isEmpty else { throw TokenHistoryError.unavailable }
            observe?(bytes, UInt64(opened.st_size) - remaining)
            remaining -= UInt64(bytes.count)
            didReadBytes?(bytes.count)
            return bytes
        },
        observeChunk: { bytes, boundary in
            if boundary > bytes.startIndex {
                prefix.update(bytes[..<boundary])
                committedPrefix = prefix
            }
            prefix.update(bytes[boundary...])
        }, continuingOversizedLine: continuingOversizedLine, accept: accept)
    let end = offset + committed
    let anchor = committedPrefix.digest
    var current = stat()
    guard lstat(url.path, &current) == 0 else { throw TokenHistoryError.unavailable }
    var before = LogFingerprint(opened)
    var after = LogFingerprint(current)
    // Allow a second append during verification, but never chase an active writer indefinitely.
    for _ in 0..<2 where before != after {
        guard after.grew(from: before) else { throw TokenHistoryError.unavailable }
        before = after
        // Validate both the reused checkpoint and every newly parsed committed byte on a racing append.
        guard try verifyCachedPrefix?() != false else { throw TokenHistoryError.unavailable }
        var checked = TokenLogPrefix(start: initial.start)
        try checked.extend(in: stream, to: end, didReadBytes: didReadBytes)
        guard checked.digest == anchor, lstat(url.path, &current) == 0 else { throw TokenHistoryError.unavailable }
        after = LogFingerprint(current)
    }
    if before == after { return (end, anchor) }

    // The snapshot never stabilized. Keep only the old checkpoint if it still matches
    // the readable transcript after the last observed append. Leave its offset unchanged for retry.
    guard offset > 0, after.grew(from: before) else { throw TokenHistoryError.unavailable }
    let matches: Bool
    if let verifyCachedPrefix {
        matches = try verifyCachedPrefix()
    } else {
        var cached = TokenLogPrefix()
        try cached.extend(in: stream, to: offset, didReadBytes: didReadBytes)
        matches = cached.digest == initial.digest
    }
    guard matches, lstat(url.path, &current) == 0 else { throw TokenHistoryError.unavailable }
    let final = LogFingerprint(current)
    guard final == after || final.grew(from: after) else { throw TokenHistoryError.unavailable }
    throw TokenLogSnapshotError.verifiedPreviousCheckpoint
}

// Consume only newline-committed records. A trailing fragment is re-read after the writer appends.
enum TokenLogLine {
    static let maximumSize = 16 * 1024 * 1024
    case complete(Data)
    case oversized(prefix: Data)
}

func readTokenLogLines(
    read: () throws -> Data, observeChunk: ((Data, Data.Index) -> Void)? = nil, continuingOversizedLine: Bool = false,
    accept: (TokenLogLine) throws -> Void
) throws -> UInt64 {
    var alreadyOversized = continuingOversizedLine
    var pending = Data()
    var lineLength = 0
    var committed: UInt64 = 0
    while true {
        // FileHandle and Foundation decoders can leave autoreleased objects alive for the entire scan.
        let reachedEnd = try autoreleasepool {
            let chunk = try read()
            guard !chunk.isEmpty else { return true }
            var start = chunk.startIndex
            while let newline = tokenLogNewline(in: chunk, from: start) {
                let segment = chunk[start..<newline]
                lineLength += segment.count
                if alreadyOversized || lineLength > TokenLogLine.maximumSize {
                    try accept(.oversized(prefix: Data(pending.prefix(1024))))
                } else if pending.isEmpty {
                    try accept(.complete(segment))
                } else {
                    pending.append(segment)
                    try accept(.complete(pending))
                }
                committed += UInt64(lineLength) + 1
                pending.removeAll(keepingCapacity: true)
                lineLength = 0
                alreadyOversized = false
                start = newline + 1
            }
            // start is the boundary after the last committed newline, or startIndex if there was none.
            observeChunk?(chunk, start)
            let tail = chunk[start...]
            lineLength += tail.count
            if !alreadyOversized && lineLength <= TokenLogLine.maximumSize { pending.append(tail) }
            return false
        }
        if reachedEnd { return committed }
    }
}

// Search contiguous UTF-8 bytes directly, including when a chunk is a slice with a nonzero startIndex.
private func tokenLogNewline(in chunk: Data, from start: Data.Index) -> Data.Index? {
    chunk.withUnsafeBytes { bytes in
        let offset = start - chunk.startIndex
        guard offset < bytes.count, let base = bytes.baseAddress,
            let match = memchr(base + offset, 10, bytes.count - offset)
        else { return nil }
        return chunk.startIndex + base.distance(to: UnsafeRawPointer(match))
    }
}

private struct RolloutRow: Decodable {
    enum Payload {
        case metadata(SessionMetadata)
        case turn(TurnMarker, startsTurn: Bool)
        case clearTurnModel
        case response(ResponseUsage, checkpoint: Bool)
        case counter(CounterUsage)
        case ignored
    }

    enum CodingKeys: String, CodingKey { case type, timestamp, ordinal, payload }
    enum EventKeys: String, CodingKey { case type, info }
    enum CompactionKeys: String, CodingKey { case latest = "latest_token_usage_record" }

    let timestamp: String?
    let ordinal: UInt64?
    let payload: Payload

    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try row.decodeIfPresent(String.self, forKey: .timestamp)
        ordinal = try row.decodeIfPresent(UInt64.self, forKey: .ordinal)
        switch try row.decode(String.self, forKey: .type) {
        case "session_meta":
            payload = .metadata(try row.decode(SessionMetadata.self, forKey: .payload))
        case "turn_context":
            payload = .turn(try row.decode(TurnMarker.self, forKey: .payload), startsTurn: false)
        case "token_usage_record":
            payload = .response(try row.decode(ResponseUsage.self, forKey: .payload), checkpoint: false)
        case "compacted":
            let checkpoint = try row.nestedContainer(keyedBy: CompactionKeys.self, forKey: .payload)
            payload =
                try checkpoint.decodeIfPresent(ResponseUsage.self, forKey: .latest)
                .map { .response($0, checkpoint: true) } ?? .ignored
        case "event_msg":
            let event = try row.nestedContainer(keyedBy: EventKeys.self, forKey: .payload)
            switch try event.decode(String.self, forKey: .type) {
            case "task_started":
                payload = .turn(try row.decode(TurnMarker.self, forKey: .payload), startsTurn: true)
            case "task_complete", "turn_complete", "turn_aborted", "turn_started", "model_reroute":
                // A reroute carries no response ID. Later counters need fresh, attributable model evidence.
                payload = .clearTurnModel
            case "token_count":
                payload = try event.decodeIfPresent(CounterUsage.self, forKey: .info).map(Payload.counter) ?? .ignored
            default:
                payload = .ignored
            }
        default:
            payload = .ignored
        }
    }
}

private struct SessionMetadata: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case forkedFromID = "forked_from_id"
        case parentThreadID = "parent_thread_id"
        case subagentHistoryStartOrdinal = "subagent_history_start_ordinal"
        case historyBase = "history_base"
    }

    let id: String
    let forkedFromID: String?
    let parentThreadID: String?
    let subagentHistoryStartOrdinal: UInt64?

    struct HistoryBase: Codable {
        let threadID: String
        enum CodingKeys: String, CodingKey { case threadID = "thread_id" }
    }
    let historyBase: HistoryBase?

    var hasParent: Bool { forkedFromID != nil || parentThreadID != nil || historyBase != nil }
    var inlineForkParent: String? {
        historyBase == nil && subagentHistoryStartOrdinal == nil ? forkedFromID : nil
    }
}

// An explicitly malformed or unsupported ID blocks fallback to a different model.
private enum RecordedModel {
    case absent
    case specified(String?)

    init<Key>(_ fields: KeyedDecodingContainer<Key>, key: Key) {
        guard fields.contains(key) else {
            self = .absent
            return
        }
        let value = try? fields.decode(String.self, forKey: key)
        // Persist only catalog IDs, even for logs produced by custom providers.
        self = .specified(value.flatMap { TokenPricing.isKnownCodexModel($0) ? $0 : nil })
    }

    func resolved(or fallback: String?) -> String? {
        switch self {
        case .absent: return fallback
        case .specified(let model): return model
        }
    }
}

private struct TurnMarker: Decodable {
    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case model
    }

    let turnID: String?
    let model: RecordedModel

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try fields.decodeIfPresent(String.self, forKey: .turnID)
        model = RecordedModel(fields, key: .model)
    }
}

private struct Usage: Decodable {
    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case model
    }

    let model: RecordedModel
    let totalTokens: Int64
    struct Quantities: Decodable {
        let input: Int64?
        let output: Int64?

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
        }
    }

    let quantities: Quantities?
    private let details: CostDetails?

    private struct CostDetails: Decodable {
        let cached: Int64?
        let cacheWrite: Int64?
        let reasoning: Int64?

        enum CodingKeys: String, CodingKey {
            case cached = "cached_input_tokens"
            case cacheWrite = "cache_write_input_tokens"
            case reasoning = "reasoning_output_tokens"
        }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        model = RecordedModel(fields, key: .model)
        totalTokens = try fields.decode(Int64.self, forKey: .totalTokens)
        quantities = try? Quantities(from: decoder)
        // Extra pricing fields must never make a previously readable token total disappear.
        details = try? CostDetails(from: decoder)
    }

    func cost(model: String?) -> Double? {
        guard let model, let details, let outputTokens = quantities?.output,
            details.reasoning.map({ $0 >= 0 && $0 <= outputTokens }) ?? true
        else { return nil }
        // Codex includes its reasoning tokens in the reported output bucket.
        return TokenPricing.codex(
            model: model, input: quantities?.input, cached: details.cached, cacheWrite: details.cacheWrite,
            output: outputTokens, total: totalTokens)
    }
}

private struct ResponseUsage: Decodable {
    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case threadID = "thread_id"
        case turnID = "turn_id"
        case usage, model
    }

    let responseID: String
    let threadID: String
    let turnID: String?
    let usage: Usage
    let model: RecordedModel

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        responseID = try fields.decode(String.self, forKey: .responseID)
        threadID = try fields.decode(String.self, forKey: .threadID)
        turnID = try fields.decodeIfPresent(String.self, forKey: .turnID)
        usage = try fields.decode(Usage.self, forKey: .usage)
        model = RecordedModel(fields, key: .model)
    }
}

private struct CounterUsage: Decodable {
    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }

    let lastTokenUsage: Usage
    let totalTokenUsage: Usage
}

private struct UsageEvent: Codable {
    let date: Date?
    let turn: String?
    let total: Int64
    let counter: CounterSample?
    let response: String?
    let owner: String?
    var checkpoint: Bool? = nil
    var usd: Double? = nil
    var copiedUSD: Double? = nil
}

private struct CounterSample: Codable {
    let last: Int64
    let estimated: Bool
    let inherited: Bool
    var contextModel: String?
}

private struct ResponseKey: Hashable {
    let thread: String
    let response: String
}

private struct SnapshotKey: Hashable {
    let turnOrThread: String
    let generation: Int
    let total: Int64
    let last: Int64
}

private struct CheckpointScope: Hashable {
    let thread: String
    let turn: String?

    enum Domain: Hashable {
        case anonymous
        case thread(String)
        case turn(String)
    }

    var domains: [Domain] {
        var result: [Domain] = [.thread(thread), .anonymous]
        if let turn { result.append(.turn(turn)) }
        return result
    }
}

// One bucket holds anonymous counters with the same reported request size.
private struct CheckpointCounters {
    private var count = 0
    private var domains: [CheckpointScope.Domain: [SnapshotKey]] = [:]
    private var occupied: [SnapshotKey: CheckpointScope] = [:]
    private var unpriced = Set<CheckpointScope.Domain>()
    private var exhausted = Set<CheckpointScope.Domain>()
    private var fullCursor: [CheckpointScope.Domain: Int] = [:]

    mutating func add(_ key: SnapshotKey, owner: String?) {
        count += 1
        domains[owner.map(CheckpointScope.Domain.thread) ?? .anonymous, default: []].append(key)
        domains[.turn(key.turnOrThread), default: []].append(key)
    }

    mutating func reserve(for start: CheckpointScope, snapshots: inout [SnapshotKey: Contribution]) -> Int64 {
        let initial = start.domains
        for domain in initial where unpriced.insert(domain).inserted {
            // Any possible overlap can put the dated counter under a different turn model.
            for key in domains[domain] ?? [] { snapshots[key]?.usd = nil }
        }
        guard occupied.count < count else { return 0 }

        // Occupied counters never become free. A direct, full-size match is already optimal.
        for domain in initial {
            guard let keys = domains[domain] else { continue }
            var cursor = fullCursor[domain] ?? 0
            while cursor < keys.count {
                let key = keys[cursor]
                cursor += 1
                if occupied[key] == nil, snapshots[key]?.tokens == key.last {
                    fullCursor[domain] = cursor
                    occupied[key] = start
                    return key.last
                }
            }
            fullCursor[domain] = cursor
        }

        // Find the largest reachable free contribution, reassigning earlier matches as needed.
        // Thread and turn lists can overlap. Expand each list once per search.
        var queue = [start]
        var visited = Set<CheckpointScope.Domain>()
        var route: [CheckpointScope: (parent: CheckpointScope, counter: SnapshotKey)] = [:]
        var best: (scope: CheckpointScope, counter: SnapshotKey, tokens: Int64)?
        var index = 0
        search: while index < queue.count {
            let scope = queue[index]
            index += 1
            for domain in scope.domains where !exhausted.contains(domain) && visited.insert(domain).inserted {
                for key in domains[domain] ?? [] {
                    if let holder = occupied[key] {
                        if holder != start && route[holder] == nil {
                            route[holder] = (scope, key)
                            queue.append(holder)
                        }
                    } else if let tokens = snapshots[key]?.tokens, tokens > (best?.tokens ?? 0) {
                        best = (scope, key, tokens)
                        if tokens == key.last { break search }
                    }
                }
            }
        }
        guard let best else {
            // These counters are all occupied by requests with no route to a free counter.
            // Adding more requests cannot release any of them.
            exhausted.formUnion(visited)
            return 0
        }
        occupied[best.counter] = best.scope
        var scope = best.scope
        while let step = route[scope] {
            occupied[step.counter] = step.parent
            scope = step.parent
        }
        return best.tokens
    }
}

private struct Contribution {
    let tokens: Int64
    let date: Date?
    let original: Bool
    var owner: String? = nil
    var usd: Double? = nil
    var latestDate: Date? = nil
    var conflictingPrice = false

    func preferred(over previous: Self?) -> Self {
        guard let previous else { return self }
        if original != previous.original { return original ? self : previous }
        if tokens != previous.tokens { return tokens < previous.tokens ? self : previous }
        // The count and date follow the existing conservative choice. Resolve equal-count price
        // evidence independently so directory order cannot select a conflicting model or breakdown.
        var result = date.map { current in previous.date.map { current < $0 } ?? true } == true ? self : previous
        if date == previous.date {
            // When both copies agree on the earliest instant, either can narrow the possible dates.
            // In particular, an exact dated copy resolves a same-start range from a reverse match.
            if let latestDate, let previousEnd = previous.latestDate {
                result.latestDate = min(latestDate, previousEnd)
            } else {
                result.latestDate = nil
            }
        }
        result.conflictingPrice =
            conflictingPrice || previous.conflictingPrice
            || (usd != nil && previous.usd != nil && usd != previous.usd)
        result.usd = result.conflictingPrice ? nil : usd ?? previous.usd
        return result
    }
}

private func cappedSum(_ lhs: Int64, _ rhs: Int64, partial: inout Bool) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
        partial = true
        return .max
    }
    return sum
}

struct CompressedLogConfiguration {
    var maximumBytes = 256 * 1024 * 1024
    var timeout: TimeInterval = 15
    var executable: URL?

    var binary: URL? {
        executable
            ?? ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }.map { URL(fileURLWithPath: $0) }
    }
}

private final class CompressedLogBudget {
    var remainingBytes: Int
    let deadline: DispatchTime
    var exhausted: Bool { remainingBytes == 0 || DispatchTime.now() >= deadline }

    init(_ configuration: CompressedLogConfiguration) {
        remainingBytes = configuration.maximumBytes
        deadline = .now() + configuration.timeout
    }
}

private enum CompressedLogError: Error {
    case byteLimitExceeded, decoderRejected
}

private final class CompressedLog {
    private let process = Process()
    private let reader: FileHandle
    private let exited = DispatchSemaphore(value: 0)
    private let budget: CompressedLogBudget

    init(input: FileHandle, configuration: CompressedLogConfiguration, budget: CompressedLogBudget) throws {
        self.budget = budget
        guard let binary = configuration.binary else { throw TokenHistoryError.unavailable }
        let pipe = Pipe()
        reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw TokenHistoryError.unavailable }
        process.executableURL = binary
        process.arguments = ["-d", "-c", "-q"]
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    func close() {
        try? reader.close()
        // The decoder is disposable. A child that hangs or ignores signals must not hold the history queue.
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .milliseconds(250))
        }
    }

    func read() throws -> Data {
        let fd = reader.fileDescriptor
        while true {
            let now = DispatchTime.now()
            guard now < budget.deadline else { throw TokenHistoryError.unavailable }
            let remaining = budget.deadline.uptimeNanoseconds - now.uptimeNanoseconds
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((remaining + 999_999) / 1_000_000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw TokenHistoryError.unavailable
            }
            // Probe one byte past the budget to distinguish exact-limit EOF from excess output.
            var bytes = Data(count: min(64 * 1024, budget.remainingBytes + 1))
            let count = bytes.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress, raw.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count >= 0 else { throw TokenHistoryError.unavailable }
            guard count <= budget.remainingBytes else {
                budget.remainingBytes = 0
                guard DispatchTime.now() < budget.deadline, process.isRunning || process.terminationStatus == 0 else {
                    throw TokenHistoryError.unavailable
                }
                throw CompressedLogError.byteLimitExceeded
            }
            budget.remainingBytes -= count
            bytes.count = count
            return bytes
        }
    }

    func finish() throws {
        guard DispatchTime.now() < budget.deadline, exited.wait(timeout: budget.deadline) == .success,
            process.terminationReason == .exit
        else { throw TokenHistoryError.unavailable }
        guard process.terminationStatus == 0 else { throw CompressedLogError.decoderRejected }
    }
}
