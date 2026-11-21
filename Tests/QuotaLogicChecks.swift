import Foundation
import os

@main
@MainActor
struct QuotaLogicChecks {
    static func main() async throws {
        let reports = checkReports()
        let transitions = checkAccountTransitions()
        try await checkExpiredResetPolling()
        try await checkResetPollingAfterRelaunch()
        checkMenuBarLimitsSetting()
        try await checkInitialResetReadFailure()
        try await checkClaudeConnectionActions()
        try await checkClaudeProfiles()
        print("Passed \(reports) quota display scenarios and \(transitions) account restriction transitions.")
    }

    static func checkClaudeProfiles() async throws {
        let files = FileManager.default
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            fatalError("Run profile checks with check.sh in an isolated home")
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent("profile-check-" + UUID().uuidString)
        let first = root.appendingPathComponent("one")
        let second = root.appendingPathComponent("two")
        let now = Date()
        defer { try? files.removeItem(at: root) }
        for (profile, amount) in [(first, 23), (second, 75)] {
            let projects = profile.appendingPathComponent("projects")
            try files.createDirectory(at: projects, withIntermediateDirectories: true)
            let transcript =
                #"{"type":"assistant","timestamp":"2026-11-18T12:00:00Z","message":{"id":"same-id","model":"test","stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":\#(amount)}}}"#
            try (transcript + "\n").write(
                to: projects.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
            let report = #"{"session_id":"same-id","rate_limits":{"five_hour":{"used_percentage":\#(amount)}}}"#
            let file = ClaudeQuotaSource.cacheFile(for: profile)
            precondition(
                file.resolvingSymlinksInPath().path.hasPrefix(
                    URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"))
            try ClaudeQuotaSource.capture(statusLine: Data(report.utf8), file: file)
        }
        let reader = LocalTokenReader()
        for (profile, amount) in [(first, 23), (second, 75), (first, 23)] {
            let report = try ClaudeQuotaSource.read(file: ClaudeQuotaSource.cacheFile(for: profile))
            let totals = try await reader.totals(for: .claude, now: now, claudeProfile: profile)
            precondition(
                report?.windows.first?.used == Double(amount) && totals.allTime == Int64(amount) && !totals.partial)
        }
        print("Switched between two Claude profiles with distinct percentages and token totals.")
    }

    static func checkClaudeConnectionActions() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude", forKey: "providerSelection")
        let store = UsageResets(file: URL(fileURLWithPath: suite).appendingPathExtension("resets"))
        let reading = QuotaReading(fetchedAt: Date(), windows: [.init(minutes: 300, remaining: 52, resetsAt: nil)])
        let upgrade = "Upgrade Claude Code Connection"
        for legacy in [false, true] {
            for status: ClaudeConnection.Status in [.needsUpgrade, .configured, .notConfigured] {
                for available in [false, true] {
                    let app = AppDelegate(
                        resetStore: store, defaults: defaults, monitorNetwork: false,
                        readCodex: { _ in preconditionFailure("Codex is disabled") },
                        readClaude: {
                            if legacy { throw ClaudeUsageClient.Failure.unsupported }
                            return available ? reading : nil
                        },
                        readLegacyClaude: {
                            precondition(legacy)
                            return available ? reading : nil
                        }, readClaudeConnectionStatus: { (status, status != .notConfigured) })
                    app.networkChanged(available: false)
                    app.networkChanged(available: true)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while (app.display.refreshing || app.makePanel().claudeConnectionStatus != status)
                        && ContinuousClock.now < deadline
                    {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let panel = app.makePanel()
                    precondition(!panel.display.refreshing && panel.display.hasCurrentPercentage == available)
                    precondition(panel.claudeUsesLegacyReport == legacy)
                    let action = panel.claudeSetupAction(for: panel.display)
                    switch status {
                    case .needsUpgrade:
                        precondition(action == upgrade && panel.claudeSettingsAction == upgrade)
                    case .configured:
                        precondition(action == nil && panel.claudeSettingsAction == "Reconnect Claude Code")
                    case .notConfigured:
                        precondition(action == (legacy && !available ? "Connect Claude Code" : nil))
                        precondition(panel.claudeSettingsAction == nil)
                    }
                }
            }
        }
        let app = AppDelegate(
            resetStore: store, defaults: defaults, monitorNetwork: false,
            readClaude: { throw ClaudeUsageClient.Failure.unavailable },
            readClaudeConnectionStatus: { (.needsUpgrade, true) })
        app.networkChanged(available: false)
        app.networkChanged(available: true)
        app.networkChanged(available: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while app.makePanel().claudeSettingsAction == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!app.display.hasCurrentPercentage && app.makePanel().claudeSettingsAction == upgrade)
    }

    static func checkExpiredResetPolling() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        let receipt = file.appendingPathExtension("completed")
        defer { try? FileManager.default.removeItem(at: receipt) }
        let store = UsageResets(file: file)
        let app = AppDelegate(
            resetStore: store, defaults: defaults, monitorNetwork: false,
            readCodex: { _ in
                return QuotaReading(
                    fetchedAt: Date(), windows: [], resetCredits: .init(availableCount: 3),
                    resetCountOnlyFingerprint: "sample")
            },
            redeem: { _ in preconditionFailure("Balance verification must not submit a reset") })
        try JSONSerialization.data(withJSONObject: [
            "account": "sample", "count": 3, "time": Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate,
        ]).write(to: receipt)
        app.networkChanged(available: false)
        app.networkChanged(available: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.awaitingUpdatedBalance && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(store.awaitingUpdatedBalance, "The expired receipt must still block new spending")
        precondition(app.nextRefreshDate == nil, "An expired receipt must not schedule an extra quota read")
    }

    static func checkResetPollingAfterRelaunch() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        let receipt = file.appendingPathExtension("completed")
        defer { try? FileManager.default.removeItem(at: receipt) }
        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try JSONSerialization.data(withJSONObject: [
            "account": "sample", "count": 3, "time": origin.timeIntervalSinceReferenceDate,
        ]).write(to: receipt)

        func finishRead(_ app: AppDelegate) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while app.display.refreshing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(!app.display.refreshing && !app.display.failed)
        }

        let cases: [(relaunch: Int, polls: [Int], slept: Bool)] = [
            (14, [29, 44, 59], false), (29, [44, 59], false), (44, [59], false),
            (44, [], true),
        ]
        for scenario in cases {
            let fixture = OSAllocatedUnfairLock(initialState: (age: 0, readAges: [Int]()))
            func launch() -> AppDelegate {
                let app = AppDelegate(
                    resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false,
                    quotaNow: { origin.addingTimeInterval(Double(fixture.withLock { $0.age })) },
                    readCodex: { needsIdentity in
                        precondition(needsIdentity)
                        let age = fixture.withLock { state in
                            state.readAges.append(state.age)
                            return state.age
                        }
                        return QuotaReading(
                            fetchedAt: origin.addingTimeInterval(Double(age)),
                            windows: [.init(minutes: 300, remaining: 64, resetsAt: nil)],
                            resetCredits: .init(availableCount: 3), resetCountOnlyFingerprint: "sample")
                    },
                    redeem: { _ in preconditionFailure("Balance verification must not submit a reset") })
                app.networkChanged(available: false)
                app.networkChanged(available: true)
                return app
            }

            do {
                let original = launch()
                try await finishRead(original)
                precondition(original.nextRefreshDate == origin.addingTimeInterval(15))
            }
            fixture.withLock { $0.age = scenario.relaunch }
            let app = launch()
            try await finishRead(app)
            let firstDue = scenario.relaunch + 15
            precondition(app.nextRefreshDate == origin.addingTimeInterval(Double(firstDue)))
            let firstTick = scenario.slept ? 60 : scenario.relaunch + 1
            for age in firstTick...105 {
                fixture.withLock { $0.age = age }
                app.tick()
                try await finishRead(app)
            }
            let readAges = fixture.withLock { $0.readAges }
            precondition(readAges == [0, scenario.relaunch] + scenario.polls, "Unexpected Codex reads: \(readAges)")
            precondition(app.nextRefreshDate == nil && app.makePanel().resetBalanceUnconfirmed)
            precondition(!app.makePanel().canUseReset)
            print("Codex relaunch at +\(scenario.relaunch)s, slept=\(scenario.slept), observed read ages \(readAges).")
        }
    }

    static func checkMenuBarLimitsSetting() {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        func launch() -> AppDelegate {
            AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        precondition(launch().menuBarLimits == [.codex: .fiveHour, .claude: .fiveHour], "5-hour is the default.")
        defaults.set("mostUsed", forKey: "claudeMenuBarLimits")
        precondition(launch().menuBarLimits[.claude] == .fiveHour, "The retired most-used choice falls back to 5-hour.")
        launch().selectMenuBarLimits(.both, for: .claude)
        precondition(defaults.string(forKey: "claudeMenuBarLimits") == "both")
        precondition(
            launch().menuBarLimits == [.codex: .fiveHour, .claude: .both], "Each provider keeps its own choice.")
        launch().selectMenuBarLimits(.both, for: .codex)
        precondition(defaults.string(forKey: "codexMenuBarLimits") == "both" && launch().menuBarLimits[.codex] == .both)
        print("Menu bar limits settings persisted per provider across relaunch.")
    }

    static func checkInitialResetReadFailure() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let dir = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, outcome) in [QuotaResetClaimResult.reset, .nothingToReset].enumerated() {
            let store = UsageResets(file: dir.appendingPathComponent("pending-\(index).json"))
            let app = AppDelegate(
                resetStore: store, defaults: defaults, monitorNetwork: false,
                readCodex: { _ in throw URLError(.timedOut) },
                redeem: { _ in preconditionFailure("Balance verification must not submit a reset") })
            let now = Date()
            let reading = QuotaReading(
                fetchedAt: now, windows: [.init(minutes: 300, remaining: 64, resetsAt: nil)],
                resetCredits: .init(availableCount: 3), resetCountOnlyFingerprint: "sample")
            let display = QuotaDisplay(reading: reading, now: now, failed: false, refreshing: false)
            store.prepare(display)
            precondition(store.begin(display) != nil)
            app.finishReset(outcome)
            precondition(app.display.refreshing, "A reset outcome must refresh the current balance immediately")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while app.display.refreshing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(!app.display.refreshing && app.display.failed)
            if outcome == .reset {
                precondition(store.awaitingUpdatedBalance && !store.canPrepare(display))
                precondition(app.nextRefreshDate == nil, "A failed post-spend read must not start a retry chain")
            } else {
                precondition(app.nextRefreshDate != nil, "An ordinary quota read must keep its transient error retry")
            }
        }
    }

    static func checkReports() -> Int {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        var count = 0
        for short in [0, 1, 48, 52, 99, 100] {
            for weekly in [0, 1, 48, 52, 99, 100] {
                for resetsIn: Int? in [nil, 0, 60, 194, 196] {
                    let fiveHour = QuotaWindow(
                        minutes: 300, used: Double(short),
                        resetsAt: resetsIn.map { fetched.addingTimeInterval(Double($0)) })
                    let week = QuotaWindow(minutes: 10080, used: Double(weekly), resetsAt: nil)
                    for age in [-1, 0, 59, 60, 193, 194, 195, 196] {
                        for provider in UsageProvider.allCases {
                            for mode in PercentageMode.allCases {
                                for failed in [false, true] {
                                    for blocked in [false, true] {
                                        let reading = QuotaReading(
                                            fetchedAt: fetched,
                                            windows: count.isMultiple(of: 3) ? [week, fiveHour] : [fiveHour, week],
                                            ordinaryUsageAllowed: blocked ? false : nil)
                                        let display = QuotaDisplay(
                                            reading: reading, now: fetched.addingTimeInterval(Double(age)),
                                            failed: failed,
                                            refreshing: !failed, provider: provider, percentageMode: mode)
                                        let fresh = (0..<195).contains(age) && age < (resetsIn ?? Int.max) && !failed
                                        let used = max(short, weekly)
                                        let expected =
                                            fresh && !blocked ? "\(mode == .used ? used : 100 - used)%" : "–%"
                                        precondition(
                                            display.title == expected
                                                && display.hasCurrentPercentage == (fresh && !blocked),
                                            "Case \(count), \(provider) \(mode), expected \(expected), got \(display.title)"
                                        )
                                        if fresh && !blocked {
                                            let minutes = short >= weekly ? 300 : 10080
                                            precondition(
                                                display.limitingWindow?.minutes == minutes,
                                                "Wrong limit in case \(count)")
                                        }
                                        count += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return count
    }

    static func checkAccountTransitions() -> Int {
        // Exercise all three-event histories for two known identities and one unidentified account.
        let owners: [String?] = ["account-A", "account-B", nil]
        let permissions: [Bool?] = [false, true, nil]
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        defer { try? FileManager.default.removeItem(at: file) }
        func launch() -> AppDelegate {
            AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        func check(_ app: AppDelegate, _ owner: String?, _ allowed: Bool?) -> Bool {
            app.restrictionNeedsConfirmation(
                QuotaReading(
                    fetchedAt: Date(), windows: [], resetCountOnlyFingerprint: owner, ordinaryUsageAllowed: allowed))
        }
        defaults.set(["unidentified"], forKey: "restrictedCodexAccounts")
        var migrated = launch()
        precondition(check(migrated, "account-A", nil))
        for owner in ["account-A", "account-B"] {
            precondition(!check(migrated, owner, true))
        }
        migrated = launch()
        precondition(!check(migrated, "account-A", nil) && !check(migrated, "account-B", nil))
        precondition(!check(migrated, nil, false))
        precondition(check(migrated, "account-A", nil) && check(migrated, "account-B", nil))
        precondition(!check(migrated, "account-A", true))
        migrated = launch()
        precondition(!check(migrated, "account-A", nil) && check(migrated, "account-B", nil))
        precondition(check(migrated, nil, nil))

        var count = 0
        for trace in 0..<729 {
            defaults.removePersistentDomain(forName: suite)
            defaults.set("codex", forKey: "providerSelection")
            var app = launch()
            var unknownRestriction = false
            var decisions = [Bool?](repeating: nil, count: 2)
            var events = trace
            for step in 0..<3 {
                let event = events % 9
                events /= 9
                let identity = event / 3
                let allowed = permissions[event % 3]
                let reading = QuotaReading(
                    fetchedAt: Date(), windows: [], resetCountOnlyFingerprint: owners[identity],
                    ordinaryUsageAllowed: allowed)
                let expected: Bool
                if let allowed {
                    if owners[identity] != nil {
                        decisions[identity] = allowed
                    } else if !allowed {
                        unknownRestriction = true
                        decisions = decisions.map { $0 == true ? nil : $0 }
                    }
                    expected = false
                } else {
                    if owners[identity] == nil {
                        expected = unknownRestriction || decisions.contains(false)
                    } else {
                        expected = decisions[identity].map { !$0 } ?? unknownRestriction
                    }
                }
                if step == 2 { app = launch() }
                precondition(
                    app.restrictionNeedsConfirmation(reading) == expected, "Restriction trace \(trace), step \(step)")
                count += 1
            }
        }
        return count
    }
}
