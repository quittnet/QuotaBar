import CryptoKit
import Darwin
import Foundation

enum ClaudeQuotaSource {
    static let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.quotabar.QuotaBar/claude", isDirectory: true)
        .appendingPathComponent("quota.json")

    static func read(file: URL = cacheFile, now: Date = Date()) throws -> QuotaReading? {
        guard let snapshot = try load(file), (snapshot.lastRecordedAt ?? snapshot.observedAt) <= now else { return nil }
        guard let limits = snapshot.limits, !limits.activeWindows(at: now).isEmpty else { return nil }
        let windows = limits.windows
        return QuotaReading(fetchedAt: snapshot.observedAt, windows: windows)
    }

    /// Accepts the documented Claude Code status-line JSON. Never persists the original input.
    static func capture(statusLine: Data, file: URL = cacheFile, now: Date = Date()) throws {
        let payload: StatusLine
        do {
            payload = try JSONDecoder().decode(StatusLine.self, from: statusLine)
        } catch {
            try invalidate(file: file, now: now)
            throw error
        }
        let limits = payload.rateLimits.flatMap { $0.activeWindows(at: now).isEmpty ? nil : $0 }
        try record(limits, sessionID: payload.sessionID, file: file, now: now)
    }

    static func invalidate(file: URL = cacheFile, now: Date = Date()) throws {
        try record(nil, sessionID: nil, file: file, now: now)
    }

    private static func record(_ limits: Limits?, sessionID: String?, file: URL, now: Date) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Several terminals can render at once. Serialize comparison and replacement.
        let lock = open(file.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // The next valid report can replace a damaged cache.
        let previous = try? load(file)
        if let previous, (previous.lastRecordedAt ?? previous.observedAt) > now { return }
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
            observedAt: observedAt, lastRecordedAt: now, limits: accepted, unavailable: accepted == nil,
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
