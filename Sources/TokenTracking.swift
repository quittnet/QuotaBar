import Foundation

actor LocalTokenReader {
    private lazy var codex = TokenHistory()
    private var claude: (profile: URL, history: ClaudeTokenHistory)?

    func totals(for provider: UsageProvider, now: Date, claudeProfile: URL) throws -> TokenTotals {
        switch provider {
        case .codex: return try codex.read(now: now)
        case .claude:
            if let claude, claude.profile == claudeProfile { return try claude.history.read(now: now) }
            let history = ClaudeTokenHistory(profile: claudeProfile)
            claude = (claudeProfile, history)
            return try history.read(now: now)
        }
    }
}
