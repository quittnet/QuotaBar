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
        func detailed(_ ids: [String], count: Int = 2, date: Date = Date(), account: String? = "fixture") throws
            -> QuotaDisplay
        {
            let rows = ids.map { ["id": $0, "resetType": "codexRateLimits", "status": "available"] }
            let data = try JSONSerialization.data(withJSONObject: [
                "accountId": account as Any, "rateLimits": ["primary": ["usedPercent": 70]],
                "rateLimitResetCredits": ["availableCount": count, "credits": rows],
            ])
            let reading = try JSONDecoder().decode(RateLimitsResponse.self, from: data).reading(fetchedAt: date)
            return .init(reading: reading, now: date, failed: false, refreshing: false)
        }
        let before = try detailed(["A", "B"])
        let missingAccount = try detailed(["A", "B"], account: nil)
        precondition(!detailedStore.canPrepare(missingAccount), "A named credit requires a verified owner")
        detailedStore.prepare(before)
        precondition(detailedStore.begin(missingAccount) == nil)
        detailedStore.prepare(before)
        let namedAttempt = try require(detailedStore.begin(before))
        precondition(
            namedAttempt.creditID == "A" && namedAttempt.accountFingerprint == before.reading?.resetAccountFingerprint)
        detailedStore.finish(.unknown, reading: before.reading)
        let pendingNamed = UsageResets(file: detailFile)
        let otherAccount = try detailed(["A", "B"], account: "another")
        precondition(!pendingNamed.canPrepare(missingAccount) && !pendingNamed.canPrepare(otherAccount))
        pendingNamed.prepare(before)
        precondition(pendingNamed.begin(before) == namedAttempt)
        let unboundFile = dir.appendingPathComponent("legacy-pending.json")
        let legacyRecord = try JSONEncoder().encode(
            ResetAttempt(key: UUID(), creditID: "A", accountFingerprint: nil, startingCount: 2))
        try legacyRecord.write(to: unboundFile)
        let unboundStore = UsageResets(file: unboundFile)
        for display in [missingAccount, before] {
            unboundStore.received(display.reading!)
            precondition(unboundStore.isRetry && !unboundStore.canPrepare(display))
            unboundStore.prepare(display)
            precondition(unboundStore.begin(display) == nil)
        }
        let retainedRecord = try Data(contentsOf: unboundFile)
        precondition(unboundStore.phase == .uncertain && retainedRecord == legacyRecord)
        pendingNamed.finish(.reset, reading: before.reading)
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
        try checkBalancePolling(in: dir)
        try checkManualRecovery(in: dir)
        print(
            "Reset confirmation, cancellation, double-click, relaunch, account switch, polling budget and clean failures passed."
        )
    }

    @MainActor static func checkBalancePolling(in dir: URL) throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let file = dir.appendingPathComponent("polling-reset.json")
        let receipt = file.appendingPathExtension("completed")
        func saveReceipt(account: String?, at time: Date) throws {
            try JSONSerialization.data(withJSONObject: [
                "account": account as Any, "count": 3, "time": time.timeIntervalSinceReferenceDate,
            ]).write(to: receipt)
        }
        func reading(at now: Date, account: String? = "sample", count: Int = 3) -> QuotaReading {
            .init(
                fetchedAt: now, windows: [.init(minutes: 300, remaining: 64, resetsAt: nil)],
                resetCredits: .init(availableCount: count), resetCountOnlyFingerprint: account)
        }

        try saveReceipt(account: "sample", at: time)
        let store = UsageResets(file: file)
        let report = reading(at: time)
        store.received(report)
        for age in [0.0, 15, 30, 44] {
            let now = time.addingTimeInterval(age)
            let poll = try require(store.nextBalancePoll(for: report, at: now))
            precondition(poll.fireDate(at: now) == now.addingTimeInterval(15))
            precondition(poll.fireDate(at: time.addingTimeInterval(-1)) == nil)
            precondition(poll.fireDate(at: time.addingTimeInterval(60)) == nil, "Sleep must not extend polling")
        }
        for age in [-1.0, 45, 60, 3600] {
            precondition(store.nextBalancePoll(for: report, at: time.addingTimeInterval(age)) == nil)
        }
        for age in [14, 29, 44] {
            let restarted = UsageResets(file: file)
            var now = time.addingTimeInterval(Double(age))
            let fresh = reading(at: now)
            restarted.received(fresh)
            var observed: [Int] = []
            while let poll = restarted.nextBalancePoll(for: fresh, at: now) {
                let next = try require(poll.fireDate(at: now))
                precondition(next > now && next < time.addingTimeInterval(60))
                observed.append(Int(next.timeIntervalSince(time)))
                now = next
            }
            precondition(observed == Array(stride(from: age + 15, to: 60, by: 15)))
        }
        print("Reset store relaunch at +14s, +29s and +44s: all fast checks expired before +60s.")
        for account in ["other", nil] {
            let otherReport = reading(at: time, account: account)
            store.received(otherReport)
            precondition(store.nextBalancePoll(for: otherReport, at: time) == nil)
            precondition(FileManager.default.fileExists(atPath: receipt.path))
        }

        let relaunched = UsageResets(file: file)
        let later = time.addingTimeInterval(180)
        let unchanged = reading(at: later)
        relaunched.received(unchanged)
        let unchangedDisplay = QuotaDisplay(reading: unchanged, now: later, failed: false, refreshing: false)
        precondition(relaunched.nextBalancePoll(for: unchanged, at: later) == nil)
        precondition(relaunched.awaitingUpdatedBalance && !relaunched.canPrepare(unchangedDisplay))
        let changed = reading(at: later, count: 2)
        relaunched.received(changed)
        let changedDisplay = QuotaDisplay(reading: changed, now: later, failed: false, refreshing: false)
        precondition(relaunched.canPrepare(changedDisplay) && !FileManager.default.fileExists(atPath: receipt.path))

        try saveReceipt(account: nil, at: time)
        let unbound = UsageResets(file: file)
        unbound.received(report)
        precondition(unbound.awaitingUpdatedBalance && unbound.nextBalancePoll(for: report, at: time) == nil)
    }

    @MainActor static func checkManualRecovery(in dir: URL) throws {
        let files = FileManager.default
        let old = Date().addingTimeInterval(-10)
        func display(_ owner: String? = "A", _ fetched: Date? = nil) -> QuotaDisplay {
            let reading = QuotaReading(
                fetchedAt: fetched ?? old, windows: [.init(minutes: 300, remaining: 5, resetsAt: nil)],
                resetCredits: .init(availableCount: 2), resetCountOnlyFingerprint: owner)
            return QuotaDisplay(reading: reading, now: max(Date(), reading.fetchedAt), failed: false, refreshing: false)
        }
        func refuses(_ work: () throws -> Void, line: UInt = #line) {
            do { try work() } catch { return }
            preconditionFailure("Unsafe recovery accepted at line " + String(line))
        }
        func mode(_ url: URL) throws -> Int { try files.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int }
        func record(_ account: String) -> [String: Any] {
            ["account": account, "count": 2, "time": old.timeIntervalSinceReferenceDate]
        }

        let pending = dir.appendingPathComponent("recovery-pending")
        let first = UsageResets(file: pending)
        let staleWindow = UsageResets(file: pending)
        let startedBefore = staleWindow.readGeneration()
        staleWindow.prepare(display())
        first.prepare(display())
        let attempt = try require(first.begin(display()))
        let recovering = UsageResets(file: pending)
        refuses { _ = try recovering.reviewRecovery(display()) }
        first.finish(.unknown, reading: display().reading)
        refuses { _ = try recovering.reviewRecovery(display("B")) }
        let review = try recovering.reviewRecovery(display())
        let competitor = UsageResets(file: pending)
        competitor.prepare(display())
        precondition(competitor.begin(display()) == attempt)
        refuses { _ = try recovering.recover(review, display: display()) }
        competitor.finish(.unknown, reading: display().reading)
        let bytes = try Data(contentsOf: pending)
        try bytes.write(to: pending, options: .atomic)
        refuses { _ = try recovering.recover(review, display: display()) }
        let archive = try recovering.recover(recovering.reviewRecovery(display()), display: display())
        let archivedPending = archive.appendingPathComponent(pending.lastPathComponent)
        let archivedBytes = try Data(contentsOf: archivedPending)
        let archiveMode = try mode(archive)
        let fileMode = try mode(archivedPending)
        precondition(archivedBytes == bytes && archiveMode == 0o700 && fileMode == 0o600)
        precondition(!files.fileExists(atPath: pending.path) && !recovering.canPrepare(display()))
        let fresh = display("A", Date().addingTimeInterval(1))
        // An old open confirmation cannot be reused, even if paired with a fresh display.
        precondition(staleWindow.begin(fresh) == nil && !files.fileExists(atPath: pending.path))
        let reopened = UsageResets(file: pending)
        precondition(!reopened.canPrepare(display()) && !reopened.canPrepare(display(nil, fresh.now)))
        reopened.received(fresh.reading!, generation: startedBefore)
        precondition(!reopened.canPrepare(fresh), "An old in-flight fetch stays ineligible after a clock change")
        reopened.received(fresh.reading!, generation: reopened.readGeneration())
        reopened.prepare(fresh)
        let next = try require(reopened.begin(fresh))
        precondition(next.key != attempt.key)
        reopened.finish(.failedBeforeSending, reading: fresh.reading)
        let freshFile = UsageResets(file: pending)
        precondition(!freshFile.canPrepare(display()))

        let receiptBase = dir.appendingPathComponent("recovery-accounts")
        let receipts = receiptBase.appendingPathExtension("completed")
        let original = try JSONSerialization.data(withJSONObject: [record("A"), record("B")])
        try original.write(to: receipts)
        let multi = UsageResets(file: receiptBase)
        multi.received(display().reading!)
        precondition(multi.canReviewRecovery(display()))
        let scoped = try multi.reviewRecovery(display())
        refuses { _ = try multi.recover(scoped, display: display("B")) }
        let saved = try multi.recover(scoped, display: display())
        let archived = try Data(contentsOf: saved.appendingPathComponent(receipts.lastPathComponent))
        precondition(archived == original)
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: receipts)) as! [[String: Any]]
        precondition(remaining.count == 1 && remaining[0]["account"] as? String == "B")
        let later = display("B", Date().addingTimeInterval(2))
        multi.received(later.reading!)
        precondition(multi.awaitingUpdatedBalance && !multi.canPrepare(later))

        let broken = dir.appendingPathComponent("recovery-malformed")
        let brokenReceipts = broken.appendingPathExtension("completed")
        let mixed = try JSONSerialization.data(withJSONObject: [record("B"), ["damaged": true] as [String: Any]])
        try mixed.write(to: brokenReceipts)
        let corrupt = UsageResets(file: broken)
        precondition(corrupt.phase == .storageUnavailable)
        let corruptArchive = try corrupt.recover(corrupt.reviewRecovery(display()), display: display())
        let recovered = try Data(contentsOf: corruptArchive.appendingPathComponent(brokenReceipts.lastPathComponent))
        precondition(recovered == mixed)
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: brokenReceipts)) as! [[String: Any]]
        precondition(kept.count == 1 && kept[0]["account"] as? String == "B")
        for (i, data) in [Data(), Data("unreadable json".utf8), Data(repeating: 0x20, count: 1_048_577)].enumerated() {
            let path = dir.appendingPathComponent("corrupt-pending-\(i)")
            try data.write(to: path)
            let store = UsageResets(file: path)
            let folder = try store.recover(store.reviewRecovery(display()), display: display())
            let copy = try Data(contentsOf: folder.appendingPathComponent(path.lastPathComponent))
            precondition(copy == data && !store.canPrepare(display()) && !files.fileExists(atPath: path.path))
        }
        let future = try JSONEncoder().encode(["time": Date().addingTimeInterval(7200).timeIntervalSinceReferenceDate])
        var futureJSON = try JSONSerialization.jsonObject(with: future) as! [String: Any]
        futureJSON["generation"] = UUID().uuidString
        let wrongDate = try JSONSerialization.data(withJSONObject: futureJSON)
        // Another writer can leave a damaged record after the app has shown the confirmation.
        // A failed begin must expose recovery immediately, without a restart or a provider claim.
        for (index, records) in [
            ("", Data("malformed".utf8)), ("completed", Data("malformed".utf8)),
            ("recovery", Data("malformed".utf8)), ("recovery", wrongDate),
        ].enumerated() {
            let path = dir.appendingPathComponent("damaged-after-confirmation-\(index)")
            let (suffix, contents) = records
            let record = suffix.isEmpty ? path : path.appendingPathExtension(suffix)
            let store = UsageResets(file: path)
            store.prepare(display())
            precondition(store.phase == .confirming)
            try contents.write(to: record)
            precondition(store.begin(display()) == nil)
            precondition(store.phase == .storageUnavailable && store.canReviewRecovery(display()))
            store.received(display().reading!)
            let reviewed = try store.reviewRecovery(display())
            let saved = try store.recover(reviewed, display: display())
            let stored = try Data(contentsOf: saved.appendingPathComponent(record.lastPathComponent))
            precondition(stored == contents && !store.canPrepare(display()))
        }
        let oversizedFence = Data(repeating: 0x5a, count: 8 * 1024 * 1024 + 1)
        for (index, bytes) in [Data(), Data("malformed".utf8), wrongDate, oversizedFence].enumerated() {
            let path = dir.appendingPathComponent("fence-repair-\(index)")
            let fence = path.appendingPathExtension("recovery")
            try bytes.write(to: fence)
            if index == 1 { try original.write(to: path.appendingPathExtension("completed")) }
            var before = stat()
            precondition(lstat(fence.path, &before) == 0)
            let store = UsageResets(file: path)
            precondition(
                store.phase == .storageUnavailable && !store.canPrepare(display()) && store.canReviewRecovery(display())
            )
            let priorRead = store.readGeneration()
            let archive = try store.recover(store.reviewRecovery(display()), display: display())
            let originalFence = try Data(contentsOf: archive.appendingPathComponent(fence.lastPathComponent))
            var archived = stat()
            precondition(lstat(archive.appendingPathComponent(fence.lastPathComponent).path, &archived) == 0)
            precondition(
                originalFence == bytes && archived.st_ino == before.st_ino && archived.st_mode & 0o777 == 0o600)
            if index == 1 {
                let unchanged = try Data(contentsOf: path.appendingPathExtension("completed"))
                precondition(unchanged == original)
            }
            let observed = display("C", Date().addingTimeInterval(5))
            store.received(observed.reading!, generation: priorRead)
            precondition(!store.canPrepare(observed))
            store.received(observed.reading!, generation: store.readGeneration())
            precondition(store.canPrepare(observed))
        }
        let largeReceiptPath = dir.appendingPathComponent("oversized-receipt")
        let largeReceipt = largeReceiptPath.appendingPathExtension("completed")
        try oversizedFence.write(to: largeReceipt)
        let largeReceiptStore = UsageResets(file: largeReceiptPath)
        do {
            _ = try largeReceiptStore.reviewRecovery(display())
            preconditionFailure("An opaque oversized receipt must not reach recovery confirmation")
        } catch {
            precondition(error.localizedDescription.contains("too large"))
        }
        precondition(!files.fileExists(atPath: largeReceiptPath.appendingPathExtension("recovery").path))
        let unchangedLargeReceipt = try Data(contentsOf: largeReceipt)
        precondition(unchangedLargeReceipt == oversizedFence)
        let unsafe = dir.appendingPathComponent("recovery-hardlink")
        try files.linkItem(at: receipts, to: unsafe)
        let unsafeStore = UsageResets(file: unsafe)
        refuses { _ = try unsafeStore.reviewRecovery(display()) }
        try files.removeItem(at: unsafe)
        try files.createSymbolicLink(at: unsafe, withDestinationURL: receipts)
        refuses { _ = try unsafeStore.reviewRecovery(display()) }
        let safe = try JSONSerialization.jsonObject(with: Data(contentsOf: receipts)) as! [[String: Any]]
        precondition(safe.first?["account"] as? String == "B")
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}
