import Foundation

@main
struct ClaudeConnectionChecks {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("QuotaBar-connection-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("QuotaBar ' quoted $ app")
        let captured = root.appendingPathComponent("captured.json")
        let arguments = root.appendingPathComponent("arguments.txt")
        try script(
            "#!/bin/sh\nprintf '%s' \"$1\" > " + quote(arguments.path)
                + "\ncat > " + quote(captured.path) + "\n", to: executable)

        let fresh = root.appendingPathComponent("fresh ' config $ directory")
        try ClaudeConnection.connect(directory: fresh, executable: executable)
        precondition(ClaudeConnection.isConfigured(directory: fresh))
        let first = try settings(fresh)
        let command = try statusCommand(first)
        let payload =
            #"{"session_id":"fixture-session","rate_limits":{"five_hour":{"used_percentage":12.5}},"model":{"display_name":"Fixture model"}}"#
        let freshOutput = try run(command, input: payload)
        precondition(!freshOutput.isEmpty, "A fresh status line needs visible output.")
        try check(try String(contentsOf: arguments, encoding: .utf8) == "--capture-claude-quota")
        let capturedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: captured)) as! [String: Any]
        precondition(capturedJSON["session_id"] as? String == "fixture-session")
        precondition(capturedJSON["rate_limits"] is [String: Any])
        let configured = try Data(contentsOf: fresh.appendingPathComponent("settings.json"))
        try ClaudeConnection.connect(directory: fresh, executable: executable)
        try check(try Data(contentsOf: fresh.appendingPathComponent("settings.json")) == configured)
        try check(try statusCommand(settings(fresh)) == command)

        let existing = root.appendingPathComponent("existing")
        try files.createDirectory(at: existing, withIntermediateDirectories: true)
        let originalInput = root.appendingPathComponent("original-input.json")
        let originalCommand = "cat > " + quote(originalInput.path) + "; printf '%s' 'existing output'"
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": originalCommand, "padding": 4],
            "permissions": ["allow": ["Read"]], "theme": "dark",
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys])
        try originalData.write(to: existing.appendingPathComponent("settings.json"))
        try ClaudeConnection.connect(directory: existing, executable: executable)
        precondition(ClaudeConnection.isConfigured(directory: existing))
        let updated = try settings(existing)
        precondition(updated["theme"] as? String == "dark")
        precondition((updated["permissions"] as? NSDictionary) == (original["permissions"] as? NSDictionary))
        precondition((updated["statusLine"] as? [String: Any])?["padding"] as? Int == 4)
        try check(try run(statusCommand(updated), input: payload) == "existing output")
        try check(try String(contentsOf: originalInput, encoding: .utf8) == payload)
        let allFiles = files.enumerator(at: existing, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
        precondition(
            allFiles.contains { (try? Data(contentsOf: $0)) == originalData },
            "The original settings must remain available as a backup.")
        let existingCommand = try statusCommand(updated)
        try ClaudeConnection.connect(directory: existing, executable: executable)
        try check(try statusCommand(settings(existing)) == existingCommand)
        try check(try run(existingCommand, input: payload) == "existing output")

        let multiline = payload + "\n\n"
        try check(try run(existingCommand, input: multiline) == "existing output")
        try check(try String(contentsOf: originalInput, encoding: .utf8) == multiline)
        try script("#!/bin/sh\nexit 4\n", to: executable)
        try check(try run(existingCommand, input: payload) == "existing output")

        let managedScript = existing.appendingPathComponent(".quotabar/statusline.sh")
        try files.removeItem(at: managedScript)
        precondition(!ClaudeConnection.isConfigured(directory: existing))
        try ClaudeConnection.connect(directory: existing, executable: executable)
        precondition(ClaudeConnection.isConfigured(directory: existing))
        try check(try run(existingCommand, input: payload) == "existing output")

        var overridden = try settings(existing)
        overridden["statusLine"] = ["type": "command", "command": "cat >/dev/null; printf 'replacement output'"]
        try JSONSerialization.data(withJSONObject: overridden).write(
            to: existing.appendingPathComponent("settings.json"))
        precondition(!ClaudeConnection.isConfigured(directory: existing))
        try ClaudeConnection.connect(directory: existing, executable: executable)
        precondition(ClaudeConnection.isConfigured(directory: existing))
        try check(try run(statusCommand(settings(existing)), input: payload) == "replacement output")

        let replacedCommand = try statusCommand(settings(existing))
        try Data("edited by user".utf8).write(to: managedScript)
        precondition(!ClaudeConnection.isConfigured(directory: existing))
        var changedScriptRejected = false
        do { try ClaudeConnection.connect(directory: existing, executable: executable) } catch {
            changedScriptRejected = true
        }
        precondition(changedScriptRejected)
        try check(try String(contentsOf: managedScript, encoding: .utf8) == "edited by user")
        try files.removeItem(at: managedScript)
        try ClaudeConnection.connect(directory: existing, executable: executable)
        try check(try run(replacedCommand, input: payload) == "replacement output")

        let collision = root.appendingPathComponent("collision")
        let reserved = collision.appendingPathComponent(".quotabar/statusline.sh")
        try files.createDirectory(at: reserved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated user file".utf8).write(to: reserved)
        var collisionRejected = false
        do { try ClaudeConnection.connect(directory: collision, executable: executable) } catch {
            collisionRejected = true
        }
        precondition(collisionRejected)
        try check(try String(contentsOf: reserved, encoding: .utf8) == "unrelated user file")

        let redirected = root.appendingPathComponent("redirected")
        try files.createDirectory(at: redirected, withIntermediateDirectories: true)
        try files.createSymbolicLink(
            at: redirected.appendingPathComponent(".quotabar"),
            withDestinationURL: existing.appendingPathComponent(".quotabar"))
        let sourceState = try Data(contentsOf: existing.appendingPathComponent(".quotabar/state.json"))
        var symlinkRejected = false
        do { try ClaudeConnection.connect(directory: redirected, executable: executable) } catch {
            symlinkRejected = true
        }
        precondition(symlinkRejected)
        try check(try Data(contentsOf: existing.appendingPathComponent(".quotabar/state.json")) == sourceState)

        for (name, invalid) in [
            ("malformed", "{invalid"),
            ("array", "[]"),
            ("unsupported", #"{"statusLine":{"type":"other","command":"echo x"}}"#),
            ("missing-command", #"{"statusLine":{"type":"command"}}"#),
        ] {
            let directory = root.appendingPathComponent(name)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("settings.json")
            let bytes = Data(invalid.utf8)
            try bytes.write(to: path)
            precondition(!ClaudeConnection.isConfigured(directory: directory))
            var rejected = false
            do { try ClaudeConnection.connect(directory: directory, executable: executable) } catch { rejected = true }
            precondition(rejected, "Invalid or unsupported settings must be reported.")
            try check(try Data(contentsOf: path) == bytes)
        }
        print(
            "Claude connection setup preserved settings, status output, input, backups, and quoted paths; invalid settings stayed intact."
        )
    }

    private static func check(_ predicate: @autoclosure () throws -> Bool) rethrows {
        let passed = try predicate()
        precondition(passed)
    }

    private static func settings(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func statusCommand(_ settings: [String: Any]) throws -> String {
        guard let status = settings["statusLine"] as? [String: Any], let command = status["command"] as? String,
            status["type"] as? String == "command"
        else { throw CocoaError(.fileReadCorruptFile) }
        return command
    }

    private static func script(_ contents: String, to path: URL) throws {
        try contents.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ command: String, input: String) throws -> String {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self)
    }
}
