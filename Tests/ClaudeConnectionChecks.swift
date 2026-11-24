import CryptoKit
import Darwin
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
        try checkCommandSpellings(root: root, executable: executable)
        try checkProfileChain(root: root)
        try checkActiveProfileSwitch(root: root, executable: executable)
        try checkConcurrentSettings(root: root, executable: executable)
        try checkUndoAndMetadata(root: root, executable: executable)
        try checkReformattedSettings(root: root, executable: executable)
        try checkSamePathHelperUpdate(root: root, executable: executable)
        try checkStandaloneUninstall(root: root, executable: executable)
        try checkV1Migration(root: root, executable: executable, captured: captured)
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

    private static func setCommand(_ command: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": command]])
            .write(to: directory.appendingPathComponent("settings.json"))
    }

    private static func checkCommandSpellings(root: URL, executable: URL) throws {
        let directory = root.appendingPathComponent("plain")
        let path = directory.appendingPathComponent(".quotabar/statusline.sh").path
        let alias = root.appendingPathComponent("direct-alias")
        let original = "cat; printf ' custom'"
        try setCommand(original, in: directory)
        try ClaudeConnection.connect(directory: directory, executable: executable)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: path)
        let hashDirectory = root.appendingPathComponent("hash#directory")
        let spaceDirectory = root.appendingPathComponent("with spaces")
        for directoryAlias in [hashDirectory, spaceDirectory] {
            try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
        }
        let hashPath = hashDirectory.appendingPathComponent(".quotabar/statusline.sh").path
        let spacePath = spaceDirectory.appendingPathComponent(".quotabar/statusline.sh").path
        for spelling in [
            "/bin/bash " + path, path, quote(path), "/bin/bash \"" + path + "\"", alias.path, hashPath,
            "/bin/bash " + spacePath.replacingOccurrences(of: " ", with: "\\ "),
            spacePath.replacingOccurrences(of: "with spaces", with: "wi'th 'sp\"aces\""),
        ] {
            try check(try run(spelling, input: "hello") == "hello custom")
            try setCommand(spelling, in: directory)
            precondition(ClaudeConnection.isConfigured(directory: directory), "Own wrapper must resolve: " + spelling)
            try ClaudeConnection.connect(directory: directory, executable: executable)
            try check(try run(statusCommand(settings(directory)), input: "hello") == "hello custom")
        }
        for custom in [
            path + " extra", path + "; :", path + "*", path + "$EMPTY", path + "`true`", path + " # comment",
        ] {
            try setCommand(custom, in: directory)
            precondition(!ClaudeConnection.isConfigured(directory: directory))
        }
        let folder = directory.appendingPathComponent(".quotabar")
        let backup = folder.appendingPathComponent("previous-settings.json")
        let state = folder.appendingPathComponent("state.json")
        let originalBackup = try Data(contentsOf: backup)
        let originalState = try Data(contentsOf: state)
        for invocation in [
            "/bin/bash " + quote(path), alias.path,
            "/bin/bash " + spacePath.replacingOccurrences(of: " ", with: "\\ "),
            #"/bin/bash "$CLAUDE_CONFIG_DIR/.quotabar/statusline.sh""#,
            #"/bin/bash "${CLAUDE_CONFIG_DIR}"/.quotabar/statusline.sh"#,
            #"/bin/bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.quotabar/statusline.sh""#,
            #"/bin/bash "${CLAUDE_CONFIG_DIR:-"${HOME}"/.claude}"/.quotabar/statusline.sh"#,
        ] {
            let compound = invocation + " | /usr/bin/tr a-z A-Z"
            let profileEnvironment = "export CLAUDE_CONFIG_DIR=" + quote(directory.path) + "; "
            try setCommand(compound, in: directory)
            let url = directory.appendingPathComponent("settings.json")
            let edit = try Data(contentsOf: url)
            try check(try run(profileEnvironment + compound, input: "hello") == "HELLO CUSTOM")
            try mustFail { try ClaudeConnection.connect(directory: directory, executable: executable) }
            try mustFail { try ClaudeConnection.disconnect(directory: directory) }
            try check(try Data(contentsOf: url) == edit)
            try check(try Data(contentsOf: state) == originalState)
            try check(try Data(contentsOf: backup) == originalBackup)
            try check(
                try run(profileEnvironment + statusCommand(settings(directory)), input: "hello") == "HELLO CUSTOM")
        }

        // An independent script can share the wrapper's filename prefix.
        let personal = folder.appendingPathComponent("statusline.sh.personal")
        try script("#!/bin/sh\nprintf personal\n", to: personal)
        for independent in [quote(personal.path), "/bin/bash " + quote(personal.path) + " | /bin/cat"] {
            try setCommand(independent, in: directory)
            try ClaudeConnection.connect(directory: directory, executable: executable)
            try check(try run(statusCommand(settings(directory)), input: "") == "personal")
        }
        let lastCommand = "/bin/bash " + quote(personal.path) + " | /bin/cat"
        try ClaudeConnection.disconnect(directory: directory)
        try check(try statusCommand(settings(directory)) == lastCommand)
        try check(try run(lastCommand, input: "") == "personal")

        let literalDirectory = root.appendingPathComponent("literal-dollar")
        try ClaudeConnection.connect(directory: literalDirectory, executable: executable)
        let literal = #"printf '%s' '$CLAUDE_CONFIG_DIR/.quotabar/statusline.sh'"#
        try setCommand(literal, in: literalDirectory)
        try ClaudeConnection.connect(directory: literalDirectory, executable: executable)
        try check(
            try run(statusCommand(settings(literalDirectory)), input: "")
                == "$CLAUDE_CONFIG_DIR/.quotabar/statusline.sh")
        try ClaudeConnection.disconnect(directory: literalDirectory)
        try check(try statusCommand(settings(literalDirectory)) == literal)
    }

    private static func checkProfileChain(root: URL) throws {
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let capture = root.appendingPathComponent("count-captures")
        let log = root.appendingPathComponent("captures.log")
        let profiles = root.appendingPathComponent("capture-profiles")
        try script(
            "#!/bin/sh\nif test \"$QUOTABAR_SKIP_NESTED_CAPTURE\" = 1; then exit 0; fi\nprintf '%s\\n' \"$QUOTABAR_CAPTURE_PROFILE\" >> "
                + quote(profiles.path) + "\ncat >> "
                + quote(log.path) + "\n",
            to: capture)
        let final = "test \"$QUOTABAR_CAPTURE_PROFILE\" = unrelated || exit 1; printf 'second '; cat"
        try setCommand(final, in: second)
        try ClaudeConnection.connect(directory: second, executable: capture)
        try setCommand(try statusCommand(settings(second)), in: first)
        try ClaudeConnection.connect(directory: first, executable: capture)
        let command = try statusCommand(settings(first))
        try check(try run("QUOTABAR_CAPTURE_PROFILE=unrelated " + command, input: "abc\n") == "second abc\n")
        let firstProfile = first.resolvingSymlinksInPath().path + "\n"
        let secondProfile = second.resolvingSymlinksInPath().path + "\n"
        let expectedProfiles = firstProfile
        try check(try String(contentsOf: profiles, encoding: .utf8) == expectedProfiles)
        try check(try String(contentsOf: log, encoding: .utf8) == "abc\n")

        // The previous profile-tagged wrapper still calls its binary unconditionally. The
        // new outer wrapper sends a suppression flag through the original command's environment.
        let previousURL = second.appendingPathComponent(".quotabar/statusline.sh")
        let current = try String(contentsOf: previousURL, encoding: .utf8)
        let prior = current.components(separatedBy: "\n").filter {
            !$0.hasPrefix("quotabar_outer=") && !$0.hasPrefix("if [[ -n")
                && !$0.hasPrefix("export QUOTABAR_SKIP_NESTED_CAPTURE=")
        }.joined(separator: "\n").replacingOccurrences(of: "if [[ $quotabar_outer == 1 && -x", with: "if [[ -x")
        try script(prior, to: previousURL)
        precondition(ClaudeConnection.status(directory: second) == .needsUpgrade)
        try check(try run("QUOTABAR_CAPTURE_PROFILE=unrelated " + command, input: "old\n") == "second old\n")
        try ClaudeConnection.connect(directory: second, executable: capture)

        // This independent one-trip fuse bounds the fixture even when the wrapper guard regresses.
        let fuse = quote(root.appendingPathComponent("cycle-entered").path)
        let alias = root.appendingPathComponent("first-script-alias")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: first.appendingPathComponent(".quotabar/statusline.sh"))
        let cycle =
            "if test -e " + fuse + "; then printf overflow; else touch " + fuse + "; "
            + quote(alias.path) + "; fi; printf done"
        try setCommand(cycle, in: second)
        try ClaudeConnection.connect(directory: second, executable: capture)
        try check(try run(command, input: "x") == "done")
        try check(try String(contentsOf: log, encoding: .utf8) == "abc\nold\nx")
        try setCommand("printf 'first '; cat", in: first)
        try ClaudeConnection.connect(directory: first, executable: capture)
        try setCommand(command, in: second)
        try ClaudeConnection.connect(directory: second, executable: capture)
        try check(try run(try statusCommand(settings(second)), input: "B") == "first B")
        try check(
            try String(contentsOf: profiles, encoding: .utf8) == firstProfile + firstProfile + firstProfile
                + secondProfile)
        try check(try String(contentsOf: log, encoding: .utf8) == "abc\nold\nxB")
    }

    private static func checkV1Migration(root: URL, executable: URL, captured: URL) throws {
        let files = FileManager.default
        let real = root.appendingPathComponent("installed")
        let alias = root.appendingPathComponent("alias ' path")
        let managed = real.appendingPathComponent(".quotabar")
        try files.createDirectory(at: managed, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: alias, withDestinationURL: real)
        let child = real.appendingPathComponent("child")
        try files.createDirectory(at: child, withIntermediateDirectories: false)
        let dotDot = child.appendingPathComponent("..")
        let childAlias = root.appendingPathComponent("child-alias")
        try files.createSymbolicLink(at: childAlias, withDestinationURL: child)
        let aliasedParent = childAlias.appendingPathComponent("..")
        let marker = "app.quotabar.QuotaBar.statusline.v1"
        let original = #"set -- 'quoted argument'; printf '%s\n' "$1" && cat"#
        let stateURL = managed.appendingPathComponent("state.json")
        let scriptURL = managed.appendingPathComponent("statusline.sh")
        func installV1(savedCommand: String, guardLines: String = "", storedExecutable: URL? = nil) throws {
            // Earlier versions lacked both standalone-uninstall files.
            for name in ["QuotaBarClaudeDisconnect", "uninstall.sh"] {
                let file = managed.appendingPathComponent(name)
                if files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
            }
            let executable = storedExecutable ?? executable
            try JSONSerialization.data(withJSONObject: [
                "marker": marker, "originalCommand": savedCommand, "executable": executable.path,
            ]).write(to: stateURL)
            let oldScript = """
                #!/bin/bash
                # \(marker)
                \(guardLines)IFS= read -r -d '' quotabar_input || :
                if [[ -x \(quote(executable.path)) ]]; then
                    printf '%s' "$quotabar_input" | \(quote(executable.path)) --capture-claude-quota >/dev/null 2>&1 || :
                fi
                printf '%s' "$quotabar_input" | /bin/sh -c \(quote(savedCommand))

                """
            try script(oldScript, to: scriptURL)
        }
        try installV1(savedCommand: original)
        let oldBytes = try Data(contentsOf: scriptURL)
        let priorCommand = "/bin/bash " + quote(alias.appendingPathComponent(".quotabar/statusline.sh").path)
        let settingsURL = real.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": priorCommand]])
            .write(to: settingsURL)
        precondition(ClaudeConnection.status(directory: real) == .needsUpgrade)
        precondition(!ClaudeConnection.isConfigured(directory: real), "An unguarded hook should offer reconnection.")
        try ClaudeConnection.connect(directory: real, executable: executable)
        let command = try statusCommand(settings(real))
        let savedState = try Data(contentsOf: stateURL)
        let state = try JSONSerialization.jsonObject(with: savedState) as! [String: String]
        precondition(state["originalCommand"] == original)
        let savedScript = try Data(contentsOf: scriptURL)
        precondition(savedScript != oldBytes)
        let savedSettings = try Data(contentsOf: settingsURL)
        let savedFiles = try files.contentsOfDirectory(atPath: real.path).sorted()
        for directory in [alias, dotDot, aliasedParent, real] {
            precondition(ClaudeConnection.isConfigured(directory: directory))
            try ClaudeConnection.connect(directory: directory, executable: executable)
            try check(try Data(contentsOf: settingsURL) == savedSettings)
            try check(try Data(contentsOf: stateURL) == savedState)
            try check(try Data(contentsOf: scriptURL) == savedScript)
            try check(try files.contentsOfDirectory(atPath: real.path).sorted() == savedFiles)
        }
        try check(try run(command, input: "payload\n\n") == "quoted argument\npayload\n\n")
        let capturedInput = try Data(contentsOf: captured)
        let scriptID = try run("/usr/bin/stat -f '%d:%i' " + quote(scriptURL.path), input: "")
            .trimmingCharacters(in: .newlines)
        try check(try run("QUOTABAR_STATUSLINE_VISITED=" + quote(scriptID) + " " + command, input: "") == "")
        try check(try Data(contentsOf: captured) == capturedInput)

        let globalGuard =
            "if [[ \"${QUOTABAR_STATUSLINE_ACTIVE:-}\" == 1 ]]; then exit 0; fi\n"
            + "export QUOTABAR_STATUSLINE_ACTIVE=1\n"
        try installV1(
            savedCommand: original, guardLines: globalGuard, storedExecutable: root.appendingPathComponent("old-app"))
        precondition(ClaudeConnection.status(directory: real) == .needsUpgrade)
        try ClaudeConnection.connect(directory: real, executable: executable)
        precondition(ClaudeConnection.status(directory: real) == .configured)
        try check(try run(command, input: "{}") == "quoted argument\n{}")

        // Repair the saved v1 self-reference before running anything from this fixture.
        try installV1(savedCommand: priorCommand)
        try ClaudeConnection.connect(directory: real, executable: executable)
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: String]
        precondition(repaired["originalCommand"] == nil)
        try check(try !String(contentsOf: scriptURL, encoding: .utf8).contains("/bin/sh -c"))
        try check(try run(command, input: "{}") == "Claude Code")

        let visitedGuard = """
            quotabar_id=$(/usr/bin/stat -L -f '%d:%i' "${BASH_SOURCE[0]}") || exit 0
            case "|${QUOTABAR_STATUSLINE_VISITED:-}|" in *"|$quotabar_id|"*) exit 0 ;; esac
            export QUOTABAR_STATUSLINE_VISITED="${QUOTABAR_STATUSLINE_VISITED:-}|$quotabar_id"

            """
        try installV1(savedCommand: original, guardLines: visitedGuard)
        precondition(ClaudeConnection.status(directory: real, executable: executable) == .needsUpgrade)
        try ClaudeConnection.connect(directory: real, executable: executable)
        precondition(ClaudeConnection.status(directory: real, executable: executable) == .configured)

        // Restore against a real legacy state with no backup. Only the recorded command is recoverable.
        try installV1(savedCommand: original)
        try setCommand(priorCommand, in: real)
        try ClaudeConnection.disconnect(directory: real)
        try check(try statusCommand(settings(real)) == original)
        precondition(!files.fileExists(atPath: managed.path))

        // Genuine older installers created private UUID backups and rewrote all JSON formatting.
        try files.createDirectory(at: managed, withIntermediateDirectories: true)
        try installV1(savedCommand: original)
        let rawCommand = try JSONEncoder().encode(original)
        let previous =
            Data(#"{ "theme" : 1.200, "statusLine" : { "type" : "command", "command" : "#.utf8)
            + rawCommand + Data(" } }\n".utf8)
        var installed = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
        installed["statusLine"] = ["type": "command", "command": command]
        try JSONSerialization.data(withJSONObject: installed, options: [.prettyPrinted, .sortedKeys]).write(
            to: settingsURL)
        let backup = real.appendingPathComponent("settings.json.quotabar-backup-" + UUID().uuidString)
        try previous.write(to: backup)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let other = real.appendingPathComponent("settings.json.quotabar-backup-my-copy")
        try Data("user copy".utf8).write(to: other)
        let lock = real.appendingPathComponent(".quotabar-connection.lock")
        try Data().write(to: lock)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        try ClaudeConnection.connect(directory: real, executable: executable)
        precondition(!files.fileExists(atPath: backup.path) && !files.fileExists(atPath: lock.path))
        try check(try Data(contentsOf: managed.appendingPathComponent("previous-settings.json")) == previous)
        try ClaudeConnection.disconnect(directory: real)
        try check(try Data(contentsOf: settingsURL) == previous)
        try check(try Data(contentsOf: other) == Data("user copy".utf8))
        precondition(!files.fileExists(atPath: managed.path))

        // A legacy file saved after discovery belongs to its editor, even when its name still matches.
        for artifact in [lock, backup] {
            try files.createDirectory(at: managed, withIntermediateDirectories: true)
            try installV1(savedCommand: original)
            try (artifact == lock ? Data() : previous).write(to: artifact)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
            let edited = Data("saved while upgrading".utf8)
            try mustFail {
                try ClaudeConnection.connect(directory: real, executable: executable) { stage in
                    if stage == .installingUninstaller { try edited.write(to: artifact, options: .atomic) }
                }
            }
            try check(try Data(contentsOf: artifact) == edited)
            try ClaudeConnection.disconnect(directory: real)
            try check(try Data(contentsOf: artifact) == edited)
        }
    }

    private static func checkReformattedSettings(root: URL, executable: URL) throws {
        let dir = root.appendingPathComponent("reformatted")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let command = #"printf '%s' 'literal $(echo untouched) and "quotes" ☕'"#
        let originalLine: [String: Any] = ["type": "command", "command": command, "padding": 4, "extra": "keep"]
        try JSONSerialization.data(withJSONObject: ["statusLine": originalLine, "theme": "dark"]).write(to: url)
        try ClaudeConnection.connect(directory: dir, executable: executable)
        var updated = try settings(dir)
        var line = updated["statusLine"] as! [String: Any]
        try check(try statusCommand(updated) != command)
        line["padding"] = 7
        line["custom"] = ["format": "✓"]
        updated["statusLine"] = line
        updated["newKey"] = ["enabled": true]
        let rewritten = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        precondition(String(decoding: rewritten, as: UTF8.self).contains("\n  \"newKey\""))
        try rewritten.write(to: url)
        try ClaudeConnection.disconnect(directory: dir)
        let restored = try settings(dir)
        try check(try statusCommand(restored).utf8.elementsEqual(command.utf8))
        precondition((restored["statusLine"] as? [String: Any])?["extra"] as? String == "keep")
        line["command"] = command
        updated["statusLine"] = line
        precondition((restored as NSDictionary).isEqual(updated))
        print("Claude disconnect after full settings rewrite: original command and all edited fields preserved.")
    }

    private static func checkSamePathHelperUpdate(root: URL, executable: URL) throws {
        let profile = root.appendingPathComponent("same-app-path")
        try setCommand("printf original", in: profile)
        let settingsURL = profile.appendingPathComponent("settings.json")
        let original = try Data(contentsOf: settingsURL)
        try ClaudeConnection.connect(directory: profile, executable: executable)
        let folder = profile.appendingPathComponent(".quotabar")
        let helper = folder.appendingPathComponent("QuotaBarClaudeDisconnect")
        let current = try Data(contentsOf: helper)
        let record = folder.appendingPathComponent("state.json")
        let launcher = folder.appendingPathComponent("uninstall.sh")
        var state = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: record))
        let currentDigest = state["disconnectHelperSHA256"]!
        let earlier = Data("#!/bin/sh\nexit 0\n".utf8)
        let earlierDigest = SHA256.hash(data: earlier).map { String(format: "%02x", $0) }.joined()
        try earlier.write(to: helper)
        try String(contentsOf: launcher, encoding: .utf8).replacingOccurrences(of: currentDigest, with: earlierDigest)
            .write(to: launcher, atomically: false, encoding: .utf8)
        state["disconnectHelperSHA256"] = earlierDigest
        try JSONEncoder().encode(state).write(to: record)
        precondition(ClaudeConnection.status(directory: profile, executable: executable) == .needsUpgrade)
        try ClaudeConnection.connect(directory: profile, executable: executable)
        precondition(ClaudeConnection.status(directory: profile, executable: executable) == .configured)
        try check(try Data(contentsOf: helper) == current)
        try ClaudeConnection.connect(directory: profile, executable: executable) { _ in
            throw CocoaError(.fileWriteUnknown)
        }
        try ClaudeConnection.disconnect(directory: profile)
        try check(try Data(contentsOf: settingsURL) == original)
    }

    /// The connection folder carries an uninstaller that still works after QuotaBar.app is deleted.
    private static func checkStandaloneUninstall(root: URL, executable: URL) throws {
        let files = FileManager.default
        func runUninstaller(_ dir: URL) throws -> (status: Int32, output: String) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [dir.appendingPathComponent(".quotabar/uninstall.sh").path]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }
        func connectRemovableApp(_ name: String, settings start: String?) throws -> URL {
            let dir = root.appendingPathComponent("uninstall-" + name)
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            if let start { try Data(start.utf8).write(to: dir.appendingPathComponent("settings.json")) }
            let app = root.appendingPathComponent("Removable-" + name)
            try files.copyItem(at: executable, to: app)
            try ClaudeConnection.connect(directory: dir, executable: app)
            let installed = dir.appendingPathComponent(".quotabar/uninstall.sh")
            let mode = try files.attributesOfItem(atPath: installed.path)[.posixPermissions] as? Int
            precondition(mode == 0o700, "The uninstaller must be private and executable.")
            try files.removeItem(at: app)
            return dir
        }

        // An edited original command and unrelated edits survive after the app is gone.
        let command = #"printf '%s' 'literal $(echo untouched) and "quotes" ☕'"#
        let original = try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": command, "padding": 3], "theme": "dark",
        ])
        let restoring = try connectRemovableApp("restore", settings: String(decoding: original, as: UTF8.self))
        var edited = try settings(restoring)
        edited["permissions"] = ["allow": ["Bash(ls:*)"]]
        edited["nothing"] = NSNull()
        try JSONSerialization.data(withJSONObject: edited, options: [.prettyPrinted, .sortedKeys])
            .write(to: restoring.appendingPathComponent("settings.json"))
        let restored = try runUninstaller(restoring)
        precondition(restored.status == 0, restored.output)
        let after = try settings(restoring)
        try check(try statusCommand(after).utf8.elementsEqual(command.utf8))
        precondition((after["statusLine"] as? [String: Any])?["padding"] as? Int == 3)
        precondition(after["theme"] as? String == "dark" && after["permissions"] != nil && after["nothing"] is NSNull)
        precondition(!files.fileExists(atPath: restoring.appendingPathComponent(".quotabar").path))

        // Renaming a whole profile leaves the installed command pointing at the former location.
        let movedSource =
            #"{ "theme":"light", "value":1.250e+02, "statusLine":{"type":"command","command":"printf \u0068i"} }"#
        for upgrade in [false, true] {
            let old = try connectRemovableApp("move-" + String(upgrade), settings: movedSource)
            let moved = root.appendingPathComponent("renamed profile " + String(upgrade))
            try files.moveItem(at: old, to: moved)
            let settingsURL = moved.appendingPathComponent("settings.json")
            let edited = try String(contentsOf: settingsURL, encoding: .utf8)
                .replacingOccurrences(of: "light", with: "dark")
            try Data(edited.utf8).write(to: settingsURL)
            let note = moved.appendingPathComponent(".quotabar/personal.txt")
            try Data("keep".utf8).write(to: note)
            precondition(ClaudeConnection.status(directory: moved, executable: executable) == .needsUpgrade)
            if upgrade {
                try ClaudeConnection.connect(directory: moved, executable: executable)
                precondition(ClaudeConnection.status(directory: moved, executable: executable) == .configured)
                let backup = try Data(contentsOf: moved.appendingPathComponent(".quotabar/previous-settings.json"))
                precondition(backup == Data(movedSource.utf8))
                try check(try run(statusCommand(settings(moved)), input: "") == "hi")
            }
            let result = try runUninstaller(moved)
            precondition(result.status == 0, result.output)
            try check(
                try Data(contentsOf: settingsURL)
                    == Data(movedSource.replacingOccurrences(of: "light", with: "dark").utf8))
            try check(try Data(contentsOf: note) == Data("keep".utf8))
            try check(try files.contentsOfDirectory(atPath: note.deletingLastPathComponent().path) == ["personal.txt"])
        }

        // A copy may intentionally use the still-live original profile's wrapper.
        let live = try connectRemovableApp("live-source", settings: movedSource)
        let copy = root.appendingPathComponent("profile copy")
        try files.copyItem(at: live, to: copy)
        let copyURL = copy.appendingPathComponent("settings.json")
        let liveURL = live.appendingPathComponent("settings.json")
        let selected = try Data(contentsOf: copyURL)
        precondition(ClaudeConnection.status(directory: copy, executable: executable) == .notConfigured)
        try ClaudeConnection.connect(directory: copy, executable: executable)
        try check(try run(statusCommand(settings(copy)), input: "") == "hi")
        try ClaudeConnection.disconnect(directory: copy)
        try check(try Data(contentsOf: copyURL) == selected)
        try check(try Data(contentsOf: liveURL) == selected)
        try check(try run(statusCommand(settings(live)), input: "") == "hi")

        // Without a previous status line, the QuotaBar entry is removed.
        let empty = try connectRemovableApp("empty", settings: #"{"theme":"light"}"#)
        let removed = try runUninstaller(empty)
        precondition(removed.status == 0, removed.output)
        let emptied = try settings(empty)
        precondition(emptied["statusLine"] == nil && emptied["theme"] as? String == "light")
        precondition(!files.fileExists(atPath: empty.appendingPathComponent(".quotabar").path))

        // A replacement status line that still calls the wrapper is left for the user to resolve.
        let chained = try connectRemovableApp("chained ' profile", settings: "{}")
        let commandWithPipe = try statusCommand(settings(chained)) + " | tr a-z A-Z"
        let replacement = try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": commandWithPipe]
        ])
        try replacement.write(to: chained.appendingPathComponent("settings.json"))
        let copied = root.appendingPathComponent("copied compound profile")
        try files.copyItem(at: chained, to: copied)
        let copyCleanup = try runUninstaller(copied)
        precondition(copyCleanup.status == 0, copyCleanup.output)
        try check(try Data(contentsOf: copied.appendingPathComponent("settings.json")) == replacement)
        precondition(!files.fileExists(atPath: copied.appendingPathComponent(".quotabar").path))

        for dir in [chained, root.appendingPathComponent("renamed compound profile")] {
            if dir != chained { try files.moveItem(at: chained, to: dir) }
            let refused = try runUninstaller(dir)
            precondition(refused.status != 0 && refused.output.contains("still calls QuotaBar"), refused.output)
            try check(try Data(contentsOf: dir.appendingPathComponent("settings.json")) == replacement)
            precondition(files.fileExists(atPath: dir.appendingPathComponent(".quotabar/state.json").path))
        }

        // A linked settings file is never replaced through the link.
        let linked = try connectRemovableApp("linked", settings: "{}")
        let target = root.appendingPathComponent("uninstall-linked-target.json")
        try files.moveItem(at: linked.appendingPathComponent("settings.json"), to: target)
        try files.createSymbolicLink(at: linked.appendingPathComponent("settings.json"), withDestinationURL: target)
        let linkedBefore = try Data(contentsOf: target)
        let linkRefused = try runUninstaller(linked)
        precondition(linkRefused.status != 0 && linkRefused.output.contains("link"), linkRefused.output)
        try check(try Data(contentsOf: target) == linkedBefore)

        let absent = try connectRemovableApp("absent", settings: nil)
        let deleted = try runUninstaller(absent)
        precondition(deleted.status == 0, deleted.output)
        precondition(!files.fileExists(atPath: absent.appendingPathComponent("settings.json").path))

        let source = #"{ "id":9007199254740993, "amount":1.2500e+02, "theme":"dark" }"# + "\n"
        let precise = try connectRemovableApp("precise", settings: source)
        let preciseURL = precise.appendingPathComponent("settings.json")
        let current = try String(contentsOf: preciseURL, encoding: .utf8)
        try Data(current.replacingOccurrences(of: "dark", with: "light").utf8).write(to: preciseURL)
        let exact = try runUninstaller(precise)
        precondition(exact.status == 0, exact.output)
        try check(try Data(contentsOf: preciseURL) == Data(source.replacingOccurrences(of: "dark", with: "light").utf8))

        let other = try connectRemovableApp("other-profile", settings: "{}")
        let switched = try connectRemovableApp("switched", settings: "{}")
        try setCommand(try statusCommand(settings(other)), in: switched)
        let switchedSettings = switched.appendingPathComponent("settings.json")
        let beforeSwitchCleanup = try Data(contentsOf: switchedSettings)
        let otherWrapper = other.appendingPathComponent(".quotabar/statusline.sh")
        let beforeOther = try Data(contentsOf: otherWrapper)
        let privateNote = switched.appendingPathComponent(".quotabar/note.txt")
        try Data("keep me".utf8).write(to: privateNote)
        let cleaned = try runUninstaller(switched)
        precondition(cleaned.status == 0, cleaned.output)
        try check(try Data(contentsOf: switchedSettings) == beforeSwitchCleanup)
        try check(try Data(contentsOf: otherWrapper) == beforeOther)
        try check(try Data(contentsOf: privateNote) == Data("keep me".utf8))
        try check(try files.contentsOfDirectory(atPath: privateNote.deletingLastPathComponent().path) == ["note.txt"])

        for name in ["statusline.sh", "uninstall.sh", "previous-settings.json", "QuotaBarClaudeDisconnect"] {
            let edited = try connectRemovableApp("modified-" + name, settings: "{}")
            let directory = edited.appendingPathComponent(".quotabar")
            let changed = directory.appendingPathComponent(name)
            let bytes = try Data(contentsOf: changed) + Data("\n# local change\n".utf8)
            try bytes.write(to: changed)
            let settingsURL = edited.appendingPathComponent("settings.json")
            let savedSettings = try Data(contentsOf: settingsURL)
            let refused = try runUninstaller(edited)
            precondition(refused.status != 0, "Standalone uninstall accepted edited " + name)
            try mustFail { try ClaudeConnection.disconnect(directory: edited) }
            try mustFail { try ClaudeConnection.connect(directory: edited, executable: executable) }
            try check(try Data(contentsOf: changed) == bytes)
            try check(try Data(contentsOf: settingsURL) == savedSettings)
        }

        // Upgrade a genuine build-39 layout using the frozen script template and the recorded commands.
        let template = try String(contentsOfFile: "Tests/Fixtures/Build39ClaudeUninstall.txt", encoding: .utf8)
        for editOldScript in [false, true] {
            let prior = try connectRemovableApp(
                "build39-" + String(editOldScript), settings: String(decoding: original, as: UTF8.self))
            let managedDir = prior.appendingPathComponent(".quotabar")
            let stateFile = managedDir.appendingPathComponent("state.json")
            var priorState = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateFile))
            priorState.removeValue(forKey: "disconnectHelperSHA256")
            try JSONEncoder().encode(priorState).write(to: stateFile)
            try files.removeItem(at: managedDir.appendingPathComponent("QuotaBarClaudeDisconnect"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let managed = String(decoding: try encoder.encode(statusCommand(settings(prior))), as: UTF8.self)
            let saved = String(decoding: try encoder.encode(priorState["originalCommand"]), as: UTF8.self)
            let oldBytes = Data(
                (template.replacingOccurrences(of: "__QUOTABAR_MANAGED__", with: managed)
                    .replacingOccurrences(of: "__QUOTABAR_ORIGINAL__", with: saved)
                    + (editOldScript ? "# keep my edits\n" : "")).utf8)
            let oldUninstall = managedDir.appendingPathComponent("uninstall.sh")
            try oldBytes.write(to: oldUninstall)
            precondition(ClaudeConnection.status(directory: prior) == .needsUpgrade)
            if editOldScript {
                try mustFail { try ClaudeConnection.connect(directory: prior, executable: executable) }
                try mustFail { try ClaudeConnection.disconnect(directory: prior) }
                try check(try Data(contentsOf: oldUninstall) == oldBytes)
            } else {
                let oldRecord = try Data(contentsOf: stateFile)
                let installedWrapper = managedDir.appendingPathComponent("statusline.sh")
                let oldWrapper = try Data(contentsOf: installedWrapper)
                let settingsURL = prior.appendingPathComponent("settings.json")
                let oldSettings = try Data(contentsOf: settingsURL)
                let helper = managedDir.appendingPathComponent("QuotaBarClaudeDisconnect")
                let localLauncher = oldBytes + Data("# local edit during upgrade\n".utf8)
                let localHelper = Data("editor's concurrent revision\n".utf8)
                try mustFail {
                    try ClaudeConnection.connect(directory: prior, executable: executable) { stage in
                        if stage == .installingUninstaller {
                            try localLauncher.write(to: oldUninstall, options: .atomic)
                            try localHelper.write(to: helper, options: .atomic)
                        }
                    }
                }
                try check(try Data(contentsOf: oldUninstall) == localLauncher)
                try check(try Data(contentsOf: helper) == localHelper)
                try check(try Data(contentsOf: stateFile) == oldRecord)
                try check(try Data(contentsOf: installedWrapper) == oldWrapper)
                try check(try Data(contentsOf: settingsURL) == oldSettings)
                try oldBytes.write(to: oldUninstall)
                try files.removeItem(at: helper)
                try ClaudeConnection.connect(directory: prior, executable: executable)
                precondition(ClaudeConnection.isConfigured(directory: prior))
                let migrated = try runUninstaller(prior)
                precondition(migrated.status == 0, migrated.output)
                try check(try Data(contentsOf: prior.appendingPathComponent("settings.json")) == original)
            }
        }

        // Disconnecting from the app also removes the uninstaller.
        let app = root.appendingPathComponent("Kept-app")
        try files.copyItem(at: executable, to: app)
        let kept = root.appendingPathComponent("uninstall-in-app")
        try ClaudeConnection.connect(directory: kept, executable: app)
        try ClaudeConnection.disconnect(directory: kept)
        precondition(!files.fileExists(atPath: kept.appendingPathComponent(".quotabar").path))
        print("Claude standalone uninstaller: restored after app removal, refused unsafe edits, removed by disconnect.")
    }

    private static func checkUndoAndMetadata(root: URL, executable: URL) throws {
        let files = FileManager.default
        let dir = root.appendingPathComponent("editable-profile")
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let original = #"""
            {
              "number" : 1.2300e+02,
              "nested" : ["command", {"statusLine":"\u263a"}],
              "status\u004cine" : { "padding":2, "type":"command", "command": "printf \u0068i" },
              "theme":"dark"
            }

            """#
        try Data(original.utf8).write(to: url)
        try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let attr = "com.example.quotabar-fixture"
        let value = Array("keep attribute".utf8)
        precondition(setxattr(url.path, attr, value, value.count, 0, 0) == 0)
        let secondExe = root.appendingPathComponent("another-working-executable")
        try script("#!/bin/sh\ncat >/dev/null\n", to: secondExe)
        try ClaudeConnection.connect(directory: dir, executable: executable)
        let managed = try statusCommand(settings(dir))
        let quoted = try JSONSerialization.data(
            withJSONObject: managed, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let expected = original.replacingOccurrences(
            of: #""printf \u0068i""#, with: String(decoding: quoted, as: UTF8.self))
        try check(try Data(contentsOf: url) == Data(expected.utf8))
        precondition(ClaudeConnection.status(directory: dir, executable: secondExe) == .needsUpgrade)
        for exe in [secondExe, executable, secondExe] { try ClaudeConnection.connect(directory: dir, executable: exe) }
        try check(try files.contentsOfDirectory(atPath: dir.path).sorted() == [".quotabar", "settings.json"])
        let backup = dir.appendingPathComponent(".quotabar/previous-settings.json")
        try check(try Data(contentsOf: backup) == Data(original.utf8))
        try check(try files.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        try check(try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640)
        var attrBytes = Array(repeating: UInt8(0), count: value.count)
        precondition(getxattr(url.path, attr, &attrBytes, attrBytes.count, 0, 0) == value.count && attrBytes == value)
        let edited = expected.replacingOccurrences(of: #""theme":"dark""#, with: #""theme":"light""#)
            .replacingOccurrences(of: #""padding":2"#, with: #""padding":9"#)
        try Data(edited.utf8).write(to: url)
        try ClaudeConnection.disconnect(directory: dir)
        let restored = original.replacingOccurrences(of: #""theme":"dark""#, with: #""theme":"light""#)
            .replacingOccurrences(of: #""padding":2"#, with: #""padding":9"#)
        try check(try Data(contentsOf: url) == Data(restored.utf8))
        try check(try files.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        try check(try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640)

        for (i, raw) in [nil, "{}", "{\n}", "{ \"statusLine\" : null, \"theme\" : 2 }\n", "{\"x\":2,}"].enumerated() {
            let dir = root.appendingPathComponent("undo-\(i)")
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("settings.json")
            if let raw { try Data(raw.utf8).write(to: url) }
            try ClaudeConnection.connect(directory: dir, executable: executable)
            precondition(ClaudeConnection.canDisconnect(directory: dir))
            try ClaudeConnection.disconnect(directory: dir)
            check((try? Data(contentsOf: url)) == raw.map { Data($0.utf8) })
            precondition(!ClaudeConnection.canDisconnect(directory: dir))
        }

        let hard = root.appendingPathComponent("hardlinks")
        try files.createDirectory(at: hard, withIntermediateDirectories: true)
        let settings = hard.appendingPathComponent("settings.json")
        try Data(original.utf8).write(to: settings)
        let alias = hard.appendingPathComponent("alias")
        try files.linkItem(at: settings, to: alias)
        try mustFail { try ClaudeConnection.connect(directory: hard, executable: executable) }
        var info = stat()
        precondition(lstat(settings.path, &info) == 0 && info.st_nlink == 2)
        try check(try files.contentsOfDirectory(atPath: hard.path).sorted() == ["alias", "settings.json"])
        try files.removeItem(at: alias)
        try ClaudeConnection.connect(directory: hard, executable: executable)
        try files.linkItem(at: settings, to: alias)
        try mustFail { try ClaudeConnection.disconnect(directory: hard) }
        precondition(ClaudeConnection.isConfigured(directory: hard))
        try files.removeItem(at: alias)
        try ClaudeConnection.disconnect(directory: hard)

        let translocated = root.appendingPathComponent("AppTranslocation/ID/d/QuotaBar.app/Contents/MacOS/QuotaBar")
        try files.createDirectory(at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script("#!/bin/sh\nexit 0\n", to: translocated)
        let untouched = root.appendingPathComponent("untouched")
        try mustFail { try ClaudeConnection.connect(directory: untouched, executable: translocated) }
        precondition(!files.fileExists(atPath: untouched.path))

        let suite = testPreferencesDomain()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let env = ["CLAUDE_CONFIG_DIR": dir.path]
        precondition(
            ClaudeProfile.resolve(defaults: defaults, environment: [:], home: root).lastPathComponent == ".claude")
        precondition(ClaudeProfile.resolve(defaults: defaults, environment: env, home: root).path == dir.path)
        ClaudeProfile.select(hard, defaults: defaults)
        precondition(ClaudeProfile.resolve(defaults: defaults, environment: env, home: root).path == hard.path)
        ClaudeProfile.select(nil, defaults: defaults)
        precondition(ClaudeProfile.resolve(defaults: defaults, environment: env, home: root).path == dir.path)

        try ClaudeConnection.connect(directory: dir, executable: executable)
        let different = #"{"statusLine":{"type":"command","command":"printf changed"},"new":1}"#
        try Data(different.utf8).write(to: url)
        let keep = dir.appendingPathComponent(".quotabar/other-file")
        try Data("mine".utf8).write(to: keep)
        try ClaudeConnection.disconnect(directory: dir)
        try check(try Data(contentsOf: url) == Data(different.utf8))
        try check(try Data(contentsOf: keep) == Data("mine".utf8))

        // A copied profile with an updated wrapper command must rebind its capture destination.
        let originalProfile = root.appendingPathComponent("profile-before-copy")
        let copy = root.appendingPathComponent("profile-after-copy")
        try ClaudeConnection.connect(directory: originalProfile, executable: executable)
        try files.copyItem(at: originalProfile, to: copy)
        try setCommand("/bin/bash " + quote(copy.appendingPathComponent(".quotabar/statusline.sh").path), in: copy)
        precondition(ClaudeConnection.status(directory: copy, executable: executable) == .needsUpgrade)
        try ClaudeConnection.connect(directory: copy, executable: executable)
        precondition(ClaudeConnection.status(directory: copy, executable: executable) == .configured)
        let capturedProfile = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: copy.appendingPathComponent(".quotabar/state.json")))
        precondition(capturedProfile["captureProfile"] == copy.resolvingSymlinksInPath().path)
    }

    private static func mustFail(_ operation: () throws -> Void, line: UInt = #line) throws {
        do { try operation() } catch { return }
        preconditionFailure("Expected refusal at line " + String(line))
    }

    private static func checkActiveProfileSwitch(root: URL, executable: URL) throws {
        let files = FileManager.default
        let first = root.appendingPathComponent("first selected profile")
        let second = root.appendingPathComponent("second selected profile")
        let active = root.appendingPathComponent("selected profile")
        let next = root.appendingPathComponent("next profile")
        func select(_ directory: URL) throws {
            try files.createSymbolicLink(at: next, withDestinationURL: directory)
            precondition(rename(next.path, active.path) == 0)
        }
        for profile in [first, second] {
            try files.createDirectory(at: profile, withIntermediateDirectories: false)
            try Data(#"{"theme":"dark","statusLine":{"type":"command","command":"printf original"}}"#.utf8)
                .write(to: profile.appendingPathComponent("settings.json"))
        }
        let original = try Data(contentsOf: first.appendingPathComponent("settings.json"))
        try select(first)
        try ClaudeConnection.connect(directory: active, executable: executable) { stage in
            if stage == .installingUninstaller { try select(second) }
        }
        precondition(ClaudeConnection.isConfigured(directory: first))
        precondition(!ClaudeConnection.canDisconnect(directory: second))
        try check(try Data(contentsOf: second.appendingPathComponent("settings.json")) == original)

        try ClaudeConnection.connect(directory: second, executable: executable)
        try select(first)
        try ClaudeConnection.disconnect(directory: active) { stage in
            if stage == .cleanup { try select(second) }
        }
        precondition(!files.fileExists(atPath: first.appendingPathComponent(".quotabar").path))
        try check(try Data(contentsOf: first.appendingPathComponent("settings.json")) == original)
        precondition(ClaudeConnection.isConfigured(directory: second))
        try ClaudeConnection.disconnect(directory: second)
        try check(try Data(contentsOf: second.appendingPathComponent("settings.json")) == original)
    }

    private static func checkConcurrentSettings(root: URL, executable: URL) throws {
        let files = FileManager.default
        let dir = root.appendingPathComponent("conflict")
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let baseline = Data(#"{"settings":"before"}"#.utf8)
        let first = Data(#"{"settings":"saved during commit"}"#.utf8)
        let second = Data(#"{"settings":"saved during rollback"}"#.utf8)
        try baseline.write(to: url)
        try mustFail {
            try ClaudeConnection.connect(directory: dir, executable: executable) { stage in
                if stage == .beforeDisplacing { try first.write(to: url, options: .atomic) }
            }
        }
        try check(try Data(contentsOf: url) == first)
        try mustFail {
            try ClaudeConnection.connect(directory: dir, executable: executable) { stage in
                if stage == .beforeDisplacing { try baseline.write(to: url, options: .atomic) }
                if stage == .afterDisplacing { try second.write(to: url, options: .atomic) }
            }
        }
        try check(try Data(contentsOf: url) == second)
        let recovery = try files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".quotabar-settings-recovery-") }
        precondition(recovery.count == 1)
        try check(try Data(contentsOf: recovery[0].appendingPathComponent("settings.json")) == baseline)
        try check(try files.attributesOfItem(atPath: recovery[0].path)[.posixPermissions] as? Int == 0o700)

        let clean = root.appendingPathComponent("delete-conflict")
        let newSettings = clean.appendingPathComponent("settings.json")
        try ClaudeConnection.connect(directory: clean, executable: executable)
        try mustFail {
            try ClaudeConnection.disconnect(directory: clean) { stage in
                if stage == .beforeDisplacing { try first.write(to: newSettings, options: .atomic) }
            }
        }
        try check(try Data(contentsOf: newSettings) == first)
        try ClaudeConnection.disconnect(directory: clean)
        try check(try Data(contentsOf: newSettings) == first)

        // Both uninstall entry points use this transaction. Two editors racing the
        // disconnect keep the second save active and the displaced first save in recovery.
        let racing = root.appendingPathComponent("disconnect-two-saves")
        try files.createDirectory(at: racing, withIntermediateDirectories: true)
        let active = racing.appendingPathComponent("settings.json")
        try baseline.write(to: active)
        try ClaudeConnection.connect(directory: racing, executable: executable)
        try mustFail {
            try ClaudeConnection.disconnect(directory: racing) { stage in
                if stage == .beforeDisplacing { try first.write(to: active, options: .atomic) }
                if stage == .afterDisplacing { try second.write(to: active, options: .atomic) }
            }
        }
        let versions = try files.contentsOfDirectory(at: racing, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".quotabar-settings-recovery-") }
        precondition(versions.count == 1 && ClaudeConnection.canDisconnect(directory: racing))
        try check(try Data(contentsOf: versions[0].appendingPathComponent("settings.json")) == first)
        try check(try Data(contentsOf: active) == second)
        try ClaudeConnection.disconnect(directory: racing)
        try check(try Data(contentsOf: active) == second)

        let changedDuringCleanup = root.appendingPathComponent("cleanup-edit")
        try ClaudeConnection.connect(directory: changedDuringCleanup, executable: executable)
        let launcher = changedDuringCleanup.appendingPathComponent(".quotabar/uninstall.sh")
        let localEdit = Data("# User's revised uninstall script\n".utf8)
        try mustFail {
            try ClaudeConnection.disconnect(directory: changedDuringCleanup) { stage in
                if stage == .cleanup { try localEdit.write(to: launcher, options: .atomic) }
            }
        }
        try check(try Data(contentsOf: launcher) == localEdit)
        precondition(ClaudeConnection.canDisconnect(directory: changedDuringCleanup))

        try ClaudeConnection.connect(directory: dir, executable: executable)
        try mustFail {
            try ClaudeConnection.disconnect(directory: dir) { stage in
                if stage == .cleanup { throw CocoaError(.userCancelled) }
            }
        }
        precondition(ClaudeConnection.canDisconnect(directory: dir))
        precondition(!files.fileExists(atPath: dir.appendingPathComponent(".quotabar/previous-settings.json").path))
        try ClaudeConnection.disconnect(directory: dir)
        precondition(!ClaudeConnection.canDisconnect(directory: dir))
        try check(try Data(contentsOf: url) == second)
    }

    private static func check(_ predicate: @autoclosure () throws -> Bool, line: UInt = #line) rethrows {
        let passed = try predicate()
        precondition(passed, "Connection fixture failed at line " + String(line))
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
