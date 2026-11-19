import Foundation

actor LocalTokenReader {
    private lazy var codex = TokenHistory()
    private lazy var claude = ClaudeTokenHistory()

    func totals(for provider: UsageProvider, now: Date) throws -> TokenTotals {
        switch provider {
        case .codex: return try codex.read(now: now)
        case .claude: return try claude.read(now: now)
        }
    }
}
