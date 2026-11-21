import Darwin
import Foundation

struct ResetAttempt: Codable, Equatable, Sendable {
    let key: UUID
    let creditID: String?
    let accountFingerprint: String?
    let startingCount: Int?

    fileprivate var hasBoundOwner: Bool {
        accountFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    fileprivate func matchesOwner(in reading: QuotaReading) -> Bool {
        guard let currentOwner = reading.resetOwner(for: creditID) else { return false }
        return currentOwner == accountFingerprint
    }
}

extension QuotaReading {
    func resetOwner(for creditID: String?) -> String? {
        let owner = creditID == nil ? resetCountOnlyFingerprint : resetAccountFingerprint
        guard let owner, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return owner
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

    fileprivate struct Fence: Codable, Equatable {
        let generation: UUID
        let time: Date
    }

    fileprivate struct FileStamp: Equatable {
        let inode: ino_t
        let device: dev_t
        let size: off_t
        let seconds: Int
        let nanos: Int

        init?(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw CocoaError(.fileReadNoPermission)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
                throw RecoveryFailure("The reset record must be an owned, regular file with one link.")
            }
            inode = info.st_ino
            device = info.st_dev
            size = info.st_size
            seconds = info.st_ctimespec.tv_sec
            nanos = info.st_ctimespec.tv_nsec
        }
    }

    fileprivate enum RecoveryTarget: Equatable {
        case pending, invalidPending
        case receipt(CompletedReset)
        case invalidReceipts, invalidFence
    }

    struct Recovery {
        fileprivate let target: RecoveryTarget
        fileprivate let pending: FileStamp?
        fileprivate let completed: FileStamp?
        fileprivate let fence: FileStamp?

        var message: String {
            let detail: String
            switch target {
            case .invalidFence:
                detail =
                    "QuotaBar will archive and replace the damaged or future-dated recovery record. Your pending requests and receipts are preserved."
            case .pending: detail = "QuotaBar will archive the pending request and stop retrying it."
            case .invalidPending:
                detail = "QuotaBar cannot identify the damaged pending request. It will archive the original file."
            case .receipt(let receipt):
                detail =
                    receipt.account == nil
                    ? "QuotaBar will archive the selected legacy receipt, which has no saved account identity."
                    : "QuotaBar will archive this account’s saved reset receipt."
            case .invalidReceipts:
                detail = "QuotaBar will archive the damaged balance record and retain every readable receipt."
            }
            return
                "Continue only after you have verified the earlier request’s final outcome and remaining balance in Codex for every account that may be affected. If the outcome is still unknown, keep the record. "
                + detail
                + " Recovery changes local records only. Another reset requires a fresh account and balance check."
        }
    }

    private struct RecoveryFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private var fenceFile: URL { file.appendingPathExtension("recovery") }
    private var recoveryFence: Fence?
    private var confirmationFence: Fence?

    struct ReadGeneration: Equatable {
        fileprivate let id: UUID?
        fileprivate let valid: Bool
    }

    // A request already in flight at recovery can arrive later, even across wall-clock adjustments.
    // Capture the on-disk generation at request start independently in each running instance.
    func readGeneration() -> ReadGeneration {
        do {
            let fence = try Self.read(Fence.self, at: fenceFile)
            return ReadGeneration(id: fence?.generation, valid: fence.map { $0.time <= Date() } ?? true)
        } catch { return ReadGeneration(id: nil, valid: false) }
    }

    private struct VerifiedBalance: Equatable {
        let date: Date
        let account: String?
        let individual: String?
        let count: Int?

        init(_ reading: QuotaReading) {
            date = reading.fetchedAt
            account = reading.resetAccountFingerprint
            individual = reading.resetCountOnlyFingerprint
            count = reading.resetCredits?.availableCount
        }
    }

    private var verifiedBalance: VerifiedBalance?

    private func afterRecovery(_ reading: QuotaReading) -> Bool {
        guard let recoveryFence else { return true }
        return recoveryFence.time <= Date() && reading.fetchedAt > recoveryFence.time
            && verifiedBalance == VerifiedBalance(reading)
    }

    struct BalancePoll {
        private let window: Range<Date>
        private let scheduled: Date

        fileprivate init?(receiptTime: Date, now: Date) {
            let window = receiptTime..<receiptTime.addingTimeInterval(60)
            let scheduled = now.addingTimeInterval(15)
            guard window.contains(now), window.contains(scheduled) else { return nil }
            self.window = window
            self.scheduled = scheduled
        }

        func fireDate(at now: Date) -> Date? {
            window.contains(now) ? scheduled : nil
        }
    }

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

    func nextBalancePoll(for reading: QuotaReading, at now: Date) -> BalancePoll? {
        guard phase == .ready, let completedBalance, let account = completedBalance.account,
            reading.resetOwner(for: completedBalance.credit) == account,
            completedBalance.awaitsBalance(from: reading)
        else { return nil }
        return BalancePoll(receiptTime: completedBalance.time, now: now)
    }

    init(file: URL) {
        self.file = file
        restore()
    }

    private func restore() {
        do {
            let latest = try Self.read(Fence.self, at: fenceFile)
            if latest != recoveryFence { verifiedBalance = nil }
            recoveryFence = latest
            if let latest, latest.time > Date() {
                throw RecoveryFailure(
                    "The recovery record is dated in the future. Check the system clock and review the record.")
            }
            let receipts = try readCompletions()
            hasCountOnlyReceipt = receipts.contains { $0.credit == nil }
            if let saved = try Self.read(ResetAttempt.self, at: file) {
                if pending != saved || phase != .uncertain {
                    notice =
                        saved.hasBoundOwner
                        ? "The last reset is unconfirmed. Retry the same request to check it."
                        : "The pending reset has no saved account identity. QuotaBar can’t safely retry it."
                }
                pending = saved
                completedBalance = nil
                phase = .uncertain
            } else {
                completedBalance = receipts.first
                pending = nil
                phase = .ready
                notice = nil
            }
        } catch {
            phase = .storageUnavailable
            notice = (error as? RecoveryFailure)?.message ?? "The saved reset records could not be read."
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
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
            info.st_nlink == 1
        else {
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
            try Self.syncDirectory(completedFile.deletingLastPathComponent())
        } else {
            try Self.writePrivate(try JSONEncoder().encode(receipts), to: completedFile)
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
            !display.stale, !display.refreshing, afterRecovery(reading)
        else { return false }
        if let pending {
            return pending.matchesOwner(in: reading)
        }
        guard completedBalance == nil, let credits = reading.resetCredits,
            credits.canClaim(at: display.now)
        else { return false }
        return reading.resetOwner(for: credits.preferredCreditID(at: display.now)) != nil
    }

    func prepare(_ display: QuotaDisplay) {
        guard canPrepare(display), let reading = display.reading else { return }
        let target = reading.resetCredits?.preferredCreditID(at: display.now)
        selection =
            pending
            ?? ResetAttempt(
                key: UUID(), creditID: target, accountFingerprint: reading.resetOwner(for: target),
                startingCount: reading.resetCredits?.availableCount)
        confirmationFence = recoveryFence
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
            attempt.matchesOwner(in: reading)
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
            // A newly created application-support folder also needs its name published.
            try Self.syncDirectory(file.deletingLastPathComponent().deletingLastPathComponent())
            let lockPath = file.appendingPathExtension("lock").path
            let fd = try Self.openLock(at: lockPath)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                cancel()
                notice = "Another QuotaBar window is using a reset."
                return nil
            }
            lockFD = fd
            let currentFence = try Self.read(Fence.self, at: fenceFile)
            guard currentFence == confirmationFence, afterRecovery(reading) else {
                releaseLock()
                cancel()
                restore()
                if phase != .storageUnavailable {
                    notice =
                        "A reset record was recovered. Refresh the account and balance, then review a new confirmation."
                }
                return nil
            }
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
                try Self.writePrivate(try JSONEncoder().encode(attempt), to: file)
            } else {
                // A prior attempt may have published its name but failed to sync the directory.
                try Self.syncDirectory(file.deletingLastPathComponent())
            }
        } catch {
            releaseLock()
            cancel()
            // The record may have changed since the confirmation was opened. Reclassify it
            // so a damaged pending request, receipt or fence can be reviewed in this session.
            restore()
            if phase == .ready { notice = "QuotaBar couldn’t save this request. Try again." }
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
            try Self.syncDirectory(file.deletingLastPathComponent())
            pending = nil
            phase = .ready
        } catch {
            phase = .uncertain
            notice = "The request finished, but its saved record could not be cleared."
        }
    }

    func canReviewRecovery(_ display: QuotaDisplay) -> Bool {
        if phase != .submitting, phase != .confirming, let recoveryFence, recoveryFence.time > Date() { return true }
        switch phase {
        case .storageUnavailable: return true
        case .uncertain:
            guard let pending, pending.hasBoundOwner else { return true }
            return !display.stale && !display.refreshing && (display.reading.map(pending.matchesOwner) ?? false)
        case .ready:
            guard !display.stale, !display.refreshing, let receipt = completedBalance, let reading = display.reading
            else { return false }
            return receipt.account == nil || receipt.account == reading.resetOwner(for: receipt.credit)
        case .submitting, .confirming: return false
        }
    }

    func reviewRecovery(_ display: QuotaDisplay) throws -> Recovery {
        try withRecoveryLock { try inspectRecovery(display) }
    }

    private func inspectRecovery(_ display: QuotaDisplay) throws -> Recovery {
        let pendingStamp = try FileStamp(file)
        let completedStamp = try FileStamp(completedFile)
        let fenceStamp = try FileStamp(fenceFile)
        let target: RecoveryTarget
        if fenceStamp != nil, !readGeneration().valid {
            target = .invalidFence
        } else if pendingStamp != nil {
            if let attempt = try? Self.read(ResetAttempt.self, at: file) {
                if attempt.hasBoundOwner,
                    display.reading.map(attempt.matchesOwner) != true || display.stale || display.refreshing
                {
                    throw RecoveryFailure("Refresh the original Codex account before reviewing this pending request.")
                }
                target = .pending
            } else {
                target = .invalidPending
            }
        } else if let completedStamp {
            if let receipts = try? readCompletions() {
                guard let reading = display.reading, !display.stale, !display.refreshing,
                    let receipt = receipts.first(where: {
                        ($0.account == nil || $0.account == reading.resetOwner(for: $0.credit))
                            && $0.awaitsBalance(from: reading)
                    })
                else { throw RecoveryFailure("Refresh the original Codex account to review its saved receipt.") }
                target = .receipt(receipt)
            } else {
                // A large opaque receipt collection could contain many unrelated accounts.
                // Never discard them merely because normal decoding reached its size bound.
                guard completedStamp.size <= Self.maximumRecoveryBytes else {
                    throw RecoveryFailure("The reset receipt file is too large to safely separate account records.")
                }
                target = .invalidReceipts
            }
        } else {
            throw RecoveryFailure("The reset records have already changed. Refresh the balance.")
        }
        return Recovery(target: target, pending: pendingStamp, completed: completedStamp, fence: fenceStamp)
    }

    private static let maximumRecoveryBytes = 8 * 1024 * 1024

    private func withRecoveryLock<T>(_ body: () throws -> T) throws -> T {
        guard phase != .submitting, lockFD < 0 else { throw RecoveryFailure("A reset is still in progress.") }
        var directoryInfo = stat()
        let directory = file.deletingLastPathComponent()
        guard lstat(directory.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
            directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o022 == 0
        else {
            throw RecoveryFailure("The reset record folder must be an owned directory with restricted write access.")
        }
        let fd = try Self.openLock(at: file.appendingPathExtension("lock").path)
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw RecoveryFailure("Another QuotaBar window is using a reset.")
        }
        return try body()
    }

    // Never dispatch or replay a provider request here. Persist the fence BEFORE clearing any record:
    // a crash at any later point still rejects prior balances and confirmations in every instance.
    @discardableResult
    func recover(_ review: Recovery, display: QuotaDisplay) throws -> URL {
        try withRecoveryLock {
            let latest = try inspectRecovery(display)
            guard latest.target == review.target, latest.pending == review.pending,
                latest.completed == review.completed,
                latest.fence == review.fence
            else {
                throw RecoveryFailure("The reset record changed. Review it again before recovering.")
            }
            let archive = file.deletingLastPathComponent().appendingPathComponent("reset-recovery-" + UUID().uuidString)
            let source: URL
            let retained: Data?
            switch review.target {
            case .invalidFence:
                source = fenceFile
                retained = nil
            case .pending, .invalidPending:
                source = file
                retained = nil
            case .receipt(let selected):
                source = completedFile
                var receipts = try readCompletions()
                guard let index = receipts.firstIndex(of: selected) else {
                    throw RecoveryFailure("The saved receipt changed.")
                }
                receipts.remove(at: index)
                retained = receipts.isEmpty ? nil : try JSONEncoder().encode(receipts)
            case .invalidReceipts:
                source = completedFile
                retained = try retainedReadableReceipts()
            }
            guard mkdir(archive.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            let saved = archive.appendingPathComponent(source.lastPathComponent)
            let fence = Fence(generation: UUID(), time: Date())
            do {
                let encoded = try JSONEncoder().encode(fence)
                try Self.syncDirectory(archive.deletingLastPathComponent())
                if review.target == .invalidFence {
                    // Stage the new fence in the private archive. One swap publishes it and
                    // archives the exact previous inode, including oversized or unreadable bytes.
                    try Self.writePrivate(encoded, to: saved)
                    var exchanged = false
                    defer { if !exchanged { _ = unlink(saved.path) } }
                    guard try FileStamp(source) == review.fence,
                        fchmodat(AT_FDCWD, source.path, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                        renamex_np(source.path, saved.path, UInt32(RENAME_SWAP)) == 0
                    else { throw CocoaError(.fileWriteUnknown) }
                    exchanged = true
                    try Self.syncDirectory(archive)
                    try Self.syncDirectory(source.deletingLastPathComponent())
                } else {
                    if retained != nil {
                        guard let original = try Self.recoveryBytes(at: source) else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        try Self.writePrivate(original, to: saved)
                    }
                    try Self.writePrivate(encoded, to: fenceFile)
                    if let retained {
                        try Self.writePrivate(retained, to: source)
                    } else {
                        guard fchmodat(AT_FDCWD, source.path, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                            renamex_np(source.path, saved.path, UInt32(RENAME_EXCL)) == 0
                        else { throw CocoaError(.fileWriteUnknown) }
                        try Self.syncDirectory(archive)
                        try Self.syncDirectory(source.deletingLastPathComponent())
                    }
                }
                recoveryFence = fence
                verifiedBalance = nil
            } catch {
                _ = rmdir(archive.path)
                throw error
            }
            selection = nil
            confirmationFence = nil
            retryingSubmission = false
            restore()
            notice = "Reset record archived. Refresh the account and balance before using a reset."
            return archive
        }
    }

    private func retainedReadableReceipts() throws -> Data? {
        // Decode rows independently so one legacy or damaged entry cannot discard a different account's receipt.
        guard let data = try Self.recoveryBytes(at: completedFile) else { throw CocoaError(.fileReadUnknown) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows = object as? [Any] ?? [object]
        var retained: [Any] = []
        for row in rows where JSONSerialization.isValidJSONObject(row) {
            let bytes = try JSONSerialization.data(withJSONObject: row)
            if (try? JSONDecoder().decode(CompletedReset.self, from: bytes)) != nil { retained.append(row) }
        }
        guard retained.count != rows.count || rows.isEmpty else {
            throw RecoveryFailure(
                "The saved receipt collection could not be safely reduced. Check its size and format.")
        }
        return retained.isEmpty ? nil : try JSONSerialization.data(withJSONObject: retained)
    }

    private static func recoveryBytes(at url: URL) throws -> Data? {
        guard let stamp = try FileStamp(url) else { return nil }
        if stamp.size == 0 { return Data() }
        return try PrivateFile.read(url, maximumBytes: maximumRecoveryBytes)
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private static func writePrivate(_ bytes: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".reset-write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_EXCL | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { _ = unlink(temporary.path) }
        try handle.write(contentsOf: bytes)
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func received(_ reading: QuotaReading) { received(reading, generation: readGeneration()) }

    func received(_ reading: QuotaReading, generation: ReadGeneration) {
        if phase == .uncertain || phase == .storageUnavailable { restore() }
        do {
            let latest = try Self.read(Fence.self, at: fenceFile)
            if latest != recoveryFence, phase != .submitting {
                cancel()
                restore()
            }
            if let recoveryFence {
                guard generation.valid, generation.id == recoveryFence.generation,
                    recoveryFence.time <= Date(), reading.fetchedAt > recoveryFence.time,
                    reading.resetCredits != nil
                else { return }
                verifiedBalance = VerifiedBalance(reading)
            } else if !generation.valid || generation.id != nil {
                return
            }
        } catch {
            phase = .storageUnavailable
            notice = "QuotaBar couldn’t verify local reset recovery. Check the saved records."
            return
        }
        if phase == .uncertain, let pending,
            pending.hasBoundOwner,
            !pending.matchesOwner(in: reading)
        {
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
