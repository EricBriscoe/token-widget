import Foundation

/// Reads the JSONL session transcripts Claude Code writes under
/// `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`.
///
/// Every assistant message carries a complete `usage` block, which is the only
/// part we care about. Lines of every other type are skipped by a byte test
/// before the JSON decoder ever sees them.
public struct ClaudeCodeProvider: TranscriptProvider {
    public let provider = Provider.claudeCode
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var roots: [URL] {
        [home.appendingPathComponent(".claude/projects", isDirectory: true)]
    }

    public func makeParser(file: URL, resuming state: ParserState?) -> TranscriptLineParser {
        Parser(provider: provider)
    }

    final class Parser: TranscriptLineParser {
        let provider: Provider
        var state = ParserState()

        init(provider: Provider) { self.provider = provider }

        private static let usageMarker = Array("\"usage\"".utf8)
        private static let decoder = JSONDecoder()

        func mayContainUsage(_ line: Data) -> Bool {
            line.containsSubsequence(Self.usageMarker)
        }

        func record(from line: Data) -> UsageRecord? {
            guard let entry = try? Self.decoder.decode(Entry.self, from: line) else { return nil }
            guard let message = entry.message, let usage = message.usage else { return nil }

            // `<synthetic>` marks a placeholder the CLI inserts for an API
            // error. It is not a real request and must not reach the cost math.
            guard let model = message.model, model != "<synthetic>", !model.isEmpty else { return nil }
            guard let stamp = entry.timestamp, let timestamp = TimestampParser.parse(stamp) else { return nil }

            // Older transcripts predate the `cache_creation` breakdown; fall
            // back to the flat total and treat it as 5-minute, the default TTL.
            let write5m: Int
            let write1h: Int
            if let breakdown = usage.cache_creation {
                write5m = breakdown.ephemeral_5m_input_tokens ?? 0
                write1h = breakdown.ephemeral_1h_input_tokens ?? 0
            } else {
                write5m = usage.cache_creation_input_tokens ?? 0
                write1h = 0
            }

            var counts = TokenCounts()
            counts.input = usage.input_tokens ?? 0
            counts.cacheWrite5m = write5m
            counts.cacheWrite1h = write1h
            counts.cacheRead = usage.cache_read_input_tokens ?? 0
            counts.output = usage.output_tokens ?? 0
            counts.thinking = usage.output_tokens_details?.thinking_tokens ?? 0
            counts.webSearches = usage.server_tool_use?.web_search_requests ?? 0
            counts.messages = 1

            let normalized = PriceBook.normalize(model)
            // `speed` is absent on older entries, where standard was the only option.
            let isFast = normalized.fast || usage.speed == "fast"

            return UsageRecord(
                timestamp: timestamp,
                key: ModelKey(provider: provider, model: normalized.id, fast: isFast),
                counts: counts,
                dedupKey: Self.dedupKey(entry: entry, message: message),
                projectPath: entry.cwd
            )
        }

        /// A resumed or forked session replays earlier messages into a new
        /// file, so identity has to come from the request rather than the file
        /// it sits in. A handful of very old entries carry no `requestId`, so
        /// the message ID and then the entry UUID act as fallbacks.
        private static func dedupKey(entry: Entry, message: Message) -> UInt64 {
            if let request = entry.requestId, !request.isEmpty {
                return fnv1a64("\(message.id ?? "")|\(request)")
            }
            if let id = message.id, !id.isEmpty { return fnv1a64("msg|\(id)") }
            return fnv1a64("uuid|\(entry.uuid ?? UUID().uuidString)")
        }

        // Only the fields we consume; JSONDecoder ignores everything else.
        private struct Entry: Decodable {
            let timestamp: String?
            let requestId: String?
            let uuid: String?
            let cwd: String?
            let message: Message?
        }

        private struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        private struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
            let output_tokens_details: OutputDetails?
            let cache_creation: CacheCreation?
            let server_tool_use: ServerToolUse?
            let speed: String?
        }

        private struct OutputDetails: Decodable {
            let thinking_tokens: Int?
        }

        private struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
        }

        private struct ServerToolUse: Decodable {
            let web_search_requests: Int?
        }
    }
}

extension Data {
    /// Naive substring search, which is plenty for a needle this short and
    /// avoids building a String for every line of a 550 MB corpus.
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let limit = count - needle.count
            let first = needle[0]
            var index = 0
            while index <= limit {
                if base[index] == first {
                    var offset = 1
                    while offset < needle.count, base[index + offset] == needle[offset] { offset += 1 }
                    if offset == needle.count { return true }
                }
                index += 1
            }
            return false
        }
    }
}
