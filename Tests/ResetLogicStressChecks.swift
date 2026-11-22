import Foundation

// Headless model checking: only synthetic readings and a disposable directory are used.
// No QuotaSource calls, account credentials, app launch, or live reset claims.
@main
struct ResetLogicStressChecks {
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(bound))
        }
    }

    struct Input {
        var account: String? = "account-A"
        var count: Int? = 3
        var failed = false
        var refreshing = false
        var expired = false
        var futureDated = false
        var afterCompletion = true
        var missingReading = false

        var usable: Bool { !missingReading && !failed && !refreshing && !expired && !futureDated }
        var display: QuotaDisplay {
            let fetched = Date(timeIntervalSince1970: afterCompletion ? 4_102_444_800 : 946_684_800)
            let reading = QuotaReading(
                fetchedAt: fetched, windows: [.init(minutes: 300, remaining: 0, resetsAt: nil)],
                resetCredits: count.map { .init(availableCount: $0) }, resetCountOnlyFingerprint: account)
            return .init(
                reading: missingReading ? nil : reading,
                now: fetched.addingTimeInterval(expired ? QuotaDisplay.maximumAge : (futureDated ? -1 : 0)),
                failed: failed, refreshing: refreshing)
        }
    }

    // Deliberately model observable protocol rules, not production persistence helpers.
    struct Model {
        enum Phase: String { case ready, confirming, submitting, uncertain }
        struct Intent {
            let owner: String?
            let count: Int?
        }
        var phase = Phase.ready
        var pending: ResetAttempt?
        var selection: Intent?
        var receipts: [String: Int] = [:]
        var blockedByReceipt = false
        var retrying = false
        var seenKeys: Set<UUID> = []
        var lastRead: Input?

        func eligible(_ input: Input) -> Bool {
            guard input.usable, phase == .ready || phase == .uncertain else { return false }
            if let pending { return pending.accountFingerprint == input.account }
            guard let owner = input.account, !blockedByReceipt, (input.count ?? 0) > 0 else { return false }
            return lastRead?.account == owner && lastRead?.count == input.count
                && lastRead?.afterCompletion == input.afterCompletion
        }
        mutating func prepare(_ input: Input) {
            guard eligible(input) else { return }
            selection =
                pending.map { Intent(owner: $0.accountFingerprint, count: $0.startingCount) }
                ?? Intent(owner: input.account, count: input.count)
            phase = .confirming
        }
        mutating func cancel() {
            guard phase == .confirming else { return }
            selection = nil
            phase = pending == nil ? .ready : .uncertain
        }
        mutating func begin(_ input: Input, actual: ResetAttempt?, context: String) {
            guard phase == .confirming, let selection else {
                require(actual == nil, "unexpected dispatch", context)
                return
            }
            let accepted =
                input.usable && selection.owner == input.account
                && (pending != nil || (input.count == selection.count && (input.count ?? 0) > 0))
            guard accepted else {
                require(actual == nil, "invalid confirmation dispatched", context)
                cancel()
                return
            }
            guard let actual else { preconditionFailure("\(context): eligible dispatch rejected") }
            if let pending {
                require(actual == pending, "retry identity or original balance changed", context)
            } else {
                require(
                    actual.creditID == nil && actual.accountFingerprint == selection.owner
                        && actual.startingCount == selection.count, "wrong dispatch intent", context)
                require(seenKeys.insert(actual.key).inserted, "new request reused an old key", context)
            }
            retrying = pending != nil
            pending = actual
            phase = .submitting
        }
        mutating func finish(_ outcome: QuotaResetClaimResult) {
            guard phase == .submitting, let pending else { return }
            selection = nil
            if outcome == .unknown
                || (retrying && [.accountChanged, .unavailable, .failedBeforeSending].contains(outcome))
            {
                phase = .uncertain
                return
            }
            if outcome == .reset {
                receipts[pending.accountFingerprint!] = pending.startingCount!
                blockedByReceipt = true
            }
            self.pending = nil
            phase = .ready
        }
        mutating func restore() {
            lastRead = nil
            selection = nil
            phase = pending == nil ? .ready : .uncertain
            blockedByReceipt = pending == nil && !receipts.isEmpty
        }
        mutating func received(_ input: Input) {
            guard !input.missingReading else { return }
            if phase == .uncertain { restore() }
            lastRead = input
            guard phase == .ready || phase == .confirming else { return }
            if let account = input.account, let count = input.count, input.afterCompletion,
                let prior = receipts[account], count != prior
            {
                receipts.removeValue(forKey: account)
            }
            blockedByReceipt = receipts.contains { account, _ in
                input.account == nil || input.account == account
            }
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String, _ context: String) {
        precondition(condition(), "\(context): \(message)")
    }

    @MainActor static func main() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("quotabar-reset-model-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let outcomes: [QuotaResetClaimResult] = [
            .unknown, .reset, .nothingToReset, .noCredit, .accountChanged, .unavailable, .failedBeforeSending,
        ]
        var events = 0
        var dispatched = 0
        var retries = 0
        var completions = 0
        var relaunches = 0
        var outcomeCounts = [Int](repeating: 0, count: outcomes.count)
        for seed in 1...48 {
            let file = directory.appendingPathComponent("pending-\(seed).json")
            var store = UsageResets(file: file)
            var model = Model()
            var random = Generator(state: UInt64(seed))
            var input = Input()
            for step in 0..<1200 {
                let context = "seed=\(seed) step=\(step)"
                let event = random.next(12)
                if model.phase == .submitting {
                    let index = random.next(outcomes.count)
                    store.finish(outcomes[index], reading: input.display.reading)
                    model.finish(outcomes[index])
                    outcomeCounts[index] += 1
                    if outcomes[index] == .reset { completions += 1 }
                } else {
                    switch event {
                    case 0, 1, 2:
                        store.prepare(input.display)
                        model.prepare(input)
                    case 3, 4:
                        let wasRetry = model.pending != nil
                        let attempt = store.begin(input.display)
                        model.begin(input, actual: attempt, context: context)
                        if attempt != nil {
                            dispatched += 1
                            if wasRetry { retries += 1 }
                        }
                    case 5:
                        store.cancel()
                        model.cancel()
                    case 6:
                        store = UsageResets(file: file)
                        model.restore()
                        relaunches += 1
                    case 7, 8:
                        input.account = ["account-A", "account-B", nil][random.next(3)]
                        input.count = [nil, 0, 1, 2, 3, 4][random.next(6)]
                        input.afterCompletion = random.next(4) != 0
                        if let reading = input.display.reading {
                            store.received(reading, generation: store.readGeneration())
                        }
                        model.received(input)
                    case 9:
                        input.failed = random.next(3) == 0
                        input.refreshing = random.next(3) == 0
                        input.expired = random.next(3) == 0
                        input.futureDated = random.next(5) == 0
                        input.missingReading = random.next(5) == 0
                    default:
                        input = Input(account: random.next(2) == 0 ? "account-A" : "account-B", count: 3)
                        store.received(input.display.reading!, generation: store.readGeneration())
                        model.received(input)
                    }
                }
                require(String(describing: store.phase) == model.phase.rawValue, "phase diverged", context)
                require(store.isRetry == (model.pending != nil), "pending indicator diverged", context)
                require(
                    store.needsCountOnlyIdentityRefresh == (model.pending != nil || !model.receipts.isEmpty),
                    "identity refresh requirement diverged", context)
                require(store.awaitingUpdatedBalance == model.blockedByReceipt, "balance gate diverged", context)
                require(store.canPrepare(input.display) == model.eligible(input), "eligibility diverged", context)
                let saved =
                    files.fileExists(atPath: file.path)
                    ? try JSONDecoder().decode(ResetAttempt.self, from: Data(contentsOf: file)) : nil
                require(saved == model.pending, "durable pending differs from expected request", context)
                events += 1
            }
            // Release a held file lock before discarding this instance.
            if model.phase == .submitting { store.finish(.unknown, reading: nil) }
        }
        require(
            dispatched > 500 && retries > 100 && completions > 50 && relaunches > 1000,
            "trace did not exercise enough successful transitions", "coverage")
        require(outcomeCounts.allSatisfy { $0 > 50 }, "missing finish outcome coverage", "coverage")
        try storageRecovery(in: directory)
        try detailedReceipts(in: directory)
        print(
            "Reset model stress passed: \(events) events, 48 seeds, \(dispatched) dispatches, \(retries) retries, "
                + "\(completions) resets, \(relaunches) relaunches; all seven outcomes, detailed receipts, and storage recovery checked."
        )
    }

    @MainActor static func detailedReceipts(in directory: URL) throws {
        let before = Date(timeIntervalSince1970: 946_684_800)
        let after = Date(timeIntervalSince1970: 4_102_444_800)
        func fixture(_ ids: [String], count: Int, at date: Date) throws -> QuotaDisplay {
            let rows = ids.map { ["id": $0, "resetType": "codexRateLimits", "status": "available"] }
            let data = try JSONSerialization.data(withJSONObject: [
                "accountId": "synthetic-detail-account", "rateLimits": ["primary": ["usedPercent": 100]],
                "rateLimitResetCredits": ["availableCount": count, "credits": rows],
            ])
            let reading = try JSONDecoder().decode(RateLimitsResponse.self, from: data).reading(fetchedAt: date)
            return .init(reading: reading, now: date, failed: false, refreshing: false)
        }
        // At unchanged count, only a complete replacement list proves the used credit disappeared.
        let variants: [(ids: [String], count: Int, fresh: Bool, blocked: Bool)] = [
            (["credit-A", "credit-B"], 2, true, true),
            (["credit-B", "credit-A"], 2, true, true),
            (["credit-B"], 2, true, true),
            ([], 2, true, true),
            (["credit-B", "credit-C"], 2, false, true),
            (["credit-B", "credit-C"], 2, true, false),
            (["credit-B"], 1, true, false),
            ([], 0, true, false),
        ]
        for (index, variant) in variants.enumerated() {
            let file = directory.appendingPathComponent("detail-\(index).json")
            let original = try fixture(["credit-A", "credit-B"], count: 2, at: before)
            let store = UsageResets(file: file)
            store.received(original.reading!, generation: store.readGeneration())
            store.prepare(original)
            require(store.begin(original)?.creditID == "credit-A", "wrong detailed credit", "detail")
            store.finish(.reset, reading: original.reading)
            let relaunched = UsageResets(file: file)
            let updated = try fixture(variant.ids, count: variant.count, at: variant.fresh ? after : before)
            relaunched.received(updated.reading!, generation: relaunched.readGeneration())
            require(
                relaunched.awaitingUpdatedBalance == variant.blocked,
                "receipt completeness or age gate diverged", "detail=\(index)")
            require(
                !relaunched.needsCountOnlyIdentityRefresh, "detailed receipt requested count-only identity", "detail")
            let persisted = UsageResets(file: file)
            require(persisted.awaitingUpdatedBalance == variant.blocked, "receipt pruning not durable", "detail")
        }
    }

    @MainActor static func storageRecovery(in directory: URL) throws {
        let file = directory.appendingPathComponent("corrupt.json")
        let display = Input().display
        try Data("invalid JSON".utf8).write(to: file)
        let store = UsageResets(file: file)
        require(
            store.phase == .storageUnavailable && !store.canPrepare(display), "corrupt record admitted reset", "storage"
        )
        store.prepare(display)
        require(store.begin(display) == nil, "corrupt record dispatched", "storage")
        try FileManager.default.removeItem(at: file)
        store.received(display.reading!, generation: store.readGeneration())
        require(store.phase == .ready && store.canPrepare(display), "repaired storage did not recover", "storage")
        store.prepare(display)
        let attempt = store.begin(display)
        require(attempt != nil, "repair did not permit dispatch", "storage")
        store.finish(.unknown, reading: nil)
        let recovered = UsageResets(file: file)
        recovered.prepare(display)
        require(recovered.begin(display) == attempt, "recovered storage changed request key", "storage")
        recovered.finish(.nothingToReset, reading: nil)
        require(!FileManager.default.fileExists(atPath: file.path), "settled request persisted", "storage")
    }
}
