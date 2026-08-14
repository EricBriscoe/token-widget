import XCTest
@testable import TokenWidgetCore

/// Shapes here are copied from real rollout files under `~/.codex/sessions`.
final class CodexParserTests: XCTestCase {
    private func makeParser(file: String = "/tmp/rollout-a.jsonl") -> TranscriptLineParser {
        CodexProvider().makeParser(file: URL(fileURLWithPath: file), resuming: nil)
    }

    private func turnContext(model: String = "gpt-5.6-sol") -> String {
        """
        {"timestamp":"2026-08-13T20:33:51.779Z","type":"turn_context","payload":{"turn_id":"t-1",\
        "cwd":"/Users/eric/dev/token-widget","model":"\(model)","effort":"high"}}
        """
    }

    private func tokenCount(
        timestamp: String = "2026-08-13T20:34:03.066Z",
        input: Int = 23_552,
        cached: Int = 11_008,
        cacheWrite: Int = 0,
        output: Int = 435,
        reasoning: Int = 125
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output),\
        "reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)},\
        "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output),\
        "reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)},\
        "model_context_window":258400}}}
        """
    }

    private func webSearchCall(
        timestamp: String = "2026-03-05T22:48:55.271Z",
        query: String = "docker compose down project name precedence"
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"web_search_call",\
        "status":"completed","action":{"type":"search","query":"\(query)","queries":["\(query)"]}}}
        """
    }

    // MARK: - Token counts

    func testTakesModelFromTurnContext() throws {
        let parser = makeParser()
        XCTAssertNil(parser.record(from: Data(turnContext().utf8)))
        let record = try XCTUnwrap(parser.record(from: Data(tokenCount().utf8)))
        XCTAssertEqual(record.key.model, "gpt-5.6-sol")
        XCTAssertEqual(record.key.provider, .codex)
    }

    /// OpenAI reports cached and freshly-written tokens *inside* `input_tokens`,
    /// so leaving them in would bill the same tokens at two rates.
    func testCachedAndWrittenTokensAreSplitOutOfInput() throws {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))
        let record = try XCTUnwrap(parser.record(
            from: Data(tokenCount(input: 20_000, cached: 11_000, cacheWrite: 4_000, output: 435).utf8)
        ))
        XCTAssertEqual(record.counts.input, 5_000)
        XCTAssertEqual(record.counts.cacheRead, 11_000)
        XCTAssertEqual(record.counts.cacheWrite5m, 4_000)
        XCTAssertEqual(record.counts.output, 435)
        XCTAssertEqual(record.counts.thinking, 125)
        XCTAssertEqual(record.counts.messages, 1)
        // Every input token is accounted for exactly once.
        XCTAssertEqual(record.counts.totalInput, 20_000)
    }

    func testReasoningTokensAreNotAddedOnTopOfOutput() throws {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))
        let record = try XCTUnwrap(parser.record(from: Data(tokenCount(output: 435, reasoning: 125).utf8)))
        XCTAssertEqual(record.counts.output, 435)
        XCTAssertEqual(record.counts.thinking, 125)
        XCTAssertEqual(record.counts.billedTotal, 23_552 + 435)
    }

    // MARK: - Deduplication

    /// Resuming or forking a session writes a new rollout file that replays the
    /// earlier turns verbatim. Keying on the file path counted them once per
    /// file; 122 turn identities in the author's corpus appear in two files.
    func testSameTurnInTwoRolloutFilesDedupes() throws {
        let first = makeParser(file: "/tmp/rollout-a.jsonl")
        let second = makeParser(file: "/tmp/rollout-b.jsonl")
        _ = first.record(from: Data(turnContext().utf8))
        _ = second.record(from: Data(turnContext().utf8))

        let a = try XCTUnwrap(first.record(from: Data(tokenCount().utf8)))
        let b = try XCTUnwrap(second.record(from: Data(tokenCount().utf8)))
        XCTAssertEqual(a.dedupKey, b.dedupKey)
    }

    func testDistinctTurnsKeepDistinctIdentities() throws {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))
        let a = try XCTUnwrap(parser.record(from: Data(tokenCount(timestamp: "2026-08-13T20:34:03.066Z").utf8)))
        let b = try XCTUnwrap(parser.record(from: Data(tokenCount(timestamp: "2026-08-13T20:34:09.512Z").utf8)))
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
    }

    // MARK: - Web search

    func testWebSearchCallIsCountedAsABillableRequest() throws {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))
        let record = try XCTUnwrap(parser.record(from: Data(webSearchCall().utf8)))
        XCTAssertEqual(record.counts.webSearches, 1)
        // Not an assistant message, so it must not inflate the message count or
        // the token total.
        XCTAssertEqual(record.counts.messages, 0)
        XCTAssertEqual(record.counts.billedTotal, 0)
    }

    /// `web_search_end` is the UI event for the same search. Counting it too
    /// would bill every search twice.
    func testWebSearchEndEventIsIgnored() {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))
        let line = """
        {"timestamp":"2026-04-29T15:26:04.811Z","type":"event_msg","payload":{"type":"web_search_end",\
        "call_id":"ws_088","query":"codex approvals_reviewer","action":{"type":"search","query":"x"}}}
        """
        XCTAssertNil(parser.record(from: Data(line.utf8)))
    }

    func testTheByteFilterLetsEveryRelevantLineThrough() {
        let parser = makeParser()
        for line in [turnContext(), tokenCount(), webSearchCall()] {
            XCTAssertTrue(parser.mayContainUsage(Data(line.utf8)), "filtered out: \(line.prefix(40))")
        }
        let unrelated = """
        {"timestamp":"2026-08-13T20:33:52Z","type":"response_item","payload":{"type":"function_call",\
        "name":"shell","arguments":"{}"}}
        """
        XCTAssertFalse(parser.mayContainUsage(Data(unrelated.utf8)))
    }

    // MARK: - Roots

    /// Codex moves finished sessions aside; they are still usage that was billed.
    func testArchivedSessionsAreScanned() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let roots = CodexProvider(home: home).roots.map(\.path)
        XCTAssertTrue(roots.contains { $0.hasSuffix(".codex/sessions") })
        XCTAssertTrue(roots.contains { $0.hasSuffix(".codex/archived_sessions") })
    }

    // MARK: - Cumulative fallback

    /// Some rollouts report only a running total. Differencing them keeps the
    /// whole conversation from being re-added on every event.
    func testCumulativeOnlyTotalsAreDifferenced() throws {
        let parser = makeParser()
        _ = parser.record(from: Data(turnContext().utf8))

        func cumulative(_ input: Int, _ output: Int, at stamp: String) -> String {
            """
            {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count","info":{\
            "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,\
            "output_tokens":\(output),"reasoning_output_tokens":0}}}}
            """
        }

        let first = try XCTUnwrap(parser.record(from: Data(cumulative(1_000, 100, at: "2026-08-13T20:34:03.066Z").utf8)))
        let second = try XCTUnwrap(parser.record(from: Data(cumulative(2_500, 260, at: "2026-08-13T20:35:03.066Z").utf8)))
        XCTAssertEqual(first.counts.input, 1_000)
        XCTAssertEqual(second.counts.input, 1_500)
        XCTAssertEqual(second.counts.output, 160)
    }
}
