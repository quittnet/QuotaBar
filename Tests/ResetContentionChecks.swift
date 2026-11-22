import Foundation

@main
struct ResetContentionChecks {
    @MainActor static func main() throws {
        let files = FileManager.default
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--confirm" {
            let directory = URL(fileURLWithPath: args[2])
            let display = fixture()
            let store = UsageResets(file: directory.appendingPathComponent("pending"))
            try waitUntil("verified fixture balance") {
                store.received(display.reading!, generation: store.readGeneration())
                return store.canPrepare(display)
            }
            store.prepare(display)
            precondition(store.phase == .confirming)
            try Data().write(to: directory.appendingPathComponent("ready-" + args[3]))
            try waitUntil("start signal") { files.fileExists(atPath: directory.appendingPathComponent("go").path) }
            if let attempt = store.begin(display) {
                try Data(attempt.key.uuidString.utf8).write(to: directory.appendingPathComponent("winner-" + args[3]))
                // Exit before receiving an outcome, just as an interrupted app would.
            }
            return
        }

        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        for round in 0..<8 {
            let directory = root.appendingPathComponent(String(round))
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            var workers: [Process] = []
            defer { for worker in workers where worker.isRunning { worker.terminate() } }
            for index in 0..<12 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: args[0])
                process.arguments = ["--confirm", directory.path, String(index)]
                try process.run()
                workers.append(process)
            }
            try waitUntil("all confirmations to open") {
                try files.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ready-") }.count
                    == workers.count
            }
            try Data().write(to: directory.appendingPathComponent("go"))
            try waitUntil("workers to exit") { workers.allSatisfy { !$0.isRunning } }
            precondition(workers.allSatisfy { $0.terminationStatus == 0 })
            let winners = try files.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("winner-") }
            precondition(winners.count == 1, "Expected exactly one accepted confirmation in round \(round)")
            let key = try String(contentsOf: directory.appendingPathComponent(winners[0]), encoding: .utf8)
            let recovered = UsageResets(file: directory.appendingPathComponent("pending"))
            let display = fixture()
            precondition(recovered.phase == .uncertain)
            recovered.prepare(display)
            precondition(recovered.begin(display)?.key.uuidString == key, "Relaunch changed the pending reset identity")
            recovered.finish(.reset, reading: display.reading)
            precondition(!recovered.canPrepare(display), "Successful claim allowed the same balance to be spent again")
        }
        print(
            "Reset contention passed: 8 races with 12 processes, one accepted confirmation and one recovered key per race."
        )
    }

    static func waitUntil(_ label: String, _ ready: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while try !ready() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw NSError(
                    domain: "ResetContentionChecks", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for " + label])
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func fixture() -> QuotaDisplay {
        let now = Date()
        let reading = QuotaReading(
            fetchedAt: now, windows: [.init(minutes: 10080, remaining: 50, resetsAt: nil)],
            resetCredits: .init(availableCount: 2), resetCountOnlyFingerprint: "fixture-account")
        return QuotaDisplay(reading: reading, now: now, failed: false, refreshing: false)
    }
}
