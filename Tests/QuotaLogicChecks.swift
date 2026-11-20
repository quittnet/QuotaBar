import Foundation

@main
@MainActor
struct QuotaLogicChecks {
    static func main() {
        let reports = checkReports()
        let transitions = checkAccountTransitions()
        print("Passed \(reports) quota display scenarios and \(transitions) account restriction transitions.")
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
        let suite = "QuotaBar.LogicTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: file) }
        func launch() -> AppDelegate {
            AppDelegate(resetStore: UsageResets(file: file), defaults: defaults, monitorNetwork: false)
        }
        var count = 0
        for trace in 0..<729 {
            defaults.removePersistentDomain(forName: suite)
            defaults.set("codex", forKey: "providerSelection")
            var app = launch()
            var lastKnownRestrictions = [false, false, false]
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
                    if !allowed || owners[identity] != nil { lastKnownRestrictions[identity] = !allowed }
                    expected = false
                } else {
                    expected =
                        owners[identity] == nil
                        ? lastKnownRestrictions.contains(true)
                        : lastKnownRestrictions[identity] || lastKnownRestrictions[2]
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
