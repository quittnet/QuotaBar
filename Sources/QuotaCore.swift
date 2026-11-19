import CryptoKit
import Darwin
import Foundation

struct QuotaWindow: Sendable, Equatable {
    let minutes: Int?
    let used: Double
    let resetsAt: Date?
    var remaining: Double { max(0, 100 - used) }
}

extension QuotaWindow {
    init(minutes: Int?, remaining: Double, resetsAt: Date?) {
        self.init(minutes: minutes, used: 100 - remaining, resetsAt: resetsAt)
    }
}

struct QuotaReading: Sendable {
    let fetchedAt: Date
    let windows: [QuotaWindow]
    let resetCredits: QuotaResetCredits?
    let ordinaryUsageAllowed: Bool?
    let resetAccountFingerprint: String?
    let resetCountOnlyFingerprint: String?

    init(
        fetchedAt: Date,
        windows: [QuotaWindow],
        resetCredits: QuotaResetCredits? = nil,
        resetAccountFingerprint: String? = nil,
        resetCountOnlyFingerprint: String? = nil,
        ordinaryUsageAllowed: Bool? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.resetCredits = resetCredits
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.resetAccountFingerprint = resetAccountFingerprint
        self.resetCountOnlyFingerprint = resetCountOnlyFingerprint
    }
}

struct QuotaResetCredits: Sendable {
    let availableCount: Int
    private let backendSelectsCredit: Bool
    private let credits: [Credit]

    fileprivate struct Credit: Sendable {
        let id: String
        let expiresAt: Date?
    }

    init(availableCount: Int) {
        self.init(availableCount: availableCount, credits: [], backendSelectsCredit: true)
    }

    fileprivate init(availableCount: Int, credits: [Credit], backendSelectsCredit: Bool) {
        self.backendSelectsCredit = backendSelectsCredit
        self.availableCount = max(0, availableCount)
        self.credits = credits.sorted { left, right in
            guard let leftExpiration = left.expiresAt else { return false }
            return right.expiresAt.map { leftExpiration < $0 } ?? true
        }
    }

    func availableCount(at date: Date) -> Int {
        // Codex may omit or cap the detail list. Only known expirations reduce the reported count.
        let expired = credits.lazy.filter { $0.expiresAt.map { $0 <= date } ?? false }.count
        return max(0, availableCount - expired)
    }

    func canClaim(at date: Date) -> Bool {
        availableCount(at: date) > 0 && (backendSelectsCredit || preferredCredit(at: date) != nil)
    }

    func nextExpiration(at date: Date) -> Date? {
        preferredCredit(at: date)?.expiresAt
    }

    func preferredCreditID(at date: Date) -> String? {
        preferredCredit(at: date)?.id
    }

    func reportedAvailability(of id: String) -> Bool? {
        if credits.contains(where: { $0.id == id }) { return true }
        // Only a complete set of unique, available detail rows can establish absence.
        return credits.count == availableCount ? false : nil
    }

    private func preferredCredit(at date: Date) -> Credit? {
        guard availableCount(at: date) > 0 else { return nil }
        return credits.first { $0.expiresAt.map { $0 > date } ?? true }
    }
}

enum QuotaResetClaimResult: Sendable, Equatable {
    case reset, nothingToReset, noCredit, accountChanged, unavailable, failedBeforeSending, unknown
}

enum QuotaSource: Sendable {
    static func read(
        includeCountOnlyIdentity: Bool = false, executable: URL? = nil, timeout: DispatchTimeInterval = .seconds(15)
    ) throws -> QuotaReading {
        do {
            return try withTransport(executable: executable, timeout: timeout) { transport in
                try transport.send(#"{"id":2,"method":"account/rateLimits/read"}"#)
                let response: RateLimitsResponse
                do {
                    response = try transport.receive(id: 2)
                } catch is RPCError {
                    throw transport.quotaReadFailure()
                }
                let fetchedAt = Date()
                let credits = response.quotaResetCredits
                let mayOfferCountOnly =
                    credits?.canClaim(at: fetchedAt) == true && credits?.preferredCreditID(at: fetchedAt) == nil
                let countOnlyFingerprint: String?
                if let workspace = response.resetAccountFingerprint,
                    includeCountOnlyIdentity || mayOfferCountOnly || response.ordinaryUsageAllowed == false
                {
                    countOnlyFingerprint = try? transport.readCountOnlyFingerprint(workspace: workspace)
                } else {
                    countOnlyFingerprint = nil
                }
                return try response.reading(fetchedAt: fetchedAt, resetCountOnlyFingerprint: countOnlyFingerprint)
            }
        } catch is RPCError {
            throw QuotaError.requestFailed
        }
    }

    static func claimReset(
        idempotencyKey: UUID,
        creditID: String?,
        accountFingerprint: String? = nil,
        executable: URL? = nil,
        timeout: DispatchTimeInterval = .seconds(20)
    ) -> QuotaResetClaimResult {
        guard creditID != nil || accountFingerprint != nil else { return .accountChanged }
        var mayHaveSentClaim = false
        do {
            return try withTransport(executable: executable, timeout: timeout) { transport in
                if let accountFingerprint {
                    try transport.send(
                        #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#
                    )
                    let account: RateLimitsResponse = try transport.receive(id: 2)
                    guard let workspace = account.resetAccountFingerprint else { return .accountChanged }
                    let currentFingerprint =
                        creditID == nil
                        ? try transport.readCountOnlyFingerprint(workspace: workspace)
                        : workspace
                    guard currentFingerprint == accountFingerprint else { return .accountChanged }
                }

                let request = ResetClaimRequest(
                    params: .init(
                        idempotencyKey: idempotencyKey.uuidString.lowercased(),
                        creditId: creditID
                    ))
                let payload = try JSONEncoder().encode(request)
                // A transport failure after attempting to write can leave the outcome unknown.
                mayHaveSentClaim = true
                try transport.send(payload)
                let response: ResetClaimResponse = try transport.receive(id: request.id)
                return response.result
            }
        } catch let error as RPCError where mayHaveSentClaim && error.resetMethodUnavailable {
            return .unavailable
        } catch {
            return mayHaveSentClaim ? .unknown : .failedBeforeSending
        }
    }

    private static func withTransport<Result>(
        executable: URL?,
        timeout: DispatchTimeInterval,
        _ run: (inout CodexTransport) throws -> Result
    ) throws -> Result {
        guard let executable = executable ?? executableURL() else { throw QuotaError.codexNotFound }

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw QuotaError.launchFailed
        }
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        defer {
            try? writer.close()
            // Closing stdin usually lets the stdio process exit by itself.
            if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .milliseconds(250))
                }
            }
            try? reader.close()
        }

        // A stopped or unresponsive server must neither signal the menu app nor block a write.
        let writerFlags = fcntl(writer.fileDescriptor, F_GETFL)
        guard writerFlags != -1,
            fcntl(writer.fileDescriptor, F_SETFL, writerFlags | O_NONBLOCK) != -1,
            fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1
        else {
            throw QuotaError.transportFailed
        }

        var transport = CodexTransport(reader: reader, writer: writer, timeout: timeout)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let initialize: [String: Any] = [
            "id": 1, "method": "initialize",
            "params": [
                "clientInfo": ["name": "quotabar", "title": "QuotaBar", "version": version],
                "capabilities": ["explicitGatewayOauth": true],
            ],
        ]
        try transport.send(try JSONSerialization.data(withJSONObject: initialize))
        let _: InitializeResponse = try transport.receive(id: 1)
        try transport.send(#"{"method":"initialized"}"#)
        return try run(&transport)
    }

    private static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(
                fileURLWithPath:
                    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let customCandidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
        }
        return (candidates + customCandidates).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

enum QuotaError: LocalizedError {
    case codexNotFound, launchFailed, transportFailed, timedOut, invalidResponse, requestFailed, quotaUnavailable

    case signInRequired, subscriptionRequired

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to Codex with ChatGPT, then click Refresh."
        case .subscriptionRequired:
            "Codex is using an API key. Sign in with ChatGPT to see subscription limits."
        case .codexNotFound:
            "The Codex CLI could not be found."
        case .launchFailed:
            "The Codex app server could not start."
        case .transportFailed:
            "The Codex app server connection closed."
        case .timedOut:
            "The Codex quota request timed out."
        case .invalidResponse:
            "Codex returned an unreadable quota response."
        case .requestFailed:
            "Codex could not retrieve the account quota."
        case .quotaUnavailable:
            "Codex reported no rate-limit windows for this account."
        }
    }
}

private struct InitializeResponse: Decodable {}

private struct ReplyHeader: Decodable {
    let id: Int
    let method: String?
}

private struct Reply<Result: Decodable>: Decodable {
    let result: Result?
    let error: RPCError?
}

private struct RPCError: Decodable, Error {
    let code: Int
    let message: String?

    var resetMethodUnavailable: Bool {
        // Older app servers report an unknown request variant as Invalid Request.
        code == -32601
            || (code == -32600
                && message?.hasPrefix("Invalid request: unknown variant `account/rateLimitResetCredit/consume`") == true)
    }
}

private struct ResetClaimRequest: Encodable {
    let id = 4
    let method = "account/rateLimitResetCredit/consume"
    let params: Params

    struct Params: Encodable {
        let idempotencyKey: String
        let creditId: String?
    }
}

private struct ResetClaimResponse: Decodable {
    let outcome: String

    var result: QuotaResetClaimResult {
        switch outcome {
        case "reset", "alreadyRedeemed": .reset
        case "nothingToReset": .nothingToReset
        case "noCredit": .noCredit
        default: .unknown
        }
    }
}

private struct AccountIdentityResponse: Decodable {
    struct Account: Decodable { let type: String }
    let account: Account?
    let requiresOpenaiAuth: Bool?
    let userId: String?

    private enum CodingKeys: String, CodingKey { case account, requiresOpenaiAuth, userId }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decode(Account?.self, forKey: .account)
        requiresOpenaiAuth = try values.decodeIfPresent(Bool.self, forKey: .requiresOpenaiAuth)
        userId = try values.decodeIfPresent(String.self, forKey: .userId)
    }
}

private func fingerprint(_ input: String) -> String {
    SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct RateLimitsResponse: Decodable {
    private let windows: [QuotaWindow]
    let ordinaryUsageAllowed: Bool?
    let resetAccountFingerprint: String?
    let quotaResetCredits: QuotaResetCredits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits, rateLimitsByLimitId, rateLimitResetCredits, accountId, ordinaryUsageAllowed
    }

    private enum BucketKey: String, CodingKey { case codex }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let buckets = try? values.nestedContainer(keyedBy: BucketKey.self, forKey: .rateLimitsByLimitId)
        let main = try? buckets?.decode(Snapshot.self, forKey: .codex)
        let selected: Snapshot?
        if let main, main.limitId == nil || main.limitId == "codex" {
            selected = main
        } else {
            let legacy = try? values.decode(Snapshot.self, forKey: .rateLimits)
            // A malformed or nonempty map cannot establish that an unidentified legacy bucket belongs to Codex.
            let noMap =
                !values.contains(.rateLimitsByLimitId) || (try? values.decodeNil(forKey: .rateLimitsByLimitId)) == true
            let compatible = legacy?.limitId == "codex" || (legacy?.limitId == nil && noMap)
            selected = compatible ? legacy : nil
        }
        windows = selected?.windows ?? []
        let ordinary = try values.decodeIfPresent(Bool.self, forKey: .ordinaryUsageAllowed)
        ordinaryUsageAllowed = selected?.hasExplicitRestriction == true ? false : ordinary
        let credits = try? values.decode(ResetCreditsSummary.self, forKey: .rateLimitResetCredits)
        quotaResetCredits = credits?.quotaResetCredits
        if let accountId = try? values.decode(String.self, forKey: .accountId),
            !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            resetAccountFingerprint = fingerprint(accountId)
        } else {
            resetAccountFingerprint = nil
        }
    }

    struct Snapshot: Decodable {
        let limitId: String?
        let spendControlReached: Bool?
        let rateLimitReachedType: ReachedReason?

        enum ReachedReason: String, Decodable {
            case rateLimit = "rate_limit_reached"
            case ownerCredits = "workspace_owner_credits_depleted"
            case memberCredits = "workspace_member_credits_depleted"
            case ownerUsage = "workspace_owner_usage_limit_reached"
            case memberUsage = "workspace_member_usage_limit_reached"
        }

        var hasExplicitRestriction: Bool {
            spendControlReached == true || rateLimitReachedType != nil
        }

        let windows: [QuotaWindow]

        private enum CodingKeys: String, CodingKey {
            case limitId, primary, secondary, spendControlReached, rateLimitReachedType
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            limitId = try values.decodeIfPresent(String.self, forKey: .limitId)
            let primary = try values.decodeIfPresent(Window.self, forKey: .primary)?.quotaWindow()
            let secondary = try values.decodeIfPresent(Window.self, forKey: .secondary)?.quotaWindow()
            spendControlReached = try values.decodeIfPresent(Bool.self, forKey: .spendControlReached)
            rateLimitReachedType = try values.decodeIfPresent(ReachedReason.self, forKey: .rateLimitReachedType)
            let reported = primary == secondary ? [primary] : [primary, secondary]
            windows = reported.compactMap { $0 }.sorted { ($0.minutes ?? Int.max) < ($1.minutes ?? Int.max) }
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Int64?

        func quotaWindow() throws -> QuotaWindow {
            guard usedPercent.isFinite, usedPercent >= 0, usedPercent <= Double(Int32.max),
                windowDurationMins.map({ $0 > 0 }) ?? true,
                resetsAt.map({ $0 > 0 && Double($0) < Date.distantFuture.timeIntervalSince1970 }) ?? true
            else {
                throw QuotaError.invalidResponse
            }
            let reset = resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
            return QuotaWindow(minutes: windowDurationMins, used: usedPercent, resetsAt: reset)
        }
    }

    private struct ResetCreditsSummary: Decodable {
        let availableCount: Int
        let credits: [Credit]
        let countOnly: Bool

        private enum CodingKeys: String, CodingKey { case availableCount, credits }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try values.decode(Int.self, forKey: .availableCount)
            guard availableCount >= 0 else { throw QuotaError.invalidResponse }
            countOnly = try !values.contains(.credits) || values.decodeNil(forKey: .credits)
            var details: [Credit] = []
            if !countOnly {
                var rows = try values.nestedUnkeyedContainer(forKey: .credits)
                while !rows.isAtEnd {
                    let row = try rows.superDecoder()
                    if let credit = try? Credit(from: row) { details.append(credit) }
                }
            }
            credits = details
        }

        struct Credit: Decodable, Equatable {
            let id: String
            let resetType: String
            let status: String
            let expiresAt: Int64?
        }

        var quotaResetCredits: QuotaResetCredits? {
            var seen: [String: Credit] = [:]
            var availableCredits: [QuotaResetCredits.Credit] = []
            for credit in credits {
                guard !credit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let previous = seen.updateValue(credit, forKey: credit.id) {
                    guard previous == credit else { return nil }
                    continue
                }
                guard credit.resetType == "codexRateLimits", credit.status == "available" else { continue }
                let expiration = credit.expiresAt.map { Date(timeIntervalSince1970: Double($0)) }
                guard expiration.map({ $0.timeIntervalSince1970 > 0 && $0 < .distantFuture }) ?? true else {
                    return nil
                }
                availableCredits.append(.init(id: credit.id, expiresAt: expiration))
            }
            guard availableCredits.count <= availableCount else { return nil }
            return QuotaResetCredits(
                availableCount: availableCount, credits: availableCredits, backendSelectsCredit: countOnly)
        }
    }

    func reading(fetchedAt: Date, resetCountOnlyFingerprint: String? = nil) throws -> QuotaReading {
        guard !windows.isEmpty || ordinaryUsageAllowed == false else { throw QuotaError.quotaUnavailable }
        return QuotaReading(
            fetchedAt: fetchedAt,
            windows: windows,
            resetCredits: quotaResetCredits,
            resetAccountFingerprint: resetAccountFingerprint,
            resetCountOnlyFingerprint: resetCountOnlyFingerprint,
            ordinaryUsageAllowed: ordinaryUsageAllowed
        )
    }
}

private struct CodexTransport {
    let reader: FileHandle
    let writer: FileHandle
    private let deadline: DispatchTime
    private var buffer = Data()
    private let decoder = JSONDecoder()

    init(reader: FileHandle, writer: FileHandle, timeout: DispatchTimeInterval) {
        self.reader = reader
        self.writer = writer
        self.deadline = DispatchTime.now() + timeout
    }

    func send(_ request: String) throws {
        try send(Data(request.utf8))
    }

    func send(_ request: Data) throws {
        var line = request
        line.append(0x0A)
        do {
            try writer.write(contentsOf: line)
        } catch {
            throw QuotaError.transportFailed
        }
    }

    mutating func quotaReadFailure() -> QuotaError {
        do {
            try send(#"{"id":3,"method":"account/read","params":{}}"#)
            let identity: AccountIdentityResponse = try receive(id: 3, timeout: .seconds(2))
            if identity.account?.type == "apiKey" { return .subscriptionRequired }
            if identity.account == nil && identity.requiresOpenaiAuth == true { return .signInRequired }
        } catch {
            // A failed identity check cannot establish that the user signed out.
        }
        return .requestFailed
    }

    mutating func readCountOnlyFingerprint(workspace: String) throws -> String? {
        try send(#"{"id":3,"method":"account/read","params":{}}"#)
        let account: AccountIdentityResponse = try receive(id: 3, timeout: .seconds(2))
        guard account.account?.type == "chatgpt", let user = account.userId,
            !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return fingerprint("QuotaBar count-only reset v1\u{0}\(workspace)\u{0}\(user)")
    }

    mutating func receive<Result: Decodable>(id: Int, timeout: DispatchTimeInterval? = nil) throws -> Result {
        let responseDeadline = timeout.map { min(deadline, DispatchTime.now() + $0) } ?? deadline
        while true {
            let line = try readLine(deadline: responseDeadline)
            guard let header = try? decoder.decode(ReplyHeader.self, from: line),
                header.id == id, header.method == nil
            else {
                continue
            }
            guard let reply = try? decoder.decode(Reply<Result>.self, from: line) else {
                throw QuotaError.invalidResponse
            }
            if let error = reply.error {
                guard reply.result == nil else { throw QuotaError.invalidResponse }
                throw error
            }
            guard let result = reply.result else { throw QuotaError.invalidResponse }
            return result
        }
    }

    private mutating func readLine(deadline: DispatchTime) throws -> Data {
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { throw QuotaError.timedOut }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < 1_048_576 else { throw QuotaError.invalidResponse }
            let timeout = (deadline.uptimeNanoseconds - now.uptimeNanoseconds + 999_999) / 1_000_000
            let fd = reader.fileDescriptor
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(timeout))
            if ready == 0 { throw QuotaError.timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw QuotaError.transportFailed
            }
            // Use read(2) so one available chunk returns without waiting to fill a FileHandle buffer.
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw QuotaError.transportFailed }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
