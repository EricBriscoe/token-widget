import XCTest
@testable import TokenWidgetCore

/// Claude Code deletes its own transcripts after a retention period (30 days by
/// default). Once that happens the aggregated snapshot is the only surviving
/// record of that usage, so these tests pin the behaviour that keeps it.
final class HistoryRetentionTests: XCTestCase {
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
            lockURL: storeDirectory.appendingPathComponent("store.lock"),
            backupURL: storeDirectory.appendingPathComponent("snapshot.previous.json")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func makeScanner() -> UsageScanner {
        UsageScanner(providers: [ClaudeCodeProvider(home: home)], store: store, calendar: utc, chunkSize: 512)
    }

    private func line(request: String, day: String, output: Int = 100) -> String {
        """
        {"type":"assistant","timestamp":"\(day)T12:00:00.000Z","requestId":"\(request)","uuid":"u-\(request)",\
        "cwd":"/Users/eric/dev/demo","message":{"id":"m-\(request)","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"cache_read_input_tokens":50,"output_tokens":\(output)}}}
        """
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(to: sessionsDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The headline guarantee: usage recorded years ago survives its transcript
    /// being deleted, and keeps accumulating alongside new days.
    func testHistorySurvivesTranscriptPruningAcrossYears() throws {
        try write(line(request: "old-1", day: "2024-03-04") + "\n", to: "2024.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        // Claude Code prunes the old transcript and a new session starts.
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("2024.jsonl"))
        try write(line(request: "new-1", day: "2026-08-14") + "\n", to: "2026.jsonl")

        let snapshot = try scanner.scan()

        XCTAssertEqual(snapshot.days.map(\.day), [
            DayID(year: 2024, month: 3, day: 4),
            DayID(year: 2026, month: 8, day: 14)
        ])
        XCTAssertEqual(snapshot.totalMessages, 2)
    }

    /// Repeated scans with every transcript gone must not erode the history.
    func testRepeatedScansWithNoTranscriptsLeftKeepHistoryIntact() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        let scanner = makeScanner()
        let original = try scanner.scan()
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("old.jsonl"))

        for _ in 0..<3 {
            let snapshot = try scanner.scan()
            XCTAssertEqual(snapshot.days, original.days)
            XCTAssertEqual(snapshot.totalMessages, 1)
        }
    }

    /// A history file we cannot parse must stop the scan rather than be
    /// silently replaced by whatever transcripts still exist.
    func testUnreadableHistoryStopsTheScanInsteadOfOverwriting() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        let scanner = makeScanner()
        _ = try scanner.scan()

        let snapshotURL = storeDirectory.appendingPathComponent("snapshot.json")
        try Data("{ not valid json".utf8).write(to: snapshotURL)

        XCTAssertThrowsError(try scanner.scan()) { error in
            guard case ScanError.historyUnreadable = error else {
                return XCTFail("expected historyUnreadable, got \(error)")
            }
        }
        // The damaged file is left alone rather than replaced.
        let onDisk = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "{ not valid json")
    }

    /// A snapshot written by a newer build is not decoded and thrown away.
    func testNewerSnapshotFormatIsRefusedNotDiscarded() throws {
        var future = UsageSnapshot()
        future.version = UsageSnapshot.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(future).write(to: storeDirectory.appendingPathComponent("snapshot.json"))

        guard case .unreadable = store.load() else {
            return XCTFail("a newer format should not be treated as readable")
        }
        XCTAssertThrowsError(try makeScanner().scan())
    }

    func testSaveKeepsThePreviousSnapshotAsABackup() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "one.jsonl")
        let scanner = makeScanner()
        let first = try scanner.scan()

        try write(line(request: "b", day: "2025-01-03") + "\n", to: "two.jsonl")
        let second = try scanner.scan()

        let backup = try XCTUnwrap(store.loadBackup())
        XCTAssertEqual(backup.days.count, first.days.count)
        XCTAssertEqual(second.days.count, 2)
    }

    /// Rebuilding is destructive once transcripts are gone, so it has to be undoable.
    func testResetIsRecoverableFromBackup() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        _ = try makeScanner().scan()
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("old.jsonl"))

        store.reset()
        XCTAssertNil(store.loadSnapshot())

        let restored = try XCTUnwrap(store.restoreBackup())
        XCTAssertEqual(restored.days.map(\.day), [DayID(year: 2025, month: 1, day: 2)])
    }

    func testExportedHistoryCanBeImportedBack() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        _ = try makeScanner().scan()

        let export = storeDirectory.appendingPathComponent("export.json")
        try store.exportHistory(to: export)

        store.reset()
        try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent("snapshot.previous.json"))
        XCTAssertNil(store.loadSnapshot())

        let imported = try store.importHistory(from: export)
        XCTAssertEqual(imported.days.map(\.day), [DayID(year: 2025, month: 1, day: 2)])
        XCTAssertEqual(imported.totalMessages, 1)
    }

    /// Importing a file that overlaps the current history must not double-count
    /// the days they share.
    func testImportDoesNotDoubleCountOverlappingDays() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        let scanner = makeScanner()
        let original = try scanner.scan()

        let export = storeDirectory.appendingPathComponent("export.json")
        try store.exportHistory(to: export)

        let merged = try store.importHistory(from: export)
        XCTAssertEqual(merged.totalMessages, original.totalMessages)
        XCTAssertEqual(merged.days.count, 1)
    }

    func testMergePrefersTheFullerRecordAndUnionsDays() {
        let key = ModelKey(provider: .claudeCode, model: "claude-opus-5")
        func snapshot(day: DayID, output: Int) -> UsageSnapshot {
            var counts = TokenCounts()
            counts.output = output
            counts.messages = 1
            return UsageSnapshot(
                days: [DaySummary(day: day, entries: [
                    ModelEntry(provider: key.provider, model: key.model, fast: key.fast, counts: counts)
                ])]
            )
        }

        let thin = snapshot(day: DayID(year: 2025, month: 5, day: 1), output: 10)
        var rich = snapshot(day: DayID(year: 2025, month: 5, day: 1), output: 90)
        rich.days.append(contentsOf: snapshot(day: DayID(year: 2025, month: 6, day: 1), output: 5).days)

        let merged = UsageSnapshot.merging(thin, rich)
        XCTAssertEqual(merged.days.count, 2)
        XCTAssertEqual(merged.days.first?.totals.output, 90, "the fuller record wins rather than summing")
    }
}
