import Darwin
import Foundation

@main
enum ResetFlowChecks {
    @MainActor static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pending.json")
        let now = Date()
        func display(
            _ count: Int, account: String? = "sample", failed: Bool = false, observedAt: Date? = nil,
            shownAt: Date? = nil
        )
            -> QuotaDisplay
        {
            let data = QuotaReading(
                fetchedAt: observedAt ?? now, windows: [.init(minutes: 10080, remaining: 64, resetsAt: nil)],
                resetCredits: .init(availableCount: count), resetAccountFingerprint: "same-workspace",
                resetCountOnlyFingerprint: account)
            return .init(reading: data, now: shownAt ?? data.fetchedAt, failed: failed, refreshing: false)
        }
        let valid = display(3)
        let store = UsageResets(file: file)

        precondition(!store.canPrepare(display(0)) && !store.canPrepare(display(3, failed: true)))
        precondition(!store.canPrepare(display(3, account: nil)))
        precondition(!store.canPrepare(display(3, observedAt: now.addingTimeInterval(1), shownAt: now)))
        precondition(store.begin(valid) == nil)
        store.prepare(valid)
        store.cancel()
        precondition(store.phase == .ready && !FileManager.default.fileExists(atPath: file.path))
        store.prepare(valid)
        precondition(store.begin(display(3, account: "other")) == nil)
        precondition(store.phase == .ready)
        store.prepare(valid)
        let secondWindow = UsageResets(file: file)
        secondWindow.prepare(valid)
        let original = try require(store.begin(valid))
        precondition(store.begin(valid) == nil && !store.canPrepare(valid))
        let concurrent = UsageResets(file: file)
        concurrent.prepare(valid)
        precondition(concurrent.begin(valid) == nil)
        store.finish(.unknown, reading: valid.reading)
        precondition(store.phase == .uncertain)

        let observer = UsageResets(file: file)
        let resumed = UsageResets(file: file)
        precondition(
            resumed.phase == .uncertain && resumed.canPrepare(display(0)) && resumed.needsCountOnlyIdentityRefresh)
        precondition(!resumed.canPrepare(display(3, account: "other")))
        for failure in [QuotaResetClaimResult.failedBeforeSending, .accountChanged, .unavailable] {
            resumed.prepare(valid)
            precondition(resumed.begin(valid) == original)
            resumed.finish(failure, reading: valid.reading)
            precondition(resumed.phase == .uncertain && FileManager.default.fileExists(atPath: file.path))
        }
        resumed.prepare(valid)
        precondition(resumed.begin(valid) == original)
        resumed.finish(.reset, reading: valid.reading)
        precondition(resumed.phase == .ready && !FileManager.default.fileExists(atPath: file.path))
        precondition(resumed.needsCountOnlyIdentityRefresh && !resumed.canPrepare(valid))
        precondition(
            secondWindow.begin(valid) == nil, "A stale confirmation in another process can spend a second credit")
        let relaunched = UsageResets(file: file)
        precondition(relaunched.needsCountOnlyIdentityRefresh && !relaunched.canPrepare(valid))
        let refreshed = Date().addingTimeInterval(1)
        let switched = display(2, account: "other", observedAt: refreshed)
        observer.received(switched.reading!)
        precondition(
            observer.phase == .ready && observer.canPrepare(switched), "Another process completed this pending request")
        resumed.received(display(3, account: nil, observedAt: refreshed).reading!)
        precondition(resumed.needsCountOnlyIdentityRefresh && !resumed.canPrepare(valid))
        resumed.received(display(2, observedAt: refreshed).reading!)
        precondition(resumed.canPrepare(display(2)) && !resumed.needsCountOnlyIdentityRefresh)

        for outcome in [
            QuotaResetClaimResult.nothingToReset, .noCredit, .unavailable, .failedBeforeSending, .accountChanged,
        ] {
            let current = display(2, observedAt: refreshed)
            resumed.prepare(current)
            let newAttempt = try require(resumed.begin(current))
            precondition(newAttempt.key != original.key)
            resumed.finish(outcome, reading: valid.reading)
            precondition(resumed.phase == .ready && !FileManager.default.fileExists(atPath: file.path))
        }
        let detailFile = dir.appendingPathComponent("detailed.json")
        let detailedStore = UsageResets(file: detailFile)
        func detailed(_ ids: [String], count: Int = 2, date: Date = Date()) throws -> QuotaDisplay {
            let rows = ids.map { ["id": $0, "resetType": "codexRateLimits", "status": "available"] }
            let data = try JSONSerialization.data(withJSONObject: [
                "accountId": "fixture", "rateLimits": ["primary": ["usedPercent": 70]],
                "rateLimitResetCredits": ["availableCount": count, "credits": rows],
            ])
            let reading = try JSONDecoder().decode(RateLimitsResponse.self, from: data).reading(fetchedAt: date)
            return .init(reading: reading, now: date, failed: false, refreshing: false)
        }
        let before = try detailed(["A", "B"])
        detailedStore.prepare(before)
        precondition(detailedStore.begin(before)?.creditID == "A")
        detailedStore.finish(.reset, reading: before.reading)
        let detailObserver = UsageResets(file: detailFile)
        let after = Date().addingTimeInterval(1)
        for ids in [["B", "A"], ["B"]] {
            let unchanged = try detailed(ids, date: after)
            detailObserver.received(unchanged.reading!)
            precondition(!detailObserver.canPrepare(unchanged), "Reordered or capped details cannot confirm removal")
        }
        let replaced = try detailed(["B", "C"], date: after)
        detailObserver.received(replaced.reading!)
        precondition(detailObserver.canPrepare(replaced), "A complete list confirms removal even at the same count")
        let receiptFile = dir.appendingPathComponent("account-receipts.json")
        let accountStore = UsageResets(file: receiptFile)
        accountStore.prepare(valid)
        precondition(accountStore.begin(display(4)) == nil, "A changed balance requires a new confirmation")
        accountStore.prepare(valid)
        precondition(accountStore.begin(valid) != nil)
        // An intervening refresh must not replace the starting balance committed with the idempotency key.
        accountStore.finish(.reset, reading: display(2).reading)
        let later = now.addingTimeInterval(3600)
        let unchangedA = display(3, observedAt: later)
        accountStore.received(unchangedA.reading!)
        precondition(accountStore.awaitingUpdatedBalance && !accountStore.canPrepare(unchangedA))
        let otherB = display(4, account: "account-B", observedAt: later)
        accountStore.received(otherB.reading!)
        precondition(accountStore.canPrepare(otherB))
        accountStore.prepare(otherB)
        precondition(accountStore.begin(otherB) != nil)
        accountStore.finish(.reset, reading: otherB.reading)
        let multiAccount = UsageResets(file: receiptFile)
        multiAccount.received(unchangedA.reading!)
        precondition(multiAccount.awaitingUpdatedBalance && !multiAccount.canPrepare(unchangedA))
        let increasedA = display(5, observedAt: later)
        multiAccount.received(increasedA.reading!)
        precondition(multiAccount.canPrepare(increasedA))
        multiAccount.received(otherB.reading!)
        precondition(multiAccount.awaitingUpdatedBalance && !multiAccount.canPrepare(otherB))
        let changedB = display(3, account: "account-B", observedAt: later)
        multiAccount.received(changedB.reading!)
        precondition(multiAccount.canPrepare(changedB))
        let verified = UsageResets(file: receiptFile)
        precondition(verified.canPrepare(unchangedA), "Returning to a previously confirmed count must stay eligible")

        // Existing installations stored one receipt in an object, and pending requests had no starting count.
        let legacy = receiptFile.appendingPathExtension("completed")
        try JSONSerialization.data(withJSONObject: [
            "account": "sample", "count": 3, "time": now.timeIntervalSinceReferenceDate,
        ]).write(to: legacy)
        let originalVersion = UsageResets(file: receiptFile)
        originalVersion.received(unchangedA.reading!)
        precondition(originalVersion.awaitingUpdatedBalance)
        originalVersion.received(increasedA.reading!)
        precondition(originalVersion.canPrepare(increasedA) && !FileManager.default.fileExists(atPath: legacy.path))
        let legacyAttempt = try JSONDecoder().decode(
            ResetAttempt.self,
            from: Data(#"{"key":"205365b8-5110-4ff4-9301-54612cc1d002","accountFingerprint":"sample"}"#.utf8))
        precondition(legacyAttempt.startingCount == nil && legacyAttempt.accountFingerprint == "sample")
        let invalid = dir.appendingPathComponent("invalid-reset.json")
        let linkedReset = dir.appendingPathComponent("linked-reset.json")
        try Data(count: 1024 * 1024 + 1).write(to: invalid)
        precondition(UsageResets(file: invalid).phase == .storageUnavailable)
        try FileManager.default.createSymbolicLink(at: linkedReset, withDestinationURL: invalid)
        precondition(UsageResets(file: linkedReset).phase == .storageUnavailable)
        let fifo = dir.appendingPathComponent("reset-pipe.json")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        precondition(UsageResets(file: fifo).phase == .storageUnavailable)
        let unsafeLockFile = dir.appendingPathComponent("unsafe-lock.json")
        let lockTarget = dir.appendingPathComponent("lock-target")
        let targetContents = Data("keep existing file".utf8)
        try targetContents.write(to: lockTarget)
        try FileManager.default.createSymbolicLink(
            at: unsafeLockFile.appendingPathExtension("lock"), withDestinationURL: lockTarget)
        let unsafeLock = UsageResets(file: unsafeLockFile)
        unsafeLock.prepare(valid)
        precondition(unsafeLock.begin(valid) == nil && unsafeLock.phase == .ready)
        let preservedContents = try Data(contentsOf: lockTarget)
        precondition(preservedContents == targetContents)
        let fifoLockFile = dir.appendingPathComponent("fifo-lock.json")
        precondition(mkfifo(fifoLockFile.appendingPathExtension("lock").path, 0o600) == 0)
        let fifoLock = UsageResets(file: fifoLockFile)
        fifoLock.prepare(valid)
        precondition(fifoLock.begin(valid) == nil && fifoLock.phase == .ready)
        print(
            "Reset confirmation, cancellation, double-click, recovery after relaunch, account switch and clean failures passed."
        )
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}
