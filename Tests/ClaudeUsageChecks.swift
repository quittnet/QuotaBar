import Darwin
import Foundation

@main
struct ClaudeUsageChecks {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        if let nativePath = environment["QUOTABAR_MOCK_NATIVE_PATH"], environment["PATH"] != nativePath {
            exit(1)
        }
        if CommandLine.arguments.contains("-p") {
            try serveMock()
            return
        }
        if CommandLine.arguments.contains("app-server") {
            try serveCodexMock()
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--selected-cli" {
            let name = CommandLine.arguments[2]
            let file = URL(fileURLWithPath: CommandLine.arguments[3])
            guard let home = environment["CFFIXED_USER_HOME"], file.path.hasPrefix(home + "/") else { exit(1) }
            // Let the normal provider entry point see the parent fixture without writing standard defaults.
            let suite = CommandLine.arguments[4]
            guard let selection = UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) else { exit(1) }
            UserDefaults.standard.setVolatileDomain(selection, forName: UserDefaults.argumentDomain)
            guard ProviderExecutable.hasSelection(name),
                ProviderExecutable.selected(name) == file.resolvingSymlinksInPath()
            else { exit(1) }
            let reading =
                name == "codex" ? try QuotaSource.read(timeout: .seconds(2)) : try ClaudeUsageClient.read(timeout: 2)
            precondition(reading.windows.first?.used == 37)
            return
        }
        if CommandLine.arguments.dropFirst().first == "--npm-cli" {
            let provider = CommandLine.arguments[2]
            do {
                try checkNPMCLI(provider: provider)
            } catch {
                print("Npm-style \(provider) launch failed: \(error)")
                exit(1)
            }
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--live"]) {
            // Discover the CLI as a fresh install would. The test binary's own preferences domain can hold
            // CLI choices left by older fixture runs that point at deleted temporary files.
            let suite = testPreferencesDomain()
            let isolated = UserDefaults(suiteName: suite)!
            defer { isolated.removePersistentDomain(forName: suite) }
            do {
                let reading = try ClaudeUsageClient.read(defaults: isolated)
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
        func parseReset(_ timestamp: String) throws -> Date? {
            let body = report.replacingOccurrences(of: "2027-01-15T10:00:00.123456+00:00", with: timestamp)
            return try ClaudeUsageClient.parse(Data(body.utf8), now: now).windows.first?.resetsAt
        }
        for date in [
            "2030-02-29T12:00:00Z", "2032-02-30T00:00:00Z", "2030-02-28T12:00:00Ztrailing",
            "2030-02-28T12:00:00.250Ztrailing", "2030-02-28T24:00:00Z", "2030-02-28T12:00:00+02:60",
        ] {
            try expect(.invalidResponse) { _ = try parseReset(date) }
        }
        let offsetDate = try parseReset("2032-02-29T23:45:00.250-02:30")
        let utcDate = try parseReset("2032-03-01T02:15:00.250Z")
        let hourOffset = try parseReset("2032-03-01T04:15:00.250+02")
        precondition(offsetDate != nil && offsetDate == utcDate && hourOffset == utcDate)
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
        for mode in [
            "success", "interleaved", "final-eof", "partial-eof", "unsupported", "denied", "invalid", "oversized",
            "hang", "exit",
        ] {
            setenv("QUOTABAR_CLAUDE_TEST_MODE", mode, 1)
            defer { unsetenv("QUOTABAR_CLAUDE_TEST_MODE") }
            if ["success", "interleaved", "final-eof"].contains(mode) {
                let live = try ClaudeUsageClient.read(executable: executable, timeout: 2)
                precondition(live.windows.first?.remaining == 63)
            } else {
                let failure: ClaudeUsageClient.Failure
                switch mode {
                case "unsupported": failure = .unsupported
                case "invalid", "oversized", "partial-eof": failure = .invalidResponse
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
        try checkConfigurationDirectory(executable: executable)
        try checkNPMCLI(provider: "codex")
        try checkNPMCLI(provider: "claude")
        print(
            "Claude control checks passed: no conversation turns, exact aggregate windows, malformed data rejection, unsupported protocol, bounded output, EOF, and timeout cleanup."
        )
    }

    private static func checkNPMCLI(provider: String) throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("quotabar CLI " + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        func script(_ name: String, _ content: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let cliModule = try script("cli.js", "#!/usr/bin/env node\n")
        let cli = directory.appendingPathComponent(provider)
        try files.createSymbolicLink(at: cli, withDestinationURL: cliModule)
        _ = try script(
            "node",
            """
            #!/bin/sh
            [ "$1" = "$QUOTABAR_MOCK_NPM_CLI" ] || exit 1
            shift
            exec "$QUOTABAR_MOCK_NPM_PROBE" "$@"

            """)
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        let probe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        setenv("QUOTABAR_MOCK_NPM_CLI", cli.path, 1)
        setenv("QUOTABAR_MOCK_NPM_PROBE", probe.path, 1)
        defer {
            if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
            unsetenv("QUOTABAR_MOCK_NPM_CLI")
            unsetenv("QUOTABAR_MOCK_NPM_PROBE")
            unsetenv("QUOTABAR_MOCK_NATIVE_PATH")
        }
        func read(executable: URL, path: String) throws {
            setenv("PATH", path, 1)
            let reading =
                provider == "codex"
                ? try QuotaSource.read(executable: executable, timeout: .seconds(2))
                : try ClaudeUsageClient.read(executable: executable, timeout: 2)
            precondition(reading.windows.first?.used == 37)
        }
        let guiPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        try read(executable: cli, path: guiPath)
        let competing = directory.appendingPathComponent("competing", isDirectory: true)
        try files.createDirectory(at: competing, withIntermediateDirectories: false)
        _ = try script("competing/node", "#!/bin/sh\nexit 1\n")
        let competingPath = "\(competing.path):\(guiPath):\(directory.path)"
        try read(executable: cli, path: ".::" + competingPath)
        let native = directory.appendingPathComponent("native-" + provider)
        try files.createSymbolicLink(at: native, withDestinationURL: probe)
        for path in [guiPath, competingPath] {
            setenv("QUOTABAR_MOCK_NATIVE_PATH", path, 1)
            try read(executable: native, path: ".::" + path)
        }

        let versions = directory.appendingPathComponent("nvm/versions/node", isDirectory: true)
        for version in ["v9.12.0", "v22.1.0", "v22.12.0", "v99.0.0-invalid"] {
            let bin = versions.appendingPathComponent("\(version)/bin", isDirectory: true)
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            try files.createSymbolicLink(at: bin.appendingPathComponent(provider), withDestinationURL: cliModule)
        }
        let paths = ProviderCLIPaths(
            home: directory,
            environment: ["PATH": ".::\(guiPath)", "NVM_DIR": directory.appendingPathComponent("nvm").path])
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(paths.executable(named: provider, preferred: [native], defaults: defaults) == nil)
        let chosen = versions.appendingPathComponent("v22.12.0/bin/\(provider)")
        try ProviderExecutable.choose(chosen, name: provider, defaults: defaults)
        precondition(
            paths.executable(named: provider, preferred: [], defaults: defaults) == chosen.resolvingSymlinksInPath())
        let chosenBin = chosen.deletingLastPathComponent()
        try files.createSymbolicLink(at: chosenBin.appendingPathComponent("node"), withDestinationURL: probe)
        let selectedCheck = Process()
        selectedCheck.executableURL = probe
        precondition(defaults.synchronize())
        selectedCheck.arguments = ["--selected-cli", provider, chosen.path, suite]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "QUOTABAR_MOCK_NATIVE_PATH")
        environment["HOME"] = directory.path
        environment["CFFIXED_USER_HOME"] = directory.path
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        environment["CODEX_HOME"] = directory.path
        environment["PATH"] = guiPath
        selectedCheck.environment = environment
        try selectedCheck.run()
        selectedCheck.waitUntilExit()
        precondition(
            selectedCheck.terminationStatus == 0, "Selected CLI must work through the provider’s normal entry point")
        let selectedEnv = paths.childEnvironment(
            for: chosen.resolvingSymlinksInPath(), named: provider, defaults: defaults)
        precondition(selectedEnv["PATH"]?.components(separatedBy: ":").first == chosenBin.path)
        let moved = directory.appendingPathComponent("relocated-" + provider)
        try files.moveItem(at: chosen, to: moved)
        precondition(ProviderExecutable.hasSelection(provider, defaults: defaults))
        precondition(paths.executable(named: provider, preferred: [], defaults: defaults) == nil)
        try ProviderExecutable.choose(moved, name: provider, defaults: defaults)
        do {
            try ProviderExecutable.choose(chosen, name: provider, defaults: defaults)
            preconditionFailure("Choosing the old, missing path should fail")
        } catch let error as CocoaError {
            precondition(error.code == .fileReadNoPermission)
        }
        precondition(ProviderExecutable.selected(provider, defaults: defaults) == cliModule.resolvingSymlinksInPath())
        try files.moveItem(at: moved, to: chosen)
        precondition(ProviderExecutable.selected(provider, defaults: defaults) == nil)
        try ProviderExecutable.choose(chosen, name: provider, defaults: defaults)
        try Data("#!/usr/bin/env node\n// new version\n".utf8).write(to: cliModule)
        precondition(paths.executable(named: provider, preferred: [], defaults: defaults) == nil)
        try ProviderExecutable.choose(chosen, name: provider, defaults: defaults)
        precondition(
            paths.executable(named: provider, preferred: [], defaults: defaults) == chosen.resolvingSymlinksInPath())
        try files.removeItem(at: chosen)
        try files.createSymbolicLink(at: chosen, withDestinationURL: probe)
        precondition(paths.executable(named: provider, preferred: [], defaults: defaults) == nil)
        ProviderExecutable.useAutomatic(provider, defaults: defaults)
        precondition(paths.executable(named: provider, preferred: [], defaults: defaults) == nil)
        let childPath = paths.childEnvironment(for: cli)["PATH"]
        precondition(childPath == "\(directory.path):\(guiPath)")
    }

    private static func serveCodexMock() throws {
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let reply: String
            switch request?["method"] as? String {
            case "initialize": reply = #"{"id":1,"result":{}}"#
            case "account/rateLimits/read":
                reply = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":300}}}}"#
            default: continue
            }
            try FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8))
        }
    }

    private static func expect(_ failure: ClaudeUsageClient.Failure, _ run: () throws -> Void) throws {
        do {
            try run()
            preconditionFailure("Expected a Claude usage failure")
        } catch let error as ClaudeUsageClient.Failure {
            precondition(String(describing: error) == String(describing: failure))
        }
    }

    /// The default ~/.claude profile must reach Claude Code without CLAUDE_CONFIG_DIR, or Claude Code
    /// reads a separate, signed-out .claude.json and keychain item and reports no subscription limits.
    private static func checkConfigurationDirectory(executable: URL) throws {
        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        func child(_ environment: [String: String]) -> String? {
            ClaudeProfile.childConfigurationDirectory(defaults: defaults, environment: environment, home: home)
        }
        for invalid in ["", "relative/profile"] {
            precondition(child(["CLAUDE_CONFIG_DIR": invalid]) == nil)
        }
        precondition(child([:]) == nil, "The default profile must not set CLAUDE_CONFIG_DIR.")
        precondition(child(["CLAUDE_CONFIG_DIR": "/Users/fixture/.claude"]) == "/Users/fixture/.claude")
        precondition(child(["CLAUDE_CONFIG_DIR": "/Volumes/work/claude"]) == "/Volumes/work/claude")
        for standard in ["/Users/fixture/.claude", "/Users/fixture/.claude/", "/Users/fixture/./.claude"] {
            ClaudeProfile.select(URL(fileURLWithPath: standard, isDirectory: true), defaults: defaults)
            precondition(child(["CLAUDE_CONFIG_DIR": "/Volumes/work/claude"]) == nil)
            precondition(child([:]) == nil, "Selecting \(standard) must keep Claude Code's default profile.")
        }
        ClaudeProfile.select(URL(fileURLWithPath: "/Users/fixture/work-claude", isDirectory: true), defaults: defaults)
        precondition(child([:]) == "/Users/fixture/work-claude")
        ClaudeProfile.select(nil, defaults: defaults)

        // A home reached through a link (/tmp is /private/tmp) must match whether or not .claude exists yet.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("quotabar-alias-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spellings = [root.path, "/private" + root.path]
        for exists in [false, true] {
            let folder = root.appendingPathComponent(".claude", isDirectory: true)
            if exists { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            for homeSpelling in spellings {
                for selectedSpelling in spellings {
                    ClaudeProfile.select(
                        URL(fileURLWithPath: selectedSpelling + "/.claude", isDirectory: true), defaults: defaults)
                    let home = URL(fileURLWithPath: homeSpelling, isDirectory: true)
                    let value = ClaudeProfile.childConfigurationDirectory(
                        defaults: defaults, environment: [:], home: home)
                    precondition(
                        value == nil,
                        "Selecting \(selectedSpelling)/.claude with home \(homeSpelling) (exists: \(exists)) passed a path."
                    )
                }
            }
        }
        ClaudeProfile.select(nil, defaults: defaults)

        // The real read path omits the variable for the default profile and passes a configured one.
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("claude-env-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: record) }
        let inherited = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        defer { if let inherited { setenv("CLAUDE_CONFIG_DIR", inherited, 1) } }
        setenv("QUOTABAR_CLAUDE_TEST_MODE", "success", 1)
        setenv("QUOTABAR_CLAUDE_ENV_RECORD", record.path, 1)
        defer {
            unsetenv("QUOTABAR_CLAUDE_TEST_MODE")
            unsetenv("QUOTABAR_CLAUDE_ENV_RECORD")
        }
        unsetenv("CLAUDE_CONFIG_DIR")
        let standardDirectory = ClaudeProfile.directory.path
        precondition(standardDirectory.hasSuffix("/.claude") && ClaudeProfile.childConfigurationDirectory() == nil)
        _ = try ClaudeUsageClient.read(executable: executable, timeout: 2)
        let omitted = try String(contentsOf: record, encoding: .utf8)
        precondition(omitted == "<unset>", "Default profile passed CLAUDE_CONFIG_DIR=\(omitted).")
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("custom-claude").path
        setenv("CLAUDE_CONFIG_DIR", custom, 1)
        _ = try ClaudeUsageClient.read(executable: executable, timeout: 2)
        let passed = try String(contentsOf: record, encoding: .utf8)
        precondition(passed == custom)
        ClaudeProfile.select(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"), defaults: defaults)
        _ = try ClaudeUsageClient.read(executable: executable, timeout: 2, defaults: defaults)
        let selectedStandard = try String(contentsOf: record, encoding: .utf8)
        precondition(selectedStandard == "<unset>")
        print("Claude default profile reaches Claude Code without CLAUDE_CONFIG_DIR; custom profiles pass it.")
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
        if let record = ProcessInfo.processInfo.environment["QUOTABAR_CLAUDE_ENV_RECORD"] {
            let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "<unset>"
            try Data(value.utf8).write(to: URL(fileURLWithPath: record))
        }
        if mode == "hang" {
            sleep(10)
            return
        }
        if mode == "exit" { return }
        if mode == "oversized" {
            try FileHandle.standardOutput.write(contentsOf: Data(repeating: 0x41, count: 3 * 1024 * 1024))
            return
        }
        if mode == "partial-eof" {
            try FileHandle.standardOutput.write(contentsOf: Data(#"{"type":"control_response""#.utf8))
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
            ], appendNewline: mode != "final-eof")
    }

    private static func respond(_ request: [String: Any], body: [String: Any], appendNewline: Bool = true) throws {
        let response: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": request["request_id"]!, "response": body],
        ]
        var data = try JSONSerialization.data(withJSONObject: response)
        if appendNewline { data.append(0x0A) }
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
