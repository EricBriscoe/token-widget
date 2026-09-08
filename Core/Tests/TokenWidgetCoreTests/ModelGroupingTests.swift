import XCTest
@testable import TokenWidgetCore

final class ModelGroupingTests: XCTestCase {
    private let day = DayID(year: 2026, month: 9, day: 7)

    private func entry(_ provider: Provider, _ model: String, output: Int, fast: Bool = false) -> ModelEntry {
        ModelEntry(provider: provider, model: model, fast: fast,
                   counts: TokenCounts(input: 100, output: output, messages: 1))
    }

    private func breakdown(_ entries: [ModelEntry]) -> PeriodBreakdown {
        let snapshot = UsageSnapshot(days: [DaySummary(day: day, entries: entries)])
        return UsageQuery(snapshot: snapshot, priceBook: .builtIn)
            .breakdown(.month, metric: .tokens, now: day.date())
    }

    func testPiAndCLIsMergeByModelWhileCostsStillUseOriginalBillingLanes() {
        let entries = [
            entry(.codex, "gpt-6-astra", output: 100),
            entry(.pi, "openai/gpt-6-astra", output: 200),
            entry(.pi, "openai/gpt-6-astra", output: 300, fast: true),
            entry(.claudeCode, "claude-opus-5", output: 400),
            entry(.pi, "anthropic/claude-opus-5", output: 500)
        ]
        let result = breakdown(entries)
        XCTAssertEqual(result.models.count, 2)
        XCTAssertEqual(result.totals.output, 1500)
        XCTAssertEqual(result.totals.messages, 5)
        XCTAssertEqual(result.models.map(\.displayName), ["Opus 5", "gpt-6-astra"])
        XCTAssertEqual(result.models.map { $0.counts.output }, [900, 600])
        let expected = entries.reduce(0.0) {
            $0 + PriceBook.builtIn.cost(for: $1.counts, model: $1.model, provider: $1.provider, fast: $1.fast, on: day)
        }
        XCTAssertEqual(result.cost, expected, accuracy: 0.000001)
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.cost }, expected, accuracy: 0.000001)
        let segments = result.points.flatMap(\.segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.tokens }, 1500)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.cost }, expected, accuracy: 0.000001)
        XCTAssertTrue(result.hasApproximateCost)
        XCTAssertEqual(breakdown(Array(entries.reversed())).models.map(\.displayName), result.models.map(\.displayName))
    }

    func testUnrelatedVendorsWithSameLeafAreNotMerged() {
        let result = breakdown([
            entry(.pi, "vendor-a/shared-model", output: 100),
            entry(.pi, "vendor-b/shared-model", output: 200)
        ])
        XCTAssertEqual(result.models.count, 2)
        XCTAssertNotEqual(result.models[0].key, result.models[1].key)
    }
}
