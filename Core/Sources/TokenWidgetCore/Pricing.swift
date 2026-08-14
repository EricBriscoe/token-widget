import Foundation

/// Per-million-token rates for one model on one day.
///
/// Cache rates are derived from the input rate rather than stored separately:
/// a 5-minute cache write bills at 1.25x input, a 1-hour write at 2x, and a
/// cache read at 0.1x.
public struct ModelPrice: Sendable, Hashable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(input: Double, output: Double) {
        inputPerMTok = input
        outputPerMTok = output
    }

    public var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    public var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }
    public var cacheReadPerMTok: Double { inputPerMTok * 0.1 }

    /// Server-side web search, billed per request rather than per token.
    public static let webSearchPerThousandRequests = 10.0

    public func cost(for counts: TokenCounts) -> Double {
        var tokens: Double = 0
        tokens += Double(counts.input) * inputPerMTok
        tokens += Double(counts.cacheWrite5m) * cacheWrite5mPerMTok
        tokens += Double(counts.cacheWrite1h) * cacheWrite1hPerMTok
        tokens += Double(counts.cacheRead) * cacheReadPerMTok
        tokens += Double(counts.output) * outputPerMTok

        let searches = Double(counts.webSearches) / 1_000.0
        let search = searches * Self.webSearchPerThousandRequests
        return tokens / 1_000_000.0 + search
    }
}

/// What the price book knows about a given model.
public enum PriceLookup: Sendable, Equatable {
    /// A published rate applies.
    case priced(ModelPrice)
    /// Runs on the user's own hardware, so there is no per-token charge.
    case local
    /// No published rate is on file. Cost is reported as zero and the model is
    /// surfaced in the UI, so a missing rate never masquerades as $0 of usage.
    case unknown
}

/// Published Anthropic list prices, keyed by normalized model ID.
///
/// Rates only cover models with a documented public price. Anything else
/// resolves to `.unknown` on purpose; inventing a plausible number would put
/// a wrong total on screen with no way to tell.
public struct PriceBook: Sendable {
    struct Tier: Sendable {
        /// Inclusive first day this rate applies, or nil for "always was".
        let from: DayID?
        /// Inclusive last day this rate applies, or nil for "still current".
        let through: DayID?
        let price: ModelPrice

        func covers(_ day: DayID) -> Bool {
            if let from, day < from { return false }
            if let through, through < day { return false }
            return true
        }
    }

    private let standard: [String: [Tier]]
    private let fast: [String: [Tier]]

    public static let current = PriceBook(
        standard: [
            // Frontier tier
            "claude-fable-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 10, output: 50))],
            "claude-mythos-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 10, output: 50))],
            "claude-mythos-preview": [Tier(from: nil, through: nil, price: ModelPrice(input: 10, output: 50))],

            // Opus tier
            "claude-opus-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 5, output: 25))],
            "claude-opus-4-8": [Tier(from: nil, through: nil, price: ModelPrice(input: 5, output: 25))],
            "claude-opus-4-7": [Tier(from: nil, through: nil, price: ModelPrice(input: 5, output: 25))],
            "claude-opus-4-6": [Tier(from: nil, through: nil, price: ModelPrice(input: 5, output: 25))],

            // Sonnet tier. Sonnet 5 launched on introductory pricing that runs
            // through 2026-08-31; days on either side of that bill differently.
            "claude-sonnet-5": [
                Tier(
                    from: nil,
                    through: DayID(year: 2026, month: 8, day: 31),
                    price: ModelPrice(input: 2, output: 10)
                ),
                Tier(
                    from: DayID(year: 2026, month: 9, day: 1),
                    through: nil,
                    price: ModelPrice(input: 3, output: 15)
                )
            ],
            "claude-sonnet-4-6": [Tier(from: nil, through: nil, price: ModelPrice(input: 3, output: 15))],

            // Haiku tier
            "claude-haiku-4-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 1, output: 5))]
        ],
        fast: [
            // Fast mode is a research preview on Opus 5 at premium rates.
            "claude-opus-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 10, output: 50))]
        ]
    )

    init(standard: [String: [Tier]], fast: [String: [Tier]]) {
        self.standard = standard
        self.fast = fast
    }

    /// Resolve the rate for a model on a specific day.
    ///
    /// A fast-mode request with no published fast rate falls back to the
    /// standard rate; `isApproximate` reports that so the UI can say so.
    public func lookup(model: String, fast isFast: Bool, on day: DayID) -> (price: PriceLookup, isApproximate: Bool) {
        let id = PriceBook.normalize(model).id
        if PriceBook.isLocalModel(id) { return (.local, false) }

        if isFast, let tiers = fast[id], let tier = tiers.first(where: { $0.covers(day) }) {
            return (.priced(tier.price), false)
        }
        guard let tiers = standard[id], let tier = tiers.first(where: { $0.covers(day) }) else {
            return (.unknown, false)
        }
        return (.priced(tier.price), isFast)
    }

    public func cost(for counts: TokenCounts, model: String, fast: Bool, on day: DayID) -> Double {
        switch lookup(model: model, fast: fast, on: day).price {
        case .priced(let price): return price.cost(for: counts)
        case .local, .unknown: return 0
        }
    }

    /// A model identifier with a slash is a Hugging Face style repo path, which
    /// means it is being served locally rather than billed per token.
    public static func isLocalModel(_ id: String) -> Bool { id.contains("/") }

    /// Reduce the many spellings of a model ID to the one the table is keyed on.
    ///
    /// Handles the Bedrock `anthropic.` prefix, context-window suffixes such as
    /// `[1m]`, dated snapshots like `-20251001`, and the retired `-fast` model
    /// strings that predate the `speed` request parameter.
    public static func normalize(_ raw: String) -> (id: String, fast: Bool) {
        var id = raw.lowercased().trimmingCharacters(in: .whitespaces)

        if let bracket = id.firstIndex(of: "[") { id = String(id[id.startIndex..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[id.startIndex..<at]) }
        for prefix in ["anthropic.", "us.anthropic.", "eu.anthropic."] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }

        var fast = false
        if id.hasSuffix("-fast") {
            fast = true
            id.removeLast("-fast".count)
        }

        // Trailing 8-digit date snapshot: claude-haiku-4-5-20251001.
        if let dash = id.lastIndex(of: "-") {
            let tail = id[id.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) {
                id = String(id[id.startIndex..<dash])
            }
        }

        return (id, fast)
    }
}
