import Foundation

/// Native Pi sessions, including child sessions stored beneath the session root.
/// Only assistant usage is decoded; tool output and retained context are ignored.
public struct PiProvider: TranscriptProvider {
    public let provider = Provider.pi
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var roots: [URL] {
        [home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)]
    }

    public func makeParser(file: URL, resuming state: ParserState?) -> TranscriptLineParser {
        Parser(state: state ?? ParserState())
    }

    final class Parser: TranscriptLineParser {
        var state: ParserState
        private let decoder = JSONDecoder()
        private static let usageMarker = Array("\"usage\"".utf8)
        private static let sessionMarker = Array("\"session\"".utf8)

        init(state: ParserState) { self.state = state }

        func mayContainUsage(_ line: Data) -> Bool {
            line.containsSubsequence(Self.usageMarker) || line.containsSubsequence(Self.sessionMarker)
        }

        func record(from line: Data) -> UsageRecord? {
            guard let entry = try? decoder.decode(Entry.self, from: line) else { return nil }
            if entry.type == "session" {
                state.projectPath = entry.cwd
                return nil
            }
            guard entry.type == "message", let message = entry.message,
                  message.role == "assistant", message.stopReason != "pending",
                  let usage = message.usage,
                  let model = message.model, !model.isEmpty, model != "<synthetic>",
                  let vendor = message.provider, !vendor.isEmpty,
                  let id = entry.id, !id.isEmpty,
                  let stamp = entry.timestamp, let timestamp = TimestampParser.parse(stamp)
            else { return nil }

            // Pi's input/cache lanes are already disjoint. Reasoning is part of
            // output, not an additional billable lane. No cache TTL is recorded.
            let counts = TokenCounts(
                input: max(0, usage.input ?? 0),
                cacheWrite5m: max(0, usage.cacheWrite ?? 0),
                cacheRead: max(0, usage.cacheRead ?? 0),
                output: max(0, usage.output ?? 0),
                thinking: min(max(0, usage.reasoning ?? 0), max(0, usage.output ?? 0)),
                messages: 1
            )
            guard counts.billedTotal > 0 else { return nil }
            let normalized = PriceBook.normalize(model)
            let pricingVendor = vendor == "openai-codex" ? "openai" : vendor
            let qualifiedModel = normalized.id.hasPrefix(pricingVendor + "/")
                ? normalized.id : "\(pricingVendor)/\(normalized.id)"
            // Forks preserve entry IDs and timestamps. IDs alone are only 32
            // bits, so include time and model; never use the file/session path.
            return UsageRecord(
                timestamp: timestamp,
                key: ModelKey(provider: .pi, model: qualifiedModel, fast: normalized.fast),
                counts: counts,
                dedupKey: fnv1a64("pi|\(id)|\(stamp)|\(vendor)|\(model)"),
                projectPath: state.projectPath
            )
        }

        private struct Entry: Decodable {
            let type: String?
            let id: String?
            let timestamp: String?
            let cwd: String?
            let message: Message?
        }

        private struct Message: Decodable {
            let role: String?
            let provider: String?
            let model: String?
            let stopReason: String?
            let usage: Usage?
        }

        private struct Usage: Decodable {
            let input: Int?
            let output: Int?
            let cacheRead: Int?
            let cacheWrite: Int?
            let reasoning: Int?
        }
    }
}
