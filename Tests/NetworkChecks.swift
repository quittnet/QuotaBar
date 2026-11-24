import AppKit
import Foundation

private final class NetworkReadings: @unchecked Sendable {
    private let lock = NSLock()
    private let finishOldReading = DispatchSemaphore(value: 0)
    private var calls = 0
    private var finishedOld = false
    private let delayFirstFailure: Bool

    init(delayFirstFailure: Bool = false) { self.delayFirstFailure = delayFirstFailure }

    var count: Int { lock.withLock { calls } }
    var oldFinished: Bool { lock.withLock { finishedOld } }

    func codex() throws -> QuotaReading {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 {
            if delayFirstFailure { precondition(finishOldReading.wait(timeout: .now() + 10) == .success) }
            throw URLError(.notConnectedToInternet)
        }
        if call == 2 || call == 4 || call == 6 {
            precondition(finishOldReading.wait(timeout: .now() + 10) == .success)
            lock.withLock { finishedOld = true }
        }
        let values = [2: 80.0, 3: 60.0, 4: 99.0, 5: 35.0, 6: 99.0, 7: 25.0]
        guard let remaining = values[call] else { preconditionFailure("Unexpected Codex read \(call)") }
        return QuotaReading(
            fetchedAt: Date(),
            windows: [QuotaWindow(minutes: 300, remaining: remaining, resetsAt: Date().addingTimeInterval(3600))])
    }

    func releaseOldReading() { finishOldReading.signal() }
}

private final class TransientReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    func read() throws -> QuotaReading {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call % 2 == 1 { throw URLError(.timedOut) }
        return QuotaReading(
            fetchedAt: Date(),
            windows: [QuotaWindow(minutes: 300, remaining: 70, resetsAt: Date().addingTimeInterval(3600))])
    }
}

private final class ClaudeNetworkReadings: @unchecked Sendable {
    private let lock = NSLock()
    private let finishOldReading = DispatchSemaphore(value: 0)
    private var calls = 0
    private var finishedOld = false
    var count: Int { lock.withLock { calls } }
    var oldFinished: Bool { lock.withLock { finishedOld } }

    func read() throws -> QuotaReading {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { precondition(finishOldReading.wait(timeout: .now() + 10) == .success) }
        if call == 3 {
            precondition(finishOldReading.wait(timeout: .now() + 10) == .success)
            lock.withLock { finishedOld = true }
        }
        if call == 6 || call == 7 {
            let used = call == 6 ? "null" : "17"
            let report =
                #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":\#(used)}}}"#
            return try ClaudeUsageClient.parse(Data(report.utf8), now: Date())
        }
        let remaining = [1: 64.0, 2: 54.0, 3: 99.0, 4: 44.0, 5: 34.0][call]
        guard let remaining else { preconditionFailure("Unexpected Claude read") }
        return Self.reading(remaining)
    }

    func releaseOldReading() { finishOldReading.signal() }

    static func reading(_ remaining: Double) -> QuotaReading {
        QuotaReading(
            fetchedAt: Date(),
            windows: [QuotaWindow(minutes: 300, remaining: remaining, resetsAt: Date().addingTimeInterval(3600))])
    }
}

@main
enum NetworkChecks {
    @MainActor private static func dotAlphas(_ button: NSStatusBarButton) -> [CGFloat] {
        let text = button.attributedTitle
        return (0..<text.length).map { index in
            (text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1
        }
    }

    @MainActor static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = testPreferencesDomain()
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("codex", forKey: "selectedProvider")
        preferences.set("codex", forKey: "providerSelection")
        preferences.set("percentage", forKey: "menuBarLayout")
        let readings = NetworkReadings(delayFirstFailure: true)
        let disabledClaude = ClaudeNetworkReadings()
        let controller = AppDelegate(
            resetStore: UsageResets(file: root.appendingPathComponent("pending.json")), defaults: preferences,
            monitorNetwork: false, readCodex: { _ in try readings.codex() }, readClaude: { try disabledClaude.read() },
            redeem: { _ in preconditionFailure("Unexpected reset") })
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        let deadline = Date().addingTimeInterval(45)
        var stage = -2
        var animationStarted = Date.distantPast
        var initialAnimation: [CGFloat] = []
        var loadingWidth: CGFloat = 0
        var offlineAt = Date.distantPast
        let launchRace = NetworkReadings(delayFirstFailure: true)
        var raceController: AppDelegate?
        let transient = TransientReadings()
        var retryController: AppDelegate?
        var failedAt = Date.distantPast
        let claudeReadings = ClaudeNetworkReadings()
        var claudeController: AppDelegate?
        var pairedFrames: [NSImage] = []
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let preferences = UserDefaults(suiteName: suite)!
                precondition(Date() < deadline, "Network check timed out at stage \(stage)")
                guard let button = controller.item?.button, let label = button.accessibilityLabel() else { return }
                precondition(!controller.dropdown.isVisible)
                precondition(disabledClaude.count == 0, "A disabled provider must never be queried")
                switch stage {
                case -2:
                    guard readings.count == 1 else { return }
                    precondition(button.title == "···" && label.contains("Checking Codex limits"))
                    initialAnimation = dotAlphas(button)
                    loadingWidth = button.frame.width
                    animationStarted = Date()
                    stage = -1
                case -1:
                    guard Date().timeIntervalSince(animationStarted) >= 0.7 else { return }
                    precondition(button.title == "···")
                    precondition(abs(button.frame.width - loadingWidth) < 0.01)
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        precondition(dotAlphas(button) != initialAnimation)
                    }
                    readings.releaseOldReading()
                    stage = 0
                case 0:
                    guard readings.count == 1, label.contains("Current Codex limits unavailable") else { return }
                    precondition(button.title == "–%")
                    controller.networkChanged(available: false)
                    controller.networkChanged(available: true)
                    precondition(button.title == "···")
                    initialAnimation = dotAlphas(button)
                    loadingWidth = button.frame.width
                    animationStarted = Date()
                    stage = 1
                case 1:
                    guard readings.count == 2, Date().timeIntervalSince(animationStarted) >= 0.7 else { return }
                    precondition(button.title == "···" && label.contains("Checking Codex limits"))
                    precondition(abs(button.frame.width - loadingWidth) < 0.01)
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        precondition(dotAlphas(button) != initialAnimation)
                    }
                    readings.releaseOldReading()
                    stage = 10
                case 10:
                    guard readings.count == 2, label.contains("80% remaining") else { return }
                    precondition(button.title == "80%")
                    controller.networkChanged(available: true)
                    precondition(
                        button.title == "···", "A network switch must show loading while it fetches a fresh reading")
                    stage = 2
                case 2:
                    guard readings.count == 3, label.contains("60% remaining") else { return }
                    controller.networkChanged(available: true)
                    stage = 3
                case 3:
                    guard readings.count == 4 else { return }
                    controller.networkChanged(available: false)
                    precondition(button.title == "–%")
                    initialAnimation = dotAlphas(button)
                    readings.releaseOldReading()
                    offlineAt = Date()
                    stage = 4
                case 4:
                    guard readings.oldFinished, Date().timeIntervalSince(offlineAt) >= 0.5 else { return }
                    precondition(readings.count == 4, "Disconnected state must not restart an obsolete read")
                    precondition(button.title == "–%" && !label.contains("99% remaining"))
                    precondition(dotAlphas(button) == initialAnimation)
                    controller.networkChanged(available: true)
                    stage = 5
                case 5:
                    guard readings.count == 5, label.contains("35% remaining") else { return }
                    controller.networkChanged(available: true)
                    stage = 6
                case 6:
                    guard readings.count == 6 else { return }
                    controller.networkChanged(available: false)
                    controller.networkChanged(available: true)
                    readings.releaseOldReading()
                    stage = 7
                case 7:
                    precondition(!label.contains("99% remaining"))
                    guard readings.count == 7, label.contains("25% remaining") else { return }
                    print("Startup and reconnect animated three dots at a fixed width until the read completed.")
                    print("Startup attempted a quota read and showed unavailable after an offline failure.")
                    print(
                        "Reconnect and same-interface network changes refreshed immediately with the dropdown closed.")
                    print(
                        "An old-network response was discarded while offline, and reconnection recovered a fresh percentage."
                    )
                    controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    NSStatusBar.system.removeStatusItem(controller.item)
                    let next = AppDelegate(
                        resetStore: UsageResets(file: root.appendingPathComponent("pending-race.json")),
                        defaults: preferences, monitorNetwork: false,
                        readCodex: { _ in try launchRace.codex() }, readClaude: { nil },
                        redeem: { _ in preconditionFailure("Unexpected reset") })
                    raceController = next
                    next.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                    stage = 8
                case 8:
                    guard launchRace.count == 1, let next = raceController else { return }
                    precondition(next.item.button?.title == "···")
                    next.networkChanged(available: true)
                    launchRace.releaseOldReading()
                    launchRace.releaseOldReading()
                    stage = 9
                case 9:
                    guard let next = raceController, launchRace.count == 2,
                        next.item.button?.accessibilityLabel()?.contains("80% remaining") == true
                    else { return }
                    print(
                        "A reconnect during an in-flight read discarded its response and fetched from the new connection."
                    )
                    print("An initial connected notification racing a failed startup read retried immediately.")
                    next.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    NSStatusBar.system.removeStatusItem(next.item)
                    let retry = AppDelegate(
                        resetStore: UsageResets(file: root.appendingPathComponent("pending-retry.json")),
                        defaults: preferences, monitorNetwork: false,
                        readCodex: { _ in try transient.read() }, readClaude: { nil },
                        redeem: { _ in preconditionFailure("Unexpected reset") })
                    retryController = retry
                    retry.applicationDidFinishLaunching(
                        Notification(name: NSApplication.didFinishLaunchingNotification))
                    failedAt = Date()
                    stage = 11
                case 11:
                    guard let retry = retryController, let title = retry.item.button?.title else { return }
                    if transient.count == 1 {
                        precondition(title == "–%" || title == "···")
                        precondition(Date().timeIntervalSince(failedAt) < 7)
                        return
                    }
                    guard title == "70%" else { return }
                    precondition(transient.count == 2)
                    let elapsed = Date().timeIntervalSince(failedAt)
                    precondition(elapsed >= 4.9 && elapsed < 7, "The initial recovery should retry after five seconds.")
                    retry.dashboard.rootView.refresh()
                    stage = 12
                case 12:
                    guard transient.count == 3, let retry = retryController, retry.item.button?.title == "–%" else {
                        return
                    }
                    failedAt = Date()
                    stage = 13
                case 13:
                    guard let retry = retryController else { preconditionFailure("Missing retry controller") }
                    if transient.count == 3 {
                        precondition(retry.item.button?.title == "–%")
                        precondition(Date().timeIntervalSince(failedAt) < 7)
                        return
                    }
                    guard retry.item.button?.title == "70%" else { return }
                    precondition(transient.count == 4 && Date().timeIntervalSince(failedAt) < 7)
                    print("Transient failures retried automatically after five seconds with the panel closed.")
                    print(
                        "A verified success reset backoff, and a later failure hid the prior percentage until recovery."
                    )
                    retry.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    NSStatusBar.system.removeStatusItem(retry.item)
                    preferences.set("both", forKey: "providerSelection")
                    preferences.set("both", forKey: "menuBarLayout")
                    let claude = AppDelegate(
                        resetStore: UsageResets(file: root.appendingPathComponent("pending-claude.json")),
                        defaults: preferences, monitorNetwork: false,
                        readCodex: { _ in ClaudeNetworkReadings.reading(75) },
                        readClaude: { try claudeReadings.read() },
                        redeem: { _ in preconditionFailure("Unexpected reset") })
                    claudeController = claude
                    claude.applicationDidFinishLaunching(
                        Notification(name: NSApplication.didFinishLaunchingNotification))
                    // Pin the fixture's appearance before the asynchronous Codex result sets the stable title.
                    claude.item.button?.appearance = NSAppearance(named: .aqua)
                    stage = 22
                case 22:
                    guard let button = claudeController?.item.button, let image = button.image,
                        button.accessibilityLabel()?.contains("75% remaining") == true
                    else { return }
                    if pairedFrames.isEmpty { animationStarted = Date() }
                    if !pairedFrames.contains(where: { $0 === image }) { pairedFrames.append(image) }
                    precondition(pairedFrames.count <= 3, "A stable loading badge should reuse its three frames")
                    guard Date().timeIntervalSince(animationStarted) >= 1.8 else { return }
                    let expectedFrames = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 3
                    precondition(pairedFrames.count == expectedFrames)
                    claudeReadings.releaseOldReading()
                    stage = 14
                case 14:
                    guard let claude = claudeController,
                        claude.item.button?.accessibilityLabel()?.contains("64% remaining") == true
                    else { return }
                    precondition(claudeReadings.count == 1, "Enabled Claude must refresh at launch")
                    precondition(!pairedFrames.contains(where: { $0 === claude.item.button?.image }))
                    claude.dashboard.rootView.refresh()
                    stage = 15
                case 15:
                    guard let claude = claudeController,
                        claude.item.button?.accessibilityLabel()?.contains("54% remaining") == true
                    else { return }
                    precondition(claudeReadings.count == 2, "Manual refresh must query enabled Claude")
                    claude.networkChanged(available: true)
                    claude.networkChanged(available: true)
                    stage = 16
                case 16:
                    guard let claude = claudeController, claudeReadings.count == 3 else { return }
                    claude.networkChanged(available: false)
                    claudeReadings.releaseOldReading()
                    offlineAt = Date()
                    stage = 17
                case 17:
                    guard let claude = claudeController, claudeReadings.oldFinished,
                        Date().timeIntervalSince(offlineAt) > 0.5
                    else { return }
                    precondition(claudeReadings.count == 3, "Claude must remain idle while offline")
                    precondition(claude.item.button?.accessibilityLabel()?.contains("99% remaining") == false)
                    claude.networkChanged(available: true)
                    stage = 18
                case 18:
                    guard let claude = claudeController,
                        claude.item.button?.accessibilityLabel()?.contains("44% remaining") == true
                    else { return }
                    precondition(claudeReadings.count == 4, "Reconnect must fetch a current Claude reading")
                    claude.networkChanged(available: true)
                    stage = 19
                case 19:
                    guard let claude = claudeController,
                        claude.item.button?.accessibilityLabel()?.contains("34% remaining") == true
                    else { return }
                    precondition(claudeReadings.count == 5, "A network switch must refresh enabled Claude")
                    print(
                        "Claude refreshed at launch, manual refresh, reconnect and network switch; disabled Claude stayed idle."
                    )
                    print("An obsolete Claude response was discarded while offline.")
                    claude.dashboard.rootView.refresh()
                    stage = 20
                case 20:
                    guard let claude = claudeController, let label = claude.item.button?.accessibilityLabel(),
                        label.contains("Current Claude limits unavailable")
                    else { return }
                    precondition(!label.contains("34% remaining") && label.contains("75% remaining"))
                    claude.dashboard.rootView.refresh()
                    stage = 21
                default:
                    guard let claude = claudeController, let label = claude.item.button?.accessibilityLabel(),
                        label.contains("5-hour limit, 100% remaining")
                    else { return }
                    let windows = claude.makePanel().summaries.first { $0.display.provider == .claude }?.display
                        .windows
                    precondition(windows?.first { $0.minutes == 10_080 }?.remaining == 83)
                    precondition(claudeReadings.count == 7 && label.contains("75% remaining"))
                    print("An invalid Claude percentage was hidden, and an undated fresh report restored the badge.")
                    claude.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    NSStatusBar.system.removeStatusItem(claude.item)
                    preferences.removePersistentDomain(forName: suite)
                    app.terminate(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(controller) { app.run() }
    }
}
