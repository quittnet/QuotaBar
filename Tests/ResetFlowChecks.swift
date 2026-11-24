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
        precondition(!store.canPrepare(valid), "New confirmations require a read from this store")
        store.received(valid.reading!, generation: store.readGeneration())

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
        secondWindow.received(valid.reading!, generation: secondWindow.readGeneration())
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
            let previousConfirmation = resumed.confirmationGeneration
            resumed.prepare(valid)
            precondition(resumed.confirmationGeneration != previousConfirmation)
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
        observer.received(switched.reading!, generation: observer.readGeneration())
        precondition(
            observer.phase == .ready && observer.canPrepare(switched), "Another process completed this pending request")
        resumed.received(display(3, account: nil, observedAt: refreshed).reading!, generation: resumed.readGeneration())
        precondition(resumed.needsCountOnlyIdentityRefresh && !resumed.canPrepare(valid))
        resumed.received(display(2, observedAt: refreshed).reading!, generation: resumed.readGeneration())
        precondition(resumed.canPrepare(display(2, observedAt: refreshed)) && !resumed.needsCountOnlyIdentityRefresh)

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
        // A terminal outcome belongs to the account that requested it, even after its receipt settles.
        for outcome in [QuotaResetClaimResult.reset, .noCredit, .nothingToReset] {
            for nextOwner: String? in ["other-user", nil] {
                let local = UsageResets(file: dir.appendingPathComponent(UUID().uuidString))
                let before = display(2, account: "owner", observedAt: Date())
                local.received(before.reading!, generation: local.readGeneration())
                local.prepare(before)
                _ = try require(local.begin(before))
                local.finish(outcome, reading: before.reading)
                precondition(
                    local.needsCountOnlyIdentityRefresh, "Verify the owner even when the new balance is zero")
                let own = display(1, account: "owner", observedAt: Date())
                local.received(own.reading!, generation: local.readGeneration())
                precondition(
                    !local.awaitingUpdatedBalance && local.notice != nil
                        && !local.needsCountOnlyIdentityRefresh)
                let other = display(0, account: nextOwner, observedAt: Date())
                local.received(other.reading!, generation: local.readGeneration())
                precondition(local.notice == nil, "The next user saw the previous account’s reset outcome")
            }
        }
        let detailFile = dir.appendingPathComponent("detailed.json")
        let detailedStore = UsageResets(file: detailFile)
        func detailed(
            _ ids: [String], redeemed: [String] = [], count: Int = 2, date: Date = Date(), account: String? = "fixture"
        ) throws
            -> QuotaDisplay
        {
            let rows =
                ids.map { ["id": $0, "resetType": "codexRateLimits", "status": "available"] }
                + redeemed.map { ["id": $0, "resetType": "codexRateLimits", "status": "redeemed"] }
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
        detailedStore.received(before.reading!, generation: detailedStore.readGeneration())
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
            unboundStore.received(display.reading!, generation: unboundStore.readGeneration())
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
            detailObserver.received(unchanged.reading!, generation: detailObserver.readGeneration())
            precondition(!detailObserver.canPrepare(unchanged), "Reordered or capped details cannot confirm removal")
        }
        let replaced = try detailed(["B", "C"], date: after)
        detailObserver.received(replaced.reading!, generation: detailObserver.readGeneration())
        precondition(detailObserver.canPrepare(replaced), "A complete list confirms removal even at the same count")
        let cappedFile = dir.appendingPathComponent("capped-credits.json")
        let capped = UsageResets(file: cappedFile)
        capped.received(before.reading!, generation: capped.readGeneration())
        capped.prepare(before)
        precondition(capped.begin(before)?.creditID == "A")
        capped.finish(.reset, reading: before.reading)
        let spent = try detailed(["B"], redeemed: ["A"], date: after)
        let reopened = UsageResets(file: cappedFile)
        reopened.received(spent.reading!, generation: reopened.readGeneration())
        precondition(reopened.canPrepare(spent) && !reopened.awaitingUpdatedBalance)
        reopened.prepare(spent)
        precondition(reopened.begin(spent)?.creditID == "B")
        reopened.finish(.nothingToReset, reading: spent.reading)
        let receiptFile = dir.appendingPathComponent("account-receipts.json")
        let accountStore = UsageResets(file: receiptFile)
        accountStore.received(valid.reading!, generation: accountStore.readGeneration())
        accountStore.prepare(valid)
        precondition(accountStore.begin(display(4)) == nil, "A changed balance requires a new confirmation")
        accountStore.prepare(valid)
        precondition(accountStore.begin(valid) != nil)
        // An intervening refresh must not replace the starting balance committed with the idempotency key.
        accountStore.finish(.reset, reading: display(2).reading)
        let later = now.addingTimeInterval(3600)
        let unchangedA = display(3, observedAt: later)
        accountStore.received(unchangedA.reading!, generation: accountStore.readGeneration())
        precondition(accountStore.awaitingUpdatedBalance && !accountStore.canPrepare(unchangedA))
        let otherB = display(4, account: "account-B", observedAt: later)
        accountStore.received(otherB.reading!, generation: accountStore.readGeneration())
        precondition(accountStore.canPrepare(otherB))
        accountStore.prepare(otherB)
        precondition(accountStore.begin(otherB) != nil)
        accountStore.finish(.reset, reading: otherB.reading)
        let multiAccount = UsageResets(file: receiptFile)
        multiAccount.received(unchangedA.reading!, generation: multiAccount.readGeneration())
        precondition(multiAccount.awaitingUpdatedBalance && !multiAccount.canPrepare(unchangedA))
        let increasedA = display(5, observedAt: later)
        multiAccount.received(increasedA.reading!, generation: multiAccount.readGeneration())
        precondition(multiAccount.canPrepare(increasedA))
        multiAccount.received(otherB.reading!, generation: multiAccount.readGeneration())
        precondition(multiAccount.awaitingUpdatedBalance && !multiAccount.canPrepare(otherB))
        let changedB = display(3, account: "account-B", observedAt: later)
        multiAccount.received(changedB.reading!, generation: multiAccount.readGeneration())
        precondition(multiAccount.canPrepare(changedB))
        let verified = UsageResets(file: receiptFile)
        precondition(!verified.canPrepare(unchangedA), "A relaunched instance needs its own balance read")
        verified.received(unchangedA.reading!, generation: verified.readGeneration())
        precondition(verified.canPrepare(unchangedA), "Returning to a previously confirmed count must stay eligible")

        // Existing installations stored one receipt in an object, and pending requests had no starting count.
        let legacy = receiptFile.appendingPathExtension("completed")
        try JSONSerialization.data(withJSONObject: [
            "account": "sample", "count": 3, "time": now.timeIntervalSinceReferenceDate,
        ]).write(to: legacy)
        let originalVersion = UsageResets(file: receiptFile)
        originalVersion.received(unchangedA.reading!, generation: originalVersion.readGeneration())
        precondition(originalVersion.awaitingUpdatedBalance)
        originalVersion.received(increasedA.reading!, generation: originalVersion.readGeneration())
        precondition(originalVersion.canPrepare(increasedA) && !originalVersion.awaitingUpdatedBalance)
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
        unsafeLock.received(valid.reading!, generation: unsafeLock.readGeneration())
        unsafeLock.prepare(valid)
        precondition(unsafeLock.begin(valid) == nil && unsafeLock.phase == .ready)
        let preservedContents = try Data(contentsOf: lockTarget)
        precondition(preservedContents == targetContents)
        let fifoLockFile = dir.appendingPathComponent("fifo-lock.json")
        precondition(mkfifo(fifoLockFile.appendingPathExtension("lock").path, 0o600) == 0)
        let fifoLock = UsageResets(file: fifoLockFile)
        fifoLock.received(valid.reading!, generation: fifoLock.readGeneration())
        fifoLock.prepare(valid)
        precondition(fifoLock.begin(valid) == nil && fifoLock.phase == .ready)
        try checkPendingRefresh(in: dir, original: valid, other: display(3, account: "other"))
        try checkInterruptedCompletion(in: dir, original: valid)
        try checkReconciledGenerations(in: dir)
        try checkBalancePolling(in: dir)
        try checkManualRecovery(in: dir)
        print(
            "Reset confirmation, cancellation, double-click, relaunch, account switch, polling budget and clean failures passed."
        )
    }

    @MainActor static func checkPendingRefresh(in dir: URL, original: QuotaDisplay, other: QuotaDisplay) throws {
        let file = dir.appendingPathComponent("concurrent-pending.json")
        let writer = UsageResets(file: file)
        let observer = UsageResets(file: file)
        observer.received(other.reading!, generation: observer.readGeneration())
        precondition(observer.canPrepare(other))

        writer.received(original.reading!, generation: writer.readGeneration())
        writer.prepare(original)
        let request = try require(writer.begin(original))
        writer.finish(.unknown, reading: original.reading)

        observer.received(other.reading!, generation: observer.readGeneration())
        precondition(observer.phase == .uncertain, "A fresh balance must surface another instance’s pending reset")
        precondition(observer.isRetry && !observer.canPrepare(other) && !observer.canReviewRecovery(other))
        let switchNotice = observer.notice
        let relaunched = UsageResets(file: file)
        let retryNotice = relaunched.notice
        precondition(switchNotice != nil && retryNotice != nil && switchNotice != retryNotice)
        writer.prepare(original)
        precondition(writer.begin(original) == request)
        observer.received(original.reading!, generation: observer.readGeneration())
        precondition(observer.canReviewRecovery(original) && observer.notice == retryNotice)
        observer.prepare(original)
        precondition(observer.begin(original) == nil, "Account verification must still respect another window's lock")
        writer.finish(.unknown, reading: original.reading)
        let unknownOwner = QuotaReading(
            fetchedAt: original.now, windows: original.reading!.windows, resetCredits: .init(availableCount: 2))
        let unidentified = QuotaDisplay(reading: unknownOwner, now: original.now, failed: false, refreshing: false)
        relaunched.received(unknownOwner, generation: relaunched.readGeneration())
        precondition(relaunched.notice != nil && relaunched.notice != retryNotice && relaunched.notice != switchNotice)
        precondition(!relaunched.canPrepare(unidentified) && !relaunched.canReviewRecovery(unidentified))
        relaunched.received(original.reading!, generation: relaunched.readGeneration())
        precondition(relaunched.notice == retryNotice && relaunched.canPrepare(original))
        observer.prepare(original)
        observer.cancel()
        precondition(observer.phase == .uncertain && observer.isRetry)
        observer.prepare(original)
        precondition(observer.begin(original) == request)
        observer.finish(.unavailable, reading: original.reading)
        let updateNotice = observer.notice
        precondition(updateNotice != nil && updateNotice != retryNotice)
        observer.received(other.reading!, generation: observer.readGeneration())
        precondition(observer.notice == switchNotice && !observer.canPrepare(other))
        observer.received(original.reading!, generation: observer.readGeneration())
        precondition(observer.notice == updateNotice && observer.canPrepare(original))
        observer.prepare(original)
        precondition(observer.begin(original) == request)
        observer.finish(.accountChanged, reading: original.reading)
        precondition(observer.notice == switchNotice)
        observer.received(original.reading!, generation: observer.readGeneration())
        precondition(observer.notice == retryNotice && observer.canPrepare(original))
        observer.prepare(original)
        precondition(observer.begin(original) == request)
        observer.finish(.nothingToReset, reading: original.reading)

        writer.received(other.reading!, generation: writer.readGeneration())
        precondition(writer.phase == .ready && !writer.isRetry && writer.canPrepare(other))
    }

    @MainActor static func checkInterruptedCompletion(in dir: URL, original: QuotaDisplay) throws {
        let file = dir.appendingPathComponent("interrupted-completion")
        let history = file.appendingPathExtension("completed")
        let writer = UsageResets(file: file)
        let reading = try require(original.reading)
        writer.received(reading, generation: writer.readGeneration())
        writer.prepare(original)
        let request = try require(writer.begin(original))
        let pendingBytes = try Data(contentsOf: file)
        writer.finish(.unknown, reading: reading)
        let observer = UsageResets(file: file)
        observer.received(reading, generation: observer.readGeneration())
        observer.prepare(original)
        let cleanObserver = UsageResets(file: file)
        cleanObserver.received(reading, generation: cleanObserver.readGeneration())
        cleanObserver.prepare(original)
        writer.prepare(original)
        precondition(writer.begin(original) == request)
        writer.finish(.reset, reading: reading)
        precondition(cleanObserver.begin(original) == nil && cleanObserver.awaitingUpdatedBalance)
        precondition(!cleanObserver.isRetry && !cleanObserver.canPrepare(original))
        let receiptBytes = try Data(contentsOf: history)

        // Recreate the two durable files from immediately before the pending record was removed.
        try pendingBytes.write(to: file, options: .atomic)
        precondition(observer.begin(original) == nil, "An open confirmation replayed a recorded success")
        try pendingBytes.write(to: file, options: .atomic)
        let relaunched = UsageResets(file: file)
        precondition(relaunched.awaitingUpdatedBalance && !relaunched.isRetry && !relaunched.canPrepare(original))
        let preserved = try Data(contentsOf: history)
        precondition(preserved == receiptBytes && !FileManager.default.fileExists(atPath: file.path))

        let other = ResetAttempt(
            key: UUID(), creditID: request.creditID, accountFingerprint: request.accountFingerprint,
            startingCount: request.startingCount)
        try JSONEncoder().encode(other).write(to: file, options: .atomic)
        let uncertain = UsageResets(file: file)
        uncertain.prepare(original)
        precondition(uncertain.begin(original) == other, "A separate pending request lost its original retry")
        uncertain.finish(.unknown, reading: reading)
    }

    @MainActor static func checkReconciledGenerations(in dir: URL) throws {
        let file = dir.appendingPathComponent("generation.json")
        let writer = UsageResets(file: file)
        let openConfirmation = UsageResets(file: file)
        let lateReader = UsageResets(file: file)
        let otherOwner = UsageResets(file: file)
        let date = Date().addingTimeInterval(1)
        func display(_ count: Int, _ owner: String = "A", at observed: Date? = nil) -> QuotaDisplay {
            let date = observed ?? date
            let reading = QuotaReading(
                fetchedAt: date, windows: [], resetCredits: .init(availableCount: count),
                resetAccountFingerprint: "shared-workspace", resetCountOnlyFingerprint: owner)
            return QuotaDisplay(reading: reading, now: date, failed: false, refreshing: false)
        }
        let two = display(2)
        let one = display(1)
        let other = display(2, "B")
        let beforeSpend = lateReader.readGeneration()
        openConfirmation.received(two.reading!, generation: openConfirmation.readGeneration())
        openConfirmation.prepare(two)
        otherOwner.received(other.reading!, generation: otherOwner.readGeneration())
        otherOwner.prepare(other)
        writer.received(two.reading!, generation: writer.readGeneration())
        writer.prepare(two)
        let first = try require(writer.begin(two))
        writer.finish(.reset, reading: two.reading)
        let beforeReconciliation = lateReader.readGeneration()
        lateReader.received(one.reading!, generation: beforeSpend)
        precondition(lateReader.awaitingUpdatedBalance && !lateReader.canPrepare(one))
        writer.received(one.reading!, generation: writer.readGeneration())
        precondition(writer.canPrepare(one) && !writer.awaitingUpdatedBalance)
        struct LegacyReceipt: Decodable {
            let count: Int
            let time: Date
        }
        // A v1.8.2 writer can already hold the reset lock when an upgraded instance starts.
        let firstReadFile = dir.appendingPathComponent("legacy-writer-first")
        let firstReadHistory = firstReadFile.appendingPathExtension("completed")
        let locked = UsageResets(file: firstReadFile)
        let lock = open(firstReadFile.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        precondition(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        let pending = try JSONEncoder().encode(
            ResetAttempt(
                key: UUID(), creditID: nil, accountFingerprint: "A", startingCount: 2))
        try pending.write(to: firstReadFile)
        let dropped = locked.readGeneration()
        let pendingAfterRead = try Data(contentsOf: firstReadFile)
        precondition(!FileManager.default.fileExists(atPath: firstReadHistory.path) && pendingAfterRead == pending)
        // The old process completely settles before the delayed quota response arrives.
        let legacyBytes = try JSONSerialization.data(withJSONObject: [
            "count": 2, "account": "A", "time": date.timeIntervalSinceReferenceDate,
        ])
        try legacyBytes.write(to: firstReadHistory)
        try FileManager.default.removeItem(at: firstReadFile)
        try FileManager.default.removeItem(at: firstReadHistory)
        close(lock)
        locked.received(two.reading!, generation: dropped)
        precondition(!locked.canPrepare(two))
        locked.prepare(two)
        precondition(locked.begin(two) == nil)
        let cleanGeneration = locked.readGeneration()
        let cleanMarker = try Data(contentsOf: firstReadHistory)
        precondition((try? JSONDecoder().decode([LegacyReceipt].self, from: cleanMarker)) == nil)
        precondition((try? JSONDecoder().decode(LegacyReceipt.self, from: cleanMarker)) == nil)
        var initial = stat()
        var subsequent = stat()
        precondition(lstat(firstReadHistory.path, &initial) == 0)
        precondition(locked.readGeneration() == cleanGeneration)
        precondition(lstat(firstReadHistory.path, &subsequent) == 0 && initial.st_ino == subsequent.st_ino)
        locked.received(two.reading!, generation: cleanGeneration)
        precondition(locked.canPrepare(two))
        // A removed and re-established marker must also invalidate an open confirmation.
        locked.prepare(two)
        try FileManager.default.removeItem(at: firstReadHistory)
        let replacement = UsageResets(file: firstReadFile)
        let replacementGeneration = replacement.readGeneration()
        precondition(replacementGeneration != cleanGeneration)
        precondition(locked.begin(two) == nil && !locked.canPrepare(two))
        locked.received(two.reading!, generation: cleanGeneration)
        precondition(!locked.canPrepare(two))
        locked.received(one.reading!, generation: replacementGeneration)
        precondition(locked.canPrepare(one))

        let recoveryFile = dir.appendingPathComponent("last-legacy-receipt")
        let receipt = recoveryFile.appendingPathExtension("completed")
        try legacyBytes.write(to: receipt)
        let recovery = UsageResets(file: recoveryFile)
        let beforeRecovery = recovery.readGeneration()
        recovery.received(two.reading!, generation: beforeRecovery)
        _ = try recovery.recover(recovery.reviewRecovery(two), display: two)
        precondition(!FileManager.default.fileExists(atPath: receipt.path))
        let afterRecovery = recovery.readGeneration()
        let recreated = try Data(contentsOf: receipt)
        precondition((try? JSONDecoder().decode(LegacyReceipt.self, from: recreated)) == nil)
        let postRecovery = display(1, at: Date().addingTimeInterval(1))
        recovery.received(postRecovery.reading!, generation: beforeRecovery)
        precondition(!recovery.canPrepare(postRecovery))
        recovery.received(postRecovery.reading!, generation: afterRecovery)
        precondition(recovery.canPrepare(postRecovery))

        let saved = try Data(contentsOf: file.appendingPathExtension("completed"))
        precondition((try? JSONDecoder().decode([LegacyReceipt].self, from: saved)) == nil)
        precondition((try? JSONDecoder().decode(LegacyReceipt.self, from: saved)) == nil)
        precondition(openConfirmation.begin(two) == nil && !openConfirmation.canPrepare(two))
        for generation in [beforeSpend, beforeReconciliation] {
            lateReader.received(two.reading!, generation: generation)
            precondition(
                !lateReader.canPrepare(two), "An old read arrived with a plausible balance after reconciliation")
        }
        precondition(!FileManager.default.fileExists(atPath: file.path))
        precondition(otherOwner.begin(other) != nil, "A different individual in the same workspace stayed current")
        otherOwner.finish(.nothingToReset, reading: other.reading)
        let restarted = UsageResets(file: file)
        precondition(!restarted.canPrepare(two))
        restarted.received(two.reading!, generation: restarted.readGeneration())
        restarted.prepare(two)
        let next = try require(restarted.begin(two))
        precondition(next.key != first.key, "A later grant is eligible after a fresh read and confirmation")
        restarted.finish(.unknown, reading: two.reading)
        let retry = UsageResets(file: file)
        retry.prepare(two)
        precondition(retry.begin(two) == next, "The uncertain retry must keep the original UUID across relaunch")
        retry.finish(.nothingToReset, reading: two.reading)

        // Salvaging an unrelated malformed row must preserve the upgraded owner's generation.
        let historyFile = file.appendingPathExtension("completed")
        let history = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        let originalRows = history["receipts"] as! [[String: Any]]
        let damaged = try JSONSerialization.data(withJSONObject: [
            "receipts": originalRows + [["damaged": true]]
        ])
        try damaged.write(to: historyFile)
        retry.received(two.reading!, generation: retry.readGeneration())
        precondition(retry.phase == .storageUnavailable)
        _ = try retry.recover(retry.reviewRecovery(two), display: two)
        let recovered = try JSONSerialization.jsonObject(with: Data(contentsOf: historyFile)) as! NSDictionary
        precondition((recovered["receipts"] as? NSArray)?.isEqual(to: originalRows) == true)

        let damagedHeader = try JSONSerialization.data(withJSONObject: ["id": "invalid", "receipts": originalRows])
        try damagedHeader.write(to: historyFile)
        let headerRepair = UsageResets(file: file)
        precondition(headerRepair.phase == .storageUnavailable)
        _ = try headerRepair.recover(headerRepair.reviewRecovery(two), display: two)
        let preserved = try receiptRows(at: historyFile)
        precondition((preserved as NSArray).isEqual(to: originalRows))

        for owner in ["A", nil] {
            let legacy = dir.appendingPathComponent("legacy-generation-" + (owner ?? "unbound"))
            let stale = UsageResets(file: legacy)
            stale.received(two.reading!, generation: stale.readGeneration())
            stale.prepare(two)
            try JSONSerialization.data(withJSONObject: [
                "account": owner as Any, "count": 2, "time": date.timeIntervalSinceReferenceDate,
            ]).write(to: legacy.appendingPathExtension("completed"))
            let upgrader = UsageResets(file: legacy)
            upgrader.received(one.reading!, generation: upgrader.readGeneration())
            precondition(upgrader.canPrepare(one) && !upgrader.awaitingUpdatedBalance)
            precondition(stale.begin(two) == nil, "Migrating a legacy receipt must invalidate earlier confirmations")
        }
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
        store.received(report, generation: store.readGeneration())
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
            restarted.received(fresh, generation: restarted.readGeneration())
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
            store.received(otherReport, generation: store.readGeneration())
            precondition(store.nextBalancePoll(for: otherReport, at: time) == nil)
            precondition(FileManager.default.fileExists(atPath: receipt.path))
        }

        let relaunched = UsageResets(file: file)
        let later = time.addingTimeInterval(180)
        let unchanged = reading(at: later)
        relaunched.received(unchanged, generation: relaunched.readGeneration())
        let unchangedDisplay = QuotaDisplay(reading: unchanged, now: later, failed: false, refreshing: false)
        precondition(relaunched.nextBalancePoll(for: unchanged, at: later) == nil)
        precondition(relaunched.awaitingUpdatedBalance && !relaunched.canPrepare(unchangedDisplay))
        let changed = reading(at: later, count: 2)
        relaunched.received(changed, generation: relaunched.readGeneration())
        let changedDisplay = QuotaDisplay(reading: changed, now: later, failed: false, refreshing: false)
        precondition(relaunched.canPrepare(changedDisplay) && !relaunched.awaitingUpdatedBalance)

        try saveReceipt(account: nil, at: time)
        let unbound = UsageResets(file: file)
        unbound.received(report, generation: unbound.readGeneration())
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
        staleWindow.received(display().reading!, generation: staleWindow.readGeneration())
        staleWindow.prepare(display())
        first.received(display().reading!, generation: first.readGeneration())
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
        multi.received(display().reading!, generation: multi.readGeneration())
        precondition(multi.canReviewRecovery(display()))
        let migrated = try Data(contentsOf: receipts)
        let scoped = try multi.reviewRecovery(display())
        refuses { _ = try multi.recover(scoped, display: display("B")) }
        let saved = try multi.recover(scoped, display: display())
        let archived = try Data(contentsOf: saved.appendingPathComponent(receipts.lastPathComponent))
        precondition(archived == migrated)
        let remaining = try receiptRows(at: receipts)
        precondition(remaining.count == 1 && remaining[0]["account"] as? String == "B")
        let later = display("B", Date().addingTimeInterval(2))
        multi.received(later.reading!, generation: multi.readGeneration())
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
        let kept = try receiptRows(at: brokenReceipts)
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
            store.received(display().reading!, generation: store.readGeneration())
            store.prepare(display())
            precondition(store.phase == .confirming)
            try contents.write(to: record)
            precondition(store.begin(display()) == nil)
            precondition(store.phase == .storageUnavailable && store.canReviewRecovery(display()))
            store.received(display().reading!, generation: store.readGeneration())
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
        let safe = try receiptRows(at: receipts)
        precondition(safe.first?["account"] as? String == "B")
    }

    static func receiptRows(at url: URL) throws -> [[String: Any]] {
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return envelope["receipts"] as! [[String: Any]]
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}
