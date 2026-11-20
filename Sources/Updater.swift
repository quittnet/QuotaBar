import Combine
import Foundation

#if canImport(Sparkle)
    import Sparkle
#endif

@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()
    @Published private(set) var available = false
    @Published private(set) var pendingUpdateVersion: String?

    var canCheckForUpdates: Bool { available || pendingUpdateVersion != nil }

    func updateCheckAvailability(_ canCheck: Bool) {
        available = canCheck
    }

    func willShowUpdate(version: String, handledBySparkle: Bool) {
        if !handledBySparkle { pendingUpdateVersion = version }
    }

    func clearUpdateReminder() {
        pendingUpdateVersion = nil
    }

    #if canImport(Sparkle)
        let supported = true
        private lazy var controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        private var observation: NSKeyValueObservation?
        private var automaticObservation: NSKeyValueObservation?
        private var started = false

        var automaticallyChecksForUpdates: Bool {
            get { controller.updater.automaticallyChecksForUpdates }
            set { controller.updater.automaticallyChecksForUpdates = newValue }
        }

        func start() {
            guard !started else { return }
            started = true
            observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.updateCheckAvailability(updater.canCheckForUpdates) }
            }
            automaticObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
                [weak self] _, _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            controller.startUpdater()
        }

        func checkForUpdates() {
            guard canCheckForUpdates else { return }
            controller.checkForUpdates(nil)
        }
    #else
        let supported = false
        var automaticallyChecksForUpdates: Bool {
            get { false }
            set {}
        }
        func start() {}
        func checkForUpdates() {}
    #endif
}

#if canImport(Sparkle)
    extension UpdateController: SPUStandardUserDriverDelegate {
        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            immediateFocus
        }

        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            MainActor.assumeIsolated {
                willShowUpdate(version: update.displayVersionString, handledBySparkle: handleShowingUpdate)
            }
        }

        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            MainActor.assumeIsolated { clearUpdateReminder() }
        }

        nonisolated func standardUserDriverWillFinishUpdateSession() {
            MainActor.assumeIsolated { clearUpdateReminder() }
        }
    }
#endif
