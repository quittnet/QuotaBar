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

@main
struct OnboardingChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "QuotaBar-onboarding-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let fixture = ProviderFixture()
        defaults.set("both", forKey: "providerSelection")
        defaults.set("both", forKey: "menuBarLayout")
        let controller = AppDelegate(
            resetStore: UsageResets(
                file: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pending")),
            defaults: defaults, monitorNetwork: false,
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
                    controller.dropdown.dismiss()
                    fixture.install()
                    refreshed = true
                    controller.dashboard.rootView.refresh()
                } else if let label = button.toolTip, label.contains("42% remaining"), label.contains("73% remaining") {
                    precondition(!controller.dropdown.isVisible)
                    button.performClick(nil)
                    precondition(controller.dropdown.isVisible)
                    precondition(
                        controller.dashboard.rootView.summaries.allSatisfy {
                            !$0.missingCLI && $0.display.hasCurrentPercentage
                        })
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
