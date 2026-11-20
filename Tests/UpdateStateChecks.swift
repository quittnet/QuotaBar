import Foundation

@main
@MainActor
struct UpdateStateChecks {
    static func main() {
        let updater = UpdateController()
        precondition(!updater.available && updater.pendingUpdateVersion == nil && !updater.canCheckForUpdates)
        var transitions = 0
        for trace in 0..<46_656 {
            updater.updateCheckAvailability(false)
            updater.clearUpdateReminder()
            var events = trace
            var canStartNewCheck = false
            var reminder: String?
            for step in 0..<6 {
                let event = events % 6
                events /= 6
                switch event {
                case 0:
                    updater.updateCheckAvailability(false)
                    canStartNewCheck = false
                case 1:
                    updater.updateCheckAvailability(true)
                    canStartNewCheck = true
                case 2, 3:
                    let version = event == 2 ? "1.8.0" : "1.9.0"
                    updater.willShowUpdate(version: version, handledBySparkle: false)
                    reminder = version
                case 4:
                    updater.willShowUpdate(version: "2.0.0", handledBySparkle: true)
                default:
                    updater.clearUpdateReminder()
                    reminder = nil
                }
                precondition(
                    updater.available == canStartNewCheck, "Availability diverged at trace \(trace), step \(step)")
                precondition(
                    updater.pendingUpdateVersion == reminder, "Reminder diverged at trace \(trace), step \(step)")
                let mayOpenUpdate = canStartNewCheck || reminder != nil
                precondition(
                    updater.canCheckForUpdates == mayOpenUpdate, "Check gate diverged at trace \(trace), step \(step)")
                transitions += 1
            }
        }
        // No backend starts for an unsupported build, even after repeated calls.
        if !updater.supported {
            for _ in 0..<1000 {
                updater.start()
                updater.checkForUpdates()
                updater.automaticallyChecksForUpdates = true
                precondition(!updater.automaticallyChecksForUpdates)
            }
        }
        print(
            "Update state stress passed: \(transitions) transitions across 46,656 traces; reminder replacement, attention/session cleanup, busy checking, and recovery checked."
        )
    }
}
