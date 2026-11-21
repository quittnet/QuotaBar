import CryptoKit
import Darwin
import Foundation

enum ClaudeConnection {
    private static let marker = "app.quotabar.QuotaBar.statusline.v1"
    private static let maximumFileSize = 2 * 1024 * 1024

    enum Status: Equatable, Sendable {
        case notConfigured, needsUpgrade, configured
    }

    private enum WrapperVersion: CaseIterable {
        case current, profileTagged, visited, unguarded, globallyGuarded
    }

    private struct State: Codable {
        let marker: String
        let originalCommand: String?
        let executable: String
        let settingsBackup: String?
        let captureProfile: String?
        let legacyFormatting: String?
        var disconnecting: String? = nil
    }

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var directory: URL { ClaudeProfile.directory }

    static func selectDirectory(_ url: URL?) { ClaudeProfile.select(url) }

    static func canDisconnect() -> Bool { canDisconnect(directory: directory) }

    static func canDisconnect(directory: URL) -> Bool {
        let root = directory.appendingPathComponent(".quotabar")
        var info = stat()
        return lstat(root.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && (try? loadState(root)) != nil
    }

    static func disconnect() throws { try disconnect(directory: directory) }

    static func connect() throws {
        guard let executable = Bundle.main.executableURL else {
            throw SetupError(message: "QuotaBar couldn’t locate its installed app. Open QuotaBar and try again.")
        }
        try connect(directory: directory, executable: executable)
    }

    static func status() -> Status { status(directory: directory, executable: Bundle.main.executableURL) }

    static func isConfigured(directory: URL) -> Bool { status(directory: directory) == .configured }

    static func status(directory: URL, executable: URL? = nil) -> Status {
        guard let data = try? read(directory.appendingPathComponent("settings.json")),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            settings["disableAllHooks"] as? Bool != true,
            let line = settings["statusLine"] as? [String: Any], line["type"] as? String == "command",
            let command = line["command"] as? String
        else { return .notConfigured }
        let root = directory.appendingPathComponent(".quotabar", isDirectory: true)
        if isManagedCommand(command, root: root) {
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                let state = try? loadState(root), let script = try? read(root.appendingPathComponent("statusline.sh")),
                let version = version(of: script, state: state)
            else { return .notConfigured }
            let installed = URL(fileURLWithPath: state.executable)
            return version == .current && !isTranslocated(installed)
                && state.captureProfile.map { sameFile($0, directory.path) } == true
                && (executable.map { $0.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path }
                    ?? true)
                && FileManager.default.isExecutableFile(atPath: state.executable)
                ? .configured : .needsUpgrade
        }
        return legacyConnection(command) ? .configured : .notConfigured
    }

    static func connect(directory: URL, executable: URL, observe: ClaudeSettingsCommit.Observer? = nil) throws {
        guard !isTranslocated(executable), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SetupError(
                message: "Move QuotaBar to Applications and reopen it there before connecting Claude Code.")
        }
        let files = FileManager.default
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try withProfileLock(directory) { try install(directory: directory, executable: executable, observe: observe) }
    }

    private static func withProfileLock(_ directory: URL, body: () throws -> Void) throws {
        let lock = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard lock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // Cooperate with earlier installers while migrating their lock file.
        let legacyLock = directory.appendingPathComponent(".quotabar-connection.lock")
        let oldLock = open(legacyLock.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        defer { if oldLock >= 0 { close(oldLock) } }
        if oldLock >= 0 {
            var info = stat()
            if fstat(oldLock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                flock(oldLock, LOCK_EX) != 0
            {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        try body()
    }

    private static func isTranslocated(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().pathComponents.contains("AppTranslocation")
    }

    private static func install(directory: URL, executable: URL, observe: ClaudeSettingsCommit.Observer?) throws {
        let files = FileManager.default
        let settingsURL = directory.appendingPathComponent("settings.json")
        let previousSettings = try read(settingsURL)
        let document = try ClaudeSettingsDocument(previousSettings ?? ClaudeSettingsDocument.empty)
        let settings = document.object
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
        let root = directory.appendingPathComponent(".quotabar", isDirectory: true)
        let currentCommand = line["command"] as? String
        let currentlyManaged = currentCommand.map { isManagedCommand($0, root: root) } ?? false
        if let currentCommand, !currentlyManaged, legacyConnection(currentCommand) { return }
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
            guard oldState?.disconnecting == nil else {
                throw SetupError(message: "Finish disconnecting this Claude profile before reconnecting.")
            }
            oldScript = try read(scriptURL)
            oldStateData = try read(stateURL)
            guard let oldState,
                oldScript.map({ version(of: $0, state: oldState) != nil }) ?? true
            else {
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
        let managedCommand = wrapperCommand(directory.resolvingSymlinksInPath().appendingPathComponent(".quotabar"))
        if currentlyManaged, oldState == nil {
            throw SetupError(
                message:
                    "The saved Claude connection is incomplete. Restore the previous status line and connect again.")
        }
        var originalCommand = currentlyManaged ? oldState?.originalCommand : currentCommand
        if let saved = originalCommand, isManagedCommand(saved, root: root) { originalCommand = nil }
        let backupURL = root.appendingPathComponent("previous-settings.json")
        let oldBackup = try checkedBackup(oldState, at: backupURL)
        let legacy =
            oldState != nil && oldState?.captureProfile == nil
            ? try legacyFiles(directory, root: root, original: oldState?.originalCommand) : LegacyFiles()
        let migratedBackup = oldState?.settingsBackup == nil ? legacy.original : nil
        let backup = currentlyManaged ? oldBackup ?? migratedBackup : previousSettings
        let origin = backup.map(digest) ?? (currentlyManaged ? oldState?.settingsBackup : "absent")
        let state = State(
            marker: marker, originalCommand: originalCommand, executable: executable.path, settingsBackup: origin,
            captureProfile: directory.resolvingSymlinksInPath().path,
            legacyFormatting: currentlyManaged && (oldState?.legacyFormatting == "legacy" || migratedBackup != nil)
                ? "legacy" : nil)
        let script = wrapper(state)
        let uninstallURL = root.appendingPathComponent("uninstall.sh")
        let oldUninstaller = rootExisted ? try read(uninstallURL) : nil
        let uninstallScript = try uninstaller(managedCommand: managedCommand, originalCommand: originalCommand)
        let patched = try document.settingCommand(managedCommand)
        let updatedSettings = currentCommand == managedCommand ? document.data : patched
        guard updatedSettings.count <= maximumFileSize else { throw ClaudeSettingsDocument.Failure.unsupported }
        if currentCommand == managedCommand, oldScript == script, origin == oldState?.settingsBackup,
            legacy.files.isEmpty, oldUninstaller == uninstallScript
        {
            return
        }
        try requireSingleLink(settingsURL)
        if !rootExisted {
            try files.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var connectionFilesReady = false
        do {
            if backup != oldBackup, let backup { try write(backup, to: backupURL) }
            try write(script, to: scriptURL, permissions: 0o700)
            try write(JSONEncoder().encode(state), to: stateURL)
            try write(uninstallScript, to: uninstallURL, permissions: 0o700)
            guard try read(settingsURL) == previousSettings else {
                throw SetupError(
                    message: "Claude Code’s settings changed during setup. Connect again to use the latest settings.")
            }
            if backup == nil, oldBackup != nil { try files.removeItem(at: backupURL) }
            if previousSettings != updatedSettings {
                connectionFilesReady = true
                try ClaudeSettingsCommit.apply(
                    updatedSettings, replacing: previousSettings, at: settingsURL, observe: observe)
            }
        } catch {
            // A concurrent editor may have saved the newly installed wrapper into its own version.
            // Leave its verified script and record available if that version is now active.
            if connectionFilesReady, (try? selectsWrapper(settingsURL, root: root)) == true { throw error }
            if let oldBackup {
                try? write(oldBackup, to: backupURL)
            } else if backup != nil {
                try? files.removeItem(at: backupURL)
            }
            if let oldUninstaller {
                try? write(oldUninstaller, to: uninstallURL, permissions: 0o700)
            } else {
                try? files.removeItem(at: uninstallURL)
            }
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
        try legacy.remove()
    }

    private struct LegacyFiles {
        var files: [URL] = []
        var original: Data?

        func remove() throws {
            for url in files { try FileManager.default.removeItem(at: url) }
        }
    }

    // Older versions created a private UUID-named backup before each settings edit.
    // Only claim files with that exact shape, owner and mode alongside a verified installation.
    private static func legacyFiles(_ directory: URL, root: URL, original: String?) throws -> LegacyFiles {
        let prefix = "settings.json.quotabar-backup-"
        var result = LegacyFiles()
        var newest = -Double.infinity
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            guard UUID(uuidString: suffix)?.uuidString == suffix else { continue }
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600,
                let data = try? read(url), let doc = try? ClaudeSettingsDocument(data)
            else { continue }
            let line = doc.object["statusLine"]
            let command = (line as? [String: Any])?["command"] as? String
            guard line == nil || line is NSNull || command != nil else { continue }
            let managed = command.map { isManagedCommand($0, root: root) } ?? false
            guard command == original || managed else { continue }
            result.files.append(url)
            let time = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if time > newest, command == original, !managed {
                newest = time
                result.original = data
            }
        }
        let lock = directory.appendingPathComponent(".quotabar-connection.lock")
        var info = stat()
        if lstat(lock.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
            info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600, info.st_size == 0
        {
            result.files.append(lock)
        }
        return result
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkedBackup(_ state: State?, at url: URL) throws -> Data? {
        let data = try read(url)
        if data.map(digest) == state?.settingsBackup || (data == nil && state?.settingsBackup == "absent") {
            return data
        }
        throw SetupError(
            message:
                "The saved Claude settings backup is missing or changed. Check previous-settings.json before continuing."
        )
    }

    private static func requireSingleLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) < 0 {
            if errno == ENOENT { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw SetupError(
                message:
                    "QuotaBar cannot replace a linked settings.json. Use an independent regular settings file before changing the connection."
            )
        }
    }

    static func disconnect(directory: URL, observe: ClaudeSettingsCommit.Observer? = nil) throws {
        try withProfileLock(directory) {
            let files = FileManager.default
            let root = directory.appendingPathComponent(".quotabar")
            guard canDisconnect(directory: directory) else {
                throw SetupError(
                    message: "QuotaBar couldn’t find its connection record in the selected Claude profile.")
            }
            var state = try loadState(root)
            let scriptURL = root.appendingPathComponent("statusline.sh")
            let script = try read(scriptURL)
            guard script.map({ version(of: $0, state: state) != nil }) ?? true else {
                throw SetupError(
                    message: "The Claude connection script has been edited. Restore or move it before disconnecting.")
            }
            let backupURL = root.appendingPathComponent("previous-settings.json")
            let missingDuringCleanup = try state.disconnecting != nil && read(backupURL) == nil
            let savedBackup = missingDuringCleanup ? nil : try checkedBackup(state, at: backupURL)
            let legacy =
                state.captureProfile == nil
                ? try legacyFiles(directory, root: root, original: state.originalCommand) : LegacyFiles()
            let backup = savedBackup ?? (state.settingsBackup == nil ? legacy.original : nil)
            let settingsURL = directory.appendingPathComponent("settings.json")
            if let current = try read(settingsURL) {
                let document = try ClaudeSettingsDocument(current)
                _ = try document.rawStatusLine()
                if let line = document.object["statusLine"] as? [String: Any], line["type"] as? String == "command",
                    let command = line["command"] as? String, isManagedCommand(command, root: root)
                {
                    if missingDuringCleanup, state.settingsBackup != nil && state.settingsBackup != "absent" {
                        throw SetupError(
                            message:
                                "The Claude wrapper was selected again during cleanup. Choose a replacement status line first."
                        )
                    }
                    _ = try document.rawCommand()
                    let updated = try restoredSettings(
                        document, command: command, line: line, state: state, backup: backup, root: root)
                    try requireSingleLink(settingsURL)
                    guard try read(settingsURL) == current else {
                        throw SetupError(message: "Claude Code’s settings changed during disconnect. Try again.")
                    }
                    try ClaudeSettingsCommit.apply(updated, replacing: current, at: settingsURL, observe: observe)
                } else if let line = document.object["statusLine"] as? [String: Any],
                    let command = line["command"] as? String,
                    command.contains(scriptURL.path) || command.contains(quote(scriptURL.path))
                        || isManagedCommand(command, root: root)
                {
                    throw SetupError(
                        message:
                            "The replacement status line may still call QuotaBar’s script. Remove that reference before disconnecting."
                    )
                }
            }
            guard try !selectsWrapper(settingsURL, root: root) else {
                throw SetupError(
                    message:
                        "A Claude settings edit selected the wrapper again. Review the current status line before disconnecting."
                )
            }
            state.disconnecting = "yes"
            try write(JSONEncoder().encode(state), to: root.appendingPathComponent("state.json"))
            if script != nil { try files.removeItem(at: scriptURL) }
            let uninstallURL = root.appendingPathComponent("uninstall.sh")
            if files.fileExists(atPath: uninstallURL.path) { try files.removeItem(at: uninstallURL) }
            try legacy.remove()
            if savedBackup != nil { try files.removeItem(at: backupURL) }
            try observe?(.cleanup)
            try files.removeItem(at: root.appendingPathComponent("state.json"))
            if rmdir(root.path) != 0 && errno != ENOTEMPTY { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    private static func selectsWrapper(_ url: URL, root: URL) throws -> Bool {
        guard let data = try read(url) else { return false }
        let doc = try ClaudeSettingsDocument(data)
        _ = try doc.rawStatusLine()
        guard let line = doc.object["statusLine"] as? [String: Any], let command = line["command"] as? String else {
            return false
        }
        return isManagedCommand(command, root: root)
            || command.contains(root.appendingPathComponent("statusline.sh").path)
    }

    private static func restoredSettings(
        _ document: ClaudeSettingsDocument, command: String, line: [String: Any], state: State, backup: Data?, root: URL
    ) throws -> Data? {
        let baseline = try backup.map(ClaudeSettingsDocument.init)
        let original = state.originalCommand.flatMap { isManagedCommand($0, root: root) ? nil : $0 }
        if let baseline, try baseline.settingCommand(command) == document.data { return baseline.data }
        if let baseline, state.settingsBackup == nil || state.legacyFormatting == "legacy" {
            // The previous installer serialized the entire document this way. Exact reproduction
            // proves that it is safe to recover the original formatting even after upgrading.
            var oldSettings = baseline.object
            var installedLine = oldSettings["statusLine"] as? [String: Any] ?? [:]
            installedLine["command"] = command
            installedLine["type"] = "command"
            oldSettings["statusLine"] = installedLine
            let oldBytes = try JSONSerialization.data(
                withJSONObject: oldSettings, options: [.prettyPrinted, .sortedKeys])
            if oldBytes == document.data { return baseline.data }
            if try ClaudeSettingsDocument(oldBytes).settingCommand(command) == document.data { return baseline.data }
        }
        if let original {
            if let bytes = try baseline?.rawCommand() { return try document.settingCommand(raw: bytes) }
            return try document.settingCommand(original)
        }
        guard Set(line.keys) == ["command", "type"], line["type"] as? String == "command" else {
            throw SetupError(
                message:
                    "The Claude status line gained custom settings. Select a replacement status line before disconnecting."
            )
        }
        if state.settingsBackup == "absent",
            try ClaudeSettingsDocument(ClaudeSettingsDocument.empty).settingCommand(command) == document.data
        {
            return nil
        }
        return try document.settingStatusLine(baseline?.rawStatusLine())
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

    private static func isManagedCommand(_ command: String, root: URL) -> Bool {
        guard let words = literalWords(command), let path = words.last,
            words.count == 1 || (words.count == 2 && ["/bin/bash", "bash"].contains(words[0]))
        else { return false }
        guard path.hasPrefix("/") else { return false }
        let script = root.appendingPathComponent("statusline.sh")
        if sameFile(path, script.path) { return true }
        // When the script is missing, recognize the installer's target through directory aliases for repair.
        let suffix = "/.quotabar/statusline.sh"
        guard path.hasSuffix(suffix) else { return false }
        let parent = String(path.dropLast(suffix.count))
        return sameFile(parent.isEmpty ? "/" : parent, root.deletingLastPathComponent().path)
    }

    // Decode shell quoting and escapes for literal words only. An active shell operator or expansion
    // makes the entire command custom, even when one operand happens to identify our wrapper.
    private static func literalWords(_ command: String) -> [String]? {
        guard !command.utf8.contains(0) else { return nil }
        let operators = CharacterSet(charactersIn: ";&|<>(){}*?[]\r\n")
        var scalars = command.unicodeScalars.makeIterator()
        var delimiter: Unicode.Scalar?
        var words: [String] = []
        var word = ""
        var started = false
        while let scalar = scalars.next() {
            if scalar == delimiter {
                delimiter = nil
            } else if scalar == "\\", delimiter != "'" {
                guard let escaped = scalars.next(), escaped != "\n" else { return nil }
                if delimiter == "\"", !["$", "`", "\"", "\\"].contains(escaped) {
                    word.unicodeScalars.append("\\")
                }
                word.unicodeScalars.append(escaped)
            } else if delimiter != "'", scalar == "$" || scalar == "`" {
                return nil
            } else if delimiter != nil {
                word.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\"" {
                delimiter = scalar
            } else if scalar == " " || scalar == "\t" {
                if started {
                    words.append(word)
                    word = ""
                    started = false
                }
                continue
            } else {
                guard !operators.contains(scalar), started || scalar != "#" else { return nil }
                word.unicodeScalars.append(scalar)
            }
            guard words.count < 2 else { return nil }
            started = true
        }
        guard delimiter == nil else { return nil }
        if started { words.append(word) }
        return words
    }

    private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat()
        var right = stat()
        return stat(lhs, &left) == 0 && stat(rhs, &right) == 0
            && left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func version(of script: Data, state: State) -> WrapperVersion? {
        WrapperVersion.allCases.first {
            ($0 != .current || state.captureProfile != nil) && wrapper(state, version: $0) == script
        }
    }

    private static func wrapper(_ state: State, version: WrapperVersion = .current) -> Data {
        let guardLines: String
        switch version {
        case .unguarded:
            guardLines = ""
        case .globallyGuarded:
            guardLines =
                "if [[ \"${QUOTABAR_STATUSLINE_ACTIVE:-}\" == 1 ]]; then exit 0; fi\n"
                + "export QUOTABAR_STATUSLINE_ACTIVE=1\n"
        case .current, .profileTagged, .visited:
            // Use the actual script's device and inode so aliases share an entry while other profiles can chain.
            guardLines = """
                quotabar_id=$(/usr/bin/stat -L -f '%d:%i' "${BASH_SOURCE[0]}") || exit 0
                case "|${QUOTABAR_STATUSLINE_VISITED:-}|" in *"|$quotabar_id|"*) exit 0 ;; esac
                export QUOTABAR_STATUSLINE_VISITED="${QUOTABAR_STATUSLINE_VISITED:-}|$quotabar_id"

                """
        }
        let profile =
            (version == .current || version == .profileTagged)
            ? state.captureProfile.map { "QUOTABAR_CAPTURE_PROFILE=" + quote($0) + " " } ?? "" : ""
        let outer =
            version == .current
            ? "quotabar_outer=1\nif [[ -n \"${QUOTABAR_STATUSLINE_VISITED:-}\" || \"${QUOTABAR_STATUSLINE_ACTIVE:-}\" == 1 || \"${QUOTABAR_SKIP_NESTED_CAPTURE:-}\" == 1 ]]; then quotabar_outer=0; fi\n"
            : ""
        let capture = version == .current ? "$quotabar_outer == 1 && " : ""
        let handoff = version == .current ? "export QUOTABAR_SKIP_NESTED_CAPTURE=1\n" : ""
        let original =
            state.originalCommand.map {
                "printf '%s' \"$quotabar_input\" | /bin/sh -c " + quote($0)
            } ?? "printf '%s' 'Claude Code'"
        return Data(
            """
            #!/bin/bash
            # \(marker)
            \(outer)\(guardLines)IFS= read -r -d '' quotabar_input || :
            if [[ \(capture)-x \(quote(state.executable)) ]]; then
                printf '%s' "$quotabar_input" | \(profile)\(quote(state.executable)) --capture-claude-quota >/dev/null 2>&1 || :
            fi
            \(handoff)\(original)

            """.utf8)
    }

    /// A self-contained script that undoes the connection after QuotaBar itself has been deleted.
    /// It uses only macOS's own JavaScript engine and edits settings.json only while it still selects the wrapper.
    private static func uninstaller(managedCommand: String, originalCommand: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let managed = String(decoding: try encoder.encode(managedCommand), as: UTF8.self)
        let original = try originalCommand.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? "null"
        let program = uninstallProgram.replacingOccurrences(of: "__QUOTABAR_MANAGED__", with: managed)
            .replacingOccurrences(of: "__QUOTABAR_ORIGINAL__", with: original)
        return Data(
            """
            #!/bin/bash
            # \(marker).uninstall
            # Run with: bash ~/.claude/.quotabar/uninstall.sh (or this profile's .quotabar folder).
            # Restores the status line QuotaBar replaced and removes this folder. It works without QuotaBar.app.
            set -u
            root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
            exec /usr/bin/osascript -l JavaScript - "$root" <<'QUOTABAR_UNINSTALL'
            \(program)
            QUOTABAR_UNINSTALL

            """.utf8)
    }

    private static let uninstallProgram = #"""
        ObjC.import('Foundation');
        function run(argv) {
            const managed = __QUOTABAR_MANAGED__;
            const original = __QUOTABAR_ORIGINAL__;
            const root = argv[0];
            const profile = root.replace(/\/[^\/]+\/?$/, '');
            const settingsPath = profile + '/settings.json';
            // Any spelling of a path to a QuotaBar wrapper (/var vs /private/var, ~, symlinks) blocks removal.
            const fm = $.NSFileManager.defaultManager;
            const readText = (path) => {
                const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
                return text.isNil() ? null : ObjC.unwrap(text);
            };
            let changed = 'Claude Code settings were left unchanged.';
            if (fm.fileExistsAtPath(settingsPath)) {
                const attributes = ObjC.deepUnwrap(fm.attributesOfItemAtPathError(settingsPath, null));
                if (!attributes || attributes.NSFileType !== 'NSFileTypeRegular' || attributes.NSFileReferenceCount !== 1) {
                    throw new Error('settings.json is a link. Remove QuotaBar from its statusLine by hand, then run this script again.');
                }
                const text = readText(settingsPath);
                if (text === null) throw new Error('Could not read ' + settingsPath + '.');
                let settings;
                try { settings = JSON.parse(text); } catch (error) { throw new Error('settings.json is not valid JSON. Nothing was changed.'); }
                const line = settings && typeof settings === 'object' ? settings.statusLine : undefined;
                const command = line && typeof line === 'object' ? line.command : undefined;
                if (command === managed) {
                    if (original !== null) {
                        line.command = original;
                        changed = 'Restored the previous Claude Code status line.';
                    } else if (Object.keys(line).every((key) => key === 'type' || key === 'command')) {
                        delete settings.statusLine;
                        changed = 'Removed the QuotaBar status line.';
                    } else {
                        throw new Error('The QuotaBar status line has extra settings. Choose a replacement status line first. Nothing was changed.');
                    }
                    if (readText(settingsPath) !== text) throw new Error('settings.json changed while uninstalling. Run this script again.');
                    const output = $(JSON.stringify(settings, null, 2) + '\n');
                    if (!output.writeToFileAtomicallyEncodingError(settingsPath, true, $.NSUTF8StringEncoding, null)) {
                        throw new Error('Could not write ' + settingsPath + '. Nothing was changed.');
                    }
                    fm.setAttributesOfItemAtPathError($({ NSFilePosixPermissions: attributes.NSFilePosixPermissions }), settingsPath, null);
                } else if (typeof command === 'string' && command.includes('.quotabar/statusline.sh')) {
                    throw new Error('The current status line still calls QuotaBar’s script. Remove that reference first. Nothing was changed.');
                }
            }
            for (const name of ['statusline.sh', 'state.json', 'previous-settings.json', 'uninstall.sh']) {
                const path = root + '/' + name;
                if (fm.fileExistsAtPath(path) && !fm.removeItemAtPathError(path, null)) throw new Error('Could not remove ' + path + '.');
            }
            const left = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(root, null)) || [];
            if (left.length === 0) {
                fm.removeItemAtPathError(root, null);
                return changed + ' Removed ' + root + '.';
            }
            return changed + ' Left ' + root + ' in place because it also contains: ' + left.join(', ') + '.';
        }
        """#

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
        return !script.hasPrefix("#!/bin/bash\n# " + marker + "\n") && script.contains("--capture-claude-quota")
            && script.contains("QuotaBar.app/Contents/MacOS/QuotaBar")
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

    private static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600)
        throws
    {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".quotabar-write-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try handle.close()
        let result = rename(temporary.path, url.path)
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
