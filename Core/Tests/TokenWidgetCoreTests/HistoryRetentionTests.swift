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

        try store.reset()
        XCTAssertNil(store.loadSnapshot())

        let restored = try XCTUnwrap(store.restoreBackup())
        XCTAssertEqual(restored.days.map(\.day), [DayID(year: 2025, month: 1, day: 2)])
    }

    func testExportedHistoryCanBeImportedBack() throws {
        try write(line(request: "a", day: "2025-01-02") + "\n", to: "old.jsonl")
        _ = try makeScanner().scan()

        let export = storeDirectory.appendingPathComponent("export.json")
        try store.exportHistory(to: export)

        try store.reset()
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

    func testRestoringWithTranscriptsPresentDoesNotDoubleCountAndStillCountsNewUsage() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        try store.reset()
        XCTAssertNotNil(store.restoreBackup())
        XCTAssertEqual(try makeScanner().scan().days, original.days)

        try write(line(request: "new", day: "2025-01-02") + "\n", to: "new.jsonl")
        let updated = try makeScanner().scan()
        XCTAssertEqual(updated.totalMessages, 2)
        XCTAssertEqual(updated.days.first?.totals.output, 200)
    }

    func testImportedHistorySurvivesRescanWithoutDuplicatingExistingTranscripts() throws {
        try write(line(request: "pruned", day: "2024-01-02") + "\n", to: "pruned.jsonl")
        try write(line(request: "present", day: "2025-01-02") + "\n", to: "present.jsonl")
        let original = try makeScanner().scan()
        let export = storeDirectory.appendingPathComponent("export.json")
        try store.exportHistory(to: export)
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("pruned.jsonl"))
        try store.reset()
        _ = try makeScanner().scan()

        _ = try store.importHistory(from: export)
        let rescanned = try makeScanner().scan()
        XCTAssertEqual(rescanned.days, original.days)
        XCTAssertEqual(rescanned.totalMessages, 2)
        XCTAssertEqual(try makeScanner().scan().days, original.days)
    }

    func testMissingOrDamagedCheckpointsDoNotDuplicateRetainedHistory() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        try FileManager.default.removeItem(at: storeDirectory.appendingPathComponent("scan-state.json"))
        XCTAssertEqual(try makeScanner().scan().days, original.days)

        let dedupURL = storeDirectory.appendingPathComponent("dedup.bin")
        var damaged = try Data(contentsOf: dedupURL)
        damaged.append(0)
        try damaged.write(to: dedupURL)
        XCTAssertEqual(try makeScanner().scan().days, original.days)
    }

    func testMissingSnapshotRebuildsDespiteOldCheckpoints() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        try FileManager.default.removeItem(at: storeDirectory.appendingPathComponent("snapshot.json"))
        XCTAssertEqual(try makeScanner().scan().days, original.days)
    }

    func testImportRefusesNewerFormatsAndPreservesCurrentHistory() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        var future = UsageSnapshot()
        future.version = UsageSnapshot.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let export = storeDirectory.appendingPathComponent("future.json")
        try encoder.encode(future).write(to: export)

        XCTAssertThrowsError(try store.importHistory(from: export))
        XCTAssertEqual(store.loadSnapshot()?.days, original.days)
    }

    func testImportRefusesToOverwriteUnreadableCurrentHistory() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        _ = try makeScanner().scan()
        let export = storeDirectory.appendingPathComponent("export.json")
        try store.exportHistory(to: export)
        let snapshotURL = storeDirectory.appendingPathComponent("snapshot.json")
        let damaged = Data("{ damaged history".utf8)
        try damaged.write(to: snapshotURL)

        XCTAssertThrowsError(try store.importHistory(from: export))
        XCTAssertEqual(try Data(contentsOf: snapshotURL), damaged)
    }

    func testRestorePreservesBackupWhenCurrentHistoryIsDamaged() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        _ = try makeScanner().scan()
        try Data("broken".utf8).write(to: storeDirectory.appendingPathComponent("snapshot.json"))

        XCTAssertEqual(store.restoreBackup()?.days, original.days)
        XCTAssertEqual(store.loadSnapshot()?.days, original.days)
        XCTAssertEqual(store.loadBackup()?.days, original.days)
    }

    func testRestoreReturnsFailureWhenHistoryCannotBeWritten() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        try store.reset()
        let snapshotURL = storeDirectory.appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: snapshotURL.appendingPathComponent("blocker"))

        XCTAssertNil(store.restoreBackup())
        XCTAssertEqual(store.loadBackup()?.days, original.days)
    }

    func testInterruptedSaveRebuildsWithoutDoubleCounting() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        _ = try makeScanner().scan()
        try write(line(request: "new", day: "2025-01-02") + "\n", to: "new.jsonl")
        let dedupURL = storeDirectory.appendingPathComponent("dedup.bin")
        try FileManager.default.removeItem(at: dedupURL)
        try FileManager.default.createDirectory(at: dedupURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dedupURL.appendingPathComponent("blocker"))

        XCTAssertThrowsError(try makeScanner().scan())
        XCTAssertEqual(store.loadSnapshot()?.totalMessages, 2)
        XCTAssertTrue(store.loadScanState().files.isEmpty)
        try FileManager.default.removeItem(at: dedupURL)

        let recovered = try makeScanner().scan()
        XCTAssertEqual(recovered.totalMessages, 2)
        XCTAssertEqual(recovered.days.first?.totals.output, 200)
    }

    func testResetPreservesHistoryWhenBackupCannotBeWritten() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        let state = store.loadScanState().files
        let backupURL = storeDirectory.appendingPathComponent("snapshot.previous.json")
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: backupURL.appendingPathComponent("blocker"))

        XCTAssertThrowsError(try store.reset())
        XCTAssertEqual(store.loadSnapshot()?.days, original.days)
        XCTAssertEqual(store.loadScanState().files, state)
        XCTAssertEqual(store.loadDedupIndex().count, 1)
    }

    func testLegacyCodexCheckpointRebuildsCumulativeBaselineWithoutDuplicatingHistory() throws {
        try write(line(request: "pruned", day: "2024-01-02") + "\n", to: "pruned.jsonl")
        let codexDirectory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let transcript = codexDirectory.appendingPathComponent("rollout.jsonl")
        func cumulative(output: Int, second: Int) -> String {
            """
            {"timestamp":"2025-01-02T12:00:\(second)Z","type":"event_msg","payload":{"type":"token_count","info":{
            "total_token_usage":{"input_tokens":1000,"output_tokens":\(output)}}}}
            """.replacingOccurrences(of: "\n", with: "") + "\n"
        }
        let context = """
        {"timestamp":"2025-01-02T12:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        """
        try (context + "\n" + cumulative(output: 100, second: 10)).write(to: transcript, atomically: true, encoding: .utf8)
        let scanner = UsageScanner(
            providers: [ClaudeCodeProvider(home: home), CodexProvider(home: home)],
            store: store, calendar: utc, chunkSize: 512
        )
        let original = try scanner.scan()
        try FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("pruned.jsonl"))

        var legacy = store.loadScanState()
        legacy.version = 1
        for path in Array(legacy.files.keys) {
            legacy.files[path]?.parser?.codexTotals = nil
        }
        try JSONEncoder().encode(legacy).write(to: storeDirectory.appendingPathComponent("scan-state.json"))

        var bytesRead: Int64 = 0
        let upgraded = try scanner.scan { bytesRead = $0.bytesRead }
        XCTAssertGreaterThan(bytesRead, 0, "upgrading must reread unchanged transcripts")
        XCTAssertEqual(upgraded.days, original.days, "pruned history survives checkpoint migration")
        XCTAssertEqual(store.loadScanState().version, ScanState.currentVersion)
        let checkpoint = try XCTUnwrap(store.loadScanState().files.first { $0.key.hasSuffix("/rollout.jsonl") }?.value)
        XCTAssertNotNil(checkpoint.parser?.codexTotals)

        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(cumulative(output: 100, second: 20).utf8))
        XCTAssertEqual(try scanner.scan().days, original.days, "repeated totals after upgrading add no usage")

        try handle.write(contentsOf: Data(cumulative(output: 150, second: 30).utf8))
        let updated = try scanner.scan()
        XCTAssertEqual(updated.totalMessages, original.totalMessages + 1)
        XCTAssertEqual(updated.days.last?.totals.output, 150, "new cumulative usage adds only its delta")
    }

    func testCustomStoreDefaultsBackupToItsOwnDirectory() throws {
        let customStore = SharedStore(
            snapshotURL: storeDirectory.appendingPathComponent("snapshot.json"),
            scanStateURL: storeDirectory.appendingPathComponent("scan-state.json"),
            dedupURL: storeDirectory.appendingPathComponent("dedup.bin"),
            lockURL: storeDirectory.appendingPathComponent("store.lock")
        )
        let original = UsageSnapshot(totalMessages: 7)
        try customStore.save(snapshot: original, scanState: ScanState(), dedup: DedupIndex())
        try customStore.save(snapshot: UsageSnapshot(totalMessages: 8), scanState: ScanState(), dedup: DedupIndex())

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("snapshot.previous.json").path))
        XCTAssertEqual(customStore.loadBackup()?.totalMessages, 7)
    }

    func testExportToCurrentHistoryPathDoesNotDeleteHistory() throws {
        try write(line(request: "old", day: "2025-01-02") + "\n", to: "old.jsonl")
        let original = try makeScanner().scan()
        try store.exportHistory(to: storeDirectory.appendingPathComponent("snapshot.json"))
        XCTAssertEqual(store.loadSnapshot()?.days, original.days)
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
