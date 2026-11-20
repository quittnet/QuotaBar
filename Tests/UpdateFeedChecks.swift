import Foundation
import Sparkle

@MainActor
private final class NoUpdateUI: NSObject, SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        preconditionFailure("A probing check requested user permission")
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        preconditionFailure("Unexpected update UI")
    }
    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) { preconditionFailure("Unexpected update UI") }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        preconditionFailure("Unexpected release notes download")
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        preconditionFailure("Unexpected release notes download")
    }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        preconditionFailure("Unexpected update UI")
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        preconditionFailure("Unexpected update UI")
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        preconditionFailure("A probing check started a download")
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        preconditionFailure("Unexpected update download")
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        preconditionFailure("Unexpected update download")
    }
    func showDownloadDidStartExtractingUpdate() { preconditionFailure("Unexpected extraction") }
    func showExtractionReceivedProgress(_ progress: Double) {
        preconditionFailure("Unexpected extraction")
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        preconditionFailure("Unexpected installation")
    }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) { preconditionFailure("Unexpected installation") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        preconditionFailure("Unexpected installation")
    }
    func dismissUpdateInstallation() {}
}

@MainActor
private final class Probe: NSObject, SPUUpdaterDelegate {
    var found: SUAppcastItem?
    var noUpdate = false
    var error: Error?
    var finished = false
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { found = item }
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { noUpdate = true }
    }
    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        MainActor.assumeIsolated {
            self.error = error
            finished = true
        }
    }
    func reset() {
        found = nil
        noUpdate = false
        error = nil
        finished = false
    }
}

@main
@MainActor
struct UpdateFeedChecks {
    static func main() throws {
        let comparisons = compareVersions()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let host = Bundle.main
        let probe = Probe()
        let driver = NoUpdateUI()
        let updater = SPUUpdater(
            hostBundle: host, applicationBundle: host, userDriver: driver, delegate: probe)
        let cases: [(String, String?, Bool)] = [
            ("older", nil, false), ("newer", "38", false), ("equal", nil, false),
            ("tampered", nil, true), ("newer", "38", false), ("malformed", nil, true),
            ("multi", "39", false), ("missing", nil, true), ("incompatible", nil, false),
            ("newer", "38", false),
        ]
        var checks = 0
        for round in 0..<8 {
            for (name, version, mustError) in cases {
                let target = directory.appendingPathComponent("appcast.xml")
                if name == "missing" {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                } else {
                    try Data(contentsOf: directory.appendingPathComponent(name + ".xml")).write(
                        to: target, options: .atomic)
                }
                probe.reset()
                if checks == 0 { try updater.start() }
                updater.checkForUpdateInformation()
                for _ in 0..<20 { updater.checkForUpdateInformation() }
                let deadline = Date().addingTimeInterval(12)
                while !probe.finished && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                let context = "round \(round) \(name)"
                precondition(probe.finished, "Timed out: \(context)")
                precondition(
                    probe.found?.versionString == version,
                    "Wrong update: \(context), got \(probe.found?.versionString ?? "none")")
                if let found = probe.found {
                    precondition(probe.error == nil, "Valid update ended with an error: \(context)")
                    precondition(
                        found.signingValidationStatus == .succeeded,
                        "Feed signature was not verified: \(context)")
                }
                precondition(
                    probe.noUpdate == (version == nil && !mustError), "Wrong no-update result: \(context)")
                if mustError { precondition(probe.error != nil, "Missing error: \(context)") }
                precondition(!updater.sessionInProgress, "Session failed to settle: \(context)")
                checks += 1
            }
        }
        print(
            "Update feed stress passed: \(checks) signed-feed checks and \(comparisons) version comparisons, with 20 overlapping probe requests per check."
        )
    }

    static func compareVersions() -> Int {
        let comparator = SUStandardVersionComparator.default
        var checks = 0
        for first in stride(from: 1, through: 1000, by: 7) {
            for second in stride(from: 1, through: 1000, by: 11) {
                let expected: ComparisonResult =
                    first == second ? .orderedSame : (first < second ? .orderedAscending : .orderedDescending)
                precondition(
                    comparator.compareVersion(String(first), toVersion: String(second)) == expected)
                checks += 1
            }
        }
        for major in 0..<30 {
            for minor in 0..<30 {
                for patch in 0..<10 {
                    let version = "\(major).\(minor).\(patch)"
                    precondition(
                        comparator.compareVersion(version, toVersion: "\(major).\(minor).\(patch + 1)")
                            == .orderedAscending)
                    precondition(
                        comparator.compareVersion("\(major).\(minor + 1).0", toVersion: version)
                            == .orderedDescending)
                    checks += 2
                }
            }
        }
        return checks
    }
}
