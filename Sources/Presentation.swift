import Foundation

enum UsageProvider: String, CaseIterable, Sendable {
    case codex, claude

    var name: String { self == .codex ? "Codex" : "Claude" }

    static func detected(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Self] {
        let files = FileManager.default
        func hasHistory(_ key: String, directory: String, paths: [String]) -> Bool {
            let base =
                environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(directory)
            return paths.contains { path in
                var isDirectory: ObjCBool = false
                return files.fileExists(atPath: base.appendingPathComponent(path).path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
        return allCases.filter { provider in
            switch provider {
            case .codex: return hasHistory("CODEX_HOME", directory: ".codex", paths: ["sessions", "archived_sessions"])
            case .claude: return hasHistory("CLAUDE_CONFIG_DIR", directory: ".claude", paths: ["projects"])
            }
        }
    }
}

enum ProviderSelection: String, CaseIterable {
    case codex, claude, both

    var singleProvider: UsageProvider? {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .both: return nil
        }
    }

    var title: String {
        switch self {
        case .codex: return "ChatGPT (Codex) Only"
        case .claude: return "Claude Only"
        case .both: return "Both Providers"
        }
    }

    static func saved(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: "providerSelection").flatMap(Self.init(rawValue:)) ?? .both
    }
}

enum MenuBarLayout: String, CaseIterable {
    case percentage, logo, both

    var title: String {
        switch self {
        case .percentage: return "Percentage Only"
        case .logo: return "Logo and Percentage"
        case .both: return "Both Providers"
        }
    }
}

enum PercentageMode: String, CaseIterable {
    case remaining, used

    var title: String { self == .remaining ? "Amount Left" : "Amount Used" }
    var toggled: Self { self == .remaining ? .used : .remaining }
}

struct QuotaDisplay {
    static func refreshCountdown(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Refresh due" }
        if remaining >= 60 {
            return "Refreshes in " + String(Int(ceil(remaining / 60))) + " min"
        }
        return "Refreshes in " + String(max(1, Int(remaining))) + " sec"
    }

    static func resetCountdown(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Awaiting update" }
        let units: Set<Duration.UnitsFormatStyle.Unit>
        let precision: Double
        switch remaining {
        case 86_400...: (units, precision) = ([.days, .hours], 3_600)
        case 3_600...: (units, precision) = ([.hours, .minutes], 60)
        case 60...: (units, precision) = ([.minutes], 60)
        default: (units, precision) = ([.seconds], 1)
        }
        let seconds = precision == 1 ? ceil(remaining) : floor(remaining / precision) * precision
        let duration = Duration.seconds(seconds).formatted(.units(allowed: units, width: .wide))
        return "Limit resets in " + duration
    }

    static let refreshInterval: TimeInterval = 180
    // A scheduled read has up to 15 seconds to complete.
    static let maximumAge = refreshInterval + 15
    let reading: QuotaReading?
    let now: Date
    let failed: Bool
    let refreshing: Bool
    var provider: UsageProvider = .codex
    var percentageMode: PercentageMode = .remaining

    var restrictionUnconfirmed = false

    var windows: [QuotaWindow] {
        (reading?.windows ?? []).sorted { ($0.minutes ?? Int.max) < ($1.minutes ?? Int.max) }
    }

    func hasReset(_ window: QuotaWindow) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    var limitingWindow: QuotaWindow? {
        windows.filter { !hasReset($0) }.min {
            if $0.used != $1.used { return $0.used > $1.used }
            return ($0.minutes ?? Int.max) < ($1.minutes ?? Int.max)
        }
    }

    var validUntil: Date? {
        guard let reading else { return nil }
        let expiry = reading.fetchedAt.addingTimeInterval(Self.maximumAge)
        return reading.windows.compactMap(\.resetsAt).min().map { min($0, expiry) } ?? expiry
    }

    var stale: Bool {
        guard let reading, let validUntil else { return false }
        return failed || reading.fetchedAt > now || now >= validUntil
    }

    var restrictionMessage: String? {
        guard !stale else { return nil }
        if reading?.ordinaryUsageAllowed == false { return "Codex reports a usage restriction" }
        return restrictionUnconfirmed ? "Codex hasn’t confirmed that usage is available again" : nil
    }

    var hasCurrentPercentage: Bool { !stale && restrictionMessage == nil && limitingWindow != nil }

    var title: String {
        guard hasCurrentPercentage, let window = limitingWindow else { return "–%" }
        return formattedPercentage(for: window)
    }

    var accessibilityTitle: String {
        if let restrictionMessage { return restrictionMessage }
        guard hasCurrentPercentage, let window = limitingWindow else {
            let status = refreshing ? "Checking \(provider.name) limits" : "Current \(provider.name) limits unavailable"
            if let reading, stale {
                return status + ". Last report " + reportTime(reading.fetchedAt) + "."
            }
            return status
        }
        return provider.name + " · " + Self.name(window) + ", " + accessibilityPercentage(for: window)
            + (provider == .claude ? " · Account-wide" : "")
    }

    func reportTime(_ date: Date) -> String {
        date.formatted(
            date: Calendar.current.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }

    var tooltipReading: String {
        guard hasCurrentPercentage, let reading else { return accessibilityTitle }
        let source = provider == .claude ? " · Claude Code report " : " · Codex read "
        return accessibilityTitle + source + reportTime(reading.fetchedAt)
    }

    func formattedPercentage(for window: QuotaWindow) -> String {
        // Subtracting a tiny nonzero double from 100 can round all the way back to 100.
        if percentageMode == .remaining, window.used > 0, window.remaining == 100 { return ">99.99%" }
        return Self.percent(percentage(for: window))
    }

    func percentage(for window: QuotaWindow) -> Double {
        percentageMode == .remaining ? window.remaining : window.used
    }

    func accessibilityPercentage(for window: QuotaWindow) -> String {
        formattedPercentage(for: window) + (percentageMode == .remaining ? " remaining" : " used")
    }

    static func name(_ window: QuotaWindow) -> String {
        guard let minutes = window.minutes else { return "Usage limit" }
        switch minutes {
        case 300: return "5-hour limit"
        case 10_080: return "Weekly limit"
        case 1_440: return "Daily limit"
        default:
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
    }

    static func percent(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01%" }
        if value > 99.99 && value < 100 { return ">99.99%" }
        if value > 100 && value < 100.01 { return ">100%" }
        if let whole = Int(exactly: value) { return "\(whole)%" }
        if value < Double(Int.max) {
            return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) + "%"
        }
        return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...3)).rounded(rule: .down))
            + "%"
    }
}
