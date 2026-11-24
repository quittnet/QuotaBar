import AppKit
import Foundation

private final class ProviderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    func install() { lock.withLock { available = true } }
    func read(_ provider: UsageProvider) throws -> QuotaReading {
        guard lock.withLock({ available }) else {
            if provider == .claude { throw ClaudeUsageClient.Failure.notInstalled }
            throw QuotaError.codexNotFound
        }
        return QuotaReading(
            fetchedAt: Date(), windows: [.init(minutes: 10080, remaining: provider == .codex ? 42 : 73, resetsAt: nil)])
    }
}

@MainActor
private final class TestAnchorWindow: NSWindow {
    var screenDetached = false
    override var screen: NSScreen? { screenDetached ? nil : super.screen }
}

@main
struct OnboardingChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        let fixture = ProviderFixture()
        let testButton = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 48, height: 22))
        let anchorWindow = TestAnchorWindow(
            contentRect: testButton.frame, styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.contentView = testButton
        var detachOnRefresh = false
        defaults.set("both", forKey: "providerSelection")
        defaults.set("both", forKey: "menuBarLayout")
        let controller = AppDelegate(
            resetStore: UsageResets(
                file: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pending")),
            defaults: defaults, monitorNetwork: false,
            quotaNow: {
                if detachOnRefresh { anchorWindow.screenDetached = true }
                return Date()
            },
            readCodex: { _ in try fixture.read(.codex) }, readClaude: { try fixture.read(.claude) },
            redeem: { _ in preconditionFailure("Unexpected reset") })
        app.delegate = controller
        var refreshed = false
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let defaults = UserDefaults(suiteName: suite)!
                precondition(
                    ProcessInfo.processInfo.systemUptime < deadline, "Missing CLI onboarding or recovery timed out")
                guard let button = controller.item?.button else { return }
                if !refreshed {
                    guard controller.dropdown.isVisible else { return }
                    let summaries = controller.dashboard.rootView.summaries
                    guard
                        summaries.count == 2
                            && summaries.allSatisfy({ $0.missingCLI && !$0.display.hasCurrentPercentage })
                    else { return }
                    precondition(defaults.bool(forKey: "didPresentCLISetup"))
                    let active = controller.provider
                    let mode = controller.percentageMode
                    controller.dashboard.rootView.selectPage(.settings)
                    controller.handleClick(on: button, at: nil, secondaryClick: true)
                    precondition(controller.dropdown.isVisible && controller.dashboard.rootView.page == .usage)
                    controller.handleClick(on: button, at: nil, secondaryClick: true)
                    precondition(controller.dropdown.isVisible && controller.provider == active)
                    precondition(controller.percentageMode == mode)
                    controller.dropdown.dismiss()
                    fixture.install()
                    refreshed = true
                    controller.dashboard.rootView.refresh()
                } else if let label = button.accessibilityLabel(), label.contains("42% remaining"),
                    label.contains("73% remaining")
                {
                    precondition(!controller.dropdown.isVisible)
                    // AppKit can briefly detach the status button while resizing it for the recovered percentages.
                    guard button.window?.screen != nil else { return }
                    button.performClick(nil)
                    precondition(controller.dropdown.isVisible)
                    precondition(
                        controller.dashboard.rootView.summaries.allSatisfy {
                            !$0.missingCLI && $0.display.hasCurrentPercentage
                        })
                    let previousFrame = controller.dropdown.frame
                    controller.dropdown.dismiss()
                    let limits = NSScreen.main!.visibleFrame.insetBy(dx: 4, dy: 4)
                    let onLeft = previousFrame.midX > limits.midX
                    let x = onLeft ? limits.minX : limits.maxX - testButton.frame.width
                    anchorWindow.setFrameOrigin(NSPoint(x: x, y: limits.maxY - 55))
                    let buttonRect = anchorWindow.convertToScreen(testButton.convert(testButton.bounds, to: nil))
                    precondition(testButton.window?.screen != nil)
                    // The click arrives on screen, then the refresh loses its screen before showing the panel.
                    detachOnRefresh = true
                    controller.handleClick(on: testButton, at: nil)
                    precondition(
                        anchorWindow.screenDetached && controller.dropdown.isVisible, "Lost status-button click")
                    let opened = controller.dropdown.frame
                    let expectedX = onLeft ? limits.minX : limits.maxX - opened.width
                    let expectedY = max(limits.minY, buttonRect.minY - opened.height)
                    precondition(opened.origin != previousFrame.origin)
                    precondition(abs(opened.minX - expectedX) < 1 && abs(opened.minY - expectedY) < 1)
                    detachOnRefresh = false
                    anchorWindow.screenDetached = false
                    controller.handleClick(on: testButton, at: nil)
                    precondition(!controller.dropdown.isVisible)
                    print("One click survived a detached status screen and a second click dismissed the dropdown.")
                    defaults.removePersistentDomain(forName: suite)
                    print(
                        "Both missing provider CLIs opened setup automatically; manual refresh restored both readings and cleared setup."
                    )
                    app.terminate(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(controller) { app.run() }
    }
}
