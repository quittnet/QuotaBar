import CryptoKit
import Darwin
import Foundation

enum ClaudeQuotaSource {
    struct CaptureOrder: Codable, Sendable {
        let boot: UUID
        let ticks: UInt64

        private static let bootID: UUID? = {
            var bytes = [UInt8](repeating: 0, count: 37)
            var size = bytes.count
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
            return UUID(uuidString: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        }()

        static func current() -> Self? {
            let ticks = mach_continuous_time()
            return bootID.map { Self(boot: $0, ticks: ticks) }
        }
    }

    static var cacheFile: URL { cacheFile(for: ClaudeProfile.directory) }

    static func cacheFile(for profile: URL, configuration: String? = ClaudeProfile.childConfigurationDirectory()) -> URL
    {
        let path = profile.resolvingSymlinksInPath().standardizedFileURL.path
        let normal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            .resolvingSymlinksInPath().standardizedFileURL.path
        // Claude can sign into different accounts using the same normal folder.
        // Older path-only entries for that folder cannot be attributed to either sign-in.
        let identity = path == normal ? path + "\0" + (configuration ?? "") : path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.quotabar.QuotaBar/claude", isDirectory: true)
            .appendingPathComponent(key + ".json")
    }

    static func read(file: URL = cacheFile, now: Date = Date()) throws -> QuotaReading? {
        guard let snapshot = try load(file), (snapshot.lastRecordedAt ?? snapshot.observedAt) <= now else { return nil }
        guard let limits = snapshot.limits, !limits.activeWindows(at: now).isEmpty else { return nil }
        let windows = limits.windows
        return QuotaReading(fetchedAt: snapshot.observedAt, windows: windows)
    }

    /// Accepts the documented Claude Code status-line JSON. Never persists the original input.
    static func capture(
        statusLine: Data, file: URL = cacheFile, order: CaptureOrder? = .current(), now: Date = Date(),
        currentDate: () -> Date = Date.init
    ) throws {
        let payload: StatusLine
        do {
            payload = try JSONDecoder().decode(StatusLine.self, from: statusLine)
        } catch {
            try invalidate(file: file, order: order, now: now, currentDate: currentDate)
            throw error
        }
        let limits = payload.rateLimits.flatMap { $0.activeWindows(at: now).isEmpty ? nil : $0 }
        try record(limits, sessionID: payload.sessionID, file: file, order: order, now: now, currentDate: currentDate)
    }

    static func invalidate(
        file: URL = cacheFile, order: CaptureOrder? = .current(), now: Date = Date(),
        currentDate: () -> Date = Date.init
    ) throws {
        try record(nil, sessionID: nil, file: file, order: order, now: now, currentDate: currentDate)
    }

    private static func record(
        _ limits: Limits?, sessionID: String?, file: URL, order: CaptureOrder?, now: Date, currentDate: () -> Date
    ) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Several terminals can render at once. Serialize comparison and replacement.
        let lock = open(file.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let lockedAt = currentDate()
        guard now <= lockedAt else { return }
        var previous = try? load(file)
        if let saved = previous {
            if let order, let prior = saved.order {
                // Ticks survive sleep but reset at boot. An impossible future tick cannot establish ordering.
                if prior.boot == order.boot && prior.ticks <= mach_continuous_time() && order.ticks <= prior.ticks {
                    return
                }
            } else {
                // Legacy caches and systems without a boot ID have only wall-clock ordering.
                let recorded = saved.lastRecordedAt ?? saved.observedAt
                if recorded <= lockedAt && recorded > now { return }
            }
            if saved.observedAt > now { previous = nil }
        }
        var accepted = limits
        var sessions = previous?.recentSessions ?? []
        if let id = sessionID, !id.isEmpty {
            let key = Data(SHA256.hash(data: Data(id.utf8))).base64EncodedString()
            // An idle terminal can redraw its old snapshot, including after Claude drops an expired window.
            if let last = sessions.first(where: { $0.key == key }), last.limits != previous?.limits,
                last.limits?.activeWindows(at: now) == limits?.activeWindows(at: now)
            {
                accepted = previous?.limits
            }
            sessions.removeAll { $0.key == key }
            sessions.append(SessionReport(key: key, limits: limits))
            sessions = Array(sessions.suffix(64))
        }
        let sameBalance = previous?.limits?.activeWindows(at: now) == accepted?.activeWindows(at: now)
        let observedAt = sameBalance ? previous?.observedAt ?? now : now
        // Even an unchanged report advances ordering, without advancing the time of the quota observation.
        let snapshot = Snapshot(
            observedAt: observedAt, lastRecordedAt: now, order: order, limits: accepted, unavailable: accepted == nil,
            recentSessions: sessions)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file, options: .atomic)
    }

    private static func load(_ file: URL) throws -> Snapshot? {
        do {
            guard let data = try PrivateFile.read(file, maximumBytes: 1024 * 1024) else { return nil }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.lastRecordedAt.map({ $0 >= snapshot.observedAt }) ?? true,
                snapshot.limits.map({ !$0.windows.isEmpty && snapshot.unavailable != true })
                    ?? (snapshot.unavailable == true)
            else { throw ReadError() }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw ReadError()
        }
    }

    private struct ReadError: LocalizedError {
        var errorDescription: String? {
            "QuotaBar couldn’t read the saved Claude limits. The next Claude Code report can replace them."
        }
    }

    private struct StatusLine: Decodable {
        let sessionID: String?
        let rateLimits: Limits?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            // A malformed supplied window makes the combined percentage unknown.
            rateLimits = try? values.decode(Limits.self, forKey: .rateLimits)
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case rateLimits = "rate_limits"
        }
    }

    private struct Snapshot: Codable {
        let observedAt: Date
        // A later terminal can report the same snapshot without making its quota data fresher.
        let lastRecordedAt: Date?
        let order: CaptureOrder?
        let limits: Limits?
        let unavailable: Bool?
        let recentSessions: [SessionReport]?
    }

    private struct SessionReport: Codable {
        let key: String
        let limits: Limits?
    }

    private struct Limits: Codable, Equatable {
        let fiveHour: Window?
        let sevenDay: Window?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try values.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try values.decodeIfPresent(Window.self, forKey: .sevenDay)
        }

        var windows: [QuotaWindow] {
            [fiveHour?.quota(minutes: 300), sevenDay?.quota(minutes: 10_080)].compactMap { $0 }
        }

        func activeWindows(at date: Date) -> [QuotaWindow] {
            windows.filter { $0.resetsAt.map { $0 > date } ?? true }
        }
    }

    private struct Window: Codable, Equatable {
        let usedPercentage: Double
        let resetsAt: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try values.decode(Double.self, forKey: .usedPercentage)
            resetsAt = try values.decodeIfPresent(Double.self, forKey: .resetsAt)
            guard (0...100).contains(usedPercentage),
                resetsAt.map({ $0 > 0 && $0 < Date.distantFuture.timeIntervalSince1970 }) ?? true
            else {
                throw ReadError()
            }
        }

        func quota(minutes: Int) -> QuotaWindow {
            QuotaWindow(
                minutes: minutes, used: usedPercentage, resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
    }
}
