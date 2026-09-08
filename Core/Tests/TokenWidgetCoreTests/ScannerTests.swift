import XCTest
@testable import TokenWidgetCore

final class ScannerTests: XCTestCase {
    private var home: URL!
    private var storeDirectory: URL!
    private var store: SharedStore!
    private var utc = Calendar(identifier: .gregorian)

    private var sessionsDirectory: URL {
        home.appendingPathComponent(".claude/projects/-Users-eric-dev-demo", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        store = SharedStore(
            snapshotURL: storeDirectory.appendingPathComponent("snapshot.json"),
            scanStateURL: storeDirectory.appendingPathComponent("scan-state.json"),
            dedupURL: storeDirectory.appendingPathComponent("dedup.bin"),
            lockURL: storeDirectory.appendingPathComponent("store.lock")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func makeScanner() -> UsageScanner {
        UsageScanner(
            providers: [ClaudeCodeProvider(home: home)],
            store: store,
            calendar: utc,
            // Small chunks so the multi-chunk and carry-over paths are exercised
            // by fixtures of a realistic size.
            chunkSize: 512
        )
    }

    private func line(request: String, day: String = "2026-08-12", output: Int = 100) -> String {
        """
        {"type":"assistant","timestamp":"\(day)T12:00:00.000Z","requestId":"\(request)","uuid":"u-\(request)",\
        "cwd":"/Users/eric/dev/demo","message":{"id":"m-\(request)","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":50,\
        "output_tokens":\(output),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "speed":"standard"}}}
        """
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(to: sessionsDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func append(_ contents: String, to name: String) throws {
        let url = sessionsDirectory.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
    }

    func testAddingPiToExistingCheckpointKeepsCLITotals() throws {
        try write(line(request: "existing") + "\n", to: "one.jsonl")
        let original = try makeScanner().scan()
        XCTAssertFalse(store.loadScanState().files.isEmpty)
        XCTAssertGreaterThan(store.loadDedupIndex().count, 0)
        let piRoot = home.appendingPathComponent(".pi/agent/sessions/demo")
        try FileManager.default.createDirectory(at: piRoot, withIntermediateDirectories: true)
        let piLine = #"{"type":"message","id":"newpi","timestamp":"2026-09-07T12:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","usage":{"output":250}}}"#
        try (piLine + "\n").write(to: piRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let scanner = UsageScanner(providers: [ClaudeCodeProvider(home: home), PiProvider(home: home)],
                                   store: store, calendar: utc, priceBook: .builtIn)
        let updated = try scanner.scan()
        XCTAssertEqual(updated.days.first, original.days.first)
        XCTAssertEqual(updated.days.last?.totals.output, 250)
        XCTAssertEqual(updated.totalMessages, 2)
        let oldColors = try XCTUnwrap(original.modelColors)
        XCTAssertFalse(oldColors.isEmpty)
        for (identity, color) in oldColors { XCTAssertEqual(updated.modelColors?[identity], color) }
        let repeated = try scanner.scan()
        XCTAssertEqual(repeated.totalMessages, 2)
        XCTAssertEqual(repeated.modelColors, updated.modelColors)
    }

    func testScansAFreshTranscript() throws {
        try write([line(request: "a"), line(request: "b")].joined(separator: "\n") + "\n", to: "one.jsonl")

        let snapshot = try makeScanner().scan()

        XCTAssertEqual(snapshot.totalMessages, 2)
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertEqual(snapshot.days[0].day, DayID(year: 2026, month: 8, day: 12))
        XCTAssertEqual(snapshot.days[0].totals.output, 200)
        XCTAssertEqual(snapshot.days[0].totals.cacheRead, 100)
    }

    /// Resuming a session replays earlier messages into a new file. Those
    /// repeats share a requestId and must be counted exactly once.
    func testDeduplicatesRepeatedRequestsAcrossFiles() throws {
        try write([line(request: "a"), line(request: "b")].joined(separator: "\n") + "\n", to: "original.jsonl")
        try write([line(request: "a"), line(request: "b"), line(request: "c")].joined(separator: "\n") + "\n", to: "resumed.jsonl")

        let snapshot = try makeScanner().scan()

        XCTAssertEqual(snapshot.totalMessages, 3)
        XCTAssertEqual(snapshot.days[0].totals.output, 300)
    }

    func testIncrementalScanReadsOnlyAppendedBytes() throws {
        try write(line(request: "a") + "\n", to: "live.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        // Modification dates have one-second resolution on some filesystems, so
        // make sure the append is distinguishable from the initial write.
        Thread.sleep(forTimeInterval: 1.1)
        try append(line(request: "b") + "\n", to: "live.jsonl")

        var lastProgress: ScanProgress?
        let snapshot = try scanner.scan { lastProgress = $0 }

        XCTAssertEqual(snapshot.totalMessages, 2)
        let bytesRead = try XCTUnwrap(lastProgress?.bytesRead)
        let appendedSize = line(request: "b").utf8.count
        // Only the appended line was read back, not the whole file.
        XCTAssertEqual(Int(bytesRead), appendedSize)
    }

    func testUnchangedFilesAreNotReadAgain() throws {
        try write(line(request: "a") + "\n", to: "static.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        var lastProgress: ScanProgress?
        let snapshot = try scanner.scan { lastProgress = $0 }

        XCTAssertEqual(snapshot.totalMessages, 1)
        XCTAssertEqual(lastProgress?.bytesRead, 0)
        XCTAssertEqual(lastProgress?.newRecords, 0)
    }

    /// A transcript being written to right now usually ends mid-line. Parsing
    /// that fragment would drop the message; the scanner must wait for the
    /// newline and pick it up on the next pass.
    func testPartialTrailingLineIsDeferredUntilComplete() throws {
        let complete = line(request: "a") + "\n"
        let partial = String(line(request: "b").prefix(60))
        try write(complete + partial, to: "streaming.jsonl")

        let scanner = makeScanner()
        var snapshot = try scanner.scan()
        XCTAssertEqual(snapshot.totalMessages, 1)

        Thread.sleep(forTimeInterval: 1.1)
        try append(String(line(request: "b").dropFirst(60)) + "\n", to: "streaming.jsonl")

        snapshot = try scanner.scan()
        XCTAssertEqual(snapshot.totalMessages, 2)
    }

    /// If a file is replaced rather than appended to, the scanner re-reads it
    /// from the start; dedup keeps the totals correct.
    func testRewrittenFileDoesNotDoubleCount() throws {
        try write([line(request: "a"), line(request: "b")].joined(separator: "\n") + "\n", to: "rewritten.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        Thread.sleep(forTimeInterval: 1.1)
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("rewritten.jsonl"))
        try write([line(request: "a"), line(request: "b"), line(request: "c")].joined(separator: "\n") + "\n", to: "rewritten.jsonl")

        let snapshot = try scanner.scan()
        XCTAssertEqual(snapshot.totalMessages, 3)
    }

    private func rewriteInPlace(_ contents: String, name: String) throws {
        let url = sessionsDirectory.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path
        )
    }

    func testSameSizeRewriteInPlaceReadsNewRecords() throws {
        try write(line(request: "a") + "\n", to: "rewritten.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()
        let previous = try XCTUnwrap(store.loadScanState().files.values.first)

        try rewriteInPlace(line(request: "b") + "\n", name: "rewritten.jsonl")
        let snapshot = try scanner.scan()
        let current = try XCTUnwrap(store.loadScanState().files.values.first)

        XCTAssertEqual(current.inode, previous.inode)
        XCTAssertEqual(current.size, previous.size)
        XCTAssertEqual(snapshot.totalMessages, 2)
        XCTAssertEqual(snapshot.days[0].totals.output, 200)
    }

    func testShrinkAboveCompleteLineOffsetReadsFromBeginning() throws {
        try write(line(request: "a") + "\n" + String(repeating: "x", count: 2_000), to: "rewritten.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()
        let previous = try XCTUnwrap(store.loadScanState().files.values.first)

        try rewriteInPlace(line(request: "b", output: 1_000) + "\n", name: "rewritten.jsonl")
        let snapshot = try scanner.scan()
        let current = try XCTUnwrap(store.loadScanState().files.values.first)

        XCTAssertEqual(current.inode, previous.inode)
        XCTAssertLessThan(current.size, previous.size)
        XCTAssertGreaterThan(current.size, previous.offset)
        XCTAssertEqual(snapshot.totalMessages, 2)
        XCTAssertEqual(snapshot.days[0].totals.output, 1_100)
    }

    func testDeletedTranscriptKeepsItsHistoryButDropsScanState() throws {
        try write(line(request: "a") + "\n", to: "gone.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("gone.jsonl"))
        let snapshot = try scanner.scan()

        XCTAssertEqual(snapshot.totalMessages, 1, "history should survive the transcript being cleaned up")
        XCTAssertTrue(store.loadScanState().files.isEmpty)
    }

    func testSurfacesUnpricedAndLocalModels() throws {
        let local = """
        {"type":"assistant","timestamp":"2026-08-12T12:00:00.000Z","requestId":"local-1",\
        "message":{"id":"m1","model":"unsloth/Qwen3.6-27B-MTP-GGUF",\
        "usage":{"input_tokens":10,"output_tokens":10}}}
        """
        try write([line(request: "a"), local].joined(separator: "\n") + "\n", to: "mixed.jsonl")

        let snapshot = try makeScanner().scan()
        XCTAssertEqual(snapshot.localModels, ["qwen3.6-27b-mtp-gguf"])
        XCTAssertTrue(snapshot.unpricedModels.isEmpty)
    }

    func testSnapshotSurvivesARoundTrip() throws {
        try write([line(request: "a"), line(request: "b", day: "2026-08-13")].joined(separator: "\n") + "\n", to: "trip.jsonl")
        let written = try makeScanner().scan()

        let loaded = try XCTUnwrap(store.loadSnapshot())
        XCTAssertEqual(loaded.days.count, written.days.count)
        XCTAssertEqual(loaded.totalMessages, written.totalMessages)
        XCTAssertEqual(loaded.days.map(\.day), [DayID(year: 2026, month: 8, day: 12), DayID(year: 2026, month: 8, day: 13)])
    }
}

final class DedupIndexTests: XCTestCase {
    func testInsertReportsNovelty() {
        var index = DedupIndex()
        XCTAssertTrue(index.insert(42))
        XCTAssertFalse(index.insert(42))
        XCTAssertEqual(index.count, 1)
    }

    func testBinaryRoundTrip() {
        var index = DedupIndex()
        let keys: [UInt64] = [1, 2, .max, 0xdead_beef_cafe_babe]
        for key in keys { _ = index.insert(key) }

        var restored = DedupIndex.decode(index.encoded())
        XCTAssertEqual(restored.count, keys.count)
        for key in keys { XCTAssertFalse(restored.insert(key), "\(key) should already be present") }
    }

    func testEncodingIsEightBytesPerKey() {
        var index = DedupIndex()
        for key in UInt64(0)..<1000 { _ = index.insert(key) }
        XCTAssertEqual(index.encoded().count, 8_000)
    }
}
