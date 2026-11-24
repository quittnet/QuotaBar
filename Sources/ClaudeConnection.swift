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
        var disconnectHelperSHA256: String? = nil
        var disconnecting: String? = nil

        static func recognizes(_ key: String) -> Bool { CodingKeys(stringValue: key) != nil }
    }

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var directory: URL { ClaudeProfile.directory }

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
        var info = stat()
        let directoryExists = lstat(root.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        let state = directoryExists ? try? loadState(root).state : nil
        if isManagedCommand(command, root: root, previousProfile: state?.captureProfile) {
            guard let state, let script = try? read(root.appendingPathComponent("statusline.sh")),
                let version = version(of: script, state: state)
            else { return .notConfigured }
            let installed = URL(fileURLWithPath: state.executable)
            return version == .current && state.disconnectHelperSHA256 != nil
                && state.disconnectHelperSHA256 == bundledHelperDigest
                && FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(helperName).path)
                && FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("uninstall.sh").path)
                && !isTranslocated(installed)
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
        try withProfileLock(directory) { try install(directory: $0, executable: executable, observe: observe) }
    }

    private static func withProfileLock(_ selected: URL, body: (URL) throws -> Void) throws {
        let lock = open(selected.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard lock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // The selected profile can be a symlink. Keep every write and rollback in the
        // directory we locked, even if a profile manager switches the selection.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(lock, F_GETPATH, &path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let directory = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
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
        try body(directory)
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
        var currentlyManaged = currentCommand.map { isManagedCommand($0, root: root) } ?? false
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
            let record = try loadState(root)
            oldState = record.state
            if !currentlyManaged, let currentCommand, let previous = record.state.captureProfile {
                currentlyManaged = isManagedCommand(currentCommand, root: root, previousProfile: previous)
            }
            guard oldState?.disconnecting == nil else {
                throw SetupError(message: "Finish disconnecting this Claude profile before reconnecting.")
            }
            // Making a command that calls our own wrapper its new original would erase the
            // previous command and backup. The recursion guard would then skip its output.
            if !currentlyManaged, let currentCommand,
                referencesWrapper(currentCommand, root: root, previousProfile: record.state.captureProfile)
            {
                throw SetupError(
                    message:
                        "The edited Claude status line still calls QuotaBar’s script. Remove that reference or restore the original wrapper invocation before reconnecting."
                )
            }
            oldScript = try read(scriptURL)
            oldStateData = record.bytes
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
        let uninstallURL = root.appendingPathComponent("uninstall.sh")
        let helperURL = root.appendingPathComponent(helperName)
        let oldUninstaller = try checkedUninstaller(root, state: oldState)
        let helper = try bundledHelper()
        let helperDigest = digest(helper)
        let uninstallScript = launcher(helperDigest)
        let state = State(
            marker: marker, originalCommand: originalCommand, executable: executable.path, settingsBackup: origin,
            captureProfile: directory.resolvingSymlinksInPath().path,
            legacyFormatting: currentlyManaged && (oldState?.legacyFormatting == "legacy" || migratedBackup != nil)
                ? "legacy" : nil, disconnectHelperSHA256: helperDigest)
        let script = wrapper(state)
        let patched = try document.settingCommand(managedCommand)
        let updatedSettings = currentCommand == managedCommand ? document.data : patched
        guard updatedSettings.count <= maximumFileSize else { throw ClaudeSettingsDocument.Failure.unsupported }
        if currentCommand == managedCommand, oldScript == script, origin == oldState?.settingsBackup,
            legacy.files.isEmpty, oldUninstaller.script == uninstallScript, oldUninstaller.helper == helper,
            files.isExecutableFile(atPath: helperURL.path), files.isExecutableFile(atPath: uninstallURL.path)
        {
            return
        }
        try requireSingleLink(settingsURL)
        if !rootExisted {
            try files.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var rollback: [(url: URL, restore: Data?, installed: Data?, permissions: mode_t)] = []
        func replaceFile(_ url: URL, previous: Data?, with next: Data?, permissions: mode_t = 0o600) throws {
            var info = stat()
            if previous != nil, lstat(url.path, &info) != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try ClaudeSettingsCommit.apply(next, replacing: previous, at: url, permissions: permissions, observe: nil)
            rollback.append((url, previous, next, info.st_mode & 0o7777))
        }
        var connectionFilesReady = false
        do {
            if backup != oldBackup { try replaceFile(backupURL, previous: oldBackup, with: backup) }
            try replaceFile(scriptURL, previous: oldScript, with: script, permissions: 0o700)
            try replaceFile(stateURL, previous: oldStateData, with: JSONEncoder().encode(state))
            try replaceFile(helperURL, previous: oldUninstaller.helper, with: helper, permissions: 0o700)
            try observe?(.installingUninstaller)
            try replaceFile(uninstallURL, previous: oldUninstaller.script, with: uninstallScript, permissions: 0o700)
            guard try read(settingsURL) == previousSettings else {
                throw SetupError(
                    message: "Claude Code’s settings changed during setup. Connect again to use the latest settings.")
            }
            if previousSettings != updatedSettings {
                connectionFilesReady = true
                try ClaudeSettingsCommit.apply(
                    updatedSettings, replacing: previousSettings, at: settingsURL, observe: observe)
            }
        } catch {
            // A concurrent editor may have saved the newly installed wrapper into its own version.
            // Leave its verified script and record available if that version is now active.
            if connectionFilesReady, (try? selectsWrapper(settingsURL, root: root)) == true { throw error }
            let setupError = error
            var conflicts: [String] = []
            for file in rollback.reversed() {
                do {
                    try ClaudeSettingsCommit.apply(
                        file.restore, replacing: file.installed, at: file.url, permissions: file.permissions,
                        observe: nil)
                } catch {
                    conflicts.append(file.url.path + ". " + error.localizedDescription)
                }
            }
            if !rootExisted { _ = rmdir(root.path) }
            if !conflicts.isEmpty {
                throw SetupError(
                    message: setupError.localizedDescription + " Review " + conflicts.joined(separator: "\n"))
            }
            throw setupError
        }
        try legacy.remove()
    }

    private struct LegacyFiles {
        var files: [(url: URL, identity: stat, checksum: String?)] = []
        var original: Data?

        func remove() throws {
            for file in files {
                let expected: Data
                if let checksum = file.checksum {
                    guard let bytes = try read(file.url), digest(bytes) == checksum else {
                        throw SetupError(message: "The legacy backup changed during cleanup. Review " + file.url.path)
                    }
                    expected = bytes
                } else {
                    expected = Data()  // The legacy lock was empty when discovered.
                }
                try removeVerifiedFile(file.url, expected: expected, identity: file.identity)
            }
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
            result.files.append((url, info, digest(data)))
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
            result.files.append((lock, info, nil))
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
        try withProfileLock(directory) { directory in
            let root = directory.appendingPathComponent(".quotabar")
            guard canDisconnect(directory: directory) else {
                throw SetupError(
                    message: "QuotaBar couldn’t find its connection record in the selected Claude profile.")
            }
            let record = try loadState(root)
            var state = record.state
            let uninstaller = try checkedUninstaller(root, state: state)
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
            try requireSingleLink(settingsURL)
            if let current = try read(settingsURL) {
                let document = try ClaudeSettingsDocument(current)
                _ = try document.rawStatusLine()
                if let line = document.object["statusLine"] as? [String: Any], line["type"] as? String == "command",
                    let command = line["command"] as? String,
                    isManagedCommand(command, root: root, previousProfile: state.captureProfile)
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
                    guard try read(settingsURL) == current else {
                        throw SetupError(message: "Claude Code’s settings changed during disconnect. Try again.")
                    }
                    try ClaudeSettingsCommit.apply(updated, replacing: current, at: settingsURL, observe: observe)
                } else if let line = document.object["statusLine"] as? [String: Any],
                    let command = line["command"] as? String,
                    referencesWrapper(command, root: root, previousProfile: state.captureProfile)
                {
                    throw SetupError(
                        message:
                            "The replacement status line still calls QuotaBar’s script. Remove that reference before disconnecting."
                    )
                }
            }
            guard try !selectsWrapper(settingsURL, root: root, previousProfile: state.captureProfile) else {
                throw SetupError(
                    message:
                        "A Claude settings edit selected the wrapper again. Review the current status line before disconnecting."
                )
            }
            state.disconnecting = "yes"
            let stateURL = root.appendingPathComponent("state.json")
            let cleanupRecord = try JSONEncoder().encode(state)
            try ClaudeSettingsCommit.apply(cleanupRecord, replacing: record.bytes, at: stateURL, observe: nil)
            try removeVerifiedFile(scriptURL, expected: script)
            try legacy.remove()
            try removeVerifiedFile(backupURL, expected: savedBackup)
            try observe?(.cleanup)
            try removeVerifiedFile(root.appendingPathComponent("uninstall.sh"), expected: uninstaller.script)
            try removeVerifiedFile(root.appendingPathComponent(helperName), expected: uninstaller.helper)
            try removeVerifiedFile(stateURL, expected: cleanupRecord)
            if rmdir(root.path) != 0 && errno != ENOTEMPTY { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    private static func selectsWrapper(_ url: URL, root: URL, previousProfile: String? = nil) throws -> Bool {
        guard let data = try read(url) else { return false }
        let doc = try ClaudeSettingsDocument(data)
        _ = try doc.rawStatusLine()
        guard let line = doc.object["statusLine"] as? [String: Any], let command = line["command"] as? String else {
            return false
        }
        return referencesWrapper(command, root: root, previousProfile: previousProfile)
    }

    private static func referencesWrapper(_ command: String, root: URL, previousProfile: String? = nil) -> Bool {
        if let path = literalInvocationPath(command) {
            return isManagedPath(path, root: root, previousProfile: previousProfile)
        }
        // Also recognize literal wrapper operands in pipelines, including escaped paths and aliases.
        if let words = literalWords(command, compoundProfile: root.deletingLastPathComponent()),
            words.contains(where: {
                $0.hasPrefix("/") && isManagedPath($0, root: root, previousProfile: previousProfile)
            })
        {
            return true
        }
        let script = root.appendingPathComponent("statusline.sh")
        var paths = [script.path, script.resolvingSymlinksInPath().path]
        if let physical = realpath(script.path, nil) {
            paths.append(String(cString: physical))
            free(physical)
        }
        if let previous = missingRecordedWrapper(in: previousProfile) { paths.append(previous) }
        // A shell command embedded inside a quoted argument may still name the wrapper.
        // Require the end of its name so scripts such as statusline.sh.personal remain independent.
        return paths.contains { path in
            [path, quote(path)].contains { spelling in
                let pattern = NSRegularExpression.escapedPattern(for: spelling) + #"(?=$|[\s'";&|<>()`])"#
                return command.range(of: pattern, options: .regularExpression) != nil
            }
        }
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

    private static func loadState(_ root: URL) throws -> (state: State, bytes: Data) {
        guard let data = try read(root.appendingPathComponent("state.json")),
            let state = try? JSONDecoder().decode(State.self, from: data), state.marker == marker,
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            fields.keys.allSatisfy(State.recognizes)
        else {
            throw SetupError(
                message:
                    "The .quotabar folder already exists without a valid connection record. Check that folder before connecting."
            )
        }
        return (state, data)
    }

    private static func wrapperCommand(_ root: URL) -> String {
        "/bin/bash " + quote(root.appendingPathComponent("statusline.sh").path)
    }

    private static func isManagedCommand(_ command: String, root: URL, previousProfile: String? = nil) -> Bool {
        guard let path = literalInvocationPath(command) else { return false }
        return isManagedPath(path, root: root, previousProfile: previousProfile)
    }

    private static func literalInvocationPath(_ command: String) -> String? {
        guard let words = literalWords(command), let path = words.last,
            path.hasPrefix("/"),
            words.count == 1 || (words.count == 2 && ["/bin/bash", "bash"].contains(words[0]))
        else { return nil }
        return path
    }

    private static func isManagedPath(_ path: String, root: URL, previousProfile: String?) -> Bool {
        let script = root.appendingPathComponent("statusline.sh")
        if sameFile(path, script.path) { return true }
        // When the script is missing, recognize the installer's target through directory aliases for repair.
        let suffix = "/.quotabar/statusline.sh"
        guard path.hasSuffix(suffix) else { return false }
        let parent = String(path.dropLast(suffix.count))
        // A renamed profile still selects its old absolute path. Keep a live source wrapper
        // distinct so that a copied profile can continue chaining to the original one.
        if parent == previousProfile, missingRecordedWrapper(in: previousProfile) == path { return true }
        return sameFile(parent.isEmpty ? "/" : parent, root.deletingLastPathComponent().path)
    }

    private static func missingRecordedWrapper(in profile: String?) -> String? {
        guard let profile, profile.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: profile).appendingPathComponent(".quotabar/statusline.sh").path
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT ? path : nil
    }

    // Decode shell quoting and escapes for literal words only. An active shell operator or expansion
    // makes the entire command custom, even when one operand happens to identify our wrapper.
    private static func literalWords(_ command: String, compoundProfile: URL? = nil) -> [String]? {
        guard !command.utf8.contains(0) else { return nil }
        let allowCompound = compoundProfile != nil
        let operators = CharacterSet(charactersIn: ";&|<>(){}*?[]\r\n")
        var scalars = command.unicodeScalars[...]
        var delimiter: Unicode.Scalar?
        var words: [String] = []
        var word = ""
        var started = false
        // These shell roots can identify a dependency while checking an edited command.
        // They never establish ownership or allow QuotaBar to replace a dynamic command.
        let shellRoots = compoundProfile.map {
            (profile: $0.path, home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        }
        while let scalar = scalars.popFirst() {
            if scalar == delimiter {
                delimiter = nil
            } else if scalar == "\\", delimiter != "'" {
                guard let escaped = scalars.popFirst(), escaped != "\n" else { return nil }
                if delimiter == "\"", !["$", "`", "\"", "\\"].contains(escaped) {
                    word.unicodeScalars.append("\\")
                }
                word.unicodeScalars.append(escaped)
            } else if scalar == "~", !started, delimiter == nil, scalars.first == "/", let shellRoots {
                word = shellRoots.home
            } else if scalar == "$", delimiter != "'", word.isEmpty, let shellRoots {
                // Claude uses the selected directory when set, and $HOME/.claude otherwise.
                // Both branches of this conventional default name the active profile. Match
                // active home expansions and balanced quotes, leaving other defaults alone.
                if scalars.starts(with: "{CLAUDE_CONFIG_DIR:-".unicodeScalars),
                    let fallback = Substring(scalars).prefixMatch(
                        of: #/\{CLAUDE_CONFIG_DIR:-("?)\$(?:HOME|\{HOME\})(?:\1/\.claude|/\.claude\1)\}/#)
                {
                    scalars = scalars.dropFirst(fallback.0.utf8.count)
                    word = shellRoots.profile
                    started = true
                    continue
                }
                word = "$"
                for (name, value) in [("CLAUDE_CONFIG_DIR", shellRoots.profile), ("HOME", shellRoots.home)] {
                    let spelling = scalars.first == "{" ? "{" + name + "}" : name
                    guard scalars.starts(with: spelling.unicodeScalars) else { continue }
                    let tail = scalars.dropFirst(spelling.utf8.count)
                    guard tail.first == "/" || tail.first == "\"" || tail.first == "'" else { continue }
                    scalars = tail
                    word = value
                    break
                }
            } else if !allowCompound, delimiter != "'", scalar == "$" || scalar == "`" {
                return nil
            } else if delimiter != nil {
                word.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\"" {
                delimiter = scalar
            } else if scalar == " " || scalar == "\t" || (allowCompound && operators.contains(scalar)) {
                if started {
                    words.append(word)
                    word = ""
                    started = false
                }
                continue
            } else {
                guard allowCompound || (!operators.contains(scalar) && (started || scalar != "#")) else { return nil }
                word.unicodeScalars.append(scalar)
            }
            guard allowCompound || words.count < 2 else { return nil }
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

    private static let helperName = "QuotaBarClaudeDisconnect"
    // A same-path app update can replace its helper without changing the wrapper or capture executable.
    // The bundle belongs to this running app version. Fingerprint it once across status polls.
    private static let bundledHelperDigest = (try? bundledHelper()).map(digest)

    private static func bundledHelper() throws -> Data {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = executable.deletingLastPathComponent()
        let helperDirectory =
            Bundle.main.bundleURL.pathExtension == "app"
            ? directory.deletingLastPathComponent().appendingPathComponent("Helpers") : directory
        guard let bytes = try read(helperDirectory.appendingPathComponent(helperName)) else {
            throw SetupError(message: "The Claude disconnect helper is missing. Reinstall QuotaBar before connecting.")
        }
        return bytes
    }

    private static func launcher(_ helperDigest: String) -> Data {
        Data(
            """
            #!/bin/bash
            # \(marker).uninstall
            # Run with bash from any directory, including after QuotaBar.app has been removed.
            set -eu
            root=$(cd -P -- "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)
            helper="$root/\(helperName)"
            if [[ -L "$helper" || ! -f "$helper" || ! -x "$helper" ]]; then
                echo "Restore or move the changed Claude disconnect helper: $helper" >&2
                exit 1
            fi
            checksum=$(/usr/bin/shasum -a 256 < "$helper")
            if [[ "${checksum%% *}" != '\(helperDigest)' ]]; then
                echo "The Claude disconnect helper has been edited: $helper" >&2
                exit 1
            fi
            exec "$helper"

            """.utf8)
    }

    private static func checkedUninstaller(_ root: URL, state: State?) throws -> (script: Data?, helper: Data?) {
        let helper = try read(root.appendingPathComponent(helperName))
        if let helper, digest(helper) != state?.disconnectHelperSHA256 {
            throw SetupError(message: "Restore or move the changed " + helperName + " file before continuing.")
        }
        let script = try read(root.appendingPathComponent("uninstall.sh"))
        if let script {
            let recognized: Bool
            if let expected = state?.disconnectHelperSHA256 {
                recognized = script == launcher(expected)
            } else {
                recognized = try state.map { try isBuild39Uninstaller(script, state: $0, root: root) } ?? false
            }
            guard recognized else {
                throw SetupError(message: "Restore or move the changed uninstall.sh file before continuing.")
            }
        }
        return (script, helper)
    }

    // Build 39 embedded two JSON literals in an otherwise fixed script. Compare the entire
    // normalized file to the released template so an upgrade never claims a hand-edited copy.
    private static func isBuild39Uninstaller(_ data: Data, state: State, root: URL) throws -> Bool {
        guard let script = String(data: data, encoding: .utf8) else { return false }
        let installedRoot =
            state.captureProfile.map { URL(fileURLWithPath: $0).appendingPathComponent(".quotabar") } ?? root
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let managed = String(decoding: try encoder.encode(wrapperCommand(installedRoot)), as: UTF8.self)
        let original = String(decoding: try encoder.encode(state.originalCommand), as: UTF8.self)
        // The old writer substituted the original-command token after inserting the managed path.
        let installed = managed.replacingOccurrences(of: "__QUOTABAR_ORIGINAL__", with: original)
        let fields = "    const managed = " + installed + ";\n    const original = " + original + ";\n"
        let normalized = script.replacingOccurrences(
            of: fields, with: "    const managed = __QUOTABAR_MANAGED__;\n    const original = __QUOTABAR_ORIGINAL__;\n"
        )
        return normalized != script
            && digest(Data(normalized.utf8)) == "09b209c45b1a4eada9f6f56be3556bcbb518e66d46fc17b6de06de867dce5462"
    }

    // A managed file can change after the preflight. Displace its directory entry and
    // compare the actual bytes before releasing it, as with settings.json itself.
    private static func removeVerifiedFile(_ url: URL, expected: Data?, identity: stat? = nil) throws {
        guard let expected else { return }
        do {
            try ClaudeSettingsCommit.apply(nil, replacing: expected, at: url, removalIdentity: identity, observe: nil)
        } catch {
            throw SetupError(message: "Couldn’t remove " + url.path + ". " + error.localizedDescription)
        }
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

}
