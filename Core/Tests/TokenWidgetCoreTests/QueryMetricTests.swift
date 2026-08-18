import XCTest
@testable import TokenWidgetCore

/// The two metrics measure different things on purpose: cost prices every
/// lane (input, cache writes, cache reads, output), while the token metric
/// counts only what the model generated.
final class QueryMetricTests: XCTestCase {
    private var utc = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    func testTokenMetricCountsOnlyGeneratedTokens() throws {
        let counts = TokenCounts(
            input: 1_000,
            cacheWrite5m: 2_000,
            cacheWrite1h: 500,
            cacheRead: 50_000,
            output: 300,
            thinking: 120,
            messages: 3
        )
        let day = DayID(year: 2026, month: 8, day: 18)
        let snapshot = UsageSnapshot(days: [
            DaySummary(day: day, entries: [
                ModelEntry(provider: .claudeCode, model: "claude-opus-5", fast: false, counts: counts)
            ])
        ])

        let query = UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: utc)
        let breakdown = query.breakdown(.week, metric: .tokens, now: day.date(calendar: utc))

        let model = try XCTUnwrap(breakdown.models.first)
        XCTAssertEqual(model.value(for: .tokens), 300, "model token metric is output only")

        let chartedTokens = breakdown.points.reduce(0) { $0 + $1.tokens }
        XCTAssertEqual(chartedTokens, 300, "charted buckets carry output tokens only")

        let segments = breakdown.points.flatMap(\.segments)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.tokens }, 300, "stacked segments carry output tokens only")

        // The raw totals keep every lane so cost maths and the breakdown
        // table still see input and cache traffic.
        XCTAssertEqual(breakdown.totals.billedTotal, 53_800)
        XCTAssertEqual(breakdown.totals.output, 300)
    }

    /// The two metrics can peak on different days over the same data: a
    /// cache-heavy day dominates cost while an output-heavy day dominates the
    /// token chart. `peak(for:)` scales every bar, so a regression back to
    /// billed totals in the series path would show here first.
    func testTokenAndCostPeaksDivergeOnCacheHeavyDays() throws {
        let cacheHeavyDay = DayID(year: 2026, month: 8, day: 17)
        let outputHeavyDay = DayID(year: 2026, month: 8, day: 18)
        let snapshot = UsageSnapshot(days: [
            DaySummary(day: cacheHeavyDay, entries: [
                ModelEntry(
                    provider: .claudeCode, model: "claude-opus-5", fast: false,
                    counts: TokenCounts(cacheRead: 1_000_000, output: 100, messages: 1)
                ),
                ModelEntry(
                    provider: .claudeCode, model: "claude-haiku-4-5", fast: false,
                    counts: TokenCounts(output: 50, messages: 1)
                ),
            ]),
            DaySummary(day: outputHeavyDay, entries: [
                ModelEntry(
                    provider: .claudeCode, model: "claude-opus-5", fast: false,
                    counts: TokenCounts(output: 400, messages: 1)
                ),
                ModelEntry(
                    provider: .claudeCode, model: "claude-haiku-4-5", fast: false,
                    counts: TokenCounts(output: 300, messages: 1)
                ),
            ]),
        ])

        let query = UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: utc)
        let breakdown = query.breakdown(.week, metric: .tokens, now: outputHeavyDay.date(calendar: utc))

        // Under billed totals the cache-heavy day would win at 1,000,150.
        XCTAssertEqual(breakdown.peak(for: .tokens), 700)

        let cacheHeavyPoint = try XCTUnwrap(breakdown.points.first { $0.tokens == 150 })
        let outputHeavyPoint = try XCTUnwrap(breakdown.points.first { $0.tokens == 700 })
        XCTAssertGreaterThan(cacheHeavyPoint.cost, outputHeavyPoint.cost)
        XCTAssertEqual(breakdown.peak(for: .cost), cacheHeavyPoint.cost)

        for point in breakdown.points {
            XCTAssertEqual(point.segments.reduce(0) { $0 + $1.tokens }, point.tokens)
        }

        // The dashboard's share percentages divide model values by this total.
        XCTAssertEqual(
            breakdown.models.reduce(0.0) { $0 + $1.value(for: .tokens) },
            Double(breakdown.totals.output)
        )
        XCTAssertEqual(breakdown.totals.output, 850)
    }
}
