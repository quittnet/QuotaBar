import AppKit
import Foundation

private final class Readings: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduledReading = DispatchSemaphore(value: 0)
    private var calls: [TimeInterval] = []
    private var claudeCalls = 0

    var times: [TimeInterval] { lock.withLock { calls } }
    var claudeCount: Int { lock.withLock { claudeCalls } }

    func codex() throws -> QuotaReading {
        let count = lock.withLock {
            calls.append(ProcessInfo.processInfo.systemUptime)
            return calls.count
        }
        if count == 3 { precondition(scheduledReading.wait(timeout: .now() + 12) == .success) }
        if count == 4 { throw URLError(.notConnectedToInternet) }
        if count == 9 {
            Thread.sleep(forTimeInterval: 0.8)
            throw URLError(.notConnectedToInternet)
        }
        return Self.reading(
            count <= 2 ? 80 : (count == 3 ? 60 : 55),
            allowed: count == 6 ? false : (count == 8 ? true : nil),
            resetsIn: count == 8 ? 2 : 3600, age: count == 2 ? 30 : 0)

    }

    func releaseScheduledReading() { scheduledReading.signal() }

    func claude() -> QuotaReading {
        let count = lock.withLock {
            claudeCalls += 1
            return claudeCalls
        }
        return Self.reading(count >= 3 ? 25 : 40)
    }

    private static func reading(
        _ remaining: Double, allowed: Bool? = nil, resetsIn: TimeInterval = 3600, age: TimeInterval = 0
    ) -> QuotaReading {
        QuotaReading(
            fetchedAt: Date().addingTimeInterval(-age),
            windows: [
                QuotaWindow(minutes: 300, remaining: remaining, resetsAt: Date().addingTimeInterval(resetsIn))
            ], resetAccountFingerprint: "fixture-account", resetCountOnlyFingerprint: "fixture-user",
            ordinaryUsageAllowed: allowed)
    }
}

@main
enum RefreshChecks {
    @MainActor static func main() throws {
        checkAccountSwitches()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let session = root.appendingPathComponent("codex/sessions/rollout-refresh.jsonl")
        let files = FileManager.default
        try files.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("claude/projects"), withIntermediateDirectories: true)
        try checkOverlappingHistoryRefreshes(session: session)
        let metadata = #"{"type":"session_meta","payload":{"id":"refresh"}}"# + "\n"
        try (metadata + record("first", count: 11)).write(to: session, atomically: true, encoding: .utf8)

        let suite = testPreferencesDomain()
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("both", forKey: "menuBarLayout")
        let fixture = Readings()
        var clockOffset: TimeInterval = 0
        let controller = AppDelegate(
            resetStore: UsageResets(file: root.appendingPathComponent("pending.json")), defaults: preferences,
            monitorNetwork: false, quotaNow: { Date().addingTimeInterval(clockOffset) },
            readCodex: { _ in try fixture.codex() }, readClaude: { fixture.claude() },
            redeem: { _ in preconditionFailure("Unexpected reset") }
        )
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        let deadline = Date().addingTimeInterval(220)
        var stage = 0
        var scheduledImage: NSImage?
        var observedStaticAt: TimeInterval?
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                precondition(Date() < deadline, "Timed out at stage \(stage)")
                guard let button = controller.item?.button, let label = button.accessibilityLabel() else { return }
                precondition(!controller.dropdown.isVisible)
                switch stage {
                case 0:
                    if fixture.times.count == 1 {
                        guard ProcessInfo.processInfo.systemUptime - fixture.times[0] >= 12 else { return }
                        controller.dashboard.rootView.refresh()
                        return
                    }
                    guard fixture.times.count == 2, fixture.claudeCount == 2,
                        label.contains("80% remaining"), label.contains("40% remaining"),
                        controller.tokenTotals?.allTime == 11
                    else { return }
                    do {
                        let writer = try FileHandle(forWritingTo: session)
                        defer { try? writer.close() }
                        try writer.seekToEnd()
                        try writer.write(contentsOf: Data(record("second", count: 12).utf8))
                    } catch { preconditionFailure(error.localizedDescription) }
                    stage = 1
                case 1:
                    let sinceManual = ProcessInfo.processInfo.systemUptime - fixture.times[1]
                    if sinceManual < 175 {
                        precondition(
                            fixture.claudeCount == 2, "The display timer must not poll live Claude every 30 seconds")
                    } else {
                        precondition(fixture.claudeCount <= 3, "A scheduled refresh must query Claude only once")
                    }
                    if label.contains("Checking Codex limits"), label.contains("25% remaining"),
                        let image = button.image
                    {
                        let uptime = ProcessInfo.processInfo.systemUptime
                        if let observedStaticAt {
                            precondition(scheduledImage === image, "A closed scheduled check should show static dots")
                            if uptime - observedStaticAt >= 1 {
                                fixture.releaseScheduledReading()
                                stage = 10
                            }
                        } else {
                            scheduledImage = image
                            observedStaticAt = uptime
                        }
                    }
                case 10:
                    guard fixture.times.count == 3, fixture.claudeCount == 3, label.contains("60% remaining"),
                        controller.tokenTotals?.allTime == 23
                    else { return }
                    let delta = fixture.times[2] - fixture.times[1]
                    precondition((175...195).contains(delta), "Unexpected quota refresh interval \(delta)")
                    print(
                        String(
                            format:
                                "Automatic refresh %.2f seconds after manual refresh, past the cancelled launch deadline.",
                            delta))
                    precondition(fixture.claudeCount == 3, "The three-minute timer must refresh both providers")
                    print("A closed scheduled read kept the same loading image until its verified result arrived.")
                    print("Claude stayed idle between scheduled checks and refreshed at the three-minute deadline.")
                    stage = 2
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                case 2:
                    guard label.contains("Current Codex limits unavailable"), !label.contains("60% remaining"),
                        label.contains("25% remaining")
                    else {
                        return
                    }
                    stage = 3
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                case 3:
                    guard label.contains("55% remaining"), fixture.times.count == 5 else { return }
                    stage = 4
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                case 4:
                    guard label.contains("Codex reports a usage restriction"), !label.contains("55% remaining") else {
                        return
                    }
                    stage = 5
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                case 5:
                    guard label.contains("hasn’t confirmed"), !label.contains("55% remaining") else { return }
                    stage = 6
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                case 6:
                    guard label.contains("55% remaining"), fixture.times.count == 8 else { return }
                    stage = 7
                case 7:
                    guard fixture.times.count == 9, label.contains("Checking Codex limits"),
                        !label.contains("55% remaining")
                    else { return }
                    stage = 8
                case 8:
                    guard label.contains("Current Codex limits unavailable") else { return }
                    stage = 9
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                default:
                    guard label.contains("55% remaining"), fixture.times.count == 10 else { return }
                    print(
                        "Explicit restriction, unknown permission, confirmed recovery, and exact reset expiry passed.")
                    print("Closed-panel token updates, both providers, offline handling, and wake refresh passed.")
                    clockOffset = 6 * 3600
                    controller.dashboard.rootView.refresh()
                    clockOffset = 0
                    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
                    let delay = controller.nextRefreshDate?.timeIntervalSinceNow ?? .infinity
                    precondition(
                        abs(delay - QuotaDisplay.refreshInterval) < 2, "Clock rollback stranded the next refresh")
                    print("A six-hour clock correction restarted the three-minute countdown.")
                    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                    app.terminate(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(controller) { app.run() }
    }

    @MainActor private static func checkOverlappingHistoryRefreshes(session: URL) throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "providerSelection")
        let app = AppDelegate(
            resetStore: UsageResets(file: URL(fileURLWithPath: suite).appendingPathExtension("resets")),
            defaults: defaults, monitorNetwork: false,
            readCodex: { _ in preconditionFailure("Offline refresh must only read local history") })
        defer { app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        app.networkChanged(available: false)
        let metadata = #"{"type":"session_meta","payload":{"id":"refresh"}}"# + "\n"
        try metadata.write(to: session, atomically: true, encoding: .utf8)
        app.makePanel().refresh()
        // Keep the first scan outstanding and record a new response after its cutoff.
        Thread.sleep(forTimeInterval: 0.02)
        let entry = record("between-refreshes", count: 37, at: Date().addingTimeInterval(-0.005))
        try (metadata + entry).write(to: session, atomically: true, encoding: .utf8)
        precondition(app.makePanel().canRefresh)
        app.makePanel().refresh()
        let deadline = Date().addingTimeInterval(10)
        while app.makePanel().countingTokens && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(app.makePanel().tokens?.today == 37, "The second refresh must include the newer response")
        print("An offline refresh requested during a history scan included the response between requests.")
    }

    private static func record(_ id: String, count: Int, at timestamp: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.string(from: timestamp)
        return
            #"{"timestamp":"\#(date)","type":"token_usage_record","payload":{"thread_id":"refresh","response_id":"\#(id)","usage":{"total_tokens":\#(count)}}}"#
            + "\n"
    }

    @MainActor private static func checkAccountSwitches() {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppDelegate(defaults: defaults)
        func needsConfirmation(_ user: String?, _ allowed: Bool?) -> Bool {
            controller.restrictionNeedsConfirmation(
                QuotaReading(
                    fetchedAt: Date(), windows: [], resetAccountFingerprint: "shared-workspace",
                    resetCountOnlyFingerprint: user, ordinaryUsageAllowed: allowed))
        }
        _ = needsConfirmation("first-user", false)
        _ = needsConfirmation("second-user", true)
        precondition(needsConfirmation("first-user", nil) && !needsConfirmation("second-user", nil))
        _ = needsConfirmation("first-user", true)
        precondition(!needsConfirmation("first-user", nil))
        _ = needsConfirmation(nil, false)
        _ = needsConfirmation("second-user", true)
        precondition(needsConfirmation(nil, nil) && needsConfirmation("first-user", nil))
        precondition(!needsConfirmation("second-user", nil))
    }
}
