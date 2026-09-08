import XCTest
@testable import TokenWidgetCore

/// Two different holes both show a model at $0, and conflating them is what put
/// "codex-auto-review, unknown has no published rate" on the widget:
///
/// - **Unpriced:** a model we know the name of that no price source carries.
///   A rate would fix it.
/// - **Unattributed:** usage the transcript never tied to any model. There is
///   no name to look a rate up by, and the old parser papered over it by
///   inventing a model called `unknown`.
final class UncostedUsageTests: XCTestCase {
    private var utc = Calendar(identifier: .gregorian)
    private let day = DayID(year: 2026, month: 8, day: 18)

    override func setUp() {
        super.setUp()
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    private func breakdown(_ entries: [ModelEntry]) -> PeriodBreakdown {
        let snapshot = UsageSnapshot(days: [DaySummary(day: day, entries: entries)])
        return UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: utc)
            .breakdown(.week, now: day.date(calendar: utc))
    }

    private func entry(_ model: String, provider: Provider = .codex, tokens: Int) -> ModelEntry {
        ModelEntry(
            provider: provider,
            model: model,
            fast: false,
            counts: TokenCounts(input: tokens, messages: 1)
        )
    }

    // MARK: Parsing

    /// A Codex `/review` rollout from CLI 0.77.0: token counts, no model line
    /// anywhere in the file.
    func testTokenCountsBeforeAnyModelLineAreUnattributed() throws {
        let parser = CodexProvider().makeParser(file: URL(fileURLWithPath: "/tmp/r.jsonl"), resuming: nil)
        let line = """
        {"timestamp":"2026-01-06T14:54:20.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,\
        "cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":10}}}}
        """
        let record = try XCTUnwrap(parser.record(from: Data(line.utf8)))

        XCTAssertEqual(record.key.model, ModelKey.unattributed)
        XCTAssertTrue(record.key.isUnattributed)
        XCTAssertEqual(record.key.displayName, "Unattributed")
    }

    /// Once the file names a model, later turns attribute normally.
    func testModelLineAttributesSubsequentTurns() throws {
        let parser = CodexProvider().makeParser(file: URL(fileURLWithPath: "/tmp/r.jsonl"), resuming: nil)
        let context = """
        {"timestamp":"2026-08-17T10:00:00.000Z","type":"turn_context",\
        "payload":{"model":"gpt-5.6-sol","cwd":"/tmp"}}
        """
        let token = """
        {"timestamp":"2026-08-17T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,\
        "cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0}}}}
        """
        XCTAssertNil(parser.record(from: Data(context.utf8)))
        let record = try XCTUnwrap(parser.record(from: Data(token.utf8)))

        XCTAssertEqual(record.key.model, "gpt-5.6-sol")
        XCTAssertFalse(record.key.isUnattributed)
    }

    // MARK: Pricing

    func testUnattributedIsDistinctFromUnpriced() {
        let book = PriceBook.builtIn
        XCTAssertEqual(book.lookup(model: ModelKey.unattributed, fast: false, on: day).price, .unattributed)
        XCTAssertEqual(book.lookup(model: "codex-auto-review", fast: false, on: day).price, .unknown)
    }

    /// Snapshots are aggregated history and are never rebuilt from transcripts,
    /// so entries written by an older build still spell this `unknown` and must
    /// keep resolving to the same state rather than to a model missing a rate.
    func testLegacyUnknownIDStillResolvesAsUnattributed() {
        XCTAssertEqual(PriceBook.builtIn.lookup(model: "unknown", fast: false, on: day).price, .unattributed)

        let result = breakdown([entry("unknown", tokens: 100)])
        XCTAssertEqual(result.unattributedModels.count, 1)
        XCTAssertTrue(result.unpricedModels.isEmpty, "a parse gap is not a model with a missing rate")
    }

    /// The scanner's snapshot-wide list is what the dashboard used to name; a
    /// parse gap has no business appearing there as a model.
    func testClassificationKeepsUnattributedOutOfUnpricedModels() throws {
        let counts = TokenCounts(input: 100, messages: 1)
        let days = [DaySummary(day: day, entries: [
            ModelEntry(provider: .codex, model: ModelKey.unattributed, fast: false, counts: counts),
            ModelEntry(provider: .codex, model: "codex-auto-review", fast: false, counts: counts)
        ])]
        let snapshot = UsageSnapshot(days: days)
        let result = UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: utc)
            .breakdown(.week, now: day.date(calendar: utc))

        XCTAssertEqual(result.unpricedModels.map(\.displayName), ["codex-auto-review"])
        XCTAssertEqual(result.unattributedModels.map(\.displayName), ["Unattributed"])
    }

    // MARK: Windowing

    /// The bug on the widget: the note was built from the snapshot-wide list, so
    /// a model last used in January sat on top of an August total it contributed
    /// nothing to.
    func testNoteCoversOnlyTheWindowOnScreen() {
        let january = DayID(year: 2026, month: 1, day: 6)
        let snapshot = UsageSnapshot(days: [
            DaySummary(day: january, entries: [entry(ModelKey.unattributed, tokens: 1_000_000)]),
            DaySummary(day: day, entries: [entry("claude-opus-5", provider: .claudeCode, tokens: 1_000_000)])
        ])
        let august = UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: utc)
            .breakdown(.week, now: day.date(calendar: utc))

        XCTAssertTrue(august.unattributedModels.isEmpty)
        XCTAssertEqual(august.uncostedTokenShare, 0)
        XCTAssertNil(UsageFormat.uncostedNote(for: august))
    }

    /// Below the threshold the missing tokens move the headline by less than the
    /// cents it is rounded to, and the widget's one line is better spent on how
    /// fresh the data is.
    func testTinyGapIsNotWorthTheWidgetsOnlyFootnoteLine() {
        let result = breakdown([
            entry("claude-opus-5", provider: .claudeCode, tokens: 1_000_000),
            entry("codex-auto-review", tokens: 3_000)
        ])

        XCTAssertLessThan(result.uncostedTokenShare, PeriodBreakdown.materialUncostedShare)
        XCTAssertFalse(result.hasMaterialUncostedUsage)
        XCTAssertNotNil(UsageFormat.uncostedNote(for: result), "the dashboard still lists it")
    }

    func testGapLargeEnoughToMoveTheTotalIsFlagged() {
        let result = breakdown([
            entry("claude-opus-5", provider: .claudeCode, tokens: 1_000_000),
            entry("codex-auto-review", tokens: 200_000)
        ])

        XCTAssertTrue(result.hasMaterialUncostedUsage)
        XCTAssertEqual(UsageFormat.uncostedNote(for: result), "codex-auto-review has no published rate")
    }

    func testEmptyWindowReportsNoGap() {
        let result = breakdown([])
        XCTAssertEqual(result.uncostedTokenShare, 0)
        XCTAssertFalse(result.hasMaterialUncostedUsage)
    }

    // MARK: Wording

    /// "codex-auto-review, unknown has no published rate" was the symptom that
    /// started this: a comma join with a singular verb.
    func testNoteAgreesInNumber() {
        let one = breakdown([entry("codex-auto-review", tokens: 100)])
        XCTAssertEqual(UsageFormat.uncostedNote(for: one), "codex-auto-review has no published rate")

        let two = breakdown([
            entry("codex-auto-review", tokens: 100),
            entry("mystery-model", tokens: 100)
        ])
        XCTAssertEqual(
            UsageFormat.uncostedNote(for: two),
            "codex-auto-review and mystery-model have no published rate"
        )
    }

    func testNoteNamesEachGapWithItsOwnCause() {
        let result = breakdown([
            entry("codex-auto-review", tokens: 100),
            entry(ModelKey.unattributed, tokens: 4_000)
        ])
        XCTAssertEqual(
            UsageFormat.uncostedNote(for: result),
            "codex-auto-review has no published rate; 4.0K tokens name no model"
        )
    }

    // MARK: Palette

    /// Unattributed usage must not change fresh assignments for real models.
    func testUnattributedDoesNotDisplaceModelColours() {
        let real = [
            ModelKey(provider: .codex, model: "codex-auto-review"),
            ModelKey(provider: .claudeCode, model: "claude-opus-5")
        ]
        let unattributed = ModelKey(provider: .codex, model: ModelKey.unattributed)
        let baseline = ChartPalette(models: real)
        let combined = ChartPalette(models: [unattributed] + real)
        for key in real {
            XCTAssertEqual(combined.swatch(for: key), baseline.swatch(for: key))
            XCTAssertNotEqual(combined.swatch(for: key), combined.swatch(for: unattributed))
        }
    }

    // MARK: Wording

    func testLongListsAreTruncatedRatherThanOverflowingTheLine() {
        XCTAssertEqual(UsageFormat.list([]), "")
        XCTAssertEqual(UsageFormat.list(["a"]), "a")
        XCTAssertEqual(UsageFormat.list(["a", "b"]), "a and b")
        XCTAssertEqual(UsageFormat.list(["a", "b", "c"]), "a, b and c")
        XCTAssertEqual(UsageFormat.list(["a", "b", "c", "d"]), "a, b, c and 1 more")
        XCTAssertEqual(UsageFormat.list(["a", "b", "c", "d", "e"]), "a, b, c and 2 more")
    }
}
