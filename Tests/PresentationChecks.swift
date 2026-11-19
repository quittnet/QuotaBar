import Foundation

@main
enum PresentationChecks {
    static func main() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        try files.createDirectory(
            at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        precondition(UsageProvider.detected(environment: [:], home: home) == [.claude])
        let codexRoot = home.appendingPathComponent("alternate-codex")
        try files.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data().write(to: codexRoot.appendingPathComponent("sessions"))
        let env = ["CODEX_HOME": codexRoot.path]
        precondition(UsageProvider.detected(environment: env, home: home) == [.claude])
        try files.createDirectory(
            at: codexRoot.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        precondition(UsageProvider.detected(environment: env, home: home) == [.codex, .claude])
        for (seconds, expected) in [
            (180.0, "3 min"), (61, "2 min"), (60, "1 min"), (59.9, "59 sec"), (20, "20 sec"), (0.1, "1 sec"),
        ] {
            precondition(QuotaDisplay.refreshCountdown(seconds) == "Refreshes in " + expected)
        }
        for (seconds, expected) in [
            (0.1, "1 second"), (59, "59 seconds"), (60, "1 minute"), (3600, "1 hour"), (86400, "1 day"),
        ] {
            precondition(QuotaDisplay.resetCountdown(seconds) == "Limit resets in " + expected)
        }
        precondition(QuotaDisplay.resetCountdown(0) == "Awaiting update")
        precondition(QuotaDisplay.refreshCountdown(0) == "Refresh due")
        let now = Date()
        let session = QuotaWindow(minutes: 300, remaining: 42, resetsAt: now.addingTimeInterval(60))
        let week = QuotaWindow(minutes: 10_080, remaining: 77, resetsAt: now.addingTimeInterval(600))
        func sample(_ windows: [QuotaWindow], age: Double = 0, failed: Bool = false) -> QuotaDisplay {
            let reading = QuotaReading(fetchedAt: now.addingTimeInterval(-age), windows: windows)
            return QuotaDisplay(reading: reading, now: now, failed: failed, refreshing: false)
        }
        precondition(sample([week, session]).title == "42%")
        precondition(sample([week]).title == "77%")
        precondition(sample([week]).accessibilityTitle.contains("Weekly limit, 77% remaining"))
        precondition(sample([session], age: 601).stale)
        precondition(sample([week], failed: true).stale)
        precondition(sample([week], failed: true).title == "–%")
        precondition(sample([week], age: QuotaDisplay.maximumAge - 1).hasCurrentPercentage)
        precondition(!sample([week], age: QuotaDisplay.maximumAge).hasCurrentPercentage)
        precondition(sample([week], age: -1).title == "–%")
        precondition(sample([week]).tooltipReading.contains("Codex read "))
        let expired = QuotaWindow(minutes: 300, remaining: 10, resetsAt: now)
        precondition(sample([expired]).title == "–%")
        precondition(sample([expired, week]).stale)
        precondition(sample([expired, week]).title == "–%")
        precondition(QuotaDisplay.percent(0) == "0%")
        precondition(QuotaDisplay.percent(0.2) == "0.2%")
        precondition(QuotaDisplay.percent(100) == "100%")
        let initial = QuotaDisplay(reading: nil, now: now, failed: true, refreshing: false)
        precondition(initial.title == "–%")

        var used = sample([week, session])
        precondition(used.percentageMode == .remaining)
        used.percentageMode = used.percentageMode.toggled
        precondition(used.percentageMode == .used && used.percentageMode.toggled == .remaining)
        precondition(used.limitingWindow == session && used.title == "58%")
        precondition(used.percentage(for: week) == 23)
        precondition(used.accessibilityTitle == "Codex · 5-hour limit, 58% used")

        var stale = sample([expired, week], failed: true)
        stale.provider = .claude
        stale.percentageMode = .used
        precondition(stale.limitingWindow == week && stale.title == "–%")
        precondition(stale.accessibilityTitle.hasPrefix("Current Claude limits unavailable. Last report "))
        var unavailable = sample([expired])
        unavailable.percentageMode = .used
        precondition(unavailable.limitingWindow == nil && unavailable.title == "–%")
        precondition(unavailable.accessibilityTitle.hasPrefix("Current Codex limits unavailable"))
        let checking = QuotaDisplay(
            reading: nil, now: now, failed: false, refreshing: true, provider: .claude, percentageMode: .used)
        precondition(checking.title == "–%" && checking.accessibilityTitle == "Checking Claude limits")

        for (usedPercent, expectedRemaining, expectedUsed) in [
            (0.0, "100%", "0%"), (100.0, "0%", "100%"),
            (0.2, "99.8%", "0.2%"), (99.8, "0.2%", "99.8%"),
            (0.0001, ">99.99%", "<0.01%"), (99.99999, "<0.01%", ">99.99%"),
            (Double.leastNonzeroMagnitude, ">99.99%", "<0.01%"), (100.001, "0%", ">100%"),
            (12.0, "88%", "12%"), (87.8, "12.2%", "87.8%"), (110.0, "0%", "110%"),
        ] {
            let window = QuotaWindow(minutes: nil, used: usedPercent, resetsAt: nil)
            var display = sample([window])
            precondition(display.title == expectedRemaining)
            display.percentageMode = .used
            precondition(display.title == expectedUsed)
        }

        let full = QuotaWindow(minutes: 300, used: 100, resetsAt: nil)
        let over = QuotaWindow(minutes: 10_080, used: 110, resetsAt: nil)
        var atLimit = sample([full, over])
        precondition(atLimit.limitingWindow == over && atLimit.title == "0%")
        atLimit.percentageMode = .used
        precondition(atLimit.limitingWindow == over && atLimit.title == "110%")
        precondition(QuotaDisplay.percent(.greatestFiniteMagnitude).hasSuffix("%"))
        print("Menu percentage modes, stale, unavailable, zero, reset and weekly-only checks passed")
    }
}
