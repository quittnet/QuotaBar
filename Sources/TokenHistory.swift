import CryptoKit
import Darwin
import Foundation

struct TokenDayBoundaries {
    let today: Date
    let yesterday: Date
    let week: Date
    let month: Date

    init(now: Date, calendar: Calendar) {
        today = calendar.startOfDay(for: now)
        yesterday = calendar.date(byAdding: .day, value: -1, to: today).map(calendar.startOfDay(for:)) ?? today
        week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        month = calendar.date(byAdding: .day, value: -29, to: today) ?? today
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
}

enum TokenHistoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The local Codex session history could not be read."
    }
}

/// The cache stores only file identities, offsets and token-accounting fields.
/// Keep an instance on the serial queue that reads local history.
final class TokenHistory {
    private let home: URL
    private let cacheURL: URL?
    private let calendar: Calendar?
    private let decoder = JSONDecoder()
    private let dates = ISO8601DateFormatter()
    private let wholeSecondDates = ISO8601DateFormatter()
    private var files: [String: HistoryFile] = [:]
    private var loaded = false

    init() {
        let environment = ProcessInfo.processInfo.environment
        let configuredHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        home =
            configuredHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.quotabar.QuotaBar", isDirectory: true)
            .appendingPathComponent("token-history.json")
        calendar = nil
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    init(home: URL, cacheURL: URL? = nil, calendar: Calendar) {
        self.home = home
        self.cacheURL = cacheURL
        self.calendar = calendar
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(now: Date = Date()) throws -> TokenTotals {
        loadCache()
        let fm = FileManager.default
        var foundRoot = false
        var enumerationFailed = false
        var updated = false
        var readable = 0
        var candidates = 0
        var next: [String: HistoryFile] = [:]

        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory, isDirectory: true)
            var rootStat = stat()
            guard stat(root.path, &rootStat) == 0 else {
                if errno != ENOENT { enumerationFailed = true }
                continue
            }
            guard (rootStat.st_mode & S_IFMT) == S_IFDIR,
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
                candidates += 1
                do {
                    let fingerprint = LogFingerprint(info)
                    if let previous = files[path], previous.fingerprint == fingerprint {
                        next[path] = previous
                    } else {
                        next[path] = try scan(
                            url, compressed: compressed, fingerprint: fingerprint, previous: files[path])
                        updated = true
                    }
                    readable += 1
                } catch {
                    enumerationFailed = true
                }
            }
        }
        guard foundRoot, readable > 0 || (candidates == 0 && !enumerationFailed) else {
            throw TokenHistoryError.unavailable
        }
        updated = updated || files.keys != next.keys
        files = next
        if updated { saveCache() }
        return totals(now: now, partial: enumerationFailed)
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let data = try? PrivateFile.read(cacheURL, maximumBytes: 128 * 1024 * 1024),
            let cache = try? decoder.decode(HistoryCache.self, from: data),
            cache.version == HistoryCache.currentVersion, cache.home == home.standardizedFileURL.path
        else { return }
        files = cache.files.filter { path, file in
            file.fingerprint.size >= 0
                && (path.hasSuffix(".jsonl.zst") || file.offset <= UInt64(file.fingerprint.size))
                && file.events.allSatisfy { $0.total >= 0 && ($0.counter?.last ?? 0) >= 0 }
        }
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let cache = HistoryCache(
            version: HistoryCache.currentVersion, home: home.standardizedFileURL.path, files: files)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // The in-memory index remains valid when the cache is unavailable.
        }
    }

    private func scan(
        _ url: URL, compressed: Bool, fingerprint: LogFingerprint, previous: HistoryFile?
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

        if compressed {
            let decoder = try CompressedLog(input: stream)
            var file = HistoryFile(fingerprint: fingerprint)
            try scanLines(into: &file, read: decoder.read)
            try decoder.finish()
            var endInfo = stat()
            guard fstat(descriptor, &endInfo) == 0, LogFingerprint(endInfo) == fingerprint else {
                throw TokenHistoryError.unavailable
            }
            return file
        }

        var file = HistoryFile(fingerprint: fingerprint)
        var prefix = TokenLogPrefix()
        if let previous, previous.fingerprint.sameFile(as: fingerprint),
            previous.fingerprint.size >= 0, previous.offset <= UInt64(previous.fingerprint.size),
            fingerprint.size > previous.fingerprint.size
        {
            try prefix.extend(in: stream, to: previous.offset)
            if prefix.digest == previous.anchor {
                file = previous
                file.fingerprint = fingerprint
            } else {
                prefix = TokenLogPrefix()
            }
        }
        try stream.seek(toOffset: file.offset)
        var remaining = UInt64(fingerprint.size) - file.offset
        try scanLines(into: &file) {
            guard remaining > 0 else { return Data() }
            let data = try stream.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            guard !data.isEmpty else { throw TokenHistoryError.unavailable }
            remaining -= UInt64(data.count)
            return data
        }
        try prefix.extend(in: stream, to: file.offset)
        file.anchor = prefix.digest
        var endInfo = stat()
        guard fstat(descriptor, &endInfo) == 0, LogFingerprint(endInfo) == LogFingerprint(info) else {
            throw TokenHistoryError.unavailable
        }
        return file
    }

    private func scanLines(into file: inout HistoryFile, read: () throws -> Data) throws {
        let committed = try readTokenLogLines(read: read) { line in
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
                    if let type = try? decoder.decode(Header.self, from: header).type,
                        ["response_item", "dynamic_tools_updated"].contains(type)
                    {
                        return
                    }
                }
                file.partial = true
            }
        }
        file.offset += committed
    }

    private func accept(_ line: Data, into file: inout HistoryFile) {
        do {
            let row = try decoder.decode(RolloutRow.self, from: line)
            switch row.payload {
            case .ignored:
                return
            case .metadata(let metadata):
                if file.metadata == nil { file.metadata = metadata }
            case .turn(let marker):
                if let turn = marker.turnID { file.turn = turn }
            case .response(let response, let checkpoint):
                guard !response.responseID.isEmpty, !response.threadID.isEmpty, response.usage.totalTokens >= 0 else {
                    file.partial = true
                    return
                }
                file.events.append(
                    UsageEvent(
                        date: date(row.timestamp), turn: response.turnID ?? file.turn,
                        total: response.usage.totalTokens, counter: nil, response: response.responseID,
                        owner: response.threadID, checkpoint: checkpoint
                    ))
            case .counter(let info):
                guard info.totalTokenUsage.totalTokens >= 0, info.lastTokenUsage.totalTokens >= 0 else {
                    file.partial = true
                    return
                }
                let carried =
                    row.ordinal.flatMap { ordinal in
                        file.metadata?.subagentHistoryStartOrdinal.map { ordinal < $0 }
                    } ?? false
                file.events.append(
                    UsageEvent(
                        date: date(row.timestamp), turn: file.turn, total: info.totalTokenUsage.totalTokens,
                        counter: CounterSample(
                            last: info.lastTokenUsage.totalTokens,
                            estimated: info.lastTokenUsage.inputTokens == 0 && info.lastTokenUsage.outputTokens == 0,
                            inherited: carried
                        ),
                        response: nil, owner: nil
                    ))
            }
        } catch {
            file.partial = true
        }
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dates.date(from: text) ?? wholeSecondDates.date(from: text)
    }

    private func totals(now: Date, partial incomplete: Bool) -> TokenTotals {
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
            var pending: [Int64] = []
            var observed: Set<ResponseKey> = []
            for event in file.events {
                if let response = event.response, let owner = event.owner {
                    let key = ResponseKey(thread: owner, response: response)
                    if event.checkpoint == true {
                        guard event.date.map({ $0 <= now }) ?? true else { continue }
                        if let previous = checkpoints[key], previous.total != event.total {
                            partial = true
                            if previous.total < event.total { continue }
                        }
                        checkpoints[key] = event
                        continue
                    }
                    let original = file.metadata.map { $0.id == owner } ?? true
                    // A copying fork can rewrite the rollout timestamp. The native ID
                    // still proves spend even if its original timestamp is no longer present.
                    let contribution = Contribution(
                        tokens: event.total, date: original ? event.date : nil, original: original)
                    if let previous = responses[key], previous.tokens != contribution.tokens { partial = true }
                    responses[key] = contribution.preferred(over: responses[key])
                    if observed.insert(key).inserted {
                        pending.append(event.total)
                    }
                    continue
                }
                guard let sample = event.counter else { continue }
                let last = sample.last
                if event.total == 0, last == 0, !sample.estimated, !sample.inherited {
                    if event.date.map({ $0 <= now }) ?? true { hasRetainedUsage = true }
                }
                let matched = pending.contains(last)
                if let counter, event.total < counter { generation += 1 }
                let key = SnapshotKey(
                    turnOrThread: event.turn ?? fileID, generation: generation, total: event.total, last: last)
                if matched && !sample.estimated && !sample.inherited {
                    // The same snapshot in an archived or forked copy may lack the response record.
                    identifiedSnapshots.insert(key)
                }
                // Rate-limit and context updates often repeat an unchanged cumulative count.
                // A context estimate can change the "last" count without recording any spend.
                if counter == event.total {
                    if matched && !sample.estimated { pending.removeAll(keepingCapacity: true) }
                    continue
                }

                let increment: Int64
                if let counter, event.total >= counter {
                    increment = event.total - counter
                } else {
                    increment = min(event.total, last)
                }

                let first = counter == nil
                counter = event.total
                let reported = pending.reduce(Int64(0)) { cappedSum($0, $1, partial: &partial) }
                pending.removeAll(keepingCapacity: true)
                guard !sample.estimated, !matched, !sample.inherited else { continue }
                if first, reported == 0, event.total > last, file.metadata?.hasParent == true { continue }
                let observedIncrease = first ? event.total : increment
                if observedIncrease - min(reported, observedIncrease) > last {
                    // Only the final request has a dated usage record. Earlier increments are unaccounted for.
                    partial = true
                }
                let unpaired = min(last, max(0, increment - reported))
                guard unpaired > 0 else { continue }
                let contribution = Contribution(
                    tokens: unpaired, date: event.date, original: file.metadata?.hasParent != true,
                    owner: file.metadata?.id)
                snapshots[key] = contribution.preferred(over: snapshots[key])
            }
        }

        for key in identifiedSnapshots { snapshots.removeValue(forKey: key) }
        for (key, checkpoint) in checkpoints {
            if let response = responses[key] {
                if response.tokens != checkpoint.total { partial = true }
                continue
            }
            // Compaction records repeat the last response. Their timestamp dates the checkpoint,
            // not the request. A legacy counter may already account for it without a response ID.
            partial = true
            let overlaps = snapshots.contains { snapshot, contribution in
                snapshot.last == checkpoint.total
                    && (snapshot.turnOrThread == checkpoint.turn
                        || contribution.owner == nil || contribution.owner == key.thread)
            }
            if !overlaps {
                responses[key] = Contribution(tokens: checkpoint.total, date: nil, original: false)
            }
        }
        let days = TokenDayBoundaries(now: now, calendar: calendar ?? .current)

        var allTokens: Int64 = 0
        var monthTokens: Int64 = 0
        var weekTokens: Int64 = 0
        var yesterdayTokens: Int64 = 0
        var todayTokens: Int64 = 0
        for entry in Array(responses.values) + Array(snapshots.values) {
            guard entry.date.map({ $0 <= now }) ?? true else { continue }
            hasRetainedUsage = true
            guard entry.tokens > 0 else { continue }
            allTokens = cappedSum(allTokens, entry.tokens, partial: &partial)
            guard let date = entry.date else {
                partial = true
                continue
            }
            if date >= days.month { monthTokens = cappedSum(monthTokens, entry.tokens, partial: &partial) }
            if date >= days.week { weekTokens = cappedSum(weekTokens, entry.tokens, partial: &partial) }
            if date >= days.today {
                todayTokens = cappedSum(todayTokens, entry.tokens, partial: &partial)
            } else if date >= days.yesterday {
                yesterdayTokens = cappedSum(yesterdayTokens, entry.tokens, partial: &partial)
            }
        }
        return TokenTotals(
            allTime: allTokens, month: monthTokens, week: weekTokens, yesterday: yesterdayTokens, today: todayTokens,
            partial: partial,
            hasRetainedUsage: hasRetainedUsage)
    }
}

private struct HistoryCache: Codable {
    static let currentVersion = 3
    let version: Int
    let home: String
    let files: [String: HistoryFile]
}

private struct HistoryFile: Codable {
    var fingerprint: LogFingerprint
    var offset: UInt64 = 0
    var anchor = Data()
    var metadata: SessionMetadata?
    var turn: String?
    var events: [UsageEvent] = []
    var partial = false
}

private struct LogFingerprint: Codable, Equatable {
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

    func sameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
            && created == other.created && createdNanoseconds == other.createdNanoseconds
    }
}

// A growing JSONL file may also have been edited in place. Verify every committed byte
// before reusing parsed events, hashing each range once per changed-file check.
struct TokenLogPrefix {
    private var hash = SHA256()
    private var offset: UInt64 = 0
    var digest: Data { Data(hash.finalize()) }

    mutating func extend(in stream: FileHandle, to end: UInt64) throws {
        try stream.seek(toOffset: offset)
        while offset < end {
            let limit = Int(min(end - offset, 256 * 1024))
            guard let bytes = try stream.read(upToCount: limit), !bytes.isEmpty else {
                throw TokenHistoryError.unavailable
            }
            hash.update(data: bytes)
            offset += UInt64(bytes.count)
        }
    }
}

// Consume only newline-committed records. A trailing fragment is re-read after the writer appends.
enum TokenLogLine {
    case complete(Data)
    case oversized(prefix: Data)
}

func readTokenLogLines(read: () throws -> Data, accept: (TokenLogLine) -> Void) throws -> UInt64 {
    let maximumLineSize = 16 * 1024 * 1024
    var pending = Data()
    var lineLength = 0
    var committed: UInt64 = 0
    while true {
        let chunk = try read()
        guard !chunk.isEmpty else { return committed }
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 10) {
            let segment = chunk[start..<newline]
            lineLength += segment.count
            if lineLength > maximumLineSize {
                accept(.oversized(prefix: Data(pending.prefix(1024))))
            } else if pending.isEmpty {
                accept(.complete(segment))
            } else {
                pending.append(segment)
                accept(.complete(pending))
            }
            committed += UInt64(lineLength) + 1
            pending.removeAll(keepingCapacity: true)
            lineLength = 0
            start = newline + 1
        }
        let tail = chunk[start...]
        lineLength += tail.count
        if lineLength <= maximumLineSize { pending.append(tail) }
    }
}

private struct RolloutRow: Decodable {
    enum Payload {
        case metadata(SessionMetadata)
        case turn(TurnMarker)
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
            payload = .turn(try row.decode(TurnMarker.self, forKey: .payload))
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
                payload = .turn(try row.decode(TurnMarker.self, forKey: .payload))
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
}

private struct TurnMarker: Decodable {
    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
    }

    let turnID: String?
}

private struct Usage: Decodable {
    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    let totalTokens: Int64
    let inputTokens: Int64?
    let outputTokens: Int64?
}

private struct ResponseUsage: Decodable {
    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case threadID = "thread_id"
        case turnID = "turn_id"
        case usage
    }

    let responseID: String
    let threadID: String
    let turnID: String?
    let usage: Usage
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
}

private struct CounterSample: Codable {
    let last: Int64
    let estimated: Bool
    let inherited: Bool
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

private struct Contribution {
    let tokens: Int64
    let date: Date?
    let original: Bool
    var owner: String? = nil

    func preferred(over previous: Self?) -> Self {
        guard let previous else { return self }
        if original != previous.original { return original ? self : previous }
        if tokens != previous.tokens { return tokens < previous.tokens ? self : previous }
        if let date, previous.date.map({ date < $0 }) ?? true { return self }
        return previous
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

private final class CompressedLog {
    private let process = Process()
    private let reader: FileHandle
    private let exited = DispatchSemaphore(value: 0)

    init(input: FileHandle) throws {
        let binary = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let binary else { throw TokenHistoryError.unavailable }
        let pipe = Pipe()
        reader = pipe.fileHandleForReading
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", "-c", "-q"]
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    deinit {
        try? reader.close()
        if process.isRunning { process.terminate() }
    }

    func read() throws -> Data { try reader.read(upToCount: 256 * 1024) ?? Data() }

    func finish() throws {
        exited.wait()
        guard process.terminationStatus == 0 else { throw TokenHistoryError.unavailable }
    }
}
