import XCTest
@testable import TokenWidgetCore

final class CostDisplayTests: XCTestCase {
    private func breakdown(models: [String], offset: Int = 0) -> PeriodBreakdown {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = DayID(year: 2026, month: 9, day: 5)
        let snapshot = UsageSnapshot(days: [DaySummary(day: day, entries: models.map {
            ModelEntry(provider: .codex, model: $0, fast: false, counts: TokenCounts(output: 100, messages: 1))
        })])
        return UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: calendar)
            .breakdown(.month, offset: offset, now: day.date(calendar: calendar))
    }

    func testUnknownCostIsNotDisplayedAsZeroButTokensStayVisible() {
        let period = breakdown(models: ["unpublished-model"])
        XCTAssertTrue(period.hasUnpricedModels)
        XCTAssertEqual(UsageFormat.value(for: period, metric: .cost), "No rate")
        XCTAssertEqual(UsageFormat.value(for: period, metric: .cost, compact: true), "No rate")
        XCTAssertEqual(UsageFormat.value(for: period, metric: .tokens), "100")
    }

    func testPartialAndApproximateCostsAreMarked() {
        let period = breakdown(models: ["gpt-6-astra", "unpublished-model"])
        let display = UsageFormat.value(for: period, metric: .cost)
        XCTAssertTrue(display.hasPrefix("≈"))
        XCTAssertTrue(display.hasSuffix("+"))
        XCTAssertGreaterThan(period.cost, 0)
        XCTAssertEqual(UsageFormat.value(for: period, metric: .tokens), "200")
    }

    func testMissingRateWarningIsScopedToTheVisiblePeriod() {
        let period = breakdown(models: ["unpublished-model"], offset: -1)
        XCTAssertFalse(period.hasUnpricedModels)
        XCTAssertTrue(period.isEmpty)
        XCTAssertNotEqual(UsageFormat.value(for: period, metric: .cost), "No rate")
    }

    func testUnattributedUsageKeepsCostIncompleteAndTokensVisible() {
        for model in [ModelKey.unattributed, "unknown"] {
            let onlyUnattributed = breakdown(models: [model])
            XCTAssertFalse(onlyUnattributed.hasUnpricedModels)
            XCTAssertTrue(onlyUnattributed.hasUncostedUsage)
            XCTAssertEqual(UsageFormat.value(for: onlyUnattributed, metric: .cost), "No rate")
            XCTAssertEqual(UsageFormat.value(for: onlyUnattributed, metric: .tokens), "100")

            let mixed = breakdown(models: ["gpt-6-astra", model])
            XCTAssertTrue(UsageFormat.value(for: mixed, metric: .cost).hasSuffix("+"))
            XCTAssertEqual(UsageFormat.value(for: mixed, metric: .tokens), "200")
        }
    }

    func testLocalCostsRemainZero() {
        let period = breakdown(models: ["gpt-oss:20b"])
        XCTAssertFalse(period.hasUnpricedModels)
        XCTAssertEqual(UsageFormat.value(for: period, metric: .cost), UsageFormat.money(0))
    }
}
