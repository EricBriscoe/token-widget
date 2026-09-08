import XCTest
@testable import TokenWidgetCore

final class WidgetReloadPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_782_400)

    private func snapshot(output: Int = 100) -> UsageSnapshot {
        UsageSnapshot(days: [DaySummary(day: DayID(now), entries: [
            ModelEntry(provider: .pi, model: "openai/gpt-6-astra", fast: false,
                       counts: TokenCounts(output: output, messages: 1))
        ])])
    }

    func testInitialReloadThenNoReloadForNoOpScans() {
        var policy = WidgetReloadPolicy()
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(), pricesFetchedAt: nil, now: now))
        var rescan = snapshot()
        rescan.generatedAt = now.addingTimeInterval(3600)
        rescan.scanDuration = 0.5
        rescan.filesScanned = 30
        XCTAssertFalse(policy.shouldReload(snapshot: rescan, pricesFetchedAt: nil, now: now.addingTimeInterval(3600)))
    }

    func testEquivalentModelOrderingDoesNotSpendReloadBudget() {
        var policy = WidgetReloadPolicy()
        var original = snapshot()
        original.days[0].entries.append(ModelEntry(provider: .codex, model: "gpt-6-astra", fast: false,
                                                  counts: TokenCounts(output: 100, messages: 1)))
        XCTAssertTrue(policy.shouldReload(snapshot: original, pricesFetchedAt: nil, now: now))
        original.days[0].entries.reverse()
        XCTAssertFalse(policy.shouldReload(snapshot: original, pricesFetchedAt: nil, now: now.addingTimeInterval(900)))
    }

    func testBurstIsCoalescedAndDeferredChangeIsNotLost() {
        var policy = WidgetReloadPolicy()
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(), pricesFetchedAt: nil, now: now))
        XCTAssertFalse(policy.shouldReload(snapshot: snapshot(output: 200), pricesFetchedAt: nil, now: now.addingTimeInterval(60)))
        XCTAssertFalse(policy.shouldReload(snapshot: snapshot(output: 300), pricesFetchedAt: nil, now: now.addingTimeInterval(899)))
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(output: 300), pricesFetchedAt: nil, now: now.addingTimeInterval(900)))
        XCTAssertFalse(policy.shouldReload(snapshot: snapshot(output: 300), pricesFetchedAt: nil, now: now.addingTimeInterval(1800)))
    }

    func testPaletteChangesRefreshWithoutNewUsage() {
        var policy = WidgetReloadPolicy()
        var history = snapshot()
        XCTAssertTrue(policy.shouldReload(snapshot: history, pricesFetchedAt: nil, now: now))
        history.modelColors = ModelColorAllocator.assign(models: history.days.flatMap { $0.entries.map(\.key) })
        XCTAssertTrue(policy.shouldReload(snapshot: history, pricesFetchedAt: nil, now: now.addingTimeInterval(900)))
        XCTAssertFalse(policy.shouldReload(snapshot: history, pricesFetchedAt: nil, now: now.addingTimeInterval(1800)))
    }

    func testPricesAndCalendarRolloverRefreshWithoutNewUsage() {
        var policy = WidgetReloadPolicy()
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(), pricesFetchedAt: nil, now: now))
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(), pricesFetchedAt: now, now: now.addingTimeInterval(900)))
        XCTAssertTrue(policy.shouldReload(snapshot: snapshot(), pricesFetchedAt: now, now: now.addingTimeInterval(86400)))
    }
}
