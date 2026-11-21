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
        let selected = resolve(defaults: defaults, environment: environment, home: home)
        let standard = home.appendingPathComponent(".claude", isDirectory: true)
        let isStandard =
            selected.resolvingSymlinksInPath().standardizedFileURL.path
            == standard.resolvingSymlinksInPath().standardizedFileURL.path
        return isStandard && environment["CLAUDE_CONFIG_DIR"] == nil ? nil : selected.path
    }

    static func select(_ directory: URL?, defaults: UserDefaults = .standard) {
        if let directory {
            defaults.set(directory.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
