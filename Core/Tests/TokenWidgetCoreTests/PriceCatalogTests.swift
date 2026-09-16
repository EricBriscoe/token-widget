import XCTest
@testable import TokenWidgetCore

/// The JSON below is trimmed from a real `openrouter.ai/api/v1/models` response.
final class PriceCatalogTests: XCTestCase {
    private let feed = """
    {"data":[
      {"id":"openai/gpt-5.6-sol","pricing":{"prompt":"0.000005","completion":"0.00003",
        "web_search":"0.01","input_cache_read":"0.0000005","input_cache_write":"0.00000625"}},
      {"id":"openai/gpt-5.1-codex-max","pricing":{"prompt":"0.00000125","completion":"0.00001",
        "web_search":"0.01","input_cache_read":"0.000000125"}},
      {"id":"anthropic/claude-opus-5","pricing":{"prompt":"0.000005","completion":"0.000025",
        "web_search":"0.01","input_cache_read":"0.0000005","input_cache_write":"0.00000625",
        "input_cache_write_1h":"0.00001"}},
      {"id":"anthropic/claude-opus-5-fast","pricing":{"prompt":"0.00001","completion":"0.00005",
        "web_search":"0.01","input_cache_read":"0.000001"}},
      {"id":"anthropic/claude-sonnet-5","pricing":{"prompt":"0.000002","completion":"0.00001",
        "web_search":"0.01","input_cache_read":"0.0000002"}},
      {"id":"anthropic/claude-fable-5.1","pricing":{"prompt":"0.00001","completion":"0.00005",
        "web_search":"0.01","input_cache_read":"0.00000025","input_cache_write":"0.0000125"}},
      {"id":"anthropic/claude-opus-5:batch","pricing":{"prompt":"0.0000025","completion":"0.0000125"}},
      {"id":"someone/free-thing","pricing":{"prompt":"0","completion":"0"}},
      {"id":"openai/gpt-4o-mini","pricing":{"prompt":"0.00000015","completion":"0.0000006"}},
      {"id":"azure/gpt-4o-mini","pricing":{"prompt":"0.0000003","completion":"0.0000012"}}
    ]}
    """

    private func catalog(now: Date = Date(timeIntervalSince1970: 1_786_000_000)) throws -> PriceCatalog {
        try XCTUnwrap(OpenRouterPriceService.parse(Data(feed.utf8), now: now))
    }

    // MARK: - Version spelling

    /// Transcripts write point releases with a dash (`claude-fable-5-1`) while the
    /// feed keys them with a dot (`anthropic/claude-fable-5.1`). The dashed
    /// spelling must still find the rate, from Claude Code and via Pi alike.
    func testDashedPointReleaseFindsTheDottedFeedKey() throws {
        let direct = try XCTUnwrap(catalog().price(for: "claude-fable-5-1", provider: .claudeCode))
        XCTAssertEqual(direct.inputPerMTok, 10, accuracy: 0.0001)
        XCTAssertEqual(direct.cacheReadPerMTok, 0.25, accuracy: 0.0001)
        let viaPi = try XCTUnwrap(catalog().price(for: "anthropic/claude-fable-5-1", provider: .pi))
        XCTAssertEqual(viaPi.outputPerMTok, 50, accuracy: 0.0001)
        let day = DayID(year: 2026, month: 9, day: 16)
        let book = PriceBook.builtIn.withCatalog(try catalog())
        guard case .priced(let rate) = book.lookup(model: "claude-fable-5-1", provider: .claudeCode, fast: false, on: day).price
        else { return XCTFail("Fable 5.1 must price from the feed") }
        XCTAssertEqual(rate.outputPerMTok, 50, accuracy: 0.0001)
        XCTAssertNil(try catalog().price(for: "claude-fable-5-2", provider: .claudeCode), "an unlisted point release stays unpriced")
    }

    // MARK: - Parsing

    func testConvertsPerTokenStringsToPerMillionRates() throws {
        let price = try XCTUnwrap(catalog().price(for: "gpt-5.6-sol", provider: .codex))
        XCTAssertEqual(price.inputPerMTok, 5, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMTok, 30, accuracy: 0.0001)
        XCTAssertEqual(price.cacheReadPerMTok, 0.5, accuracy: 0.0001)
        XCTAssertEqual(price.cacheWrite5mPerMTok, 6.25, accuracy: 0.0001)
        XCTAssertEqual(price.webSearchPerThousandRequests, 10, accuracy: 0.0001)
    }

    /// Anthropic bills a 1-hour cache write at 2x input and the feed says so;
    /// that lane must not be flattened into the 5-minute rate.
    func testKeepsTheTwoAnthropicCacheWriteTiersApart() throws {
        let price = try XCTUnwrap(catalog().price(for: "claude-opus-5", provider: .claudeCode))
        XCTAssertEqual(price.cacheWrite5mPerMTok, 6.25, accuracy: 0.0001)
        XCTAssertEqual(price.cacheWrite1hPerMTok, 10, accuracy: 0.0001)
    }

    /// OpenAI charges nothing to write a cache entry on most models, so the feed
    /// omits the field. Falling back to Anthropic's multiplier is harmless
    /// because an OpenAI transcript never reports cache-write tokens for them.
    func testMissingCacheWriteFallsBackToTheVendorMultiplier() throws {
        let price = try XCTUnwrap(catalog().price(for: "gpt-5.1-codex-max", provider: .codex))
        XCTAssertEqual(price.inputPerMTok, 1.25, accuracy: 0.0001)
        XCTAssertEqual(price.cacheReadPerMTok, 0.125, accuracy: 0.0001)
        XCTAssertEqual(price.cacheWrite5mPerMTok, 1.25 * 1.25, accuracy: 0.0001)
    }

    /// `:batch`, `:free` and `:thinking` are separately-priced variants of a
    /// model already listed under its bare ID.
    func testVariantSuffixedEntriesAreSkipped() throws {
        let book = PriceBook.builtIn.withCatalog(try catalog())
        guard case .priced(let price) = book.lookup(
            model: "claude-opus-5", provider: .claudeCode, fast: false, on: DayID(year: 2026, month: 8, day: 14)
        ).price else { return XCTFail("opus-5 should be priced") }
        // The batch entry is half price; picking it up would understate the bill.
        XCTAssertEqual(price.inputPerMTok, 5, accuracy: 0.0001)
    }

    func testModelsQuotingNoRateAreNotRecordedAsFree() throws {
        XCTAssertNil(try catalog().price(for: "free-thing", provider: nil))
    }

    // MARK: - Vendor disambiguation

    /// OpenRouter carries the same leaf name under several vendors at different
    /// prices, so the harness that produced the record picks the right one.
    func testProviderPicksTheRightVendorForACollidingLeafName() throws {
        let price = try XCTUnwrap(catalog().price(for: "gpt-4o-mini", provider: .codex))
        XCTAssertEqual(price.inputPerMTok, 0.15, accuracy: 0.0001)
    }

    /// With no hint and no preferred vendor, an ambiguous name must resolve to
    /// nothing rather than to whichever vendor happened to sort first.
    func testAmbiguousLeafWithNoHintResolvesToNoPrice() throws {
        let ambiguous = PriceCatalog(fetchedAt: Date(), models: [
            "vendor-a/some-model": ModelPrice(input: 1, output: 2),
            "vendor-b/some-model": ModelPrice(input: 9, output: 18)
        ])
        XCTAssertNil(ambiguous.price(for: "some-model", provider: nil))
    }

    func testUnambiguousLeafResolvesWithoutAHint() throws {
        XCTAssertNotNil(try catalog().price(for: "gpt-5.6-sol", provider: nil))
    }

    // MARK: - Resolution order

    /// The feed reports today's rate only. A tier with explicit date bounds is
    /// historical fact it cannot express, so it has to win; otherwise every
    /// past day gets silently repriced at the current rate.
    func testDatedBuiltInTierOutranksTheCatalog() throws {
        let book = PriceBook.builtIn.withCatalog(try catalog())
        let introDay = DayID(year: 2026, month: 8, day: 31)
        let afterDay = DayID(year: 2026, month: 9, day: 1)

        guard case .priced(let intro) = book.lookup(model: "claude-sonnet-5", provider: .claudeCode, fast: false, on: introDay).price,
              case .priced(let after) = book.lookup(model: "claude-sonnet-5", provider: .claudeCode, fast: false, on: afterDay).price
        else { return XCTFail("sonnet-5 should be priced on both days") }

        XCTAssertEqual(intro.inputPerMTok, 2, accuracy: 0.0001)
        XCTAssertEqual(after.inputPerMTok, 3, accuracy: 0.0001)
    }

    /// A model with no dated tier takes the live rate, which is what lets a
    /// model released after this build price itself with no code change.
    func testCatalogOutranksAnOpenEndedBuiltInRate() throws {
        let stale = PriceCatalog(fetchedAt: Date(), models: [
            "anthropic/claude-opus-5": ModelPrice(input: 99, output: 199)
        ])
        let book = PriceBook.builtIn.withCatalog(stale)
        guard case .priced(let price) = book.lookup(
            model: "claude-opus-5", provider: .claudeCode, fast: false, on: DayID(year: 2026, month: 8, day: 14)
        ).price else { return XCTFail("opus-5 should be priced") }
        XCTAssertEqual(price.inputPerMTok, 99, accuracy: 0.0001)
    }

    /// Seven models the app prices are absent from OpenRouter. They have to keep
    /// working, or adopting the feed would be a regression.
    func testModelsMissingFromTheCatalogFallBackToBuiltInRates() throws {
        let book = PriceBook.builtIn.withCatalog(try catalog())
        let day = DayID(year: 2026, month: 8, day: 14)
        for model in ["claude-haiku-4-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                      "claude-mythos-5", "claude-mythos-preview", "claude-sonnet-4-6"] {
            let result = book.lookup(model: model, provider: .claudeCode, fast: false, on: day)
            guard case .priced = result.price else {
                return XCTFail("\(model) is not in the catalog and must fall back to a built-in rate")
            }
            XCTAssertEqual(result.source, .builtin, "\(model) should report a built-in rate")
        }
    }

    func testAModelNeitherSourceKnowsStaysUnknown() throws {
        let book = PriceBook.builtIn.withCatalog(try catalog())
        let result = book.lookup(
            model: "codex-auto-review", provider: .codex, fast: false, on: DayID(year: 2026, month: 8, day: 14)
        )
        XCTAssertEqual(result.price, .unknown)
        XCTAssertEqual(result.source, PriceSource.none)
    }

    func testCatalogFastEntryIsPreferredOverTheApproximateFallback() throws {
        let book = PriceBook.builtIn.withCatalog(try catalog())
        let result = book.lookup(
            model: "claude-opus-5", provider: .claudeCode, fast: true, on: DayID(year: 2026, month: 8, day: 14)
        )
        XCTAssertFalse(result.isApproximate)
        guard case .priced(let price) = result.price else { return XCTFail("opus-5 fast should be priced") }
        XCTAssertEqual(price.inputPerMTok, 10, accuracy: 0.0001)
    }

    // MARK: - Freshness

    func testCatalogGoesStaleAfterADay() {
        let fetched = Date(timeIntervalSince1970: 1_786_000_000)
        let catalog = PriceCatalog(fetchedAt: fetched, models: [:])
        XCTAssertFalse(catalog.isStale(now: fetched.addingTimeInterval(23 * 3_600)))
        XCTAssertTrue(catalog.isStale(now: fetched.addingTimeInterval(25 * 3_600)))
    }

    func testGarbageResponseIsRejectedRatherThanCachedEmpty() {
        XCTAssertNil(OpenRouterPriceService.parse(Data("not json".utf8), now: Date()))
        XCTAssertNil(OpenRouterPriceService.parse(Data(#"{"data":[]}"#.utf8), now: Date()))
    }

    func testRoundTripsThroughTheOnDiskFormat() throws {
        let original = try catalog()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode(PriceCatalog.self, from: encoder.encode(original))
        XCTAssertEqual(restored, original)
    }
}
