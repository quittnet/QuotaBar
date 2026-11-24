import Foundation

struct TokenSpendAmount: Sendable, Equatable {
    // Every charge in the bundled rate table is a whole number of nanodollars.
    // Sum in those units so splitting a request cannot change cent rounding.
    private var nanodollars = 0.0
    var usd: Double { nanodollars / 1_000_000_000 }
    private(set) var hasPricedUsage = false
    fileprivate(set) var partial = false

    func formattedUSD(historyPartial: Bool, locale: Locale = .current) -> String? {
        let incomplete = historyPartial || partial
        guard hasPricedUsage || !incomplete else { return nil }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale).precision(.fractionLength(2))
        return usd > 0 && usd < 0.01 ? "<" + 0.01.formatted(style) : usd.formatted(style)
    }

    mutating func add(_ cost: Double?) {
        guard let cost, cost.isFinite, cost >= 0 else {
            partial = true
            return
        }
        nanodollars += (cost * 1_000_000_000).rounded()
        hasPricedUsage = true
    }
}

struct TokenSpendTotals: Sendable, Equatable {
    var allTime = TokenSpendAmount()
    var month = TokenSpendAmount()
    var week = TokenSpendAmount()
    var yesterday = TokenSpendAmount()
    var today = TokenSpendAmount()

    var hasPartialPeriod: Bool {
        allTime.partial || month.partial || week.partial || yesterday.partial || today.partial
    }

    mutating func record(
        _ usd: Double?, tokens: Int64, date: Date?, latestDate: Date? = nil, now: Date, days: TokenDayBoundaries
    ) {
        guard tokens > 0, date.map({ $0 <= now }) ?? true else { return }
        allTime.add(usd)
        guard let date else {
            // The lifetime amount is still attributable, but any dated period might be missing it.
            month.partial = true
            week.partial = true
            yesterday.partial = true
            today.partial = true
            return
        }
        let latest = latestDate ?? date
        if date >= days.month { month.add(usd) } else if latest >= days.month { month.partial = true }
        if date >= days.week { week.add(usd) } else if latest >= days.week { week.partial = true }
        if date >= days.today { today.add(usd) } else if latest >= days.today { today.partial = true }
        let firstYesterday = (days.yesterday..<days.today).contains(date)
        let lastYesterday = (days.yesterday..<days.today).contains(latest)
        if firstYesterday && lastYesterday {
            yesterday.add(usd)
        } else if firstYesterday || lastYesterday {
            yesterday.partial = true
        }
    }
}

enum TokenPricing {
    // Increment when a rate or calculation changes so retained transcripts are repriced.
    static let revision = 2

    // Only documented snapshots share an alias's prices and cache-write rules.
    private static let codexSnapshotAliases = [
        "gpt-5.5-2026-04-23": "gpt-5.5",
        "gpt-5.4-2026-03-05": "gpt-5.4",
        "gpt-5.4-mini-2026-03-17": "gpt-5.4-mini",
        "gpt-5.4-nano-2026-03-17": "gpt-5.4-nano",
        "gpt-5.2-2025-12-11": "gpt-5.2",
        "gpt-5.1-2025-11-13": "gpt-5.1",
        "gpt-5-2025-08-07": "gpt-5",
        "gpt-5-mini-2025-08-07": "gpt-5-mini",
        "gpt-5-nano-2025-08-07": "gpt-5-nano",
    ]

    // Standard, first-party USD per million text tokens, checked 2026-11-22.
    // https://developers.openai.com/api/docs/pricing.md
    // https://platform.claude.com/docs/en/about-claude/pricing
    private struct Rates: Equatable {
        let input: Double
        let read: Double
        let output: Double

        init(_ input: Double, _ read: Double, _ output: Double) {
            self.input = input
            self.read = read
            self.output = output
        }
    }

    private static func codexRates(_ identifier: String, input: Int64) -> (rates: Rates, supportsWrites: Bool)? {
        let model = codexSnapshotAliases[identifier] ?? identifier
        let rates: Rates
        switch model {
        case "gpt-6.2-astra": rates = Rates(8, 0.4, 40)
        case "gpt-6.2-sol", "gpt-6.1-sol": rates = Rates(2, 0.1, 10)
        case "gpt-6-astra": rates = Rates(10, 1, 50)
        case "gpt-6.1-terra": rates = Rates(1, 0.05, 5)
        case "gpt-6-luna": rates = Rates(0.1, 0.01, 0.5)
        case "gpt-6-sol": rates = Rates(2, 0.2, 10)
        case "gpt-5.6-terra": rates = Rates(2, 0.2, 12)
        case "gpt-5.6-sol": rates = Rates(4, 0.4, 20)
        case "gpt-5.6-luna": rates = Rates(0.2, 0.02, 1.2)
        case "gpt-5.5": rates = Rates(5, 0.5, 30)
        case "gpt-5.4": rates = Rates(2.5, 0.25, 15)
        case "gpt-5.4-mini": return (Rates(0.75, 0.075, 4.5), false)
        case "gpt-5.4-nano": return (Rates(0.2, 0.02, 1.25), false)
        case "gpt-5.2", "gpt-5.2-codex", "gpt-5.3-codex": return (Rates(1.75, 0.175, 14), false)
        case "gpt-5", "gpt-5.1", "gpt-5-codex", "gpt-5.1-codex", "gpt-5.1-codex-max":
            return (Rates(1.25, 0.125, 10), false)
        case "gpt-5-mini": return (Rates(0.25, 0.025, 2), false)
        case "gpt-5-nano": return (Rates(0.05, 0.005, 0.4), false)
        default: return nil
        }
        let supportsWrites = model != "gpt-5.4" && model != "gpt-5.5"
        if input > 272_000 { return (Rates(rates.input * 2, rates.read * 2, rates.output * 1.5), supportsWrites) }
        return (rates, supportsWrites)
    }

    static func isKnownCodexModel(_ model: String) -> Bool {
        codexRates(model, input: 0) != nil
    }

    static func codex(
        model: String?, input: Int64?, cached: Int64?, cacheWrite: Int64? = nil, output: Int64?, total: Int64
    ) -> Double? {
        guard let model, let input, let output, input >= 0, output >= 0, input <= total,
            total - input == output, let cached = cached ?? (input == 0 ? 0 : nil),
            cached >= 0, cached <= input, let (rates, supportsWrites) = codexRates(model, input: input)
        else { return nil }
        let writes = cacheWrite ?? 0
        guard writes >= 0, writes <= input - cached, writes == 0 || supportsWrites else { return nil }
        // Codex records the total cache writes without a retention duration. Quote the standard 30m rate.
        let uncached = Double(input - cached - writes) * rates.input
        let cache = Double(cached) * rates.read + Double(writes) * rates.input * 1.25
        return (uncached + cache + Double(output) * rates.output) / 1_000_000
    }

    static func canonicalClaudeModel(_ model: String) -> String {
        switch model {
        case "claude-opus-4-5-20251101": return "claude-opus-4-5"
        case "claude-opus-4-1-20250805": return "claude-opus-4-1"
        case "claude-sonnet-4-5-20250929": return "claude-sonnet-4-5"
        case "claude-haiku-4-5-20251001": return "claude-haiku-4-5"
        default: return model
        }
    }

    private static func claudeRates(_ model: String, prompt: Double) -> Rates? {
        switch canonicalClaudeModel(model) {
        case "claude-fable-5-2", "claude-mythos-5-2": return Rates(8, 0.20, 40)
        case "claude-fable-5-1", "claude-mythos-5-1": return Rates(10, 0.25, 50)
        case "claude-fable-5", "claude-mythos-5": return Rates(10, 1, 50)
        case "claude-opus-5-5": return Rates(4, 0.20, 20)
        case "claude-sonnet-5-5": return Rates(2, 0.10, 10)
        case "claude-haiku-5-5": return prompt > 100_000 ? Rates(0.5, 0.05, 2.5) : Rates(0.1, 0.01, 0.5)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": return Rates(5, 0.5, 25)
        case "claude-sonnet-5": return Rates(2, 0.20, 10)
        case "claude-sonnet-4-6": return Rates(3, 0.3, 15)
        case "claude-opus-4-5":
            return prompt <= 200_000 ? Rates(5, 0.5, 25) : nil
        case "claude-opus-4-1", "claude-opus-4-20250514":
            return prompt <= 200_000 ? Rates(15, 1.5, 75) : nil
        case "claude-sonnet-4-5", "claude-sonnet-4-20250514":
            return prompt <= 200_000 ? Rates(3, 0.3, 15) : nil
        case "claude-haiku-4-5": return Rates(1, 0.1, 5)
        default: return nil
        }
    }

    static func claude(
        model: String?, input: Int64, cacheRead: Int64, cacheWrite: Int64, write5m: Int64?, write1h: Int64?,
        output: Int64, promptRange: ClosedRange<Int64>? = nil
    ) -> Double? {
        let short = write5m ?? 0
        let long = write1h ?? 0
        let prompt = Double(input) + Double(cacheRead) + Double(cacheWrite)
        let minimum = promptRange.map { Double($0.lowerBound) } ?? prompt
        let maximum = promptRange.map { Double($0.upperBound) } ?? prompt
        guard let model, input >= 0, cacheRead >= 0, output >= 0, short >= 0, long >= 0, short <= cacheWrite,
            cacheWrite - short == long,
            let rates = claudeRates(model, prompt: minimum),
            minimum == maximum || rates == claudeRates(model, prompt: maximum)
        else { return nil }
        let writes = (Double(short) * 1.25 + Double(long) * 2) * rates.input
        return (Double(input) * rates.input + Double(cacheRead) * rates.read + writes + Double(output) * rates.output)
            / 1_000_000
    }
}
