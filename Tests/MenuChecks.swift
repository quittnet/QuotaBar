import AppKit
import Foundation
import SwiftUI

private final class MockRedemption: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func submit(_ attempt: ResetAttempt) -> QuotaResetClaimResult {
        lock.withLock { calls += 1 }
        return .reset
    }
}

private final class ClaudeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: QuotaReading?
    func get() -> QuotaReading? { lock.withLock { reading } }
    func clear() {
        lock.withLock { reading = nil }
    }

    func populate() {
        let now = Date()
        lock.withLock {
            reading = QuotaReading(
                fetchedAt: now,
                windows: [
                    QuotaWindow(minutes: 300, remaining: 84, resetsAt: now.addingTimeInterval(7200)),
                    QuotaWindow(minutes: 10080, remaining: 52, resetsAt: now.addingTimeInterval(86400)),
                ])
        }
    }
}

// Run in a logged-in macOS session. Only this temporary test app's own views are inspected.
@main
enum MenuChecks {
    private enum Step {
        case startingCombined
        case checkingCombinedEmpty
        case checkingUnavailableClick
        case checkingUnavailableSecondaryClick
        case checkingPostedCodexClick
        case checkingCombinedUpdated
        case checkingBothDetails
        case checkingBothClaudeDetails
        case checkingCombinedPrimaryOpened(QuotaDisplay)
        case checkingCombinedUsed(QuotaDisplay)
        case checkingCombinedPrimaryClosed(QuotaDisplay)
        case checkingCombinedRemainingClosed(QuotaDisplay)
        case checkingPostedClaudeClick
        case waitingForLogo
        case checkingLogoPercentageClosed(QuotaDisplay)
        case checkingLogoUsedClosed(QuotaDisplay)
        case checkingPercentagePrimaryOpened(QuotaDisplay)
        case checkingPercentageSecondaryUsed(QuotaDisplay)
        case checkingPercentageControlRemaining(QuotaDisplay)
        case checkingPercentageSecondaryClosed(QuotaDisplay)
        case waitingForModeFeedbackExpiry(QuotaDisplay, Date)
        case opening
        case waitingForClaude
        case checkingClaudeQuota
        case inspecting
        case checkingDetailsClick(NSRect)
        case checkingConfirmationFrame(NSRect)
        case waitingForRefresh(Date)
        case waitingForMock
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "QuotaBar-check-" + UUID().uuidString)
        let mock = MockRedemption()
        let claude = ClaudeFixture()
        let suite = "QuotaBar-menu-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let useFixtures = ProcessInfo.processInfo.environment["QUOTABAR_TEST_FIXTURES"] == "1"
        defer { preferences.removePersistentDomain(forName: suite) }
        // Launch with Claude selected so the initial Codex reading must load in the background.
        preferences.set(UsageProvider.claude.rawValue, forKey: "selectedProvider")
        let controller = AppDelegate(
            resetStore: UsageResets(file: scratch.appendingPathComponent("pending.json")),
            defaults: preferences,
            monitorNetwork: false,
            readCodex: { includeCountOnlyIdentity in
                guard useFixtures else {
                    return try QuotaSource.read(includeCountOnlyIdentity: includeCountOnlyIdentity)
                }
                let now = Date()
                return QuotaReading(
                    fetchedAt: now,
                    windows: [
                        QuotaWindow(minutes: 300, remaining: 72, resetsAt: now.addingTimeInterval(7200)),
                        QuotaWindow(minutes: 10080, remaining: 46, resetsAt: now.addingTimeInterval(86400)),
                    ],
                    resetCredits: .init(availableCount: 1), resetCountOnlyFingerprint: "test-account")
            }, readClaude: { claude.get() },
            redeem: { mock.submit($0) })
        let initialLayout: MenuBarLayout = UsageProvider.detected().count > 1 ? .both : .percentage
        precondition(controller.menuLayout == initialLayout)
        precondition(controller.percentageMode == .remaining)
        precondition(!controller.detailsExpanded)
        preferences.set(["details"], forKey: "expandedDashboardSections")
        precondition(AppDelegate(defaults: preferences).detailsExpanded)
        preferences.set(["resets", "tokens"], forKey: "expandedDashboardSections")
        precondition(!AppDelegate(defaults: preferences).detailsExpanded)
        preferences.removeObject(forKey: "expandedDashboardSections")
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        let deadline = Date().addingTimeInterval(300)
        var step = Step.startingCombined
        var checkedBothDetails = false
        _ = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let preferences = UserDefaults(suiteName: suite)!
                if Date() > deadline {
                    fputs("The live dropdown check timed out while \(step).\n", stderr)
                    exit(1)
                }
                guard let item = controller.item, let button = item.button else { return }
                if case .startingCombined = step {
                    precondition(controller.provider == .claude)
                    if initialLayout == .percentage {
                        precondition(button.image == nil && button.title == "–%")
                        button.performClick(nil)
                        precondition(controller.dropdown.isVisible)
                        controller.dashboard.rootView.selectLayout(.both)
                        precondition(controller.dropdown.isVisible)
                        button.performClick(nil)
                    }
                    precondition(controller.menuLayout == .both && !controller.dropdown.isVisible)
                    step = .checkingCombinedEmpty
                    return
                }
                if case .checkingCombinedEmpty = step {
                    let label = checkCombinedButton(item, button: button)
                    guard label.contains("Codex ·"), label.contains("Current Claude limits unavailable") else { return }
                    precondition(controller.provider == .claude && !controller.dropdown.isVisible)
                    let point = combinedPoint(.claude, in: button, percentage: true, title: "–%")
                    postStatusClick(at: point, button: button, app: app)
                    step = .checkingUnavailableClick
                    return
                }
                if case .checkingUnavailableClick = step {
                    precondition(controller.provider == .claude)
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.display.provider == .claude,
                        "Expected open Claude panel, visible=\(controller.dropdown.isVisible), button=\(String(describing: button.window?.frame)), screen=\(String(describing: button.window?.screen?.frame))"
                    )
                    precondition(controller.percentageMode == .remaining)
                    controller.handleClick(on: button, at: combinedPoint(.claude, in: button))
                    precondition(!controller.dropdown.isVisible)
                    postStatusClick(
                        at: combinedPoint(.claude, in: button, percentage: true, title: "–%"),
                        button: button, app: app, secondary: true)
                    step = .checkingUnavailableSecondaryClick
                    return
                }
                if case .checkingUnavailableSecondaryClick = step {
                    precondition(controller.dropdown.isVisible && controller.provider == .claude)
                    precondition(controller.percentageMode == .remaining)
                    postCombinedClick(.codex, button: button, app: app)
                    step = .checkingPostedCodexClick
                    return
                }
                if case .checkingPostedCodexClick = step {
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.display.provider == .codex)
                    controller.handleClick(on: button, at: combinedPoint(.codex, in: button))
                    precondition(!controller.dropdown.isVisible)
                    button.performClick(nil)
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.display.provider == .codex)
                    claude.populate()
                    controller.dashboard.rootView.refresh()
                    step = .checkingCombinedUpdated
                    return
                }
                if case .checkingCombinedUpdated = step {
                    let label = checkCombinedButton(item, button: button)
                    guard label.contains("Claude · Weekly limit, 52%"),
                        !controller.dashboard.rootView.display.refreshing
                    else { return }
                    precondition(controller.provider == .codex && controller.dropdown.isVisible)
                    checkSummaryProviders(controller, expected: [.codex, .claude])
                    if !checkedBothDetails {
                        checkBothSummaries(controller, detailsVisible: false)
                        if let path = CommandLine.arguments.dropFirst(5).first,
                            let content = controller.dropdown.contentView
                        {
                            capture(content, at: path)
                        }
                        checkedBothDetails = true
                        controller.dashboard.rootView.setDetailsExpanded(true)
                        step = .checkingBothDetails
                        return
                    }
                    let badgeImage = button.image
                    controller.dashboard.rootView.cancelReset()
                    precondition(badgeImage != nil && button.image === badgeImage)
                    for (offset, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                        if let path = CommandLine.arguments.dropFirst(3 + offset).first {
                            let original = button.appearance
                            button.appearance = NSAppearance(named: appearance)
                            capture(button, at: path)
                            button.appearance = original
                        }
                    }
                    let original = controller.dashboard.rootView.display
                    precondition(original.limitingWindow != nil)
                    controller.handleClick(on: button, at: combinedPoint(.codex, in: button))
                    precondition(!controller.dropdown.isVisible)
                    postStatusClick(
                        at: combinedPoint(
                            .codex, in: button, percentage: true,
                            title: shownPercentage(.remaining, original: original)),
                        button: button, app: app)
                    step = .checkingCombinedPrimaryOpened(original)
                    return
                }
                if case .checkingBothDetails = step {
                    guard !controller.dashboard.rootView.countingTokens else { return }
                    checkBothSummaries(controller, detailsVisible: true)
                    precondition(controller.dashboard.rootView.display.provider == .codex)
                    if useFixtures { precondition(controller.dashboard.rootView.canUseReset) }
                    if let path = CommandLine.arguments.dropFirst(6).first,
                        let content = controller.dropdown.contentView
                    {
                        capture(content, at: path)
                    }
                    controller.dashboard.rootView.selectProvider(.claude)
                    step = .checkingBothClaudeDetails
                    return
                }
                if case .checkingBothClaudeDetails = step {
                    guard !controller.dashboard.rootView.countingTokens else { return }
                    checkBothSummaries(controller, detailsVisible: true)
                    precondition(controller.dashboard.rootView.display.provider == .claude)
                    precondition(!controller.dashboard.rootView.canUseReset)
                    precondition(controller.dashboard.rootView.display.limitingWindow?.remaining == 52)
                    if let path = CommandLine.arguments.dropFirst(7).first,
                        let content = controller.dropdown.contentView
                    {
                        capture(content, at: path)
                    }
                    controller.dashboard.rootView.selectProvider(.codex)
                    controller.dashboard.rootView.setDetailsExpanded(false)
                    print(
                        "Both provider limits stayed above Details while the details selector switched tokens and resets."
                    )
                    step = .checkingCombinedUpdated
                    return
                }
                if case .checkingCombinedPrimaryOpened(let original) = step {
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    postStatusClick(
                        at: combinedPoint(.claude, in: button, percentage: true),
                        button: button, app: app, secondary: true)
                    step = .checkingCombinedUsed(original)
                    return
                }
                if case .checkingCombinedUsed(let original) = step {
                    checkPercentageMode(.used, controller: controller, preferences: preferences, original: original)
                    let label = checkCombinedButton(item, button: button)
                    let used = shownPercentage(.used, original: original)
                    precondition(label.contains("Claude · Weekly limit, 48% used"))
                    checkReadout(.used, original: original, in: label)
                    let point = combinedPoint(.codex, in: button, percentage: true, title: used)
                    postStatusClick(at: point, button: button, app: app)
                    step = .checkingCombinedPrimaryClosed(original)
                    return
                }
                if case .checkingCombinedPrimaryClosed(let original) = step {
                    precondition(!controller.dropdown.isVisible && controller.provider == .codex)
                    precondition(controller.percentageMode == .used)
                    let point = combinedPoint(
                        .codex, in: button, percentage: true, title: shownPercentage(.used, original: original))
                    postStatusClick(at: point, button: button, app: app, secondary: true)
                    step = .checkingCombinedRemainingClosed(original)
                    return
                }
                if case .checkingCombinedRemainingClosed(let original) = step {
                    precondition(!controller.dropdown.isVisible && controller.provider == .codex)
                    precondition(controller.percentageMode == .remaining)
                    let label = checkCombinedButton(item, button: button)
                    precondition(label.contains("Claude · Weekly limit, 52% remaining"))
                    checkReadout(.remaining, original: original, in: label)
                    button.performClick(nil)
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    controller.dashboard.rootView.selectPercentageMode(.used)
                    checkPercentageMode(.used, controller: controller, preferences: preferences, original: original)
                    controller.dashboard.rootView.selectPercentageMode(.remaining)
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    postCombinedClick(.claude, button: button, app: app)
                    step = .checkingPostedClaudeClick
                    return
                }
                if case .checkingPostedClaudeClick = step {
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.display.provider == .claude)
                    controller.handleClick(on: button, at: combinedPoint(.claude, in: button))
                    precondition(!controller.dropdown.isVisible)
                    let padding = NSPoint(x: button.bounds.minX + 1, y: button.bounds.midY)
                    controller.handleClick(on: button, at: padding)
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.display.provider == .codex)
                    checkContentFits(controller.dashboard, in: controller.dropdown)
                    controller.dashboard.rootView.selectLayout(.logo)
                    precondition(controller.dropdown.isVisible && controller.dashboard.rootView.menuLayout == .logo)
                    precondition(
                        button.title.hasSuffix("% left") && button.image?.isTemplate == true
                            && button.imagePosition == .imageLeading)
                    precondition(AppDelegate(defaults: preferences).menuLayout == .logo)
                    step = .waitingForLogo
                    return
                }
                if case .waitingForLogo = step {
                    let original = controller.dashboard.rootView.display
                    guard !original.refreshing else { return }
                    postStatusClick(at: titleCenter(in: button), button: button, app: app)
                    step = .checkingLogoPercentageClosed(original)
                    return
                }
                if case .checkingLogoPercentageClosed(let original) = step {
                    precondition(!controller.dropdown.isVisible && controller.provider == .codex)
                    precondition(controller.percentageMode == .remaining)
                    checkSingleReadout(.remaining, original: original, button: button)
                    postStatusClick(at: titleCenter(in: button), button: button, app: app, secondary: true)
                    step = .checkingLogoUsedClosed(original)
                    return
                }
                if case .checkingLogoUsedClosed(let original) = step {
                    precondition(!controller.dropdown.isVisible && controller.provider == .codex)
                    precondition(controller.percentageMode == .used)
                    checkSingleReadout(.used, original: original, button: button)
                    guard let imageRect = button.cell?.imageRect(forBounds: button.bounds), !imageRect.isEmpty else {
                        preconditionFailure("The logo and percentage status button needs an image rect.")
                    }
                    controller.handleClick(on: button, at: NSPoint(x: imageRect.midX, y: imageRect.midY))
                    checkPercentageMode(.used, controller: controller, preferences: preferences, original: original)
                    controller.dashboard.rootView.selectPercentageMode(.remaining)
                    controller.dashboard.rootView.selectLayout(.both)
                    precondition(controller.dropdown.isVisible && controller.dashboard.rootView.menuLayout == .both)
                    precondition(AppDelegate(defaults: preferences).menuLayout == .both)
                    controller.dashboard.rootView.selectLayout(.percentage)
                    precondition(
                        controller.dropdown.isVisible && controller.dashboard.rootView.menuLayout == .percentage)
                    precondition(
                        button.title.hasSuffix("% left") && button.image == nil && button.imagePosition == .noImage)
                    precondition(AppDelegate(defaults: preferences).menuLayout == .percentage)
                    button.performClick(nil)
                    precondition(!controller.dropdown.isVisible)
                    postStatusClick(at: titleCenter(in: button), button: button, app: app)
                    step = .checkingPercentagePrimaryOpened(original)
                    return
                }
                if case .checkingPercentagePrimaryOpened(let original) = step {
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    checkSingleReadout(.remaining, original: original, button: button)
                    postStatusClick(at: titleCenter(in: button), button: button, app: app, secondary: true)
                    step = .checkingPercentageSecondaryUsed(original)
                    return
                }
                if case .checkingPercentageSecondaryUsed(let original) = step {
                    precondition(button.title == shownPercentage(.used, original: original) + " used")
                    checkPercentageMode(.used, controller: controller, preferences: preferences, original: original)
                    checkSingleReadout(.used, original: original, button: button)
                    postStatusClick(at: titleCenter(in: button), button: button, app: app, modifiers: .control)
                    step = .checkingPercentageControlRemaining(original)
                    return
                }
                if case .checkingPercentageControlRemaining(let original) = step {
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    checkSingleReadout(.remaining, original: original, button: button)
                    button.performClick(nil)
                    precondition(!controller.dropdown.isVisible)
                    postStatusClick(at: titleCenter(in: button), button: button, app: app, secondary: true)
                    step = .checkingPercentageSecondaryClosed(original)
                    return
                }
                if case .checkingPercentageSecondaryClosed(let original) = step {
                    precondition(!controller.dropdown.isVisible && controller.provider == .codex)
                    precondition(controller.percentageMode == .used)
                    checkSingleReadout(.used, original: original, button: button)
                    button.performClick(nil)
                    checkPercentageMode(.used, controller: controller, preferences: preferences, original: original)
                    controller.dashboard.rootView.selectPercentageMode(.remaining)
                    checkPercentageMode(
                        .remaining, controller: controller, preferences: preferences, original: original)
                    checkSingleReadout(.remaining, original: original, button: button)
                    button.performClick(nil)
                    precondition(!controller.dropdown.isVisible)
                    precondition(button.title == shownPercentage(.remaining, original: original) + " left")
                    step = .waitingForModeFeedbackExpiry(original, Date())
                    return
                }
                if case .waitingForModeFeedbackExpiry(let original, let start) = step {
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < 0.8 {
                        precondition(button.title == shownPercentage(.remaining, original: original) + " left")
                    }
                    guard elapsed > 1.1 else { return }
                    precondition(button.title == shownPercentage(.remaining, original: original))
                    checkProviderSelection(controller, preferences: preferences, button: button)
                    claude.clear()
                    print(
                        "Live menu layouts, both background readings, native status width, accessibility label, mouse regions, keyboard path, and saved layout passed."
                    )
                    print(
                        "Primary clicks opened and closed details without changing percentages. Secondary and Control-clicks toggled saved mode while preserving dropdown visibility and quota data."
                    )
                    step = .opening
                    return
                }
                guard !button.title.isEmpty else { return }
                precondition(item.isVisible && button.window != nil && button.image == nil)
                precondition((button.title.last == "%" || button.title == "···") && !button.title.contains(" "))
                if case .opening = step {
                    guard button.title != "–%", button.title != "···", controller.tokenTotals != nil else { return }
                    print("The percentage-only status item is attached.")
                    button.performClick(nil)
                    let host = controller.dashboard!
                    host.rootView.selectProvider(.claude)
                    host.rootView.selectProvider(.codex)
                    precondition(button.toolTip?.contains("Codex") == true)
                    host.rootView.selectProvider(.claude)
                    step = .waitingForClaude
                    return
                }
                if case .waitingForClaude = step {
                    let view = controller.dashboard.rootView
                    guard !view.display.refreshing, !view.countingTokens else { return }
                    precondition(view.display.provider == .claude && button.title == "–%")
                    precondition(view.failure == nil && !view.canUseReset && view.resetNotice == nil)
                    precondition(
                        button.toolTip?.contains("Claude") == true
                            && preferences.string(forKey: "selectedProvider") == "claude")
                    precondition(AppDelegate(defaults: preferences).provider == .claude)
                    view.prepareReset()
                    view.confirmReset()
                    precondition(mock.count == 0 && controller.dashboard.rootView.resetPhase == .ready)
                    if let totals = view.tokens {
                        precondition(
                            totals.allTime >= totals.month && totals.month >= totals.week && totals.week >= totals.today
                        )

                    } else {
                        precondition(view.tokenFailure != nil)
                    }
                    checkContentFits(controller.dashboard, in: controller.dropdown)
                    if let path = CommandLine.arguments.dropFirst(2).first,
                        let content = controller.dropdown.contentView
                    {
                        capture(content, at: path)
                    }
                    claude.populate()
                    view.refresh()
                    step = .checkingClaudeQuota
                    return
                }
                if case .checkingClaudeQuota = step {
                    let view = controller.dashboard.rootView
                    guard !view.display.refreshing, !view.countingTokens else { return }
                    precondition(view.display.windows.count == 2 && button.title == "52%")
                    precondition(button.toolTip?.contains("Claude · Weekly limit, 52%") == true)
                    checkContentFits(controller.dashboard, in: controller.dropdown)
                    precondition(!view.detailsExpanded)
                    view.setDetailsExpanded(true)
                    view.selectProvider(.codex)
                    precondition(controller.dashboard.rootView.detailsExpanded)
                    precondition(AppDelegate(defaults: preferences).detailsExpanded)
                    controller.dashboard.rootView.setDetailsExpanded(false)
                    precondition(preferences.string(forKey: "selectedProvider") == "codex")
                    precondition(button.toolTip?.contains("Codex") == true)
                    print(
                        "Provider switching, preference restoration, empty Claude state, fixture quota and reset isolation passed."
                    )
                    step = .inspecting
                    return
                }
                guard let totals = controller.tokenTotals else { return }
                precondition(
                    totals.allTime >= totals.month && totals.month >= totals.week && totals.week >= totals.today
                        && totals.today >= 0)

                guard let dropdown = controller.dropdown, dropdown.isVisible,
                    let host = controller.dashboard, let content = dropdown.contentView
                else {
                    fputs("The status button did not open its dropdown.\n", stderr)
                    exit(2)
                }
                let beforeRefresh: Date
                switch step {
                case .startingCombined, .checkingCombinedEmpty, .checkingUnavailableClick,
                    .checkingUnavailableSecondaryClick, .checkingPostedCodexClick,
                    .checkingCombinedUpdated, .checkingBothDetails, .checkingBothClaudeDetails,
                    .checkingCombinedPrimaryOpened, .checkingCombinedUsed,
                    .checkingCombinedPrimaryClosed,
                    .checkingCombinedRemainingClosed, .checkingPostedClaudeClick, .waitingForLogo,
                    .checkingLogoPercentageClosed,
                    .checkingLogoUsedClosed, .checkingPercentagePrimaryOpened, .checkingPercentageSecondaryUsed,
                    .checkingPercentageControlRemaining, .checkingPercentageSecondaryClosed,
                    .waitingForModeFeedbackExpiry, .opening,
                    .waitingForClaude, .checkingClaudeQuota:
                    preconditionFailure("The live check has not opened the dropdown.")
                case .inspecting:
                    guard host.rootView.display.reading != nil, !host.rootView.display.refreshing,
                        !host.rootView.countingTokens
                    else { return }
                    precondition(
                        !dropdown.styleMask.contains(.titled) && dropdown.styleMask.contains(.nonactivatingPanel))
                    precondition(!host.rootView.detailsExpanded)
                    checkContentFits(host, in: dropdown)
                    step = .checkingDetailsClick(dropdown.frame)
                    // Click the Details label on the same compact footer row as Refresh and Settings.
                    let point = content.convert(NSPoint(x: 48, y: 23), to: nil)
                    postClick(at: point, in: dropdown, app: app)
                    return
                case .checkingDetailsClick(let compactFrame):
                    guard let reading = host.rootView.display.reading, !host.rootView.display.refreshing,
                        !host.rootView.countingTokens
                    else { return }
                    precondition(host.rootView.detailsExpanded)
                    checkDisclosureSizing(host, compact: compactFrame, in: dropdown)
                    precondition(AppDelegate(defaults: preferences).detailsExpanded)

                    if let path = CommandLine.arguments.dropFirst().first {
                        capture(content, at: path)
                    }
                    print(
                        "Status button opened the live quota dropdown (\(Int(content.bounds.width)) x \(Int(content.bounds.height)))."
                    )
                    button.performClick(nil)
                    precondition(!dropdown.isVisible)
                    button.performClick(nil)
                    precondition(dropdown.isVisible)
                    precondition(host.rootView.detailsExpanded)
                    print("Status button closed and reopened the dropdown.")
                    sendOutsideClick(in: app)
                    precondition(!dropdown.isVisible)
                    button.performClick(nil)
                    precondition(dropdown.isVisible)
                    print("Clicking another test window dismissed the dropdown.")
                    precondition(!useFixtures || host.rootView.canUseReset)
                    if host.rootView.canUseReset {
                        let frame = dropdown.frame
                        host.rootView.prepareReset()
                        precondition(host.rootView.resetPhase == .confirming && mock.count == 0)
                        step = .checkingConfirmationFrame(frame)
                        return
                    }
                    sendKey("\u{1b}", code: 53, to: dropdown, in: app)
                    precondition(!dropdown.isVisible)
                    button.performClick(nil)
                    precondition(dropdown.isVisible)
                    host.rootView.setDetailsExpanded(false)
                    beforeRefresh = reading.fetchedAt
                case .checkingConfirmationFrame(let originalFrame):
                    checkContentFits(host, in: dropdown)
                    precondition(dropdown.frame.height > originalFrame.height)
                    precondition(abs(dropdown.frame.maxY - originalFrame.maxY) <= 1)
                    let prepareWhileExpanded = host.rootView.prepareReset
                    let confirmWhileExpanded = host.rootView.confirmReset
                    host.rootView.setDetailsExpanded(false)
                    prepareWhileExpanded()
                    confirmWhileExpanded()
                    precondition(host.rootView.resetPhase == .ready && mock.count == 0)
                    precondition(!host.rootView.detailsExpanded)
                    checkContentFits(host, in: dropdown)
                    host.rootView.setDetailsExpanded(true)
                    precondition(host.rootView.resetPhase == .ready)
                    print("Collapsing Details canceled confirmation without issuing a claim.")
                    host.rootView.prepareReset()
                    precondition(host.rootView.resetPhase == .confirming && mock.count == 0)
                    host.rootView.cancelReset()
                    precondition(host.rootView.resetPhase == .ready && mock.count == 0)
                    host.rootView.prepareReset()
                    precondition(host.rootView.resetPhase == .confirming && mock.count == 0)
                    sendKey("\u{1b}", code: 53, to: dropdown, in: app)
                    precondition(!dropdown.isVisible && mock.count == 0)
                    button.performClick(nil)
                    precondition(dropdown.isVisible && host.rootView.resetPhase == .ready && mock.count == 0)
                    print("Confirmation grew downward and Escape dismissed it without issuing a claim.")
                    host.rootView.setDetailsExpanded(false)
                    guard let reading = host.rootView.display.reading else { exit(7) }
                    beforeRefresh = reading.fetchedAt
                case .waitingForRefresh(let previousReading):
                    guard !host.rootView.display.refreshing, !host.rootView.countingTokens else { return }
                    precondition((host.rootView.display.reading?.fetchedAt ?? .distantPast) > previousReading)
                    precondition(!host.rootView.detailsExpanded)
                    print("Command-R refreshed the quota while Details was collapsed.")
                    host.rootView.setDetailsExpanded(true)
                    if host.rootView.canUseReset {
                        host.rootView.prepareReset()
                        precondition(host.rootView.resetPhase == .confirming && mock.count == 0)
                        let confirm = host.rootView.confirmReset
                        confirm()
                        confirm()
                        step = .waitingForMock
                        return
                    }
                    finish(dropdown: dropdown, scratch: scratch, preferencesSuite: suite, app: app)
                    return
                case .waitingForMock:
                    guard host.rootView.resetPhase == .ready, !host.rootView.display.refreshing else { return }
                    precondition(host.rootView.resetNotice == "Reset applied." && mock.count == 1)
                    print(
                        "Confirmation, cancellation, one simulated redemption, double-click guard and refresh passed.")
                    finish(dropdown: dropdown, scratch: scratch, preferencesSuite: suite, app: app)
                    return
                }
                sendKey("r", code: 15, modifiers: .command, to: dropdown, in: app)
                step = .waitingForRefresh(beforeRefresh)
            }
        }
        withExtendedLifetime(controller) { app.run() }
    }

    @MainActor private static func checkCombinedButton(_ item: NSStatusItem, button: NSStatusBarButton) -> String {
        guard let image = button.image, let label = button.accessibilityLabel() else {
            preconditionFailure("The combined status button needs a template image and an accessibility label.")
        }
        precondition(item.isVisible && item.length == NSStatusItem.variableLength && button.window != nil)
        precondition(image.isTemplate && button.title.isEmpty && button.imagePosition == .imageOnly)
        precondition(button.bounds.width >= image.size.width && button.bounds.width <= image.size.width + 24)
        precondition(button.toolTip?.hasPrefix(label) == true && label.contains("Codex") && label.contains("Claude"))
        return label
    }

    @MainActor private static func checkPercentageMode(
        _ mode: PercentageMode, controller: AppDelegate, preferences: UserDefaults, original: QuotaDisplay,
        file: StaticString = #fileID, line: UInt = #line
    ) {
        precondition(
            controller.percentageMode == mode && controller.provider == original.provider,
            "Expected \(original.provider) in \(mode) mode, got \(controller.provider) in \(controller.percentageMode) mode.",
            file: file, line: line)
        precondition(controller.dropdown.isVisible, "Expected the dropdown to remain visible.", file: file, line: line)
        let display = controller.dashboard.rootView.display
        precondition(display.provider == original.provider && display.percentageMode == mode, file: file, line: line)
        precondition(
            display.reading?.fetchedAt == original.reading?.fetchedAt,
            "Changing display mode should preserve the last refresh timestamp.", file: file, line: line)
        precondition(
            display.reading?.windows == original.reading?.windows,
            "Changing display mode should preserve the original quota windows.", file: file, line: line)
        precondition(
            display.limitingWindow == original.limitingWindow,
            "Changing display mode should preserve the limiting window.", file: file, line: line)
        precondition(AppDelegate(defaults: preferences).percentageMode == mode, file: file, line: line)
    }

    @MainActor private static func checkProviderSelection(
        _ controller: AppDelegate, preferences: UserDefaults, button: NSStatusBarButton
    ) {
        button.performClick(nil)
        precondition(controller.dropdown.isVisible)
        controller.dashboard.rootView.selectProviderSelection(.codex)
        precondition(controller.providerSelection == .codex && controller.provider == .codex)
        precondition(controller.menuLayout != .both)
        precondition(controller.dashboard.rootView.providerSelection == .codex)
        checkSummaryProviders(controller, expected: [.codex])
        precondition(button.accessibilityLabel()?.contains("Codex") == true)
        precondition(button.accessibilityLabel()?.contains("Claude") == false)
        let savedCodex = AppDelegate(defaults: preferences)
        precondition(savedCodex.providerSelection == .codex && savedCodex.provider == .codex)
        precondition(savedCodex.menuLayout != .both)

        controller.dashboard.rootView.selectProviderSelection(.claude)
        precondition(controller.providerSelection == .claude && controller.provider == .claude)
        precondition(controller.menuLayout != .both)
        precondition(controller.dashboard.rootView.providerSelection == .claude)
        checkSummaryProviders(controller, expected: [.claude])
        precondition(button.accessibilityLabel()?.contains("Claude") == true)
        precondition(button.accessibilityLabel()?.contains("Codex") == false)
        let savedClaude = AppDelegate(defaults: preferences)
        precondition(savedClaude.providerSelection == .claude && savedClaude.provider == .claude)
        precondition(savedClaude.menuLayout != .both)

        controller.dashboard.rootView.selectProviderSelection(.both)
        precondition(controller.providerSelection == .both && controller.menuLayout == .both)
        precondition(controller.dashboard.rootView.providerSelection == .both)
        checkSummaryProviders(controller, expected: [.codex, .claude])
        precondition(button.accessibilityLabel()?.contains("Claude") == true)
        precondition(button.accessibilityLabel()?.contains("Codex") == true)
        let savedBoth = AppDelegate(defaults: preferences)
        precondition(savedBoth.providerSelection == .both && savedBoth.menuLayout == .both)
        controller.dashboard.rootView.selectProvider(.codex)
        controller.dashboard.rootView.selectLayout(.percentage)
        button.performClick(nil)
        precondition(!controller.dropdown.isVisible && controller.provider == .codex)
        print("Provider choices persisted, selected only the enabled account, and restored both menu readings.")
    }

    @MainActor private static func checkSummaryProviders(_ controller: AppDelegate, expected: [UsageProvider]) {
        precondition(controller.dashboard.rootView.summaries.map(\.display.provider) == expected)
    }

    @MainActor private static func checkBothSummaries(_ controller: AppDelegate, detailsVisible: Bool) {
        let host = controller.dashboard!
        checkSummaryProviders(controller, expected: [.codex, .claude])
        precondition(host.rootView.summaries[1].display.limitingWindow?.remaining == 52)
        precondition(host.rootView.detailsExpanded == detailsVisible)
        checkContentFits(host, in: controller.dropdown)
    }

    private static func shownPercentage(_ mode: PercentageMode, original: QuotaDisplay) -> String {
        guard let limit = original.limitingWindow else { preconditionFailure("Expected a provider quota.") }
        return QuotaDisplay.percent(mode == .used ? limit.used : limit.remaining)
    }

    private static func checkReadout(_ mode: PercentageMode, original: QuotaDisplay, in label: String) {
        guard let limit = original.limitingWindow else { preconditionFailure("Expected a provider quota.") }
        let window = QuotaDisplay.name(limit)
        let value = shownPercentage(mode, original: original)
        precondition(label.contains("\(original.provider.name) · \(window), \(value) \(mode.rawValue)"), label)
    }

    @MainActor private static func checkSingleReadout(
        _ mode: PercentageMode, original: QuotaDisplay, button: NSStatusBarButton
    ) {
        let expected = shownPercentage(mode, original: original)
        precondition(button.title == expected || button.title == expected + (mode == .remaining ? " left" : " used"))
        guard let label = button.accessibilityLabel() else { preconditionFailure("Expected a status label.") }
        checkReadout(mode, original: original, in: label)
        precondition(button.toolTip?.hasPrefix(label) == true)
    }

    @MainActor private static func combinedPoint(
        _ provider: UsageProvider, in button: NSStatusBarButton, percentage: Bool = false, title: String = "52%"
    ) -> NSPoint {
        guard let imageRect = button.cell?.imageRect(forBounds: button.bounds), !imageRect.isEmpty else {
            preconditionFailure("The combined status button needs an image rect.")
        }
        let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
        let textWidth = ceil(NSAttributedString(string: title, attributes: [.font: font]).size().width)
        let logoAndGap: CGFloat = 17
        let logoCenter: CGFloat = 7
        let start = provider == .codex ? imageRect.minX : imageRect.maxX - logoAndGap - textWidth
        let x = start + (percentage ? logoAndGap + textWidth / 2 : logoCenter)
        return NSPoint(x: x, y: imageRect.midY)
    }

    @MainActor private static func titleCenter(in button: NSStatusBarButton) -> NSPoint {
        guard let titleRect = button.cell?.titleRect(forBounds: button.bounds), !titleRect.isEmpty else {
            preconditionFailure("The status button needs a title rect.")
        }
        return NSPoint(x: titleRect.midX, y: titleRect.midY)
    }

    @MainActor private static func postCombinedClick(
        _ provider: UsageProvider, button: NSStatusBarButton, app: NSApplication
    ) {
        postStatusClick(at: combinedPoint(provider, in: button), button: button, app: app)
    }

    @MainActor private static func postStatusClick(
        at point: NSPoint, button: NSStatusBarButton, app: NSApplication, secondary: Bool = false,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let window = button.window else { preconditionFailure("The status button is detached.") }
        postClick(at: button.convert(point, to: nil), in: window, app: app, secondary: secondary, modifiers: modifiers)
    }

    @MainActor private static func postClick(
        at point: NSPoint, in window: NSWindow, app: NSApplication, secondary: Bool = false,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        let types: [NSEvent.EventType] = secondary ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1), event.window === window
            else {
                preconditionFailure("Could not create a click in the test window.")
            }
            app.postEvent(event, atStart: false)
        }
    }

    @MainActor private static func capture(_ content: NSView, at path: String) {
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(3) }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let bytes = rep.representation(using: .png, properties: [:]) else { exit(4) }
        do { try bytes.write(to: URL(fileURLWithPath: path)) } catch { exit(5) }
    }

    @MainActor private static func sendOutsideClick(in app: NSApplication) {
        let outside = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 100, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        defer { outside.close() }
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: outside.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1), event.window === outside
        else {
            preconditionFailure("Could not create a click in the test window.")
        }
        app.sendEvent(event)
    }

    @MainActor private static func sendKey(
        _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow,
        in app: NSApplication
    ) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                )
            else { preconditionFailure("Could not create a keyboard event for the dropdown.") }
            app.sendEvent(event)
        }
    }

    @MainActor private static func checkContentFits(_ host: NSHostingController<Dashboard>, in dropdown: NSPanel) {
        host.view.layoutSubtreeIfNeeded()
        let contentSize = host.view.bounds.size
        let fittingSize = host.sizeThatFits(in: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        precondition(host.view.window === dropdown && contentSize.width >= 300 && contentSize.height > 0)
        precondition(
            abs(contentSize.height - fittingSize.height) <= 1,
            "Hosting view height \(contentSize.height) differs from fitting height \(fittingSize.height).")
        guard let content = dropdown.contentView,
            let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first,
            let footer = content.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first
        else { preconditionFailure("The panel needs a separate body scroll view and fixed footer.") }
        precondition(scroll.documentView === host.view)
        precondition(footer.window === dropdown && footer.frame.height > 0)
        precondition(abs(footer.frame.minY) <= 1 && abs(footer.frame.maxX - content.bounds.maxX) <= 1)
        precondition(abs(footer.frame.width - contentSize.width) <= 1)
        precondition(abs(scroll.frame.minY - footer.frame.maxY) <= 1)
        precondition(abs(scroll.frame.maxY - content.bounds.maxY) <= 1)
        guard let screen = dropdown.screen else { preconditionFailure("The dropdown needs a screen.") }
        let availableHeight = screen.visibleFrame.insetBy(dx: 4, dy: 4).height
        precondition(
            abs(dropdown.frame.height - min(ceil(contentSize.height) + footer.frame.height, availableHeight)) <= 1,
            "The panel must fit its body and fixed footer within the screen.")
        precondition(scroll.contentView.bounds.height <= contentSize.height + 1)

    }

    @MainActor private static func checkDisclosureSizing(
        _ host: NSHostingController<Dashboard>, compact: NSRect, in dropdown: NSPanel
    ) {
        checkContentFits(host, in: dropdown)
        let expanded = dropdown.frame
        guard let footer = dropdown.contentView?.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first else {
            preconditionFailure("The dropdown footer must stay outside its scrolling body.")
        }
        let footerFrame = footer.frame
        precondition(expanded.height > compact.height && abs(expanded.maxY - compact.maxY) <= 1)
        precondition(host.rootView.detailsExpanded)

        host.rootView.setDetailsExpanded(false)
        checkContentFits(host, in: dropdown)
        precondition(dropdown.frame == compact && !host.rootView.detailsExpanded)
        precondition(footer.frame.minY == footerFrame.minY && footer.frame.width == footerFrame.width)
        host.rootView.setDetailsExpanded(true)
        precondition(host.rootView.detailsExpanded)
        checkContentFits(host, in: dropdown)
        precondition(dropdown.frame == expanded && footer.frame == footerFrame)
        print("The refresh and settings footer stayed pinned while Details expanded and collapsed.")
        print("Details expanded all secondary information together and restored the compact panel geometry.")
    }

    @MainActor private static func finish(
        dropdown: NSPanel, scratch: URL, preferencesSuite: String, app: NSApplication
    ) {
        dropdown.cancelOperation(nil)
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
        app.terminate(nil)
    }
}
