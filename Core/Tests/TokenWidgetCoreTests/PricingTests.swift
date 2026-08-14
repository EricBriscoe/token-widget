import XCTest
@testable import TokenWidgetCore

final class PricingTests: XCTestCase {
    private let book = PriceBook.current

    func testNormalizeStripsDecorations() {
        XCTAssertEqual(PriceBook.normalize("claude-opus-5").id, "claude-opus-5")
        XCTAssertEqual(PriceBook.normalize("claude-opus-5[1m]").id, "claude-opus-5")
        XCTAssertEqual(PriceBook.normalize("anthropic.claude-opus-5").id, "claude-opus-5")
        XCTAssertEqual(PriceBook.normalize("claude-haiku-4-5-20251001").id, "claude-haiku-4-5")
        XCTAssertEqual(PriceBook.normalize("claude-opus-4-5@20251101").id, "claude-opus-4-5")
    }

    func testNormalizeDetectsLegacyFastModelStrings() {
        let normalized = PriceBook.normalize("claude-opus-4-6-fast")
        XCTAssertEqual(normalized.id, "claude-opus-4-6")
        XCTAssertTrue(normalized.fast)
    }

    func testDatedSuffixStrippingDoesNotEatVersionNumbers() {
        // `4-8` must survive; only an 8-digit date is a snapshot suffix.
        XCTAssertEqual(PriceBook.normalize("claude-opus-4-8").id, "claude-opus-4-8")
    }

    func testInputAndOutputRates() {
        let day = DayID(year: 2026, month: 8, day: 14)
        guard case .priced(let fable) = book.lookup(model: "claude-fable-5", fast: false, on: day).price else {
            return XCTFail("fable-5 should be priced")
        }
        XCTAssertEqual(fable.inputPerMTok, 10)
        XCTAssertEqual(fable.outputPerMTok, 50)

        guard case .priced(let opus) = book.lookup(model: "claude-opus-5", fast: false, on: day).price else {
            return XCTFail("opus-5 should be priced")
        }
        XCTAssertEqual(opus.inputPerMTok, 5)
        XCTAssertEqual(opus.outputPerMTok, 25)
    }

    func testCacheRatesAreDerivedFromInput() {
        let price = ModelPrice(input: 5, output: 25)
        XCTAssertEqual(price.cacheWrite5mPerMTok, 6.25)
        XCTAssertEqual(price.cacheWrite1hPerMTok, 10)
        XCTAssertEqual(price.cacheReadPerMTok, 0.5)
    }

    /// Sonnet 5 runs on introductory pricing through 2026-08-31 and reverts the
    /// next day, so the same tokens cost different amounts either side of it.
    func testSonnetIntroPricingCutover() {
        let lastIntroDay = DayID(year: 2026, month: 8, day: 31)
        let firstFullDay = DayID(year: 2026, month: 9, day: 1)

        guard case .priced(let intro) = book.lookup(model: "claude-sonnet-5", fast: false, on: lastIntroDay).price,
              case .priced(let full) = book.lookup(model: "claude-sonnet-5", fast: false, on: firstFullDay).price
        else { return XCTFail("sonnet-5 should be priced on both days") }

        XCTAssertEqual(intro.inputPerMTok, 2)
        XCTAssertEqual(intro.outputPerMTok, 10)
        XCTAssertEqual(full.inputPerMTok, 3)
        XCTAssertEqual(full.outputPerMTok, 15)
    }

    func testCostAccountsForEachCacheTierSeparately() {
        var counts = TokenCounts()
        counts.input = 1_000_000
        counts.cacheWrite5m = 1_000_000
        counts.cacheWrite1h = 1_000_000
        counts.cacheRead = 1_000_000
        counts.output = 1_000_000

        let price = ModelPrice(input: 5, output: 25)
        // 5 + 6.25 + 10 + 0.5 + 25
        XCTAssertEqual(price.cost(for: counts), 46.75, accuracy: 0.0001)
    }

    func testThinkingTokensAreNotBilledOnTopOfOutput() {
        var counts = TokenCounts()
        counts.output = 1_000_000
        counts.thinking = 800_000

        let price = ModelPrice(input: 5, output: 25)
        XCTAssertEqual(price.cost(for: counts), 25, accuracy: 0.0001)
        XCTAssertEqual(counts.billedTotal, 1_000_000)
    }

    func testWebSearchBillsPerThousandRequests() {
        var counts = TokenCounts()
        counts.webSearches = 250
        let price = ModelPrice(input: 5, output: 25)
        XCTAssertEqual(price.cost(for: counts), 2.5, accuracy: 0.0001)
    }

    func testFastModeOnOpus5IsPricedHigher() {
        let day = DayID(year: 2026, month: 8, day: 14)
        guard case .priced(let fast) = book.lookup(model: "claude-opus-5", fast: true, on: day).price else {
            return XCTFail("opus-5 fast should be priced")
        }
        XCTAssertEqual(fast.inputPerMTok, 10)
        XCTAssertEqual(fast.outputPerMTok, 50)
    }

    /// A fast request on a model with no published fast rate still gets a
    /// number, but is flagged so the UI can mark it as an estimate.
    func testFastModeWithoutPublishedRateIsFlaggedApproximate() {
        let day = DayID(year: 2026, month: 8, day: 14)
        let result = book.lookup(model: "claude-opus-4-8", fast: true, on: day)
        XCTAssertTrue(result.isApproximate)
        guard case .priced = result.price else { return XCTFail("expected fallback to standard rate") }
    }

    func testLocalModelsAreFreeRatherThanUnknown() {
        let day = DayID(year: 2026, month: 8, day: 14)
        let result = book.lookup(model: "unsloth/Qwen3.6-27B-MTP-GGUF", fast: false, on: day)
        XCTAssertEqual(result.price, .local)
        XCTAssertEqual(book.cost(for: TokenCounts(), model: "unsloth/Qwen3.6-27B-MTP-GGUF", fast: false, on: day), 0)
    }

    /// An unpriced model must report zero and be surfaced, never be quietly
    /// assigned a plausible-looking rate.
    func testUnknownModelIsUnknownNotGuessed() {
        let day = DayID(year: 2026, month: 8, day: 14)
        XCTAssertEqual(book.lookup(model: "gpt-5-codex", fast: false, on: day).price, .unknown)
    }
}
