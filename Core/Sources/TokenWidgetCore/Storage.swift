import Foundation
import Security

/// Where the app and the widget meet.
///
/// The app is not sandboxed (it has to read `~/.claude`), the widget is, and an
/// App Group container is the one directory both can open. If the group
/// entitlement is unavailable in a unit test or a build without
/// provisioning, everything falls back to Application Support, so the engine
/// still works standalone.
public enum SharedContainer {
    /// Read from the running binary's own entitlements rather than hardcoded,
    /// so building under a different Apple Developer team only means changing
    /// `project.yml` and the two entitlement files. An App Group ID must be
    /// prefixed with the team ID, so it cannot be a fixed constant in source.
    public static let appGroupID: String = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String],
              let group = value.first
        else { return fallbackAppGroupID }
        return group
    }()

    /// Used when the process carries no entitlements, such as the command-line
    /// tool or a unit test run.
    static let fallbackAppGroupID = "group.dev.ericbriscoe.tokenwidget"

    public static var usingAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    public static var directory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return ensure(group.appendingPathComponent("TokenWidget", isDirectory: true))
        }
        let fallback = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenWidget", isDirectory: true)
        return ensure(fallback)
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    public static var scanStateURL: URL { directory.appendingPathComponent("scan-state.json") }
    public static var dedupURL: URL { directory.appendingPathComponent("dedup.bin") }
    public static var lockURL: URL { directory.appendingPathComponent("store.lock") }
    /// The previous snapshot, kept because transcripts are pruned by Claude
    /// Code after its retention period. Once that happens the aggregated
    /// history is the only remaining record and cannot be rebuilt.
    public static var backupURL: URL { directory.appendingPathComponent("snapshot.previous.json") }
}

/// Advisory lock so the app's scan and any widget read never interleave.
public struct FileLock {
    private let descriptor: Int32

    public init?(url: URL) {
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
    }

    public func unlock() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func withLock<T>(at url: URL, _ body: () throws -> T) rethrows -> T {
        let lock = FileLock(url: url)
        defer { lock?.unlock() }
        return try body()
    }
}

/// Per-file bookkeeping that lets a rescan read only the bytes appended since
/// last time, instead of re-reading 550 MB of transcripts.
public struct FileScanState: Codable, Sendable, Equatable {
    public var size: Int64
    public var modified: Date
    /// Byte offset of the end of the last *complete* line consumed.
    public var offset: Int64
    /// Detects a file replaced rather than appended to.
    public var inode: UInt64
    public var parser: ParserState?

    public init(size: Int64, modified: Date, offset: Int64, inode: UInt64, parser: ParserState? = nil) {
        self.size = size
        self.modified = modified
        self.offset = offset
        self.inode = inode
        self.parser = parser
    }
}

public struct ScanState: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var files: [String: FileScanState]

    public init(version: Int = ScanState.currentVersion, files: [String: FileScanState] = [:]) {
        self.version = version
        self.files = files
    }
}

/// The set of message identities already counted, so a session that gets
/// resumed or forked into a sidechain is not billed twice.
///
/// Stored as raw little-endian `UInt64`s: at ~50k messages that is 400 KB,
/// against roughly 3 MB for the same identities as JSON strings.
public struct DedupIndex: Sendable {
    private var seen: Set<UInt64>

    public init(seen: Set<UInt64> = []) { self.seen = seen }

    public var count: Int { seen.count }

    /// Returns true when the key had not been seen before.
    public mutating func insert(_ key: UInt64) -> Bool {
        seen.insert(key).inserted
    }

    public func encoded() -> Data {
        var data = Data(capacity: seen.count * 8)
        for key in seen {
            var little = key.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> DedupIndex {
        var keys = Set<UInt64>(minimumCapacity: data.count / 8)
        data.withUnsafeBytes { raw in
            let count = raw.count / 8
            for index in 0..<count {
                let value = raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                keys.insert(UInt64(littleEndian: value))
            }
        }
        return DedupIndex(seen: keys)
    }
}

/// What happened when we tried to read the stored history.
///
/// "Missing" and "unreadable" have to be told apart. Missing means a first run
/// and rebuilding is correct; unreadable means history exists but we could not
/// parse it, and rebuilding would overwrite records whose source transcripts
/// have already been pruned.
public enum SnapshotLoad: Sendable {
    case missing
    case loaded(UsageSnapshot)
    case unreadable(reason: String)
}

/// Reads and writes the shared files, always atomically.
public struct SharedStore: Sendable {
    private let snapshotURL: URL
    private let scanStateURL: URL
    private let dedupURL: URL
    private let lockURL: URL
    private let backupURL: URL

    public init(
        snapshotURL: URL = SharedContainer.snapshotURL,
        scanStateURL: URL = SharedContainer.scanStateURL,
        dedupURL: URL = SharedContainer.dedupURL,
        lockURL: URL = SharedContainer.lockURL,
        backupURL: URL = SharedContainer.backupURL
    ) {
        self.snapshotURL = snapshotURL
        self.scanStateURL = scanStateURL
        self.dedupURL = dedupURL
        self.lockURL = lockURL
        self.backupURL = backupURL
    }

    public func loadSnapshot() -> UsageSnapshot? {
        if case .loaded(let snapshot) = load() { return snapshot }
        return nil
    }

    public func load() -> SnapshotLoad {
        FileLock.withLock(at: lockURL) {
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return .missing }
            guard let data = try? Data(contentsOf: snapshotURL) else {
                return .unreadable(reason: "the history file could not be opened")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data) else {
                return .unreadable(reason: "the history file could not be decoded")
            }
            guard snapshot.version <= UsageSnapshot.currentVersion else {
                return .unreadable(
                    reason: "the history was written by a newer version of Token Widget (format \(snapshot.version))"
                )
            }
            return .loaded(snapshot)
        }
    }

    /// The rolling backup, for recovering from a bad write.
    public func loadBackup() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    public func loadScanState() -> ScanState {
        guard let data = try? Data(contentsOf: scanStateURL),
              let state = try? JSONDecoder().decode(ScanState.self, from: data),
              state.version == ScanState.currentVersion
        else { return ScanState() }
        return state
    }

    public func loadDedupIndex() -> DedupIndex {
        guard let data = try? Data(contentsOf: dedupURL) else { return DedupIndex() }
        return DedupIndex.decode(data)
    }

    public func save(snapshot: UsageSnapshot, scanState: ScanState, dedup: DedupIndex) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let snapshotData = try encoder.encode(snapshot)
        let stateData = try JSONEncoder().encode(scanState)
        let dedupData = dedup.encoded()

        try FileLock.withLock(at: lockURL) {
            // Roll the current history to the backup before replacing it. It is
            // 8 KB per year of usage, and it is the only copy once Claude Code
            // has pruned the transcripts it came from.
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: snapshotURL, to: backupURL)
            }
            try writeAtomically(snapshotData, to: snapshotURL)
            try writeAtomically(stateData, to: scanStateURL)
            try writeAtomically(dedupData, to: dedupURL)
        }
    }

    /// Copies the current history somewhere the user chose, so it survives
    /// deleting the app or its container.
    public func exportHistory(to destination: URL) throws {
        try FileLock.withLock(at: lockURL) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: snapshotURL, to: destination)
        }
    }

    /// Merges a previously exported history into the current one, keeping the
    /// larger figure for any day both files describe.
    public func importHistory(from source: URL) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let incoming = try decoder.decode(UsageSnapshot.self, from: Data(contentsOf: source))
        let current = loadSnapshot() ?? UsageSnapshot()
        let merged = UsageSnapshot.merging(current, incoming)
        try save(snapshot: merged, scanState: loadScanState(), dedup: loadDedupIndex())
        return merged
    }

    /// Clears everything so the next scan starts from an empty history.
    ///
    /// Destructive: any day whose transcript has already been pruned cannot be
    /// recovered by rescanning. The current history is moved to the backup file
    /// first so a mistaken reset is still undoable.
    public func reset() {
        FileLock.withLock(at: lockURL) {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.moveItem(at: snapshotURL, to: backupURL)
            }
            for url in [scanStateURL, dedupURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Puts the backup back, for undoing a reset or a bad write.
    @discardableResult
    public func restoreBackup() -> UsageSnapshot? {
        guard let snapshot = loadBackup() else { return nil }
        try? save(snapshot: snapshot, scanState: ScanState(), dedup: DedupIndex())
        return snapshot
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        // Replace rather than overwrite, so a reader never sees a half-file.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
