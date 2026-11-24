import Darwin
import Foundation

enum ClaudeProfile {
    private static let key = "claudeProfileDirectory"

    static var directory: URL { resolve() }

    enum ReadError: Error { case directoryChanged }

    /// Profile managers can retarget a symlink while a background read is running.
    static func read<T>(at directory: URL, _ body: (URL) throws -> T) throws -> T {
        let before = try ReadIdentity(directory)
        let result = Result { try body(URL(fileURLWithPath: before.path, isDirectory: true)) }
        guard try ReadIdentity(directory) == before else { throw ReadError.directoryChanged }
        return try result.get()
    }

    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            createdSeconds = info.st_birthtimespec.tv_sec
            createdNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    private struct LinkRevision: Equatable {
        let id: FileID
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            id = FileID(info)
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct ReadIdentity: Equatable {
        let path: String
        let directoryID: FileID?
        private var links: [LinkRevision] = []

        init(_ directory: URL) throws {
            let literal = directory.path
            var info = stat()
            // The kernel can prove an existing ordinary path contains no symlinks in a single lookup.
            // Darwin can return the final symlink itself with AT_SYMLINK_NOFOLLOW_ANY.
            if fstatat(AT_FDCWD, literal, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0, info.st_mode & S_IFMT != S_IFLNK {
                guard let actual = realpath(literal, nil) else { throw ReadError.directoryChanged }
                defer { free(actual) }
                path = String(cString: actual)
                directoryID = FileID(info)
                return
            }

            // Resolve relative link targets against their containing directory. Inspect their
            // components too: a stable outer alias may point through a separately managed alias.
            var pending = Array(literal.split(separator: "/").reversed())
            var parent = "/"
            while let component = pending.popLast() {
                if component == "." { continue }
                if component == ".." {
                    parent = (parent as NSString).deletingLastPathComponent
                    continue
                }
                let next = (parent as NSString).appendingPathComponent(String(component))
                guard lstat(next, &info) == 0 else {
                    guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    // The kernel stops at the first absent component even if ".." follows it.
                    guard !pending.contains("..") else { throw POSIXError(.ENOENT) }
                    let missing = ClaudeProfile.canonicalPath(URL(fileURLWithPath: next))
                    parent = pending.reversed().filter { $0 != "." }.reduce(missing) {
                        ($0 as NSString).appendingPathComponent(String($1))
                    }
                    break
                }
                if info.st_mode & S_IFMT == S_IFLNK {
                    guard links.count < Int(MAXSYMLINKS) else { throw POSIXError(.ELOOP) }
                    links.append(LinkRevision(info))
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: next)
                    if target.hasPrefix("/") { parent = "/" }
                    pending.append(contentsOf: target.split(separator: "/").reversed())
                } else {
                    parent = next
                }
            }
            if let actual = realpath(literal, nil) {
                defer { free(actual) }
                path = String(cString: actual)
                guard stat(literal, &info) == 0 else { throw ReadError.directoryChanged }
                directoryID = FileID(info)
            } else {
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                path = parent
                directoryID = nil
            }
        }
    }

    static func resolve(
        defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        for path in [defaults.string(forKey: key), environment["CLAUDE_CONFIG_DIR"]] {
            if let path, path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The CLAUDE_CONFIG_DIR to pass to a Claude Code child process, or nil to use Claude Code's default profile.
    /// Claude Code treats any explicit value, even ~/.claude, as a separate profile with its own .claude.json and
    /// keychain item. Passing the default path would hide the user's normal sign-in and its subscription limits.
    static func childConfigurationDirectory(
        defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let preference = defaults.string(forKey: key), preference.hasPrefix("/") else {
            guard let inherited = environment["CLAUDE_CONFIG_DIR"], inherited.hasPrefix("/") else { return nil }
            return inherited
        }
        let selected = URL(fileURLWithPath: preference, isDirectory: true)
        let standard = home.appendingPathComponent(".claude", isDirectory: true)
        return canonicalPath(selected) == canonicalPath(standard) ? nil : selected.path
    }

    /// Resolves links through the deepest existing ancestor, then appends the missing components, so a folder
    /// that does not exist yet compares equal under every spelling of its parent (for example /tmp and /private/tmp).
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL.path
        var missing: [String] = []
        while existing != "/", !FileManager.default.fileExists(atPath: existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = existing
        if let pointer = realpath(existing, nil) {
            resolved = String(cString: pointer)
            free(pointer)
        }
        return missing.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func select(_ directory: URL?, defaults: UserDefaults = .standard) {
        if let directory {
            defaults.set(directory.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
