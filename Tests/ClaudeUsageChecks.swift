import Darwin
import Foundation

@main
struct ClaudeUsageChecks {
    static func main() throws {
        if CommandLine.arguments.contains("-p") {
            try serveMock()
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--live"]) {
            do {
                let reading = try ClaudeUsageClient.read()
                let now = Date()
                guard let peak = reading.windows.map(\.used).max() else { throw ClaudeUsageClient.Failure.unavailable }
                for mode in PercentageMode.allCases {
                    let display = QuotaDisplay(
                        reading: reading, now: now, failed: false, refreshing: false,
                        provider: .claude, percentageMode: mode)
                    let expected = mode == .used ? peak : max(0, 100 - peak)
                    let suffix = mode == .used ? " used" : " remaining"
                    guard display.hasCurrentPercentage, let window = display.limitingWindow,
                        display.percentage(for: window) == expected, display.title != "–%",
                        display.accessibilityTitle.contains(display.title + suffix)
                    else { throw ClaudeUsageClient.Failure.unavailable }
                }
                print("Claude live usage read and both percentage modes passed.")
            } catch {
                let failure = error as? ClaudeUsageClient.Failure ?? .unavailable
                print("Claude live usage check failed. " + failure.localizedDescription)
                exit(1)
            }
            return
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report =
            #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":8,"resets_at":"2027-01-15T10:00:00.123456+00:00"},"seven_day":{"utilization":1,"resets_at":"2027-01-22T10:00:00Z"},"seven_day_opus":{"utilization":95,"resets_at":"2027-01-22T10:00:00Z"},"model_scoped":[{"display_name":"private model label","utilization":98,"resets_at":"2027-01-22T10:00:00Z"}]},"private_account":"never saved"}"#
        let reading = try ClaudeUsageClient.parse(Data(report.utf8), now: now)
        precondition(reading.windows.map(\.minutes) == [300, 10_080])
        precondition(reading.windows.map(\.remaining) == [92, 99])
        precondition(reading.resetAccountFingerprint == nil && reading.resetCredits == nil)
        let idleSession =
            #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":1,"resets_at":"2027-01-22T10:00:00Z"}}}"#
        let idleReading = try ClaudeUsageClient.parse(Data(idleSession.utf8), now: now)
        precondition(idleReading.windows.map(\.remaining) == [100, 99])
        precondition(idleReading.windows.first?.resetsAt == nil && idleReading.windows.last?.resetsAt != nil)
        try expect(.invalidResponse) {
            _ = try ClaudeUsageClient.parse(
                Data(idleSession.replacingOccurrences(of: "null", with: #""bad-date""#).utf8), now: now)
        }
        let expiredSession =
            #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":100,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":1,"resets_at":"2027-01-22T10:00:00Z"}}}"#
        let currentWeek = try ClaudeUsageClient.parse(Data(expiredSession.utf8), now: now)
        precondition(currentWeek.windows.map(\.minutes) == [10_080])
        precondition(currentWeek.windows.first?.remaining == 99)
        for minutes in [300, 10_080] {
            let key = minutes == 300 ? "five_hour" : "seven_day"
            for used in [0.0, 0.2, 42.0, 100.0] {
                for reset in ["", #", "resets_at":null"#] {
                    let data = Data(
                        """
                        {"rate_limits_available":true,"rate_limits":{"\(key)":{"utilization":\(used)\(reset)}}}
                        """.utf8)
                    let reading = try ClaudeUsageClient.parse(data, now: now)
                    precondition(reading.windows.count == 1 && reading.windows.first?.resetsAt == nil)
                    precondition(reading.windows.first?.used == used && reading.windows.first?.minutes == minutes)
                    for mode in PercentageMode.allCases {
                        let display = QuotaDisplay(
                            reading: reading, now: now, failed: false, refreshing: false,
                            provider: .claude, percentageMode: mode)
                        precondition(display.hasCurrentPercentage)
                        precondition(display.percentage(for: reading.windows[0]) == (mode == .used ? used : 100 - used))
                        let stale = QuotaDisplay(
                            reading: reading, now: now.addingTimeInterval(QuotaDisplay.maximumAge),
                            failed: false, refreshing: false, provider: .claude, percentageMode: mode)
                        precondition(!stale.hasCurrentPercentage)
                    }
                }
            }
        }
        for window in [
            #"{"utilization":null}"#, #"{"resets_at":null}"#, #"{"utilization":true}"#,
            #"{"utilization":-1}"#, #"{"utilization":101}"#, #"{"utilization":"8"}"#,
            #"{"utilization":1,"resets_at":"bad-date"}"#, #"{"utilization":1,"resets_at":123}"#,
        ] {
            for key in ["five_hour", "seven_day"] {
                let other = key == "five_hour" ? "seven_day" : "five_hour"
                let data = Data(
                    """
                    {"rate_limits_available":true,"rate_limits":{"\(key)":\(window),"\(other)":{"utilization":1,"resets_at":null}}}
                    """.utf8)
                try expect(.invalidResponse) { _ = try ClaudeUsageClient.parse(data, now: now) }
            }
        }
        for malformed in ["true", "-1", "101", #""8""#] {
            try expect(.invalidResponse) {
                _ = try ClaudeUsageClient.parse(
                    Data(
                        report.replacingOccurrences(of: "\"utilization\":8", with: "\"utilization\":" + malformed).utf8),
                    now: now)
            }
        }
        try expect(.unavailable) {
            _ = try ClaudeUsageClient.parse(
                Data(#"{"rate_limits_available":true,"rate_limits":{"model_scoped":[{"utilization":20}]}}"#.utf8),
                now: now)
        }
        try expect(.unavailable) {
            _ = try ClaudeUsageClient.parse(Data(report.utf8), now: Date(timeIntervalSince1970: 2_000_000_000))
        }
        try expect(.accountUnavailable) {
            _ = try ClaudeUsageClient.parse(Data(#"{"rate_limits_available":false,"rate_limits":null}"#.utf8), now: now)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for mode in ["success", "interleaved", "unsupported", "denied", "invalid", "oversized", "hang", "exit"] {
            setenv("QUOTABAR_CLAUDE_TEST_MODE", mode, 1)
            defer { unsetenv("QUOTABAR_CLAUDE_TEST_MODE") }
            if mode == "success" || mode == "interleaved" {
                let live = try ClaudeUsageClient.read(executable: executable, timeout: 2)
                precondition(live.windows.first?.remaining == 63)
            } else {
                let failure: ClaudeUsageClient.Failure
                switch mode {
                case "unsupported": failure = .unsupported
                case "invalid", "oversized": failure = .invalidResponse
                case "hang": failure = .timedOut
                default: failure = .unavailable
                }
                let start = Date()
                try expect(failure) {
                    _ = try ClaudeUsageClient.read(executable: executable, timeout: mode == "hang" ? 0.15 : 2)
                }
                precondition(Date().timeIntervalSince(start) < 3)
            }
        }
        print(
            "Claude control checks passed: no conversation turns, exact aggregate windows, malformed data rejection, unsupported protocol, bounded output, EOF, and timeout cleanup."
        )
    }

    private static func expect(_ failure: ClaudeUsageClient.Failure, _ run: () throws -> Void) throws {
        do {
            try run()
            preconditionFailure("Expected a Claude usage failure")
        } catch let error as ClaudeUsageClient.Failure {
            precondition(String(describing: error) == String(describing: failure))
        }
    }

    private static func serveMock() throws {
        let arguments = CommandLine.arguments
        for flag in [
            "--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--tools", "--setting-sources",
            "--settings",
        ] {
            precondition(arguments.contains(flag))
        }
        guard let first = readLine(),
            let initialize = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        else { exit(1) }
        precondition(initialize["type"] as? String == "control_request")
        precondition((initialize["request"] as? [String: Any])?["subtype"] as? String == "initialize")
        try respond(initialize, body: [:])
        guard let second = readLine(),
            let request = try JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any]
        else { exit(1) }
        precondition(request["type"] as? String == "control_request")
        let query = request["request"] as? [String: Any]
        precondition(query?["subtype"] as? String == "get_usage" && query?["skip_behaviors"] as? Bool == true)
        let mode = ProcessInfo.processInfo.environment["QUOTABAR_CLAUDE_TEST_MODE"]
        if mode == "hang" {
            sleep(10)
            return
        }
        if mode == "exit" { return }
        if mode == "oversized" {
            try FileHandle.standardOutput.write(contentsOf: Data(repeating: 0x41, count: 3 * 1024 * 1024))
            return
        }
        if mode == "invalid" {
            try FileHandle.standardOutput.write(contentsOf: Data("malformed\n".utf8))
            return
        }
        if mode == "interleaved" {
            for message: [String: Any] in [
                ["type": "system", "subtype": "status"],
                [
                    "type": "control_response",
                    "response": ["subtype": "error", "request_id": "other-request", "error": "unsupported"],
                ],
            ] {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
        if mode == "denied" {
            let message: [String: Any] = [
                "type": "control_response",
                "response": ["subtype": "error", "request_id": "usage", "error": "request failed"],
            ]
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
            return
        }
        if mode == "unsupported" {
            let response: [String: Any] = [
                "type": "control_response",
                "response": [
                    "subtype": "error", "request_id": "usage", "error": "get_usage is not supported in this context",
                ],
            ]
            var data = try JSONSerialization.data(withJSONObject: response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
            return
        }
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try respond(
            request,
            body: [
                "rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": 37, "resets_at": reset]],
            ])
    }

    private static func respond(_ request: [String: Any], body: [String: Any]) throws {
        let response: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": request["request_id"]!, "response": body],
        ]
        var data = try JSONSerialization.data(withJSONObject: response)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
