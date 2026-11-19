import Darwin
import Foundation

@main
struct ClaudeUsageChecks {
    static func main() throws {
        if CommandLine.arguments.contains("-p") {
            try serveMock()
            return
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report =
            #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":8,"resets_at":"2027-01-15T10:00:00.123456+00:00"},"seven_day":{"utilization":1,"resets_at":"2027-01-22T10:00:00Z"},"seven_day_opus":{"utilization":95,"resets_at":"2027-01-22T10:00:00Z"},"model_scoped":[{"display_name":"private model label","utilization":98,"resets_at":"2027-01-22T10:00:00Z"}]},"private_account":"never saved"}"#
        let reading = try ClaudeUsageClient.parse(Data(report.utf8), now: now)
        precondition(reading.windows.map(\.minutes) == [300, 10_080])
        precondition(reading.windows.map(\.remaining) == [92, 99])
        precondition(reading.resetAccountFingerprint == nil && reading.resetCredits == nil)
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
        for mode in ["success", "unsupported", "invalid", "oversized", "hang", "exit"] {
            setenv("QUOTABAR_CLAUDE_TEST_MODE", mode, 1)
            defer { unsetenv("QUOTABAR_CLAUDE_TEST_MODE") }
            if mode == "success" {
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
