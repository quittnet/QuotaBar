import Foundation

enum ClaudeProfile {
    private static let key = "claudeProfileDirectory"

    static var directory: URL { resolve() }

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
