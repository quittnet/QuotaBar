import Foundation

actor LocalTokenReader {
    private lazy var codex = TokenHistory()
    private var claude: (profile: URL, history: ClaudeTokenHistory)?

    func totals(for provider: UsageProvider, now: Date, claudeProfile: URL) throws -> TokenTotals {
        switch provider {
        case .codex: return try codex.read(now: now)
        case .claude:
            return try ClaudeProfile.read(at: claudeProfile) { directory in
                if let claude, claude.profile == directory { return try claude.history.read(now: now) }
                let history = ClaudeTokenHistory(profile: directory)
                claude = (directory, history)
                return try history.read(now: now)
            }
        }
    }
}
