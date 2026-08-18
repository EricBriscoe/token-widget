import Foundation

/// Reads Codex CLI rollout transcripts from `~/.codex/sessions`.
///
/// Verified against a 537-file corpus (40,537 `token_count` events) covering
/// `gpt-5.1-codex-max` through `gpt-5.6-sol`. The parser stays strict: anything
/// it does not recognize is skipped rather than guessed at, so an unexpected
/// format shows up as missing usage instead of wrong numbers.
///
/// Codex reports OpenAI-style counts, where `cached_input_tokens` and
/// `cache_write_input_tokens` are *subsets* of `input_tokens`, and
/// `reasoning_output_tokens` a subset of `output_tokens`. Those are unpacked
/// into the same shape as Claude's so both chart together.
public struct CodexProvider: TranscriptProvider {
    public let provider = Provider.codex
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Archived sessions are ordinary rollouts Codex has moved aside; they are
    /// still usage that was billed.
    public var roots: [URL] {
        [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
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
        private static let searchMarker = Array("web_search_call".utf8)
        private static let decoder = JSONDecoder()

        func mayContainUsage(_ line: Data) -> Bool {
            // Model announcements have to pass the filter too, since they carry
            // the state the token lines depend on.
            line.containsSubsequence(Self.tokenMarker)
                || line.containsSubsequence(Self.modelMarker)
                || line.containsSubsequence(Self.searchMarker)
        }

        func record(from line: Data) -> UsageRecord? {
            guard let entry = try? Self.decoder.decode(Entry.self, from: line) else { return nil }

            // Remember the model from whichever line last declared one.
            if let model = entry.payload?.model ?? entry.model, !model.isEmpty {
                state.lastModel = model
            }

            switch entry.payload?.type ?? entry.type {
            case "token_count": return tokenRecord(from: entry)
            case "web_search_call": return searchRecord(from: entry)
            default: return nil
            }
        }

        private func tokenRecord(from entry: Entry) -> UsageRecord? {
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

            let input = usage.input_tokens ?? 0
            let cached = usage.cached_input_tokens ?? 0
            let written = usage.cache_write_input_tokens ?? 0

            var counts = TokenCounts()
            // OpenAI counts cached and freshly-written tokens inside the input
            // total; split them out so each lane means the same thing across
            // providers and gets its own rate.
            counts.input = max(0, input - cached - written)
            counts.cacheRead = cached
            counts.cacheWrite5m = written
            counts.output = usage.output_tokens ?? 0
            counts.thinking = usage.reasoning_output_tokens ?? 0
            counts.messages = 1

            return UsageRecord(
                timestamp: timestamp,
                key: ModelKey(provider: provider, model: currentModel, fast: false),
                counts: counts,
                dedupKey: identity("turn", stamp, "\(input)|\(counts.output)|\(cached)|\(written)"),
                projectPath: entry.payload?.cwd ?? entry.cwd
            )
        }

        /// A server-side web search, billed per request rather than per token.
        ///
        /// Counted from the `web_search_call` response item rather than the
        /// `web_search_end` UI event, because only the response item is part of
        /// the conversation that gets replayed on resume; counting both would
        /// bill each search twice. A call that fans out into several queries is
        /// counted once, matching how the rate card is quoted per call.
        private func searchRecord(from entry: Entry) -> UsageRecord? {
            guard let stamp = entry.timestamp, let timestamp = TimestampParser.parse(stamp) else { return nil }

            var counts = TokenCounts()
            counts.webSearches = 1

            return UsageRecord(
                timestamp: timestamp,
                key: ModelKey(provider: provider, model: currentModel, fast: false),
                counts: counts,
                dedupKey: identity("search", stamp, entry.payload?.action?.query ?? ""),
                projectPath: entry.payload?.cwd ?? entry.cwd
            )
        }

        /// Codex states the model on a `turn_context` line, which normally
        /// precedes the turn's token counts. Old CLI builds (0.77.0) wrote
        /// `/review` sessions that never name a model on any line, and the
        /// parser only ever moves forward, so those counts have nothing to
        /// attribute to. They get the reserved ID rather than a plausible guess
        /// or a literal "unknown", which the price book would then report as a
        /// model whose rate is merely missing.
        private var currentModel: String {
            guard let model = state.lastModel else { return ModelKey.unattributed }
            return PriceBook.normalize(model).id
        }

        /// Identity for deduplication.
        ///
        /// Deliberately excludes the file path. Resuming or forking a Codex
        /// session writes a *new* rollout file that replays the earlier turns
        /// verbatim, so a path-scoped key counts those turns once per file. In
        /// this corpus 122 turn identities appear in two files each. A
        /// millisecond timestamp plus the exact token split is what makes two
        /// records the same turn.
        private func identity(_ kind: String, _ stamp: String, _ detail: String) -> UInt64 {
            fnv1a64("codex|\(kind)|\(stamp)|\(detail)")
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
            let action: Action?
        }

        private struct Action: Decodable {
            let query: String?
        }

        private struct Info: Decodable {
            let total_token_usage: Totals?
            let last_token_usage: Totals?
        }

        struct Totals: Decodable {
            var input_tokens: Int?
            var cached_input_tokens: Int?
            var cache_write_input_tokens: Int?
            var output_tokens: Int?
            var reasoning_output_tokens: Int?

            init(
                input_tokens: Int? = nil,
                cached_input_tokens: Int? = nil,
                cache_write_input_tokens: Int? = nil,
                output_tokens: Int? = nil,
                reasoning_output_tokens: Int? = nil
            ) {
                self.input_tokens = input_tokens
                self.cached_input_tokens = cached_input_tokens
                self.cache_write_input_tokens = cache_write_input_tokens
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
                    cache_write_input_tokens: max(
                        0, (cache_write_input_tokens ?? 0) - (other.cache_write_input_tokens ?? 0)
                    ),
                    output_tokens: max(0, (output_tokens ?? 0) - (other.output_tokens ?? 0)),
                    reasoning_output_tokens: max(
                        0, (reasoning_output_tokens ?? 0) - (other.reasoning_output_tokens ?? 0)
                    )
                )
            }
        }
    }
}
