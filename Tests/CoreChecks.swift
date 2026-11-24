import Foundation

@main
enum CoreChecks {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "app-server" {
            try mockAppServer()
            return
        }
        if CommandLine.arguments.contains("--live") {
            let reading = try QuotaSource.read()
            for window in reading.windows {
                let activeReset = window.resetsAt.map { $0 > reading.fetchedAt } ?? false
                print(
                    "\(window.minutes.map(String.init) ?? "unknown") min: \(window.remaining)% left, future reset: \(activeReset)"
                )
            }
            return
        }

        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        func read(_ json: String) throws -> QuotaReading {
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(json.utf8))
            return try response.reading(fetchedAt: fetchedAt)
        }

        let weeklyOnly = try read(
            """
            {
                "rateLimits": {
                    "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1800100000},
                    "secondary":null
                }
            }
            """)
        precondition(weeklyOnly.fetchedAt == fetchedAt)
        precondition(weeklyOnly.resetCredits == nil && weeklyOnly.resetAccountFingerprint == nil)
        precondition(
            weeklyOnly.windows == [
                QuotaWindow(minutes: 10080, remaining: 64, resetsAt: Date(timeIntervalSince1970: 1_800_100_000))
            ])

        let twoWindows = try read(
            """
            {
                "rateLimits": {"primary":{"usedPercent":100,"windowDurationMins":10080}},
                "rateLimitsByLimitId": {
                    "codex": {
                        "primary":{"usedPercent":27.5,"windowDurationMins":10080},
                        "secondary":{"usedPercent":110,"windowDurationMins":300,"resetsAt":null}
                    },
                    "alternate": {"primary":{"usedPercent":0,"windowDurationMins":10080}}
                }
            }
            """)
        precondition(
            twoWindows.windows == [
                QuotaWindow(minutes: 300, used: 110, resetsAt: nil),
                QuotaWindow(minutes: 10080, remaining: 72.5, resetsAt: nil),
            ])
        precondition(twoWindows.windows.first?.remaining == 0)

        let unknownDuration = try read(#"{"rateLimits":{"primary":{"usedPercent":15}}}"#)
        precondition(unknownDuration.windows == [QuotaWindow(minutes: nil, remaining: 85, resetsAt: nil)])

        let duplicate = try read(
            """
            {
                "rateLimits": {
                    "primary":{"usedPercent":95,"windowDurationMins":300},
                    "secondary":{"usedPercent":60,"windowDurationMins":300}
                }
            }
            """)
        precondition(duplicate.windows.map(\.remaining) == [5, 40])
        let divergent = try read(
            """
            {"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1700000000},
            "secondary":{"usedPercent":98,"windowDurationMins":300,"resetsAt":1800000600}}}
            """)
        precondition(divergent.windows.map(\.remaining) == [2])
        let mixed = """
            {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1800000000},
            "secondary":{"usedPercent":35,"windowDurationMins":10080}}}
            """
        let currentWeek = try read(mixed)
        precondition(currentWeek.windows.map(\.remaining) == [65])
        let restricted = try read(
            #"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100,"resetsAt":1800000000}}}"#)
        precondition(restricted.ordinaryUsageAllowed == false && restricted.windows.isEmpty)
        func unavailable(_ json: String) throws {
            do {
                _ = try read(json)
                preconditionFailure("Malformed or ambiguous Codex windows should be unavailable")
            } catch QuotaError.quotaUnavailable {}
        }
        try unavailable(
            """
            {"rateLimits":{"primary":{"usedPercent":100}},
             "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":30},"secondary":{"usedPercent":null}},
             "alternate":{"primary":{"usedPercent":"unknown"}}}}
            """)
        try unavailable(#"{"rateLimitsByLimitId":"bad","rateLimits":{"primary":{"usedPercent":1}}}"#)
        let expiredWithBalance = try read(
            """
            {"rateLimits":{"primary":{"usedPercent":100,"resetsAt":1800000000}},
             "rateLimitResetCredits":{"availableCount":2}}
            """)
        precondition(expiredWithBalance.windows.first?.resetsAt == fetchedAt)
        precondition(expiredWithBalance.resetCredits?.availableCount == 2)
        for invalid in [
            #"{"usedPercent":-0.1}"#, #"{"usedPercent":1,"resetsAt":1800000000000}"#,
            #"{"usedPercent":1,"resetsAt":0}"#, #"{"usedPercent":1,"windowDurationMins":-1}"#,
            #"{"usedPercent":1e70}"#, #"{"usedPercent":false}"#,
        ] {
            try unavailable(
                """
                {"rateLimits":{"primary":{"usedPercent":2},"secondary":\(invalid)}}
                """)
        }
        for restriction in [
            #""spendControlReached":true"#,
            #""rateLimitReachedType":"rate_limit_reached""#,
            #""rateLimitReachedType":"workspace_owner_credits_depleted""#,
            #""rateLimitReachedType":"workspace_member_credits_depleted""#,
            #""rateLimitReachedType":"workspace_owner_usage_limit_reached""#,
            #""rateLimitReachedType":"workspace_member_usage_limit_reached""#,
        ] {
            let blocked = try read(
                """
                {"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":20},\(restriction)}}
                """)
            precondition(blocked.ordinaryUsageAllowed == false && blocked.windows.first?.remaining == 80)
        }
        for flag in [#""spendControlReached":true"#, #""rateLimitReachedType":{"kind":"new"}"#] {
            let snapshot = #"{"primary":{"usedPercent":null},\#(flag)}"#
            for legacy in ["", #","rateLimits":{"limitId":"codex","primary":{"usedPercent":2}}"#] {
                let report = try read(
                    #"{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":\#(snapshot)}\#(legacy)}"#)
                precondition(report.ordinaryUsageAllowed == false && report.windows.isEmpty)
            }
        }
        let partialRestriction = try read(
            #"{"ordinaryUsageAllowed":"unknown","rateLimits":{"spendControlReached":"unknown","rateLimitReachedType":"blocked","primary":{"usedPercent":41}}}"#
        )
        precondition(
            partialRestriction.ordinaryUsageAllowed == false && partialRestriction.windows.map(\.remaining) == [59])
        let otherBucket = try read(
            """
            {"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{
                "limitId":"other","rateLimitReachedType":"blocked","primary":{"usedPercent":null}}},
                "rateLimits":{"limitId":"codex","primary":{"usedPercent":2}}}
            """)
        precondition(otherBucket.ordinaryUsageAllowed == true && otherBucket.windows.map(\.remaining) == [98])
        let futureRestriction = try read(
            """
            {
                "ordinaryUsageAllowed":true,
                "rateLimitsByLimitId":{"codex":{
                    "primary":{"usedPercent":97,"windowDurationMins":300},
                    "secondary":{"usedPercent":85,"windowDurationMins":10080},
                    "rateLimitReachedType":"future_plan_limit"
                }},
                "rateLimits":{"limitId":"codex","primary":{"usedPercent":2,"windowDurationMins":300}}
            }
            """)
        precondition(futureRestriction.ordinaryUsageAllowed == false)
        precondition(futureRestriction.windows.map(\.remaining) == [3, 15])
        let futureRestrictionWithoutWindows = try read(
            """
            {"rateLimitsByLimitId":{"codex":{"rateLimitReachedType":"future_plan_limit"}},
             "rateLimits":{"limitId":"codex","primary":{"usedPercent":2}}}
            """)
        precondition(futureRestrictionWithoutWindows.ordinaryUsageAllowed == false)
        precondition(futureRestrictionWithoutWindows.windows.isEmpty)
        let futureLegacyRestriction = try read(
            """
            {"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":null},
             "rateLimits":{"limitId":"codex","primary":{"usedPercent":97},"rateLimitReachedType":"future_plan_limit"}}
            """)
        precondition(futureLegacyRestriction.ordinaryUsageAllowed == false)
        precondition(futureLegacyRestriction.windows.map(\.remaining) == [3])
        let blocked = try read(#"{"ordinaryUsageAllowed":false,"rateLimits":{}}"#)
        let allowed = try read(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":2}}}"#)
        let nullReason = try read(
            """
            {"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":2},"rateLimitReachedType":null}}
            """)
        precondition(blocked.ordinaryUsageAllowed == false && blocked.windows.isEmpty)
        precondition(allowed.ordinaryUsageAllowed == true && weeklyOnly.ordinaryUsageAllowed == nil)
        precondition(nullReason.ordinaryUsageAllowed == true && nullReason.windows == allowed.windows)
        for reason in ["false", "true", "3", "{}", "[]"] {
            let selected = """
                {"primary":{"usedPercent":97},"rateLimitReachedType":\(reason)}
                """
            let report = try read(
                """
                {"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":\(selected)},
                 "rateLimits":{"limitId":"codex","primary":{"usedPercent":22}}}
                """)
            precondition(report.ordinaryUsageAllowed == false && report.windows.map(\.remaining) == [3])
            let selectedOnly = try read(
                """
                {"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":\(selected)}}
                """)
            precondition(selectedOnly.ordinaryUsageAllowed == false && selectedOnly.windows == report.windows)
            let legacy = try read(
                """
                {"ordinaryUsageAllowed":true,"rateLimits":\(selected)}
                """)
            precondition(legacy.ordinaryUsageAllowed == false && legacy.windows == report.windows)
        }
        print("Codex non-string reasons: selected windows and restriction preserved with and without a legacy bucket.")
        for bucket in [#""invalid""#, #"{"primary":{"usedPercent":"invalid"}}"#] {
            let fallback = try read(
                """
                {"rateLimitsByLimitId":{"codex":\(bucket)},"rateLimits":{"limitId":"codex","primary":{"usedPercent":22}}}
                """)
            precondition(fallback.windows.map(\.remaining) == [78])
            for identity in ["null", #""alternate""#] {
                do {
                    _ = try read(
                        """
                        {"rateLimitsByLimitId":{"codex":\(bucket)},"rateLimits":{"limitId":\(identity),"primary":{"usedPercent":22}}}
                        """)
                    preconditionFailure("An ambiguous legacy bucket cannot stand in for a malformed Codex bucket")
                } catch QuotaError.quotaUnavailable {}
            }
        }

        do {
            _ = try read(
                """
                {"rateLimits":{"secondary":{"usedPercent":-1,"windowDurationMins":300}}}
                """)
            preconditionFailure("Missing or invalid windows should report quota unavailable")
        } catch QuotaError.quotaUnavailable {}

        do {
            _ = try read(
                """
                {"rateLimits":{"limitId":"alternate","primary":{"usedPercent":0,"windowDurationMins":300}}}
                """)
            preconditionFailure("An alternate model bucket should not replace the Codex quota")
        } catch QuotaError.quotaUnavailable {}

        let countOnly = try read(
            """
            {
                "accountId":"fixture-account",
                "rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},
                "rateLimitResetCredits":{"availableCount":3,"credits":null}
            }
            """)
        precondition(countOnly.resetAccountFingerprint?.count == 64)
        precondition(countOnly.resetCredits?.canClaim(at: fetchedAt) == true)
        precondition(countOnly.resetCredits?.nextExpiration(at: fetchedAt) == nil)
        precondition(countOnly.resetCredits?.preferredCreditID(at: fetchedAt) == nil)

        let detailed = try read(
            """
            {
                "accountId":"fixture-account",
                "rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},
                "rateLimitResetCredits": {
                    "availableCount":4,
                    "credits":[
                        {"id":"late","resetType":"codexRateLimits","status":"available","expiresAt":1800100000},
                        {"id":"no date","resetType":"codexRateLimits","status":"available","expiresAt":null},
                        {"id":"soon","resetType":"codexRateLimits","status":"available","expiresAt":1800000600},
                        {"id":"soon","resetType":"codexRateLimits","status":"available","expiresAt":1800000600},
                        {"id":"spent","resetType":"codexRateLimits","status":"redeemed","expiresAt":1800000001},
                        {"id":"other","resetType":"unknown","status":"available","expiresAt":1800000002}
                    ]
                }
            }
            """)
        let firstExpiration = fetchedAt.addingTimeInterval(600)
        let lastExpiration = fetchedAt.addingTimeInterval(100_000)
        precondition(detailed.resetAccountFingerprint == countOnly.resetAccountFingerprint)
        precondition(detailed.resetCredits?.availableCount(at: fetchedAt) == 4)
        precondition(detailed.resetCredits?.nextExpiration(at: fetchedAt) == firstExpiration)
        precondition(detailed.resetCredits?.preferredCreditID(at: fetchedAt) == "soon")
        precondition(detailed.resetCredits?.availableCount(at: firstExpiration) == 3)
        precondition(detailed.resetCredits?.nextExpiration(at: firstExpiration) == lastExpiration)
        precondition(detailed.resetCredits?.preferredCreditID(at: firstExpiration) == "late")
        precondition(detailed.resetCredits?.availableCount(at: lastExpiration) == 2)
        precondition(detailed.resetCredits?.preferredCreditID(at: lastExpiration) == "no date")
        precondition(detailed.resetCredits?.nextExpiration(at: lastExpiration) == nil)

        let expires = try read(
            """
            {
                "rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},
                "rateLimitResetCredits": {
                    "availableCount":1,
                    "credits":[{"id":"one","resetType":"codexRateLimits","status":"available","expiresAt":1800000600}]
                }
            }
            """)
        precondition(expires.resetCredits?.canClaim(at: fetchedAt) == true)
        precondition(expires.resetCredits?.availableCount(at: firstExpiration) == 0)
        precondition(expires.resetCredits?.canClaim(at: firstExpiration) == false)
        precondition(expires.resetCredits?.preferredCreditID(at: firstExpiration) == nil)

        let mixedDetails = try read(
            """
            {"rateLimits":{"primary":{"usedPercent":50}},
             "rateLimitResetCredits":{"availableCount":2,"credits":[
               {"id":"target","resetType":"codexRateLimits","status":"available","expiresAt":null},
               {"resetType":"unknown","status":"available"}
             ]}}
            """)
        precondition(mixedDetails.resetCredits?.preferredCreditID(at: fetchedAt) == "target")

        let zero = try read(
            #"{"rateLimits":{"primary":{"usedPercent":10}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#)
        precondition(zero.resetCredits?.availableCount == 0 && zero.resetCredits?.canClaim(at: fetchedAt) == false)
        let invalidCredits = try read(
            #"{"rateLimits":{"primary":{"usedPercent":10}},"rateLimitResetCredits":{"availableCount":"bad"}}"#)
        precondition(invalidCredits.resetCredits == nil && invalidCredits.windows.count == 1)

        func summary(_ count: Int, details: String) throws -> QuotaResetCredits? {
            try read(
                """
                {"rateLimits":{"primary":{"usedPercent":20}},
                 "rateLimitResetCredits":{"availableCount":\(count),"credits":\(details)}}
                """
            ).resetCredits
        }
        let availableRow = #"{"id":"A","resetType":"codexRateLimits","status":"available"}"#
        let spentRow = #"{"id":"A","resetType":"codexRateLimits","status":"redeemed"}"#
        let impossibleExpiry =
            #"{"id":"B","resetType":"codexRateLimits","status":"available","expiresAt":1800000000000}"#
        for (count, details) in [
            (-1, "null"), (0, "[\(availableRow)]"), (2, "[\(availableRow),\(spentRow)]"),
            (1, #""unreadable""#), (1, "[\(impossibleExpiry)]"),
        ] {
            let invalid = try summary(count, details: details)
            precondition(invalid == nil)
        }
        for details in ["[]", "[{}]", "[\(spentRow)]"] {
            let nonspecific = try summary(2, details: details)
            precondition(nonspecific?.availableCount == 2 && nonspecific?.canClaim(at: fetchedAt) == false)
        }

        try checkClaims()
        print("Quota data checks passed")
    }

    private static func checkClaims() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let log = fixtureDirectory.appendingPathComponent("requests.jsonl")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let key = UUID(uuidString: "205365B8-5110-4FF4-9301-54612CC1D002")!
        let originalCredit = "opaque\"credit\\record"

        func withMock<Result>(_ scenario: String, _ run: () throws -> Result) throws -> (Result, [[String: Any]]) {
            try Data().write(to: log)
            setenv("QUOTABAR_MOCK_SCENARIO", scenario, 1)
            setenv("QUOTABAR_MOCK_LOG", log.path, 1)
            defer {
                unsetenv("QUOTABAR_MOCK_SCENARIO")
                unsetenv("QUOTABAR_MOCK_LOG")
            }
            let result = try run()
            let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            return (result, requests)
        }

        func read(_ scenario: String, expectsUserRead: Bool, includeCountOnlyIdentity: Bool = false) throws
            -> QuotaReading
        {
            let (reading, requests) = try withMock(scenario) {
                try QuotaSource.read(includeCountOnlyIdentity: includeCountOnlyIdentity, executable: executable)
            }
            let methods = requests.compactMap { $0["method"] as? String }
            let expected =
                ["initialize", "initialized", "account/rateLimits/read"] + (expectsUserRead ? ["account/read"] : [])
            precondition(methods == expected)
            return reading
        }

        for (scenario, expected) in [
            ("quotaSignedOut", QuotaError.signInRequired), ("quotaApiKey", .subscriptionRequired),
            ("quotaMissingIdentityField", .requestFailed), ("quotaRejected", .requestFailed),
            ("quotaUnknownIdentity", .requestFailed),
            ("quotaStall", .timedOut), ("quotaDropped", .transportFailed), ("quotaMalformed", .invalidResponse),
            ("quotaPartialEOF", .transportFailed), ("quotaUnrelatedEOF", .transportFailed),
        ] {
            let (failure, requests) = try withMock(scenario) { () -> QuotaError? in
                do {
                    _ = try QuotaSource.read(executable: executable, timeout: .seconds(2))
                    return nil
                } catch let error as QuotaError {
                    return error
                }
            }
            precondition(failure == expected, "Unexpected failure for " + scenario)
            precondition(!requests.contains { ($0["method"] as? String)?.contains("consume") == true })
        }

        let finalReading = try read("quotaFinalEOF", expectsUserRead: false)
        precondition(finalReading.windows.map(\.used) == [37])
        let countOnly = try read("default", expectsUserRead: true)
        let otherUser = try read("otherUser", expectsUserRead: true)
        let noUser = try read("missingUser", expectsUserRead: true)
        let failedUserLookup = try read("userLookupFailed", expectsUserRead: true)
        let noWorkspace = try read("missingAccount", expectsUserRead: false)
        let detailed = try read("detailed", expectsUserRead: false)
        let detailedWithPending = try read("detailed", expectsUserRead: true, includeCountOnlyIdentity: true)
        let zeroWithPending = try read("zero", expectsUserRead: true, includeCountOnlyIdentity: true)
        let workspace = countOnly.resetAccountFingerprint!
        let user = countOnly.resetCountOnlyFingerprint!
        precondition(user != workspace && user.count == 64)
        precondition(otherUser.resetAccountFingerprint == workspace)
        precondition(otherUser.resetCountOnlyFingerprint != nil && otherUser.resetCountOnlyFingerprint != user)
        precondition(noUser.resetCredits?.availableCount == 3 && noUser.resetCountOnlyFingerprint == nil)
        precondition(failedUserLookup.windows.count == 1 && failedUserLookup.resetCountOnlyFingerprint == nil)
        precondition(noWorkspace.resetCountOnlyFingerprint == nil)
        precondition(detailed.resetAccountFingerprint == workspace && detailed.resetCountOnlyFingerprint == nil)
        precondition(detailedWithPending.resetCountOnlyFingerprint == user)
        precondition(
            zeroWithPending.resetCredits?.availableCount == 0 && zeroWithPending.resetCountOnlyFingerprint == user)

        for scenario in [
            "blockedZero", "blockedNamed", "blockedMissingUser", "blockedLookupFailed", "blockedNoWorkspace",
        ] {
            let reading = try read(scenario, expectsUserRead: scenario != "blockedNoWorkspace")
            precondition(reading.ordinaryUsageAllowed == false)
            let expectedIdentity = ["blockedZero", "blockedNamed"].contains(scenario) ? user : nil
            precondition(reading.resetCountOnlyFingerprint == expectedIdentity)
        }

        func claim(
            _ scenario: String,
            expected: QuotaResetClaimResult,
            creditID: String? = nil,
            identity: String? = nil,
            sends: Bool = true
        ) throws {
            let (result, requests) = try withMock(scenario) {
                QuotaSource.claimReset(
                    idempotencyKey: key,
                    creditID: creditID,
                    accountFingerprint: identity,
                    executable: executable,
                    timeout: ["stall", "ignoresTermination"].contains(scenario) ? .milliseconds(750) : .seconds(5)
                )
            }
            precondition(result == expected, "Expected \(expected) for \(scenario), got \(result)")
            if scenario == "ignoresTermination" {
                let childPID = requests.compactMap { $0["mockPID"] as? Int32 }.first!
                precondition(kill(childPID, 0) == -1 && errno == ESRCH, "Timed-out mock server still alive")
            }
            if identity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                precondition(requests.isEmpty)
            }
            let claims = requests.filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }
            precondition(claims.count == (sends ? 1 : 0))
            if identity != nil, scenario != "initFail" {
                let reads = requests.filter { $0["method"] as? String == "account/rateLimits/read" }
                precondition(reads.count == 1)
                let params = reads[0]["params"] as? [String: Any]
                precondition(params?["excludeResetCreditDetails"] as? Bool == true)
            }
            let userReads = requests.filter { $0["method"] as? String == "account/read" }
            precondition(
                userReads.count == (creditID == nil && identity != nil && scenario != "missingAccount" ? 1 : 0))
            if let params = claims.first?["params"] as? [String: Any] {
                precondition(params["idempotencyKey"] as? String == key.uuidString.lowercased())
                precondition(params["creditId"] as? String == creditID)
            } else {
                precondition(!sends)
            }
        }

        try claim("initFail", expected: .accountChanged, creditID: originalCredit, sends: false)
        try claim("initFail", expected: .accountChanged, creditID: originalCredit, identity: " ", sends: false)
        try claim(
            "missingAccount", expected: .accountChanged, creditID: originalCredit, identity: workspace, sends: false)
        try claim(
            "mismatchedAccount", expected: .accountChanged, creditID: originalCredit, identity: workspace, sends: false)
        try claim("reset", expected: .reset, creditID: originalCredit, identity: workspace)
        try claim("alreadyRedeemed", expected: .reset, creditID: originalCredit, identity: workspace)
        try claim("alreadyRedeemed", expected: .reset, identity: user)
        try claim("nothingToReset", expected: .nothingToReset, identity: user)
        try claim("noCredit", expected: .noCredit, creditID: originalCredit, identity: workspace)
        try claim("mismatchedAccount", expected: .accountChanged, identity: user, sends: false)
        try claim("missingAccount", expected: .accountChanged, identity: user, sends: false)
        try claim("otherUser", expected: .accountChanged, identity: user, sends: false)
        try claim("signedOut", expected: .accountChanged, identity: user, sends: false)
        try claim("missingUser", expected: .accountChanged, identity: user, sends: false)
        try claim("userLookupFailed", expected: .failedBeforeSending, identity: user, sends: false)
        try claim("reset", expected: .accountChanged, identity: workspace, sends: false)
        try claim("reset", expected: .accountChanged, sends: false)
        try claim("methodNotFound", expected: .unavailable, creditID: originalCredit, identity: workspace)
        try claim("unsupported", expected: .unavailable, creditID: originalCredit, identity: workspace)
        try claim(
            "initFail", expected: .failedBeforeSending, creditID: originalCredit, identity: workspace, sends: false)
        try claim("drop", expected: .unknown, creditID: originalCredit, identity: workspace)
        try claim("stall", expected: .unknown, creditID: originalCredit, identity: workspace)
        try claim("ignoresTermination", expected: .unknown, creditID: originalCredit, identity: workspace)
        try claim("serverError", expected: .unknown, creditID: originalCredit, identity: workspace)
        try claim("futureOutcome", expected: .unknown, creditID: originalCredit, identity: workspace)
    }

    private static func mockAppServer() throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["QUOTABAR_MOCK_SCENARIO"]!
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: environment["QUOTABAR_MOCK_LOG"]!))
        defer { try? log.close() }

        func reply(_ json: String) throws {
            try FileHandle.standardOutput.write(contentsOf: Data((json + "\n").utf8))
        }

        while let line = readLine() {
            let data = Data(line.utf8)
            try log.write(contentsOf: Data((line + "\n").utf8))
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            switch request["method"] as? String {
            case "initialize":
                let params = request["params"] as? [String: Any]
                let info = params?["clientInfo"] as? [String: String]
                let version =
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                precondition(info?["version"] == version)
                if scenario == "initFail" { return }
                try reply(#"{"id":1,"result":{}}"#)
            case "initialized":
                try reply(#"{"method":"account/rateLimits/updated","params":{}}"#)
            case "account/rateLimits/read":
                let params = request["params"] as? [String: Any]
                switch scenario {
                case "quotaSignedOut", "quotaApiKey", "quotaRejected", "quotaUnknownIdentity",
                    "quotaMissingIdentityField":
                    try reply(#"{"id":2,"error":{"code":-32603,"message":"Provider request failed"}}"#)
                case "quotaFinalEOF", "quotaPartialEOF", "quotaUnrelatedEOF":
                    let final: String
                    switch scenario {
                    case "quotaPartialEOF": final = #"{"id":2,"result":{"rateLimits":"#
                    case "quotaUnrelatedEOF": final = #"{"id":99,"result":{}}"#
                    default: final = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37}}}}"#
                    }
                    try FileHandle.standardOutput.write(contentsOf: Data(final.utf8))
                    return
                case "quotaDropped": return
                case "quotaStall": break
                case "quotaMalformed": try reply(#"{"id":2,"result":"bad"}"#)
                case "blockedZero", "blockedMissingUser", "blockedLookupFailed":
                    try reply(
                        #"{"id":2,"result":{"ordinaryUsageAllowed":false,"rateLimits":{},"accountId":"fixture-account","rateLimitResetCredits":{"availableCount":0,"credits":[]}}}"#
                    )
                case "blockedNamed":
                    try reply(
                        #"{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"spendControlReached":true,"primary":{"usedPercent":2}}},"accountId":"fixture-account","rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"known","resetType":"codexRateLimits","status":"available"}]}}}"#
                    )
                case "blockedNoWorkspace":
                    try reply(#"{"id":2,"result":{"ordinaryUsageAllowed":false,"rateLimits":{},"accountId":null}}"#)
                case "mismatchedAccount":
                    try reply(
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":50}},"accountId":"different-account"}}"#
                    )
                case "missingAccount":
                    try reply(
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":50}},"accountId":null,"rateLimitResetCredits":{"availableCount":3,"credits":null}}}"#
                    )
                case "detailed":
                    try reply(
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":50}},"accountId":"fixture-account","rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"known","resetType":"codexRateLimits","status":"available","expiresAt":null}]}}}"#
                    )
                case "zero":
                    try reply(
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":50}},"accountId":"fixture-account","rateLimitResetCredits":{"availableCount":0,"credits":[]}}}"#
                    )
                default:
                    let count = params?["excludeResetCreditDetails"] as? Bool == true ? 0 : 3
                    try reply(
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":50}},"accountId":"fixture-account","rateLimitResetCredits":{"availableCount":\#(count),"credits":null}}}"#
                    )
                }
            case "account/read":
                precondition((request["params"] as? [String: Any])?.isEmpty == true)
                switch scenario {
                case "quotaSignedOut":
                    try reply(#"{"id":3,"result":{"requiresOpenaiAuth":true,"account":null}}"#)
                case "quotaMissingIdentityField":
                    try reply(#"{"id":3,"result":{"requiresOpenaiAuth":true}}"#)
                case "quotaApiKey":
                    try reply(#"{"id":3,"result":{"account":{"type":"apiKey"}}}"#)
                case "quotaUnknownIdentity":
                    try reply(#"{"id":3,"error":{"code":-32603,"message":"Account unavailable"}}"#)
                case "otherUser":
                    try reply(#"{"id":3,"result":{"account":{"type":"chatgpt"},"userId":"other-user"}}"#)
                case "signedOut":
                    try reply(#"{"id":3,"result":{"account":null,"userId":"fixture-user"}}"#)
                case "missingUser", "blockedMissingUser":
                    try reply(#"{"id":3,"result":{"account":{"type":"chatgpt"},"userId":null}}"#)
                case "userLookupFailed", "blockedLookupFailed":
                    try reply(#"{"id":3,"error":{"code":-32603,"message":"Unavailable"}}"#)
                default:
                    try reply(#"{"id":3,"result":{"account":{"type":"chatgpt"},"userId":"fixture-user"}}"#)
                }
            case "account/rateLimitResetCredit/consume":
                switch scenario {
                case "drop": return
                case "stall": break
                case "ignoresTermination":
                    signal(SIGTERM, SIG_IGN)
                    alarm(10)
                    try log.write(contentsOf: Data("{\"mockPID\":\(getpid())}\n".utf8))
                    while true { pause() }
                case "methodNotFound":
                    try reply(#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"#)
                case "unsupported":
                    try reply(
                        #"{"id":4,"error":{"code":-32600,"message":"Invalid request: unknown variant `account/rateLimitResetCredit/consume`, expected `initialize`"}}"#
                    )
                case "serverError":
                    try reply(#"{"id":4,"error":{"code":-32603,"message":"rate limit reset consume timed out"}}"#)
                default:
                    try reply(#"{"id":9,"result":{"outcome":"reset"}}"#)
                    try reply(#"{"id":4,"result":{"outcome":"\#(scenario)"}}"#)
                }
            default:
                preconditionFailure("Unexpected mock request")
            }
        }
    }
}
