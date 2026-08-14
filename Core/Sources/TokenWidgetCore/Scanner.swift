import Foundation

public enum ScanError: LocalizedError {
    case historyUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .historyUnreadable(let reason):
            return """
            Stopped before rescanning because \(reason). \
            Transcripts older than Claude Code's retention period are already gone, so rebuilding now \
            would drop that history. The previous copy is kept as snapshot.previous.json.
            """
        }
    }
}

public struct ScanProgress: Sendable {
    public let filesProcessed: Int
    public let filesTotal: Int
    public let newRecords: Int
    public let bytesRead: Int64

    public var fraction: Double {
        filesTotal == 0 ? 1 : Double(filesProcessed) / Double(filesTotal)
    }
}

/// Walks every provider's transcripts and folds new messages into the stored
/// snapshot.
///
/// The first pass reads everything; later passes read only the bytes appended
/// since, which is what keeps a refresh cheap against a corpus this size. Files
/// whose size and modification date are unchanged are not opened at all.
public final class UsageScanner {
    private let providers: [TranscriptProvider]
    private let store: SharedStore
    private let calendar: Calendar
    private let priceBook: PriceBook
    private let chunkSize: Int

    public init(
        providers: [TranscriptProvider] = [ClaudeCodeProvider(), CodexProvider()],
        store: SharedStore = SharedStore(),
        calendar: Calendar = .current,
        priceBook: PriceBook = .current,
        chunkSize: Int = 4 * 1024 * 1024
    ) {
        self.providers = providers
        self.store = store
        self.calendar = calendar
        self.priceBook = priceBook
        self.chunkSize = chunkSize
    }

    @discardableResult
    public func scan(progress: ((ScanProgress) -> Void)? = nil) throws -> UsageSnapshot {
        let started = Date()

        // Refuse to rebuild over history we could not read. Claude Code prunes
        // transcripts on its own retention schedule, so days recorded here are
        // often the only surviving record. Overwriting them with whatever is
        // still on disk would quietly discard months of usage.
        let previous: UsageSnapshot?
        switch store.load() {
        case .missing:
            previous = nil
        case .loaded(let snapshot):
            previous = snapshot
        case .unreadable(let reason):
            throw ScanError.historyUnreadable(reason)
        }

        var scanState = store.loadScanState()
        var dedup = store.loadDedupIndex()
        var aggregator = UsageAggregator(resuming: previous?.days ?? [], calendar: calendar)

        let files = discoverFiles()
        var processed = 0
        var newRecords = 0
        var bytesRead: Int64 = 0

        for file in files {
            defer {
                processed += 1
                progress?(ScanProgress(
                    filesProcessed: processed,
                    filesTotal: files.count,
                    newRecords: newRecords,
                    bytesRead: bytesRead
                ))
            }

            let path = file.url.path
            let existing = scanState.files[path]

            // Untouched since the last pass: nothing to read.
            if let existing,
               existing.size == file.size,
               existing.inode == file.inode,
               abs(existing.modified.timeIntervalSince(file.modified)) < 0.001 {
                continue
            }

            // Resume mid-file only when it is the same file, grown in place.
            var startOffset: Int64 = 0
            var parserState: ParserState?
            if let existing, existing.inode == file.inode, file.size >= existing.offset {
                startOffset = existing.offset
                parserState = existing.parser
            }

            let parser = file.provider.makeParser(file: file.url, resuming: parserState)
            var consumed = startOffset

            do {
                consumed = try readLines(at: file.url, from: startOffset) { line in
                    bytesRead += Int64(line.count)
                    guard parser.mayContainUsage(line) else { return }
                    guard let record = parser.record(from: line) else { return }
                    guard dedup.insert(record.dedupKey) else { return }
                    aggregator.add(record)
                    newRecords += 1
                }
            } catch {
                // A file that vanished or turned unreadable mid-scan should not
                // abort the whole pass; the next scan picks it up.
                continue
            }

            scanState.files[path] = FileScanState(
                size: file.size,
                modified: file.modified,
                offset: consumed,
                inode: file.inode,
                parser: parser.state
            )
        }

        // Drop bookkeeping for files that no longer exist, so state does not
        // grow forever. Their aggregated totals stay in the snapshot.
        let livePaths = Set(files.map(\.url.path))
        scanState.files = scanState.files.filter { livePaths.contains($0.key) }

        let days = aggregator.daySummaries()
        let classification = classifyModels(in: days)

        let snapshot = UsageSnapshot(
            generatedAt: Date(),
            days: days,
            unpricedModels: classification.unpriced,
            approximateModels: classification.approximate,
            localModels: classification.local,
            totalMessages: days.reduce(0) { $0 + $1.totals.messages },
            scanDuration: Date().timeIntervalSince(started),
            filesScanned: files.count
        )

        try store.save(snapshot: snapshot, scanState: scanState, dedup: dedup)
        return snapshot
    }

    // MARK: - File discovery

    private struct DiscoveredFile {
        let url: URL
        let provider: TranscriptProvider
        let size: Int64
        let modified: Date
        let inode: UInt64
    }

    private func discoverFiles() -> [DiscoveredFile] {
        var found: [DiscoveredFile] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .isRegularFileKey]

        for provider in providers {
            for root in provider.presentRoots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard url.pathExtension == "jsonl" else { continue }
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true,
                          let size = values.fileSize,
                          let modified = values.contentModificationDate
                    else { continue }

                    found.append(DiscoveredFile(
                        url: url,
                        provider: provider,
                        size: Int64(size),
                        modified: modified,
                        inode: inode(of: url)
                    ))
                }
            }
        }
        return found
    }

    private func inode(of url: URL) -> UInt64 {
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else { return 0 }
        return UInt64(statInfo.st_ino)
    }

    // MARK: - Line reading

    /// Streams complete lines starting at `offset` and returns the offset of the
    /// end of the last complete line.
    ///
    /// A transcript being written to right now usually ends in a partial line;
    /// stopping short of it means the next pass re-reads and completes it rather
    /// than parsing half a JSON object.
    private func readLines(at url: URL, from offset: Int64, onLine: (Data) throws -> Void) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))

        var position = offset
        var carry = Data()

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            position += Int64(chunk.count)

            var buffer: Data
            if carry.isEmpty {
                buffer = chunk
            } else {
                buffer = carry
                buffer.append(chunk)
            }

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                if newline > lineStart { try onLine(buffer.subdata(in: lineStart..<newline)) }
                lineStart = buffer.index(after: newline)
            }
            carry = lineStart == buffer.startIndex ? buffer : buffer.subdata(in: lineStart..<buffer.endIndex)

            // Guard against a single line larger than the chunk growing without
            // bound; transcripts have very large lines, but not unbounded ones.
            if carry.count > 64 * 1024 * 1024 { carry.removeAll() }
        }

        return position - Int64(carry.count)
    }

    // MARK: - Model classification

    private func classifyModels(in days: [DaySummary]) -> (unpriced: [String], approximate: [String], local: [String]) {
        var keys = Set<ModelKey>()
        for day in days {
            for entry in day.entries { keys.insert(entry.key) }
        }

        let today = DayID(Date(), calendar: calendar)
        var unpriced: Set<String> = []
        var approximate: Set<String> = []
        var local: Set<String> = []

        for key in keys {
            let result = priceBook.lookup(model: key.model, fast: key.fast, on: today)
            switch result.price {
            case .unknown: unpriced.insert(key.displayName)
            case .local: local.insert(key.displayName)
            case .priced: if result.isApproximate { approximate.insert(key.displayName) }
            }
        }

        return (unpriced.sorted(), approximate.sorted(), local.sorted())
    }
}
