import XCTest
@testable import TokenWidgetCore

final class ClaudeCodeParserTests: XCTestCase {
    private func parse(_ json: String) -> UsageRecord? {
        let provider = ClaudeCodeProvider()
        let parser = provider.makeParser(file: URL(fileURLWithPath: "/tmp/session.jsonl"), resuming: nil)
        return parser.record(from: Data(json.utf8))
    }

    /// Shaped exactly like a line from a real transcript.
    private func assistantLine(
        model: String = "claude-opus-5",
        requestID: String = "req_001",
        messageID: String = "msg_001",
        timestamp: String = "2026-08-12T18:08:44.391Z",
        speed: String = "standard",
        cache5m: Int = 0,
        cache1h: Int = 24_265
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestID)","uuid":"u-1",\
        "cwd":"/Users/eric/dev/recipe-picker","sessionId":"s-1","message":{"id":"\(messageID)",\
        "model":"\(model)","usage":{"input_tokens":2,"cache_creation_input_tokens":\(cache5m + cache1h),\
        "cache_read_input_tokens":23218,"output_tokens":1027,\
        "output_tokens_details":{"thinking_tokens":508},\
        "server_tool_use":{"web_search_requests":3,"web_fetch_requests":0},\
        "service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":\(cache1h),"ephemeral_5m_input_tokens":\(cache5m)},\
        "speed":"\(speed)"}}}
        """
    }

    func testParsesAssistantUsage() throws {
        let record = try XCTUnwrap(parse(assistantLine()))
        XCTAssertEqual(record.key.model, "claude-opus-5")
        XCTAssertEqual(record.key.provider, .claudeCode)
        XCTAssertFalse(record.key.fast)
        XCTAssertEqual(record.counts.input, 2)
        XCTAssertEqual(record.counts.cacheRead, 23_218)
        XCTAssertEqual(record.counts.output, 1_027)
        XCTAssertEqual(record.counts.thinking, 508)
        XCTAssertEqual(record.counts.webSearches, 3)
        XCTAssertEqual(record.counts.messages, 1)
        XCTAssertEqual(record.projectPath, "/Users/eric/dev/recipe-picker")
    }

    /// The two cache TTLs bill at different multiples of the input rate, so
    /// they must not be collapsed into one number.
    func testSplitsCacheWriteByTTL() throws {
        let record = try XCTUnwrap(parse(assistantLine(cache5m: 1_000, cache1h: 24_265)))
        XCTAssertEqual(record.counts.cacheWrite5m, 1_000)
        XCTAssertEqual(record.counts.cacheWrite1h, 24_265)
    }

    /// Transcripts predating the `cache_creation` breakdown only carry the flat
    /// total; it defaults to the 5-minute TTL.
    func testFallsBackToFlatCacheTotal() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-08-12T18:08:44.391Z","requestId":"req_002",\
        "message":{"id":"msg_002","model":"claude-opus-4-8","usage":{"input_tokens":10,\
        "cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":20}}}
        """
        let record = try XCTUnwrap(parse(line))
        XCTAssertEqual(record.counts.cacheWrite5m, 5_000)
        XCTAssertEqual(record.counts.cacheWrite1h, 0)
    }

    /// `<synthetic>` is a placeholder the CLI writes for an API error. Counting
    /// it would invent usage that was never billed.
    func testSkipsSyntheticMessages() {
        XCTAssertNil(parse(assistantLine(model: "<synthetic>")))
    }

    func testSkipsLinesWithoutUsage() {
        XCTAssertNil(parse(#"{"type":"user","timestamp":"2026-08-12T18:08:44.391Z","message":{"role":"user"}}"#))
        XCTAssertNil(parse(#"{"type":"file-history-snapshot","messageId":"x"}"#))
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
    }

    func testDetectsFastMode() throws {
        let record = try XCTUnwrap(parse(assistantLine(speed: "fast")))
        XCTAssertTrue(record.key.fast)
    }

    func testNormalizesModelIdentifier() throws {
        let record = try XCTUnwrap(parse(assistantLine(model: "claude-opus-5[1m]")))
        XCTAssertEqual(record.key.model, "claude-opus-5")
    }

    /// The same request replayed into a resumed session file must produce the
    /// same identity, or it gets billed twice.
    func testDedupKeyIsStableForSameRequest() throws {
        let first = try XCTUnwrap(parse(assistantLine(requestID: "req_A", messageID: "msg_A")))
        let again = try XCTUnwrap(parse(assistantLine(requestID: "req_A", messageID: "msg_A", timestamp: "2026-08-13T09:00:00.000Z")))
        let other = try XCTUnwrap(parse(assistantLine(requestID: "req_B", messageID: "msg_B")))

        XCTAssertEqual(first.dedupKey, again.dedupKey)
        XCTAssertNotEqual(first.dedupKey, other.dedupKey)
    }

    /// A few very old entries carry no requestId; they still need an identity.
    func testFallsBackToMessageIDWhenRequestIDMissing() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-08-12T18:08:44.391Z",\
        "message":{"id":"msg_only","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let record = try XCTUnwrap(parse(line))
        XCTAssertEqual(record.dedupKey, fnv1a64("msg|msg_only"))
    }

    func testLocalModelIsKeptVerbatim() throws {
        let record = try XCTUnwrap(parse(assistantLine(model: "unsloth/Qwen3.6-27B-MTP-GGUF")))
        XCTAssertEqual(record.key.model, "unsloth/qwen3.6-27b-mtp-gguf")
        XCTAssertTrue(PriceBook.isLocalModel(record.key.model))
    }

    func testDisplayNamesArePresentable() {
        XCTAssertEqual(ModelKey(provider: .claudeCode, model: "claude-opus-5").displayName, "Opus 5")
        XCTAssertEqual(ModelKey(provider: .claudeCode, model: "claude-fable-5").displayName, "Fable 5")
        XCTAssertEqual(ModelKey(provider: .claudeCode, model: "claude-opus-4-8").displayName, "Opus 4.8")
        XCTAssertEqual(ModelKey(provider: .claudeCode, model: "claude-opus-5", fast: true).displayName, "Opus 5 (fast)")
        XCTAssertEqual(
            ModelKey(provider: .claudeCode, model: "unsloth/qwen3.6-27b-mtp-gguf").displayName,
            "qwen3.6-27b-mtp-gguf"
        )
    }
}

final class TimestampParserTests: XCTestCase {
    func testParsesFractionalSecondsInUTC() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 12, hour: 21, minute: 8, second: 44
        )))

        let date = try XCTUnwrap(TimestampParser.parse("2026-08-12T21:08:44.391Z"))
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970 + 0.391, accuracy: 0.002)
    }

    func testParsesWithoutFractionalSeconds() throws {
        let withFraction = try XCTUnwrap(TimestampParser.parse("2026-08-12T21:08:44.000Z"))
        let without = try XCTUnwrap(TimestampParser.parse("2026-08-12T21:08:44Z"))
        XCTAssertEqual(withFraction, without)
    }

    func testParsesNumericUTCOffset() throws {
        let offset = try XCTUnwrap(TimestampParser.parse("2026-08-12T23:08:44+02:00"))
        let utc = try XCTUnwrap(TimestampParser.parse("2026-08-12T21:08:44Z"))
        XCTAssertEqual(offset, utc)
    }

    func testRejectsGarbage() {
        XCTAssertNil(TimestampParser.parse(""))
        XCTAssertNil(TimestampParser.parse("yesterday"))
        XCTAssertNil(TimestampParser.parse("2026-13"))
    }
}
