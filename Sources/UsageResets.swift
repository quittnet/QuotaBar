import Darwin
import Foundation

struct ResetAttempt: Codable, Equatable, Sendable {
    let key: UUID
    let creditID: String?
    let accountFingerprint: String?
    let startingCount: Int?
}

extension QuotaReading {
    fileprivate func resetOwner(for creditID: String?) -> String? {
        creditID == nil ? resetCountOnlyFingerprint : resetAccountFingerprint
    }
}

private struct CompletedReset: Codable, Equatable {
    let account: String?
    let count: Int
    let credit: String?
    let time: Date

    func isOtherAccount(_ reading: QuotaReading) -> Bool {
        guard let account, let owner = reading.resetOwner(for: credit) else { return false }
        return owner != account
    }

    func awaitsBalance(from reading: QuotaReading) -> Bool {
        if isOtherAccount(reading) { return false }
        guard reading.fetchedAt >= time else { return true }
        if account != nil && reading.resetOwner(for: credit) == nil { return true }
        guard let credits = reading.resetCredits else { return true }
        if let credit, let available = credits.reportedAvailability(of: credit) { return available }
        return credits.availableCount == count
    }
}

@MainActor
final class UsageResets {
    enum Phase { case ready, confirming, submitting, uncertain, storageUnavailable }

    private(set) var phase: Phase = .ready
    private(set) var notice: String?
    private let file: URL
    private var lockFD: Int32 = -1
    private var pending: ResetAttempt?
    private var selection: ResetAttempt?
    private var retryingSubmission = false
    private var completedFile: URL { file.appendingPathExtension("completed") }
    private var completedBalance: CompletedReset?
    private var hasCountOnlyReceipt = false
    var awaitingUpdatedBalance: Bool { completedBalance != nil }
    var needsCountOnlyIdentityRefresh: Bool {
        (pending.map { $0.creditID == nil } ?? false) || hasCountOnlyReceipt
    }

    init(file: URL) {
        self.file = file
        restore()
    }

    private func restore() {
        do {
            if let saved = try Self.read(ResetAttempt.self, at: file) {
                if pending != saved || phase != .uncertain {
                    notice = "The last reset is unconfirmed. Retry the same request to check it."
                }
                pending = saved
                completedBalance = nil
                phase = .uncertain
            } else {
                let receipts = try readCompletions()
                completedBalance = receipts.first
                hasCountOnlyReceipt = receipts.contains { $0.credit == nil }
                pending = nil
                phase = .ready
                notice = nil
            }
        } catch {
            phase = .storageUnavailable
            notice = "The pending reset record could not be read."
        }
    }

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(file: base.appendingPathComponent("app.quotabar.QuotaBar/pending-reset.json"))
    }

    private static func read<Value: Decodable>(_ type: Value.Type, at file: URL) throws -> Value? {
        guard let data = try PrivateFile.read(file, maximumBytes: 1024 * 1024) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func openLock(at path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        return descriptor
    }

    private func readCompletions() throws -> [CompletedReset] {
        do {
            return try Self.read([CompletedReset].self, at: completedFile) ?? []
        } catch DecodingError.typeMismatch {
            return try Self.read(CompletedReset.self, at: completedFile).map { [$0] } ?? []
        }
    }

    private func writeCompletions(_ receipts: [CompletedReset]) throws {
        if receipts.isEmpty {
            try FileManager.default.removeItem(at: completedFile)
        } else {
            try JSONEncoder().encode(receipts).write(to: completedFile, options: .atomic)
        }
    }

    private func releaseLock() {
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    var isRetry: Bool { pending != nil }

    func canPrepare(_ display: QuotaDisplay) -> Bool {
        guard phase == .ready || phase == .uncertain, let reading = display.reading,
            !display.stale, !display.refreshing
        else { return false }
        if let pending {
            return pending.accountFingerprint == reading.resetOwner(for: pending.creditID)
        }
        guard completedBalance == nil, let credits = reading.resetCredits,
            credits.canClaim(at: display.now)
        else { return false }
        return credits.preferredCreditID(at: display.now) != nil || reading.resetCountOnlyFingerprint != nil
    }

    func prepare(_ display: QuotaDisplay) {
        guard canPrepare(display), let reading = display.reading else { return }
        let target = reading.resetCredits?.preferredCreditID(at: display.now)
        selection =
            pending
            ?? ResetAttempt(
                key: UUID(), creditID: target, accountFingerprint: reading.resetOwner(for: target),
                startingCount: reading.resetCredits?.availableCount)
        phase = .confirming
        notice = nil
    }

    func cancel() {
        guard phase == .confirming else { return }
        selection = nil
        phase = pending == nil ? .ready : .uncertain
        if pending != nil { notice = "The last reset is still unconfirmed." }
    }

    // Persist the operation ID before dispatch so a relaunch cannot turn a retry into a new spend.
    func begin(_ display: QuotaDisplay) -> ResetAttempt? {
        guard phase == .confirming, let attempt = selection else { return nil }
        guard let reading = display.reading, !display.stale, !display.refreshing,
            reading.resetOwner(for: attempt.creditID) == attempt.accountFingerprint
        else {
            cancel()
            notice = "Refresh the account limits, then check the reset again."
            return nil
        }
        if pending == nil {
            guard let credits = reading.resetCredits, credits.availableCount == attempt.startingCount,
                credits.canClaim(at: display.now),
                credits.preferredCreditID(at: display.now) == attempt.creditID
            else {
                cancel()
                notice = "Your available resets changed. Review the updated balance."
                return nil
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let lockPath = file.appendingPathExtension("lock").path
            let fd = try Self.openLock(at: lockPath)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                cancel()
                notice = "Another QuotaBar window is using a reset."
                return nil
            }
            lockFD = fd
            let saved = try Self.read(ResetAttempt.self, at: file)
            guard saved == pending else {
                pending = saved
                cancel()
                notice =
                    saved == nil
                    ? "The last request finished. Review the current balance."
                    : "A pending request was found. Retry that reset to check it."
                releaseLock()
                return nil
            }
            if saved == nil {
                // Another instance may have completed its reset after our confirmation opened.
                if let completion = try readCompletions().first(where: { $0.awaitsBalance(from: reading) }) {
                    completedBalance = completion
                    if completion.credit == nil { hasCountOnlyReceipt = true }
                    cancel()
                    notice = "A reset was applied. Refresh the balance before using another."
                    releaseLock()
                    return nil
                }
                try JSONEncoder().encode(attempt).write(to: file, options: .atomic)
            }
        } catch {
            releaseLock()
            cancel()
            notice = "QuotaBar couldn’t save this request. Try again."
            return nil
        }
        retryingSubmission = pending != nil
        pending = attempt
        phase = .submitting
        notice = nil
        return attempt
    }

    func finish(_ outcome: QuotaResetClaimResult, reading: QuotaReading?) {
        guard phase == .submitting, let attempt = pending else { return }
        defer { releaseLock() }
        selection = nil
        switch outcome {
        case .unknown:
            phase = .uncertain
            notice = "Codex hasn’t confirmed the reset. Retry the same request to check it."
            return
        case .failedBeforeSending, .accountChanged, .unavailable:
            // An earlier attempt with this same key may still need reconciliation.
            switch outcome {
            case .accountChanged:
                notice =
                    retryingSubmission
                    ? "Return to the original account to check this reset."
                    : "The signed-in account changed. Check the current balance before using a reset."
            case .unavailable: notice = "This Codex client does not support resets. Update Codex to retry."
            default: notice = "Couldn’t reach Codex. Try again."
            }
            if retryingSubmission {
                phase = .uncertain
                return
            }
        case .reset:
            completedBalance = CompletedReset(
                account: attempt.accountFingerprint,
                count: attempt.startingCount ?? reading?.resetCredits?.availableCount ?? 0,
                credit: attempt.creditID, time: Date())
            notice = "Reset applied."
        case .nothingToReset:
            notice = "No current limit is eligible. This request spent no reset."
        case .noCredit:
            notice =
                attempt.creditID == nil ? "Codex reported no available resets." : "That reset is no longer available."
        }
        do {
            if outcome == .reset, let completedBalance {
                var receipts = try readCompletions().filter { $0.account != completedBalance.account }
                receipts.append(completedBalance)
                try writeCompletions(receipts)
                hasCountOnlyReceipt = receipts.contains { $0.credit == nil }
            }
            try FileManager.default.removeItem(at: file)
            pending = nil
            phase = .ready
        } catch {
            phase = .uncertain
            notice = "The request finished, but its saved record could not be cleared."
        }
    }

    func received(_ reading: QuotaReading) {
        if phase == .uncertain || phase == .storageUnavailable { restore() }
        if phase == .uncertain, let pending, pending.accountFingerprint != reading.resetOwner(for: pending.creditID) {
            notice = "Return to the original Codex account to check the pending reset."
        }
        guard phase == .ready || phase == .confirming else { return }
        func update(_ receipts: [CompletedReset]) {
            if completedBalance?.isOtherAccount(reading) == true { notice = nil }
            hasCountOnlyReceipt = receipts.contains { $0.credit == nil }
            completedBalance = receipts.first { $0.awaitsBalance(from: reading) }
        }
        func stillUnverified(_ receipt: CompletedReset) -> Bool {
            receipt.isOtherAccount(reading) || receipt.awaitsBalance(from: reading)
        }
        do {
            let receipts = try readCompletions()
            update(receipts)
            guard receipts.contains(where: { !stillUnverified($0) }) else { return }
            // A later grant can return the count to its old value. Remove a verified receipt once.
            let fd = try Self.openLock(at: file.appendingPathExtension("lock").path)
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
            let latest = try readCompletions()
            let retained = latest.filter(stillUnverified)
            if retained != latest { try writeCompletions(retained) }
            update(retained)
        } catch {
            phase = .storageUnavailable
            notice = "QuotaBar couldn’t verify the saved reset balance."
        }
    }
}
