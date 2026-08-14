import Foundation

/// Reads Codex CLI rollout transcripts from `~/.codex/sessions`.
///
/// **Unverified against real data.** This machine has `~/.codex` but no
/// recorded sessions, so the shapes below are written from Codex's documented
/// rollout format and have not been checked against an actual transcript. The
/// parser is deliberately strict: anything it does not recognize is skipped
/// rather than guessed at, so an unexpected format shows up as "no Codex usage"
/// instead of wrong numbers.
///
/// Codex reports OpenAI-style counts, where `cached_input_tokens` is a *subset*
/// of `input_tokens` and `reasoning_output_tokens` a subset of `output_tokens`.
/// Those are unpacked into the same shape as Claude's so both chart together.
public struct CodexProvider: TranscriptProvider {
    public let provider = Provider.codex
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var roots: [URL] {
        [home.appendingPathComponent(".codex/sessions", isDirectory: true)]
    }

    public func makeParser(file: URL, resuming state: ParserState?) -> TranscriptLineParser {
        Parser(provider: provider, file: file, state: state ?? ParserState())
    }

    final class Parser: TranscriptLineParser {
        let provider: Provider
        let filePath: String
        var state: ParserState
        /// Set when a file only reports cumulative totals, so each event can be
        /// turned back into a per-turn delta.
        private var lastCumulative: Totals?

        init(provider: Provider, file: URL, state: ParserState) {
            self.provider = provider
            self.filePath = file.path
            self.state = state
        }

        private static let tokenMarker = Array("token_count".utf8)
        private static let modelMarker = Array("\"model\"".utf8)
        private static let decoder = JSONDecoder()

        func mayContainUsage(_ line: Data) -> Bool {
            // Model announcements have to pass the filter too, since they carry
            // the state the token lines depend on.
            line.containsSubsequence(Self.tokenMarker) || line.containsSubsequence(Self.modelMarker)
        }

        func record(from line: Data) -> UsageRecord? {
            guard let entry = try? Self.decoder.decode(Entry.self, from: line) else { return nil }

            // Remember the model from whichever line last declared one.
            if let model = entry.payload?.model ?? entry.model, !model.isEmpty {
                state.lastModel = model
            }

            let kind = entry.payload?.type ?? entry.type
            guard kind == "token_count" else { return nil }
            guard let info = entry.payload?.info ?? entry.info else { return nil }

            let usage: Totals
            if let last = info.last_token_usage {
                usage = last
            } else if let total = info.total_token_usage {
                // Only cumulative figures available: difference them so the
                // running total is not re-added on every event.
                let previous = lastCumulative ?? Totals()
                lastCumulative = total
                usage = total.subtracting(previous)
            } else {
                return nil
            }

            guard usage.hasAnyTokens else { return nil }
            guard let stamp = entry.timestamp, let timestamp = TimestampParser.parse(stamp) else { return nil }

            let cached = usage.cached_input_tokens ?? 0
            let input = usage.input_tokens ?? 0

            var counts = TokenCounts()
            // OpenAI counts cached tokens inside the input total; split them so
            // the cache-read lane means the same thing across providers.
            counts.input = max(0, input - cached)
            counts.cacheRead = cached
            counts.output = usage.output_tokens ?? 0
            counts.thinking = usage.reasoning_output_tokens ?? 0
            counts.messages = 1

            let model = state.lastModel ?? "unknown"
            let identity = "\(filePath)|\(stamp)|\(input)|\(counts.output)|\(cached)"

            return UsageRecord(
                timestamp: timestamp,
                key: ModelKey(provider: provider, model: PriceBook.normalize(model).id, fast: false),
                counts: counts,
                dedupKey: fnv1a64(identity),
                projectPath: entry.payload?.cwd ?? entry.cwd
            )
        }

        private struct Entry: Decodable {
            let timestamp: String?
            let type: String?
            let model: String?
            let cwd: String?
            let info: Info?
            let payload: Payload?
        }

        private struct Payload: Decodable {
            let type: String?
            let model: String?
            let cwd: String?
            let info: Info?
        }

        private struct Info: Decodable {
            let total_token_usage: Totals?
            let last_token_usage: Totals?
        }

        struct Totals: Decodable {
            var input_tokens: Int?
            var cached_input_tokens: Int?
            var output_tokens: Int?
            var reasoning_output_tokens: Int?

            init(
                input_tokens: Int? = nil,
                cached_input_tokens: Int? = nil,
                output_tokens: Int? = nil,
                reasoning_output_tokens: Int? = nil
            ) {
                self.input_tokens = input_tokens
                self.cached_input_tokens = cached_input_tokens
                self.output_tokens = output_tokens
                self.reasoning_output_tokens = reasoning_output_tokens
            }

            var hasAnyTokens: Bool {
                (input_tokens ?? 0) > 0 || (output_tokens ?? 0) > 0
            }

            func subtracting(_ other: Totals) -> Totals {
                Totals(
                    input_tokens: max(0, (input_tokens ?? 0) - (other.input_tokens ?? 0)),
                    cached_input_tokens: max(0, (cached_input_tokens ?? 0) - (other.cached_input_tokens ?? 0)),
                    output_tokens: max(0, (output_tokens ?? 0) - (other.output_tokens ?? 0)),
                    reasoning_output_tokens: max(
                        0, (reasoning_output_tokens ?? 0) - (other.reasoning_output_tokens ?? 0)
                    )
                )
            }
        }
    }
}
