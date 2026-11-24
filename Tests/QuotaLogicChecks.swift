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
        try await checkResetNoticeOnSignOut()
        checkMenuBarLimitsSetting()
        checkMenuBarLayoutSetting()
        checkTokenSpendSetting()
        checkDailyUsageSetting()
        try await checkCLIChoiceOrdering()
        try await checkSharedRefreshCountdown()
        try await checkStaleWindowReset()
        try await checkVisibleHistoryReaders()
        checkRefreshCountdownSchedule()
        checkResetCountdownSchedule()
        checkDailyUsage()
        try await checkInitialResetReadFailure()
        try await checkClaudeConnectionActions()
        try await checkOverlappingConnectionChecks()
        try await checkLiveRefreshDuringClaudeCacheRead()
        try await checkClaudeProfiles()
        try await checkClaudeProfileLinkChangedDuringRefresh()
        try await checkClaudeAuthenticationSwitch()
        print("Passed \(reports) quota display scenarios and \(transitions) account restriction transitions.")
    }

    static func checkRefreshCountdownSchedule() {
        let deadline = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let schedule = RefreshCountdownSchedule(deadline: deadline)
        let start = deadline.addingTimeInterval(-179.5)
        let times = schedule.entries(from: start, mode: .normal).map { deadline.timeIntervalSince($0) }
        precondition(times == [179.5, 120, 60] + (0...59).reversed().map(Double.init))
        precondition(Array(schedule.entries(from: deadline, mode: .normal)) == [deadline])
        let overdue = deadline.addingTimeInterval(5)
        precondition(Array(schedule.entries(from: overdue, mode: .normal)) == [overdue])
        precondition(QuotaDisplay.refreshCountdown(deadline.timeIntervalSince(overdue)) == "Refresh due")
        let finalSecond = deadline.addingTimeInterval(-0.1)
        precondition(Array(schedule.entries(from: finalSecond, mode: .normal)) == [finalSecond, deadline])
    }

    static func checkResetCountdownSchedule() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (remaining, expectedOffset) in [
            (180_123.4, 123.401), (86_400.2, 0.201), (3_600.4, 0.401),
            (121.2, 1.201), (60.2, 0.201), (59.2, 0.2), (1.4, 0.4), (0.2, 0.2),
        ] {
            let reset = start.addingTimeInterval(remaining)
            var entries = ResetCountdownSchedule(reset: reset).entries(from: start, mode: .normal).makeIterator()
            precondition(entries.next() == start)
            let next = entries.next()!
            precondition(abs(next.timeIntervalSince(start) - expectedOffset) < 0.0001)
            var previous = next
            while let change = entries.next() {
                precondition(change > previous && change <= reset)
                previous = change
            }
            precondition(previous == reset)
        }
        let far = ResetCountdownSchedule(reset: Date(timeIntervalSince1970: Double(Int64.max)))
        let initial = Array(far.entries(from: start, mode: .normal).prefix(3))
        precondition(initial.count == 3 && initial[0] < initial[1] && initial[1] < initial[2])
        let ended = ResetCountdownSchedule(reset: start).entries(from: start, mode: .normal)
        precondition(Array(ended) == [start])
    }

    static func checkCLIChoiceOrdering() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileManager.default
        let folder = URL(fileURLWithPath: suite + "-tools", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        func wrapper(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.resolvingSymlinksInPath()
        }
        let first = try wrapper("first")
        let second = try wrapper("second")
        let app = AppDelegate(
            resetStore: UsageResets(file: folder.appendingPathComponent("reset")), defaults: defaults,
            monitorNetwork: false, readCodex: { _ in throw QuotaError.codexNotFound },
            readClaude: { throw ClaudeUsageClient.Failure.notInstalled },
            readClaudeConnectionStatus: { (.notConfigured, false) })
        app.networkChanged(available: false)
        app.networkChanged(available: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while app.makePanel().summaries.contains(where: { !$0.missingCLI }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(app.makePanel().summaries.count == 2 && app.makePanel().summaries.allSatisfy(\.missingCLI))
        app.networkChanged(available: false)
        func delayedChoice(_ gate: DispatchSemaphore) -> Task<Void, Never> {
            app.chooseCLI(for: .codex) {
                precondition(gate.wait(timeout: .now() + 5) == .success)
                return try ProviderExecutable.Selection(first)
            }
        }
        let automaticGate = DispatchSemaphore(value: 0)
        let beforeAutomatic = delayedChoice(automaticGate)
        app.makePanel().automaticCLI(.codex)
        precondition(app.makePanel().summaries.filter(\.missingCLI).map(\.display.provider) == [.claude])
        automaticGate.signal()
        await beforeAutomatic.value
        precondition(!ProviderExecutable.hasSelection("codex", defaults: defaults))

        let replaceGate = DispatchSemaphore(value: 0)
        let beforeReplace = delayedChoice(replaceGate)
        await app.chooseCLI(for: .codex) { try ProviderExecutable.Selection(second) }.value
        replaceGate.signal()
        await beforeReplace.value
        precondition(ProviderExecutable.selected("codex", defaults: defaults) == second)

        let independentGate = DispatchSemaphore(value: 0)
        let independent = delayedChoice(independentGate)
        await app.chooseCLI(for: .claude) { try ProviderExecutable.Selection(second) }.value
        precondition(app.makePanel().summaries.allSatisfy { !$0.missingCLI })
        independentGate.signal()
        await independent.value
        precondition(ProviderExecutable.selected("codex", defaults: defaults) == first)
        precondition(ProviderExecutable.selected("claude", defaults: defaults) == second)
        defaults.set("codex", forKey: "providerSelection")
        let now = Date()
        let retry = AppDelegate(
            resetStore: UsageResets(file: folder.appendingPathComponent("retry")), defaults: defaults,
            monitorNetwork: false, quotaNow: { now }, readCodex: { _ in throw URLError(.timedOut) })
        retry.networkChanged(available: false)
        retry.networkChanged(available: true)
        for changeCLI in [false, true] {
            if changeCLI { await retry.chooseCLI(for: .codex) { try ProviderExecutable.Selection(second) }.value }
            let end = ContinuousClock.now.advanced(by: .seconds(4))
            while retry.display.refreshing && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            precondition(retry.nextRefreshDate == now.addingTimeInterval(5))
        }
        print("Automatic detection and the latest file choice take precedence for each provider independently.")
    }

    static func checkSharedRefreshCountdown() async throws {
        for retry in [false, true] {
            let suite = testPreferencesDomain()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("both", forKey: "providerSelection")
            defaults.set("claude", forKey: "selectedProvider")
            let now = Date()
            let reset = now.addingTimeInterval(12)
            let store = UsageResets(file: URL(fileURLWithPath: suite + ".reset"))
            let app = AppDelegate(
                resetStore: store, defaults: defaults, monitorNetwork: false, quotaNow: { now },
                readCodex: { _ in
                    if retry { throw URLError(.timedOut) }
                    return QuotaReading(
                        fetchedAt: now, windows: [.init(minutes: 300, remaining: 42, resetsAt: reset)],
                        resetCredits: .init(availableCount: 1), resetCountOnlyFingerprint: "fixture")
                },
                readClaude: {
                    QuotaReading(fetchedAt: now, windows: [.init(minutes: 300, remaining: 52, resetsAt: nil)])
                },
                readClaudeConnectionStatus: { (.notConfigured, false) })
            app.networkChanged(available: false)
            app.makePanel().refresh()
            app.networkChanged(available: true)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while app.makePanel().summaries.contains(where: { $0.display.refreshing }) && ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            let panel = app.makePanel()
            precondition(panel.display.provider == .claude && !panel.detailsExpanded)
            precondition(panel.nextAutoRefresh == (retry ? now.addingTimeInterval(5) : reset))
            if !retry {
                store.prepare(panel.summaries.first { $0.display.provider == .codex }!.display)
                precondition(store.phase == .confirming && app.nextRefreshDate == reset)
                store.cancel()
            }
            panel.selectProviderSelection(.claude)
            precondition(app.nextRefreshDate == now.addingTimeInterval(QuotaDisplay.refreshInterval))
            app.networkChanged(available: false)
            precondition(app.nextRefreshDate == nil)
        }
        print("The shared footer follows enabled-provider retries, window resets and expiring confirmations.")
    }

    static func checkStaleWindowReset() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let start = Date()
        let first = start.addingTimeInterval(5)
        let second = start.addingTimeInterval(18)
        var now = start
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let app = AppDelegate(
            resetStore: UsageResets(file: URL(fileURLWithPath: suite + ".reset")),
            defaults: defaults, monitorNetwork: false, quotaNow: { now },
            readCodex: { _ in
                reads.withLock { $0 += 1 }
                return QuotaReading(
                    fetchedAt: start,
                    windows: [
                        .init(minutes: 300, remaining: 40, resetsAt: first),
                        .init(minutes: 10_080, remaining: 80, resetsAt: second),
                    ])
            })
        app.networkChanged(available: false)
        app.networkChanged(available: true)
        for (index, expected) in [first, second].enumerated() {
            let timeout = ContinuousClock.now.advanced(by: .seconds(5))
            while app.display.refreshing && ContinuousClock.now < timeout {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(app.nextRefreshDate == expected && reads.withLock { $0 } == index + 1)
            now = expected
            app.tick()
        }
        let timeout = ContinuousClock.now.advanced(by: .seconds(5))
        while app.display.refreshing && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(5)) }
        app.tick()
        precondition(app.nextRefreshDate == nil && !app.display.refreshing && reads.withLock { $0 } == 3)
    }

    static func checkVisibleHistoryReaders() async throws {
        let cases: [(Dashboard.Page, DailyUsageMode, Bool, UsageProvider, Set<UsageProvider>)] = [
            (.settings, .both, true, .codex, []), (.help, .tokens, true, .claude, []),
            (.usage, .off, false, .codex, []), (.usage, .off, true, .codex, [.codex]),
            (.usage, .off, true, .claude, [.claude]), (.usage, .spend, false, .claude, [.codex, .claude]),
        ]
        for (page, mode, expanded, selected, expected) in cases {
            let suite = testPreferencesDomain()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("both", forKey: "providerSelection")
            defaults.set(selected.rawValue, forKey: "selectedProvider")
            defaults.set(mode.rawValue, forKey: DailyUsageMode.preferenceKey)
            defaults.set(expanded ? ["details"] : [], forKey: "expandedDashboardSections")
            let app = AppDelegate(
                resetStore: UsageResets(file: URL(fileURLWithPath: suite + ".reset")), defaults: defaults,
                monitorNetwork: false, readCodex: { _ in preconditionFailure("Unexpected quota read") },
                readClaude: { preconditionFailure("Unexpected quota read") })
            app.makePanel().selectPage(page)
            app.refreshVisibleTokensIfDue()
            let active = app.makePanel().summaries.filter(\.countingTokens).map(\.display.provider)
            precondition(Set(active) == expected)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while app.makePanel().summaries.contains(where: \.countingTokens) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(app.makePanel().summaries.allSatisfy { !$0.countingTokens })
        }
        print("Interim history reads run only for providers with visible token or spend rows.")
    }

    static func checkTokenSpendSetting() {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        func launch(_ provider: UsageProvider) -> AppDelegate {
            defaults.set(provider.rawValue, forKey: "providerSelection")
            return AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        let codex = launch(.codex)
        precondition(!codex.makePanel().showSpend)
        codex.makePanel().setShowSpend(true)
        precondition(codex.makePanel().showSpend)
        let claude = launch(.claude)
        precondition(claude.makePanel().display.provider == .claude && claude.makePanel().showSpend)
        claude.makePanel().setShowSpend(false)
        precondition(!claude.makePanel().showSpend && !launch(.codex).makePanel().showSpend)
        print("History defaults to Tokens and remembers Spend or Tokens across providers and launches.")
    }

    static func checkLiveRefreshDuringClaudeCacheRead() async throws {
        let domain = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("claude", forKey: "providerSelection")
        let liveReads = OSAllocatedUnfairLock(initialState: 0)
        let cacheReads = OSAllocatedUnfairLock(initialState: 0)
        let releaseCache = DispatchSemaphore(value: 0)
        let store = UsageResets(file: URL(fileURLWithPath: domain + ".reset"))
        let old = QuotaReading(fetchedAt: Date(), windows: [.init(minutes: 300, remaining: 19, resetsAt: nil)])
        let fresh = QuotaReading(fetchedAt: Date(), windows: [.init(minutes: 300, remaining: 83, resetsAt: nil)])
        let app = AppDelegate(
            resetStore: store, defaults: defaults, monitorNetwork: false, readCodex: { _ in fresh },
            readClaude: {
                let count = liveReads.withLock {
                    $0 += 1
                    return $0
                }
                if count == 1 { throw ClaudeUsageClient.Failure.unsupported }
                return fresh
            },
            readLegacyClaude: {
                let count = cacheReads.withLock {
                    $0 += 1
                    return $0
                }
                if count == 2 { precondition(releaseCache.wait(timeout: .now() + 5) == .success) }
                return old
            }, readClaudeConnectionStatus: { (.configured, true) })
        func wait(for condition: () -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
            precondition(condition(), "A live Claude refresh was lost during a status-line cache read")
        }

        app.networkChanged(available: false)
        app.networkChanged(available: true)
        try await wait { app.makePanel().claudeUsesLegacyReport && !app.display.refreshing }
        app.tick()
        try await wait { cacheReads.withLock { $0 == 2 } }
        app.makePanel().selectProviderSelection(.both)
        precondition(app.display.menuBarTitle == "19%", "A pending live check hid a current Claude reading")
        app.tick()
        releaseCache.signal()
        try await wait { app.display.menuBarTitle == "83%" && !app.display.refreshing }
        precondition(liveReads.withLock { $0 } == 2 && cacheReads.withLock { $0 } == 2)
        print("A provider refresh during a Claude cache read performed one live check and displayed its new balance.")
    }

    static func checkDailyUsageSetting() {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        func launch() -> AppDelegate {
            AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        precondition(launch().makePanel().dailyUsageMode == .tokens)
        defaults.removeObject(forKey: DailyUsageMode.preferenceKey)
        defaults.set(true, forKey: "showTokenSpend")
        let app = launch()
        precondition(app.makePanel().dailyUsageMode == .spend)
        app.makePanel().setShowSpend(false)
        precondition(launch().makePanel().dailyUsageMode == .spend)
        for mode in DailyUsageMode.allCases {
            app.makePanel().setDailyUsageMode(mode)
            precondition(app.makePanel().dailyUsageMode == mode && !app.makePanel().showSpend)
            precondition(launch().makePanel().dailyUsageMode == mode)
        }
        print("Daily usage preserves the previous beta selection and saves all four modes independently of Details.")
    }

    static func checkDailyUsage() {
        func row(_ totals: TokenTotals?, counting: Bool = false, provider: UsageProvider = .codex) -> Dashboard.Summary
        {
            let display = QuotaDisplay(reading: nil, now: Date(), failed: false, refreshing: false, provider: provider)
            return Dashboard.Summary(
                display: display, failure: nil, missingCLI: false, tokens: totals, countingTokens: counting)
        }
        precondition(row(nil, counting: true).dailyUsage(mode: .off) == nil)
        precondition(row(nil, counting: true).dailyUsage(mode: .spend) == "Counting…")
        precondition(row(nil).dailyUsage(mode: .spend) == "Spend unavailable")
        let lifetimeOnly = TokenTotals(
            allTime: 0, month: 0, week: 0, yesterday: 0, today: 0, partial: true,
            hasRetainedUsage: false, claudeStatsLifetime: 500)
        precondition(row(lifetimeOnly).dailyUsage(mode: .tokens) == "Tokens unavailable")
        precondition(row(lifetimeOnly).dailyUsage(mode: .both) == "Usage unavailable")
        var totals = TokenTotals(allTime: 10, month: 10, week: 10, yesterday: 9, today: 1, partial: false)
        precondition(row(totals).dailyUsage(mode: .tokens) == "1 token")
        totals.spend.today.add(nil)
        precondition(row(totals).dailyUsage(mode: .spend) == "Spend unavailable")
        precondition(row(totals).dailyUsage(mode: .both) == "1 token · Spend unavailable")
        totals.spend.today.add(0.003)
        let amount = totals.spend.today.formattedUSD(historyPartial: false)!
        precondition(row(totals).dailyUsage(mode: .spend) == amount)
        precondition(row(totals).dailyUsage(mode: .both) == "1 token · " + amount)
        precondition(row(totals, provider: .claude).dailyUsage(mode: .spend) == amount + " (partial)")
        precondition(row(totals, provider: .claude).dailyUsage(mode: .both) == "1 token · " + amount + " (partial)")
        let incomplete = TokenTotals(allTime: 1, month: 1, week: 1, yesterday: 0, today: 1, partial: true)
        precondition(row(incomplete).dailyUsage(mode: .tokens) == "1 token")
        precondition(row(incomplete).dailyUsage(mode: .both) == "1 token · Spend unavailable")
        precondition(row(incomplete, provider: .claude).dailyUsage(mode: .tokens) == "1 token (partial)")
        let quiet = TokenTotals(allTime: 12, month: 12, week: 12, yesterday: 12, today: 0, partial: false)
        precondition(row(quiet).dailyUsage(mode: .tokens) == "0 tokens")
        let zero = quiet.spend.today.formattedUSD(historyPartial: false)!
        precondition(row(quiet).dailyUsage(mode: .spend) == "≈" + zero)
        precondition(row(quiet).dailyUsage(mode: .both) == "0 tokens · ≈" + zero)
        print("Daily summary distinguishes no history, a quiet day, incomplete pricing and available tokens.")
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
        let alias = root.appendingPathComponent("active")
        for (profile, amount) in [(first, 23), (second, 75), (first, 23)] {
            try files.createSymbolicLink(at: alias, withDestinationURL: profile)
            let report = try ClaudeQuotaSource.read(file: ClaudeQuotaSource.cacheFile(for: alias))
            let totals = try await reader.totals(for: .claude, now: now, claudeProfile: alias)
            precondition(
                report?.windows.first?.used == Double(amount) && totals.allTime == Int64(amount) && !totals.partial)
            precondition(files.fileExists(atPath: ClaudeTokenHistory.cacheFile(for: profile)!.path))
            try files.removeItem(at: alias)
        }
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try files.createSymbolicLink(at: alias, withDestinationURL: first)
        defaults.set("claude", forKey: "providerSelection")
        ClaudeProfile.select(alias, defaults: defaults)
        let app = AppDelegate(
            resetStore: UsageResets(file: root.appendingPathComponent("pending")), defaults: defaults,
            monitorNetwork: false, readCodex: { _ in preconditionFailure("offline fixture") },
            readClaude: { preconditionFailure("offline fixture") },
            readClaudeConnectionStatus: {
                ClaudeProfile.canonicalPath(alias) == ClaudeProfile.canonicalPath(first)
                    ? (.needsUpgrade, true) : (.notConfigured, false)
            })
        app.networkChanged(available: false)
        app.makePanel().refresh()
        func waitForProfile(_ expected: Int64) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(4))
            while (app.makePanel().tokens?.allTime != expected || app.makePanel().countingTokens)
                && ContinuousClock.now < end
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(app.makePanel().tokens?.allTime == expected && !app.makePanel().countingTokens)
        }
        try await waitForProfile(23)
        let statusDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !app.makePanel().canDisconnectClaude && ContinuousClock.now < statusDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(app.makePanel().canDisconnectClaude)
        let offlineMessage = app.makePanel().failure
        precondition(offlineMessage?.hasPrefix("Offline.") == true)
        app.makePanel().selectProviderSelection(.codex)
        precondition(app.makePanel().failure == offlineMessage)
        try files.removeItem(at: alias)
        try files.createSymbolicLink(at: alias, withDestinationURL: second)
        app.makePanel().selectProviderSelection(.claude)
        precondition(app.makePanel().tokens == nil && !app.makePanel().canDisconnectClaude)
        precondition(app.makePanel().claudeSettingsAction == nil)
        precondition(app.makePanel().failure == offlineMessage)
        try await waitForProfile(75)
        print("Switching Claude profiles cleared prior totals and controls and loaded the selected history.")
    }

    static func checkClaudeProfileLinkChangedDuringRefresh() async throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileManager.default
        let root = URL(fileURLWithPath: suite + "-profiles", isDirectory: true)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let active = root.appendingPathComponent("active")
        try files.createDirectory(at: first, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: second, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: active, withDestinationURL: first)
        defaults.set("claude", forKey: "providerSelection")
        ClaudeProfile.select(active, defaults: defaults)
        let entered = OSAllocatedUnfairLock(initialState: 0)
        let gate = DispatchSemaphore(value: 0)
        @Sendable func readingFirstProfile() -> Bool {
            let isFirst = ClaudeProfile.canonicalPath(active) == ClaudeProfile.canonicalPath(first)
            if isFirst {
                entered.withLock { $0 += 1 }
                precondition(gate.wait(timeout: .now() + 5) == .success)
            }
            return isFirst
        }
        let app = AppDelegate(
            resetStore: UsageResets(file: root.appendingPathComponent("pending")), defaults: defaults,
            monitorNetwork: false,
            readClaude: {
                QuotaReading(
                    fetchedAt: Date(),
                    windows: [.init(minutes: 300, remaining: readingFirstProfile() ? 11 : 77, resetsAt: nil)])
            },
            readClaudeConnectionStatus: {
                readingFirstProfile() ? (.needsUpgrade, true) : (.configured, false)
            })
        app.networkChanged(available: false)
        app.networkChanged(available: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while entered.withLock({ $0 }) != 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(entered.withLock { $0 } == 2)
        let next = root.appendingPathComponent("next")
        try files.createSymbolicLink(at: next, withDestinationURL: second)
        precondition(rename(next.path, active.path) == 0)
        gate.signal()
        gate.signal()
        while (app.display.refreshing || app.makePanel().claudeConnectionStatus != .configured)
            && ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(
            app.display.menuBarTitle == "77%" && app.makePanel().claudeConnectionStatus == .configured
                && !app.makePanel().canDisconnectClaude)

        // Two round trips to another profile should defer the next read until the retry deadline.
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var now = Date()
        let unstable = AppDelegate(
            resetStore: UsageResets(file: root.appendingPathComponent("pending")), defaults: defaults,
            monitorNetwork: false, quotaNow: { now },
            readClaude: {
                let count = reads.withLock {
                    $0 += 1
                    return $0
                }
                if count <= 2 {
                    for destination in [first, second] {
                        try FileManager.default.createSymbolicLink(at: next, withDestinationURL: destination)
                        precondition(rename(next.path, active.path) == 0)
                    }
                }
                return QuotaReading(
                    fetchedAt: Date(), windows: [.init(minutes: 300, remaining: count <= 2 ? 11 : 77, resetsAt: nil)])
            }, readClaudeConnectionStatus: { (.notConfigured, false) })
        unstable.networkChanged(available: false)
        unstable.networkChanged(available: true)
        func finish() async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(4))
            while unstable.display.refreshing && ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(!unstable.display.refreshing)
        }
        try await finish()
        precondition(unstable.display.reading == nil && reads.withLock { $0 } == 2)
        precondition(unstable.nextRefreshDate == now.addingTimeInterval(5))
        now = now.addingTimeInterval(5)
        unstable.tick()
        try await finish()
        precondition(unstable.display.menuBarTitle == "77%" && reads.withLock { $0 } == 3)
    }

    static func checkClaudeAuthenticationSwitch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["CFFIXED_USER_HOME"] else {
            fatalError("Run authentication checks with check.sh in an isolated home")
        }
        let standard = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude")
        setenv("CLAUDE_CONFIG_DIR", standard.path, 1)
        defer {
            if let inherited = environment["CLAUDE_CONFIG_DIR"] {
                setenv("CLAUDE_CONFIG_DIR", inherited, 1)
            } else {
                unsetenv("CLAUDE_CONFIG_DIR")
            }
        }

        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude", forKey: "providerSelection")
        let store = UsageResets(file: URL(fileURLWithPath: suite).appendingPathExtension("resets"))

        for selectStandard in [true, false] {
            ClaudeProfile.select(selectStandard ? nil : standard, defaults: defaults)
            precondition(
                ClaudeProfile.childConfigurationDirectory(defaults: defaults) == (selectStandard ? standard.path : nil))
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let releaseSecond = DispatchSemaphore(value: 0)
            let app = AppDelegate(
                resetStore: store, defaults: defaults, monitorNetwork: false,
                readClaude: {
                    let call = reads.withLock {
                        $0 += 1
                        return $0
                    }
                    precondition(call == 1 || call == 2)
                    let release = call == 1 ? releaseFirst : releaseSecond
                    precondition(release.wait(timeout: .now() + 5) == .success)
                    return QuotaReading(
                        fetchedAt: Date(),
                        windows: [.init(minutes: 300, remaining: call == 1 ? 21 : 87, resetsAt: nil)])
                }, readClaudeConnectionStatus: { (.notConfigured, false) })

            func wait(until ready: () -> Bool) async throws {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                precondition(ready(), "The profile switch must start a new Claude read")
            }

            app.networkChanged(available: false)
            app.networkChanged(available: true)
            try await wait { reads.withLock { $0 == 1 } }
            let oldPath = app.makePanel().claudeProfilePath
            if selectStandard {
                app.selectClaudeProfile(standard)
            } else {
                app.makePanel().useDefaultClaudeProfile()
            }
            precondition(app.makePanel().claudeProfilePath == oldPath && oldPath == standard.path)
            precondition(
                ClaudeProfile.childConfigurationDirectory(defaults: defaults) == (selectStandard ? nil : standard.path))
            releaseFirst.signal()
            try await wait { reads.withLock { $0 == 2 } }
            precondition(
                app.display.refreshing && app.display.reading == nil, "An obsolete Claude report became visible")
            releaseSecond.signal()
            try await wait { !app.display.refreshing }
            precondition(app.display.menuBarTitle == "87%")
        }
        print("Changing Claude authentication at the same folder discarded in-flight reads in both directions.")
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

    static func checkOverlappingConnectionChecks() async throws {
        let domain = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("claude", forKey: "providerSelection")
        let count = OSAllocatedUnfairLock(initialState: 0)
        let firstRead = DispatchSemaphore(value: 0)
        let secondRead = DispatchSemaphore(value: 0)
        let app = AppDelegate(
            resetStore: UsageResets(file: URL(fileURLWithPath: domain + ".json")),
            defaults: defaults, monitorNetwork: false,
            readClaudeConnectionStatus: {
                let index = count.withLock {
                    $0 += 1
                    return $0
                }
                if index == 1 {
                    precondition(firstRead.wait(timeout: .now() + 5) == .success)
                    return (.configured, true)
                }
                if index == 2 { precondition(secondRead.wait(timeout: .now() + 5) == .success) }
                return (.needsUpgrade, true)
            })
        app.networkChanged(available: false)
        app.makePanel().refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(count.withLock { $0 } == 1)
        for _ in 0..<24 { app.makePanel().refresh() }
        firstRead.signal()
        while count.withLock({ $0 }) < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(app.makePanel().claudeConnectionStatus == .notConfigured && !app.makePanel().canDisconnectClaude)
        secondRead.signal()
        while app.makePanel().claudeConnectionStatus != .needsUpgrade && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(app.makePanel().canDisconnectClaude && count.withLock { $0 } == 2)
        print("Overlapping offline refreshes used one Claude connection check and one follow-up.")
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

        func finishRead(_ app: AppDelegate, failed: () -> Bool = { false }) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while app.display.refreshing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(!app.display.refreshing && app.display.failed == failed())
        }

        let cases: [(relaunch: Int, polls: [Int], slept: Bool, failures: Set<Int>, error: QuotaError)] = [
            (14, [29, 44, 59], false, [], .timedOut), (29, [44, 59], false, [], .timedOut),
            (44, [59], false, [], .timedOut), (44, [], true, [], .timedOut),
            (14, [29, 44, 59], false, [29], .timedOut),
            (14, [29, 44, 59], false, [29, 44, 59], .transportFailed),
            (14, [29], false, [29], .signInRequired),
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
                        if scenario.failures.contains(age) { throw scenario.error }
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
                try await finishRead(app) {
                    fixture.withLock { $0.readAges.last.map(scenario.failures.contains) == true }
                }
            }
            let readAges = fixture.withLock { $0.readAges }
            precondition(readAges == [0, scenario.relaunch] + scenario.polls, "Unexpected Codex reads: \(readAges)")
            precondition(app.nextRefreshDate == nil && app.makePanel().resetBalanceUnconfirmed)
            precondition(!app.makePanel().canUseReset)
            print("Codex relaunch at +\(scenario.relaunch)s, slept=\(scenario.slept), observed read ages \(readAges).")
        }
    }

    static func checkResetNoticeOnSignOut() async throws {
        for error in [QuotaError.signInRequired, .subscriptionRequired, .transportFailed] {
            let suite = testPreferencesDomain()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("codex", forKey: "providerSelection")
            defaults.set(["first-user"], forKey: "restrictedCodexAccounts")
            let store = UsageResets(file: URL(fileURLWithPath: suite + ".reset"))
            let failure = OSAllocatedUnfairLock<QuotaError?>(initialState: nil)
            let app = AppDelegate(
                resetStore: store, defaults: defaults, monitorNetwork: false,
                readCodex: { _ in
                    if let error = failure.withLock({ $0 }) { throw error }
                    return QuotaReading(
                        fetchedAt: Date(), windows: [.init(minutes: 300, remaining: 31, resetsAt: nil)],
                        resetCredits: .init(availableCount: 2), resetCountOnlyFingerprint: "first-user")
                })
            func settle() async throws {
                let end = ContinuousClock.now.advanced(by: .seconds(4))
                while app.display.refreshing, ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(5))
                }
                precondition(!app.display.refreshing)
            }
            app.networkChanged(available: false)
            app.networkChanged(available: true)
            try await settle()
            precondition(app.display.restrictionMessage != nil)
            store.prepare(app.display)
            precondition(store.begin(app.display) != nil)
            failure.withLock { $0 = error }
            app.finishReset(.nothingToReset)
            try await settle()
            let panel = app.makePanel()
            let sameAccountMayRemain = error == .transportFailed
            precondition((panel.resetNotice != nil) == sameAccountMayRemain)
            precondition((panel.display.reading != nil) == sameAccountMayRemain)
            precondition(
                !panel.canUseReset && !panel.display.hasCurrentPercentage && panel.display.restrictionMessage == nil)
            precondition(defaults.stringArray(forKey: "restrictedCodexAccounts") == ["first-user"])
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

    /// Which providers appear and whether logos appear are separate choices, including percentages only for both.
    static func checkMenuBarLayoutSetting() {
        for both in [false, true] {
            for logos in [false, true] {
                let layout = MenuBarLayout(showsBoth: both, showsLogos: logos)
                precondition(layout.showsBoth == both && layout.showsLogos == logos)
                precondition(layout.showing(both: !both) == MenuBarLayout(showsBoth: !both, showsLogos: logos))
                precondition(layout.showing(logos: !logos) == MenuBarLayout(showsBoth: both, showsLogos: !logos))
            }
        }
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: suite).appendingPathExtension("resets")
        func launch() -> AppDelegate {
            AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        defaults.set("both", forKey: "providerSelection")
        defaults.set("both", forKey: "menuBarLayout")
        let app = launch()
        app.makePanel().selectLayout(.bothPercentage)
        precondition(app.menuLayout == .bothPercentage && defaults.string(forKey: "menuBarLayout") == "bothPercentage")
        let restored = launch().menuLayout
        precondition(restored.showsBoth && !restored.showsLogos, "Both providers without logos must survive relaunch.")

        // A single provider cannot show both, and keeps the logo choice when the saved layout showed both.
        defaults.set("claude", forKey: "providerSelection")
        let single = launch()
        precondition(single.menuLayout == .percentage)
        single.makePanel().selectLayout(.bothPercentage)
        precondition(single.menuLayout == .percentage)
        precondition(defaults.string(forKey: "menuBarLayout") == "bothPercentage", "A rejected choice must not save.")
        defaults.set("both", forKey: "menuBarLayout")
        precondition(launch().menuLayout == .logo)
        print("Menu bar layout: provider count and logos are independent; both providers can show percentages only.")
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
            store.received(reading, generation: store.readGeneration())
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
