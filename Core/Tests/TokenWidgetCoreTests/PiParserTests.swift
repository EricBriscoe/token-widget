import XCTest
@testable import TokenWidgetCore

final class PiParserTests: XCTestCase {
    private func parser(state: ParserState? = nil) -> TranscriptLineParser {
        PiProvider().makeParser(file: URL(fileURLWithPath: "/session.jsonl"), resuming: state)
    }

    private func line(id: String = "abcd1234", stamp: String = "2026-09-07T12:00:00.000Z",
                      role: String = "assistant", vendor: String = "openai-codex",
                      model: String = "gpt-6-astra", output: Int = 100) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"\(stamp)","message":{"role":"\(role)","provider":"\(vendor)","model":"\(model)","usage":{"input":12,"output":\(output),"cacheRead":200,"cacheWrite":30,"reasoning":40,"totalTokens":342},"stopReason":"stop"}}
        """
    }

    func testNativeUsageUsesDisjointLanesAndVendorIdentity() throws {
        let record = try XCTUnwrap(parser().record(from: Data(line().utf8)))
        XCTAssertEqual(record.key, ModelKey(provider: .pi, model: "openai/gpt-6-astra"))
        XCTAssertEqual(record.counts.input, 12)
        XCTAssertEqual(record.counts.cacheRead, 200)
        XCTAssertEqual(record.counts.cacheWrite5m, 30)
        XCTAssertEqual(record.counts.output, 100)
        XCTAssertEqual(record.counts.thinking, 40)
        XCTAssertEqual(record.counts.billedTotal, 342)
        XCTAssertEqual(record.key.displayName, "gpt-6-astra")
    }

    func testForkIdentityAndShortIDCollisions() throws {
        let original = try XCTUnwrap(parser().record(from: Data(line().utf8)))
        let copy = try XCTUnwrap(parser().record(from: Data(line().utf8)))
        let collision = try XCTUnwrap(parser().record(from: Data(line(stamp: "2026-09-07T12:00:01Z").utf8)))
        XCTAssertEqual(original.dedupKey, copy.dedupKey)
        XCTAssertNotEqual(original.dedupKey, collision.dedupKey)
    }

    func testHeaderStateSurvivesIncrementalRestart() throws {
        let first = parser()
        let header = Data(#"{"type":"session","cwd":"/work/demo"}"#.utf8)
        XCTAssertTrue(first.mayContainUsage(header))
        XCTAssertNil(first.record(from: header))
        let state = try JSONDecoder().decode(ParserState.self, from: JSONEncoder().encode(first.state))
        XCTAssertEqual(parser(state: state).record(from: Data(line().utf8))?.projectPath, "/work/demo")
    }

    func testIgnoresToolUsageArtifactsAndRetainedContext() {
        XCTAssertNil(parser().record(from: Data(line(role: "toolResult").utf8)))
        let artifacts = [
            #"{"recordType":"message","message":{"role":"assistant","usage":{"output":99}}}"#,
            #"{"type":"compaction","retainedTail":[{"role":"assistant","usage":{"output":99}}]}"#,
            #"{"type":"message","id":"err","timestamp":"2026-09-07T12:00:00Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-astra","usage":{"input":0,"output":0},"stopReason":"error"}}"#,
            "not json"
        ]
        for artifact in artifacts { XCTAssertNil(parser().record(from: Data(artifact.utf8))) }
    }

    func testPiPricingDoesNotMistakeHostedModelForLocal() {
        let day = DayID(year: 2026, month: 9, day: 7)
        let result = PriceBook.builtIn.lookup(model: "openai/gpt-6-astra", provider: .pi, fast: false, on: day)
        guard case .priced = result.price else { return XCTFail("Expected OpenAI fallback rate") }
        XCTAssertTrue(result.isApproximate)
        XCTAssertEqual(PriceBook.builtIn.lookup(model: "custom/gpt-6-astra", provider: .pi, fast: false, on: day).price, .unknown)
        let rate = ModelPrice(input: 1, output: 2)
        let book = PriceBook.builtIn.withCatalog(PriceCatalog(fetchedAt: Date(), models: ["google/gemini-test": rate]))
        XCTAssertEqual(book.lookup(model: "google/gemini-test", provider: .pi, fast: false, on: day).price, .priced(rate))
    }

    func testPiScanPreservesHistoryAndHandlesForksAppendsAndPartialLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".pi/agent/sessions/project/child")
        let data = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = SharedStore(snapshotURL: data.appendingPathComponent("snapshot.json"),
                                scanStateURL: data.appendingPathComponent("scan-state.json"),
                                dedupURL: data.appendingPathComponent("dedup.bin"),
                                lockURL: data.appendingPathComponent("store.lock"))
        let retained = DaySummary(day: DayID(year: 2026, month: 8, day: 1), entries: [
            ModelEntry(provider: .codex, model: "gpt-6-astra", fast: false, counts: TokenCounts(output: 999, messages: 1))
        ])
        try store.save(snapshot: UsageSnapshot(version: 1, days: [retained], totalMessages: 1),
                       scanState: ScanState(), dedup: DedupIndex())
        let live = sessions.appendingPathComponent("session.jsonl")
        let header = #"{"type":"session","cwd":"/work/demo"}"# + "\n"
        try (header + line() + "\n").write(to: live, atomically: true, encoding: .utf8)
        func scanner() -> UsageScanner {
            UsageScanner(providers: [PiProvider(home: root)], store: store, priceBook: .builtIn, chunkSize: 64)
        }
        let first = try scanner().scan()
        XCTAssertEqual(first.totalMessages, 2)
        XCTAssertEqual(first.days.first, retained)
        XCTAssertEqual(first.version, UsageSnapshot.currentVersion)

        // A fork replays the same message; a partial new message must wait.
        try (header + line() + "\n").write(to: sessions.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8)
        let next = line(id: "newentry", output: 250)
        let handle = try FileHandle(forWritingTo: live)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(next.prefix(80).utf8))
        XCTAssertEqual(try scanner().scan().totalMessages, 2)
        try handle.write(contentsOf: Data((String(next.dropFirst(80)) + "\n").utf8))
        let updated = try scanner().scan()
        XCTAssertEqual(updated.totalMessages, 3)
        XCTAssertEqual(updated.days.last?.totals.output, 350)
        XCTAssertEqual(updated.days.first, retained)
        var progress: ScanProgress?
        _ = try scanner().scan { progress = $0 }
        XCTAssertEqual(progress?.bytesRead, 0)
        XCTAssertEqual(progress?.newRecords, 0)
    }
}
