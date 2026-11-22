import Foundation

@main
enum PresentationChecks {
    static func main() throws {
        let domain = testPreferencesDomain()
        // Seed the fixture first so a misrouted suite fails before its first preference write.
        let preferenceRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTABAR_TEST_PREFERENCES"]!)
        let fixture = preferenceRoot.appendingPathComponent((domain as NSString).lastPathComponent)
            .appendingPathExtension("plist")
        let marker = UUID().uuidString
        let seed = try PropertyListSerialization.data(fromPropertyList: ["marker": marker], format: .binary, options: 0)
        try seed.write(to: fixture)
        let preferences = UserDefaults(suiteName: domain)!
        precondition(preferences.string(forKey: "marker") == marker, "Suite failed to read the private fixture plist")
        preferences.set("written", forKey: "marker")
        precondition(preferences.synchronize())
        // cfprefsd can acknowledge synchronize() before its atomic file replacement completes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let stored = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture), format: nil)
            if (stored as? [String: String])?["marker"] == "written" { break }
            precondition(ContinuousClock.now < deadline, "Suite did not write the private fixture plist")
            Thread.sleep(forTimeInterval: 0.02)
        }
        print("Swift preferences read and wrote the private fixture plist.")
        defer { preferences.removePersistentDomain(forName: domain) }
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        try files.createDirectory(
            at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        precondition(UsageProvider.detected(environment: [:], home: home, defaults: preferences) == [.claude])
        let codexRoot = home.appendingPathComponent("alternate-codex")
        try files.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data().write(to: codexRoot.appendingPathComponent("sessions"))
        let env = ["CODEX_HOME": codexRoot.path]
        precondition(UsageProvider.detected(environment: env, home: home, defaults: preferences) == [.claude])
        try files.createDirectory(
            at: codexRoot.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        precondition(UsageProvider.detected(environment: env, home: home, defaults: preferences) == [.codex, .claude])
        ClaudeProfile.select(codexRoot, defaults: preferences)
        precondition(UsageProvider.detected(environment: env, home: home, defaults: preferences) == [.codex])
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
        func shown(
            _ windows: [QuotaWindow], provider: UsageProvider = .claude, limits: MenuBarLimits = .fiveHour,
            mode: PercentageMode = .remaining, failed: Bool = false
        ) -> QuotaDisplay {
            QuotaDisplay(
                reading: QuotaReading(fetchedAt: now, windows: windows), now: now, failed: failed, refreshing: false,
                provider: provider, percentageMode: mode, menuBarLimits: limits)
        }
        // Either provider shows its 5-hour window by default, even when the weekly window is more used.
        let busyWeek = QuotaWindow(minutes: 10_080, remaining: 30, resetsAt: now.addingTimeInterval(600))
        for provider in UsageProvider.allCases {
            let fiveHour = shown([busyWeek, session], provider: provider)
            precondition(fiveHour.menuBarTitle == "42%", fiveHour.menuBarTitle)
            precondition(fiveHour.accessibilityTitle.contains("5-hour limit, 42% remaining"))
            precondition(!fiveHour.accessibilityTitle.contains("Weekly"))
            precondition(fiveHour.offersFiveHourChoice)
            precondition(shown([busyWeek, session], provider: provider, mode: .used).menuBarTitle == "58%")
            let day = QuotaWindow(minutes: 1_440, remaining: 52, resetsAt: now.addingTimeInterval(600))
            let dailyAndSession = shown([day, session], provider: provider, limits: .both)
            precondition(dailyAndSession.offersFiveHourChoice && MenuBarLimits.both.title == "All Reported Limits")
            precondition(dailyAndSession.menuBarTitle == "5h 42% · 1d 52%")
            let both = shown([busyWeek, session], provider: provider, limits: .both)
            precondition(both.menuBarTitle == "5h 42% · 7d 30%", both.menuBarTitle)
            precondition(
                shown([busyWeek, session], provider: provider, limits: .both, mode: .used).menuBarTitle
                    == "5h 58% · 7d 70%")
            precondition(both.accessibilityTitle.contains("5-hour limit, 42% remaining · Weekly limit, 30% remaining"))
            precondition(
                shown([busyWeek, session], provider: provider, limits: .both, failed: true).menuBarTitle == "–%")
            // Plans without a 5-hour window keep the most-used window and get no choice.
            for limits in MenuBarLimits.allCases {
                let weekly = shown([busyWeek], provider: provider, limits: limits)
                precondition(weekly.menuBarTitle == "30%" && !weekly.offersFiveHourChoice)
                let daily = QuotaWindow(minutes: 1_440, remaining: 20, resetsAt: now.addingTimeInterval(600))
                let noFive = shown([busyWeek, daily], provider: provider, limits: limits)
                precondition(noFive.menuBarTitle == "20%" && !noFive.offersFiveHourChoice)
            }
            precondition(!shown([session], provider: provider).offersFiveHourChoice)
        }
        print("Menu bar 5-hour limits: shown by default when reported, both windows on request, for either provider.")
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
