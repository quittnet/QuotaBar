import Darwin
import Foundation

enum ClaudeConnection {
    private static let marker = "app.quotabar.QuotaBar.statusline.v1"
    private static let maximumFileSize = 2 * 1024 * 1024

    private struct State: Codable {
        let marker: String
        let originalCommand: String?
        let executable: String
    }

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var directory: URL {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        return configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func connect() throws {
        guard let executable = Bundle.main.executableURL else {
            throw SetupError(message: "QuotaBar couldn’t locate its installed app. Open QuotaBar and try again.")
        }
        try connect(directory: directory, executable: executable)
    }

    static func isConfigured() -> Bool { isConfigured(directory: directory) }

    static func isConfigured(directory: URL) -> Bool {
        guard let data = try? read(directory.appendingPathComponent("settings.json")),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            settings["disableAllHooks"] as? Bool != true,
            let line = settings["statusLine"] as? [String: Any], line["type"] as? String == "command",
            let command = line["command"] as? String
        else { return false }
        let root = directory.appendingPathComponent(".quotabar", isDirectory: true)
        if command == wrapperCommand(root) {
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            guard let state = try? loadState(root),
                let script = try? read(root.appendingPathComponent("statusline.sh"))
            else { return false }
            return script == wrapper(state) && FileManager.default.isExecutableFile(atPath: state.executable)
        }
        return legacyConnection(command)
    }

    static func connect(directory: URL, executable: URL) throws {
        let files = FileManager.default
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent(".quotabar-connection.lock")
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let previousSettings = try read(settingsURL)
        var settings: [String: Any] = [:]
        if let previousSettings {
            guard let object = try JSONSerialization.jsonObject(with: previousSettings) as? [String: Any] else {
                throw SetupError(
                    message: "Claude Code’s settings must contain a JSON object. Fix settings.json and try again.")
            }
            settings = object
        }
        guard settings["disableAllHooks"] as? Bool != true else {
            throw SetupError(
                message:
                    "Claude Code has disabled status lines. Enable hooks in Claude Code’s settings, then connect again."
            )
        }
        var line: [String: Any] = [:]
        if let existing = settings["statusLine"], !(existing is NSNull) {
            guard let object = existing as? [String: Any], object["type"] as? String == "command",
                let command = object["command"] as? String,
                !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw SetupError(
                    message:
                        "QuotaBar couldn’t safely extend the current Claude Code status line. Check its statusLine setting and try again."
                )
            }
            line = object
        }
        if let command = line["command"] as? String, legacyConnection(command) { return }
        let root = directory.appendingPathComponent(".quotabar", isDirectory: true)
        let scriptURL = root.appendingPathComponent("statusline.sh")
        let stateURL = root.appendingPathComponent("state.json")
        let rootExisted = files.fileExists(atPath: root.path)
        let oldState: State?
        let oldScript: Data?
        let oldStateData: Data?
        if rootExisted {
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw SetupError(
                    message:
                        "The .quotabar connection folder must be a regular directory. Check that folder and try again.")
            }
            oldState = try loadState(root)
            oldScript = try read(scriptURL)
            oldStateData = try read(stateURL)
            guard let oldState, oldScript == nil || oldScript == wrapper(oldState) else {
                throw SetupError(
                    message:
                        "QuotaBar’s Claude connection files were changed. Restore them or choose a different status line before reconnecting."
                )
            }
        } else {
            oldState = nil
            oldScript = nil
            oldStateData = nil
        }
        let managedCommand = wrapperCommand(root)
        let currentCommand = line["command"] as? String
        if currentCommand == managedCommand, oldState == nil {
            throw SetupError(
                message:
                    "The saved Claude connection is incomplete. Restore the previous status line and connect again.")
        }
        let state = State(
            marker: marker,
            originalCommand: currentCommand == managedCommand ? oldState?.originalCommand : currentCommand,
            executable: executable.path)
        let script = wrapper(state)
        line["type"] = "command"
        line["command"] = managedCommand
        settings["statusLine"] = line
        let updatedSettings = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        if currentCommand == managedCommand, oldScript == script { return }
        let backup = directory.appendingPathComponent("settings.json.quotabar-backup-" + UUID().uuidString)
        if let previousSettings { try write(previousSettings, to: backup) }
        if !rootExisted {
            try files.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        do {
            try write(script, to: scriptURL, permissions: 0o700)
            try write(JSONEncoder().encode(state), to: stateURL)
            guard try read(settingsURL) == previousSettings else {
                throw SetupError(
                    message: "Claude Code’s settings changed during setup. Connect again to use the latest settings.")
            }
            try write(updatedSettings, to: settingsURL)
        } catch {
            if let oldStateData {
                if let oldScript {
                    try? write(oldScript, to: scriptURL, permissions: 0o700)
                } else {
                    try? files.removeItem(at: scriptURL)
                }
                try? write(oldStateData, to: stateURL)
            } else {
                try? files.removeItem(at: scriptURL)
                try? files.removeItem(at: stateURL)
                _ = rmdir(root.path)
            }
            throw error
        }
    }

    private static func loadState(_ root: URL) throws -> State {
        guard let data = try read(root.appendingPathComponent("state.json")),
            let state = try? JSONDecoder().decode(State.self, from: data), state.marker == marker
        else {
            throw SetupError(
                message:
                    "The .quotabar folder already exists without a valid connection record. Check that folder before connecting."
            )
        }
        return state
    }

    private static func wrapperCommand(_ root: URL) -> String {
        "/bin/bash " + quote(root.appendingPathComponent("statusline.sh").path)
    }

    private static func wrapper(_ state: State) -> Data {
        let original =
            state.originalCommand.map {
                "printf '%s' \"$quotabar_input\" | /bin/sh -c " + quote($0)
            } ?? "printf '%s' 'Claude Code'"
        return Data(
            """
            #!/bin/bash
            # \(marker)
            IFS= read -r -d '' quotabar_input || :
            if [[ -x \(quote(state.executable)) ]]; then
                printf '%s' "$quotabar_input" | \(quote(state.executable)) --capture-claude-quota >/dev/null 2>&1 || :
            fi
            \(original)

            """.utf8)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func legacyConnection(_ command: String) -> Bool {
        if command.contains("--capture-claude-quota") && command.contains("QuotaBar.app/Contents/MacOS/QuotaBar") {
            return true
        }
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let path: String
        if parts.count == 1 {
            path = parts[0]
        } else if parts.count == 2 && ["bash", "/bin/bash", "sh", "/bin/sh"].contains(parts[0]) {
            path = parts[1]
        } else {
            return false
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? read(URL(fileURLWithPath: expanded)),
            let script = String(data: data, encoding: .utf8)
        else { return false }
        return script.contains("--capture-claude-quota") && script.contains("QuotaBar.app/Contents/MacOS/QuotaBar")
    }

    private static func read(_ url: URL) throws -> Data? {
        do {
            return try PrivateFile.read(url, maximumBytes: maximumFileSize)
        } catch {
            throw SetupError(
                message: "QuotaBar couldn’t safely read " + url.lastPathComponent
                    + ". Check that it is a readable regular file no larger than 2 MB.")
        }
    }

    private static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".quotabar-write-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
