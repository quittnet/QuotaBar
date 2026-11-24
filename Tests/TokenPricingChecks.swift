import Foundation

enum TokenPricingChecks {
    static func run() {
        func close(_ amount: Double?, _ expected: Double) -> Bool {
            guard let amount else { return false }
            return abs(amount - expected) < 0.00000001
        }
        func codex(_ input: Int64, _ cached: Int64, _ writes: Int64 = 0) -> Double? {
            TokenPricing.codex(
                model: "gpt-6.2-sol", input: input, cached: cached, cacheWrite: writes, output: 1_000,
                total: input + 1_000)
        }
        precondition(close(codex(272_000, 20_000, 2_000), (250_000 * 2 + 20_000 * 0.1 + 2_000 * 2.5 + 10_000) / 1e6))
        precondition(close(codex(272_001, 20_000, 2_000), (250_001 * 4 + 20_000 * 0.2 + 2_000 * 5 + 15_000) / 1e6))
        precondition(codex(100, 90, 11) == nil)
        func gpt54(_ id: String, input: Int64 = 10_000, writes: Int64 = 0) -> Double? {
            TokenPricing.codex(
                model: id, input: input, cached: 0, cacheWrite: writes, output: 1_000, total: input + 1_000)
        }
        let snapshot = "gpt-5.4-2026-03-05"
        precondition(TokenPricing.isKnownCodexModel(snapshot) && close(gpt54(snapshot), 0.04))
        precondition(gpt54(snapshot, input: 272_001) == gpt54("gpt-5.4", input: 272_001))
        precondition(gpt54(snapshot, writes: 1) == nil && gpt54("gpt-5.4-2099-03-05") == nil)
        precondition(TokenPricing.codex(model: "custom", input: 2, cached: 0, output: 1, total: 3) == nil)
        precondition(TokenPricing.codex(model: "gpt-5", input: 10, cached: nil, output: 1, total: 11) == nil)
        precondition(TokenPricing.codex(model: "gpt-5", input: .max, cached: 0, output: 1, total: .max) == nil)

        func haiku(input: Int64, write: Int64, short: Int64?, long: Int64?) -> Double? {
            TokenPricing.claude(
                model: "claude-haiku-5-5", input: input, cacheRead: 10_000, cacheWrite: write,
                write5m: short, write1h: long, output: 1_000)
        }
        precondition(close(haiku(input: 80_000, write: 10_000, short: 8_000, long: 2_000), 0.010))
        precondition(close(haiku(input: 80_001, write: 10_000, short: 8_000, long: 2_000), 0.0500005))
        precondition(haiku(input: 1, write: 6, short: nil, long: nil) == nil)
        precondition(haiku(input: 1, write: 6, short: 3, long: 4) == nil)

        let us = Locale(identifier: "en_US")
        var bucket = TokenSpendAmount()
        precondition(bucket.formattedUSD(historyPartial: false, locale: us) == "$0.00")
        bucket.add(nil)
        precondition(bucket.formattedUSD(historyPartial: false, locale: us) == nil)
        bucket.add(0.001)
        precondition(bucket.partial && bucket.formattedUSD(historyPartial: false, locale: us) == "<$0.01")

        // Splitting the same billable input across responses preserves the one-cent threshold and half-cent ties.
        for (tokens, expected) in [
            (4_999, "<$0.01"), (5_000, "$0.01"), (5_001, "$0.01"), (7_500, "$0.02"), (12_500, "$0.02"),
        ] {
            func charge(_ input: Int) -> Double? {
                TokenPricing.codex(
                    model: "gpt-6.2-sol", input: Int64(input), cached: 0, output: 0, total: Int64(input))
            }
            var individual = TokenSpendAmount()
            individual.add(charge(tokens))
            var split = TokenSpendAmount()
            for start in stride(from: 0, to: tokens, by: 200) {
                split.add(charge(min(200, tokens - start)))
            }
            precondition(individual == split && split.formattedUSD(historyPartial: false, locale: us) == expected)
        }

        let now = Date(timeIntervalSince1970: 1_732_700_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = TokenDayBoundaries(now: now, calendar: calendar)
        var spend = TokenSpendTotals()
        spend.record(50, tokens: 2, date: now.addingTimeInterval(1), now: now, days: days)
        spend.record(3, tokens: 2, date: days.yesterday, now: now, days: days)
        spend.record(nil, tokens: 5, date: days.month, now: now, days: days)
        precondition(spend.yesterday.usd == 3 && !spend.yesterday.partial && !spend.today.hasPricedUsage)
        precondition(spend.month.partial && !spend.week.partial && spend.allTime.usd == 3)
        spend.record(2, tokens: 1, date: nil, now: now, days: days)
        precondition(spend.allTime.usd == 5 && spend.today.partial && spend.yesterday.partial)
        // Possible dates that span all of yesterday leave yesterday incomplete rather than exact.
        var spanning = TokenSpendTotals()
        spanning.record(
            4, tokens: 1, date: days.yesterday.addingTimeInterval(-3_600),
            latestDate: days.today.addingTimeInterval(60), now: now, days: days)
        precondition(spanning.yesterday.partial && !spanning.yesterday.hasPricedUsage && spanning.today.partial)
        var inside = TokenSpendTotals()
        inside.record(
            4, tokens: 1, date: days.yesterday.addingTimeInterval(60),
            latestDate: days.today.addingTimeInterval(-60), now: now, days: days)
        precondition(inside.yesterday.usd == 4 && !inside.yesterday.partial)
        // The same ambiguity is reported for the peak day instead of being dropped silently.
        var daily = TokenDailyUsage(calendar: calendar)
        var dailyPartial = false
        daily.add(
            7, on: days.yesterday.addingTimeInterval(60), latestDate: days.today.addingTimeInterval(60),
            partial: &dailyPartial)
        precondition(dailyPartial && daily.peak == nil)
        print("Standard API rates, cache-write and long-input boundaries, partial estimates and USD display passed.")
    }
}
