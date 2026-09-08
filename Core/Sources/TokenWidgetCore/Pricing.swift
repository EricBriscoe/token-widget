import Foundation

/// Per-million-token rates for one model on one day.
///
/// Every lane is stored explicitly rather than derived, because the two vendors
/// disagree about how caching is billed: Anthropic charges a premium to *write*
/// a cache entry (1.25x input on the 5-minute TTL, 2x on the 1-hour one), while
/// most OpenAI models charge nothing to write and only discount the read. When a
/// source states just the input and output rates, the initializer fills the
/// cache lanes in with Anthropic's published multipliers.
public struct ModelPrice: Sendable, Hashable, Codable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double
    /// Server-side web search, billed per request rather than per token.
    public let webSearchPerThousandRequests: Double

    /// The rate both vendors currently charge for a server-side web search.
    public static let defaultWebSearchPerThousandRequests = 10.0

    public init(
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        cacheWrite5m: Double? = nil,
        cacheWrite1h: Double? = nil,
        webSearchPerThousandRequests: Double = ModelPrice.defaultWebSearchPerThousandRequests
    ) {
        inputPerMTok = input
        outputPerMTok = output
        cacheReadPerMTok = cacheRead ?? input * 0.1
        cacheWrite5mPerMTok = cacheWrite5m ?? input * 1.25
        cacheWrite1hPerMTok = cacheWrite1h ?? input * 2.0
        self.webSearchPerThousandRequests = webSearchPerThousandRequests
    }

    public func cost(for counts: TokenCounts) -> Double {
        var tokens: Double = 0
        tokens += Double(counts.input) * inputPerMTok
        tokens += Double(counts.cacheWrite5m) * cacheWrite5mPerMTok
        tokens += Double(counts.cacheWrite1h) * cacheWrite1hPerMTok
        tokens += Double(counts.cacheRead) * cacheReadPerMTok
        tokens += Double(counts.output) * outputPerMTok

        let searches = Double(counts.webSearches) / 1_000.0
        let search = searches * webSearchPerThousandRequests
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
    /// The transcript never named a model, so there is nothing to look a rate
    /// up by. Reported separately from `.unknown`: that is a model we know the
    /// name of and have no rate for, this is a hole in what the harness wrote.
    case unattributed
}

/// Where a rate came from, so the UI can say how current the number is.
public enum PriceSource: Sendable, Equatable {
    /// Fetched from OpenRouter, which tracks published list prices for both
    /// vendors and picks up new models without a code change.
    case catalog
    /// A rate compiled into the app. Used for historical tiers OpenRouter
    /// cannot express, and for models it does not list.
    case builtin
    case none
}

/// Resolves what a model cost on a given day.
///
/// Rates come from OpenRouter's public model list, refreshed at most daily, so a
/// model released after this build still prices correctly. Two things that feed
/// cannot supply are compiled in as fallbacks:
///
/// - **Dated tiers.** OpenRouter reports today's rate only. Repricing a day from
///   six months ago at today's rate would silently rewrite history, so a tier
///   with explicit date bounds always wins over the feed.
/// - **Unlisted models.** OpenRouter does not carry every model these harnesses
///   run. Anything missing from the feed falls through to the built-in rate.
///
/// A model neither source knows resolves to `.unknown` on purpose; inventing a
/// plausible number would put a wrong total on screen with no way to tell.
public struct PriceBook: Sendable {
    struct Tier: Sendable {
        /// Inclusive first day this rate applies, or nil for "always was".
        let from: DayID?
        /// Inclusive last day this rate applies, or nil for "still current".
        let through: DayID?
        let price: ModelPrice

        /// A tier that names a date is a historical fact the live feed does not
        /// carry, so it outranks the feed rather than falling back to it.
        var isDated: Bool { from != nil || through != nil }

        func covers(_ day: DayID) -> Bool {
            if let from, day < from { return false }
            if let through, through < day { return false }
            return true
        }
    }

    private let standard: [String: [Tier]]
    private let fast: [String: [Tier]]
    private let catalog: PriceCatalog?

    /// Built-in rates, used when the catalog has no entry and to keep a first
    /// run useful before the first fetch completes.
    ///
    /// Deliberately short. Anything OpenRouter lists does not need to be here,
    /// so this table only carries dated tiers and the models the feed omits.
    /// Verified absent from OpenRouter as of 2026-08-14: every `claude-` entry
    /// below except `fable-5`, `opus-5` and `sonnet-5`.
    public static let builtIn = PriceBook(
        standard: [
            // https://developers.openai.com/api/docs/models/gpt-6-astra
            // Standard rates; daily totals cannot resolve the >272K input tier.
            "gpt-6-astra": [Tier(from: nil, through: nil, price: ModelPrice(
                input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 12.5
            ))],
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
            // Both tiers are dated, so they outrank the live feed's single
            // current rate and old days keep the billed price.
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
            "gpt-6-astra": [Tier(from: nil, through: nil, price: ModelPrice(
                input: 20, output: 100, cacheRead: 2, cacheWrite5m: 25, cacheWrite1h: 25
            ))],
            // Fast mode is a research preview on Opus 5 at premium rates.
            "claude-opus-5": [Tier(from: nil, through: nil, price: ModelPrice(input: 10, output: 50))]
        ],
        catalog: nil
    )

    /// The built-in rates with no catalog attached. Callers that have a fetched
    /// catalog should use `withCatalog(_:)`.
    public static let current = PriceBook.builtIn

    /// The built-in rates resolved against whatever catalog is cached on disk.
    ///
    /// Read on each access so a widget timeline sees catalog refreshes even
    /// when the extension process stays alive.
    public static var shared: PriceBook {
        PriceBook.builtIn.withCatalog(OpenRouterPriceService().cached())
    }

    init(standard: [String: [Tier]], fast: [String: [Tier]], catalog: PriceCatalog?) {
        self.standard = standard
        self.fast = fast
        self.catalog = catalog
    }

    /// The same book resolving against a fetched catalog.
    public func withCatalog(_ catalog: PriceCatalog?) -> PriceBook {
        PriceBook(standard: standard, fast: fast, catalog: catalog)
    }

    /// When the attached catalog was fetched, if there is one.
    public var catalogFetchedAt: Date? { catalog?.fetchedAt }
    public var catalogModelCount: Int { catalog?.models.count ?? 0 }

    /// Resolve the rate for a model on a specific day.
    ///
    /// `provider` disambiguates the catalog: OpenRouter carries the same leaf
    /// name under more than one vendor (`openai/gpt-4o-mini` and others), so the
    /// harness that produced the record picks the right one.
    ///
    /// A fast-mode request with no published fast rate falls back to the
    /// standard rate; `isApproximate` reports that so the UI can say so.
    public func lookup(
        model: String,
        provider: Provider? = nil,
        fast isFast: Bool,
        on day: DayID
    ) -> (price: PriceLookup, isApproximate: Bool, source: PriceSource) {
        if ModelKey.isUnattributed(model) { return (.unattributed, false, .none) }
        let id = PriceBook.normalize(model).id
        if provider == .pi {
            // Pi can call multiple vendors. Preserve that identity rather than
            // treating every vendor/model ID as local or guessing a leaf rate.
            for (prefix, source) in [("openai/", Provider.codex), ("anthropic/", Provider.claudeCode)] {
                if id.hasPrefix(prefix) {
                    let result = lookup(model: String(id.dropFirst(prefix.count)), provider: source, fast: isFast, on: day)
                    return (result.price, true, result.source)
                }
            }
            if let rate = catalog?.price(for: id, provider: .pi) {
                return (.priced(rate), true, .catalog)
            }
            return (.unknown, false, .none)
        }
        if PriceBook.isLocalModel(id) { return (.local, false, .none) }
        // The stored daily counts do not retain request sizes needed for
        // Astra's long-context surcharge.
        let hasContextTier = id == "gpt-6-astra"

        if isFast, let price = resolve(id: id, table: fast, catalogID: "\(id)-fast", provider: provider, day: day) {
            return (.priced(price.rate), hasContextTier, price.source)
        }
        guard let price = resolve(id: id, table: standard, catalogID: id, provider: provider, day: day) else {
            return (.unknown, false, .none)
        }
        return (.priced(price.rate), isFast || hasContextTier, price.source)
    }

    /// Dated built-in tier, then the catalog, then an open-ended built-in tier.
    private func resolve(
        id: String,
        table: [String: [Tier]],
        catalogID: String,
        provider: Provider?,
        day: DayID
    ) -> (rate: ModelPrice, source: PriceSource)? {
        let tiers = table[id] ?? []
        if let dated = tiers.first(where: { $0.isDated && $0.covers(day) }) {
            return (dated.price, .builtin)
        }
        if let fromCatalog = catalog?.price(for: catalogID, provider: provider) {
            return (fromCatalog, .catalog)
        }
        if let open = tiers.first(where: { $0.covers(day) }) {
            return (open.price, .builtin)
        }
        return nil
    }

    public func cost(for counts: TokenCounts, model: String, provider: Provider? = nil, fast: Bool, on day: DayID) -> Double {
        switch lookup(model: model, provider: provider, fast: fast, on: day).price {
        case .priced(let price): return price.cost(for: counts)
        case .local, .unknown, .unattributed: return 0
        }
    }

    /// A model served from the user's own hardware, which costs nothing per
    /// token. Two spellings show up: a Hugging Face repo path like
    /// `unsloth/Qwen3.6-27B-GGUF`, and an Ollama `name:tag` such as
    /// `gpt-oss:20b`. No hosted model ID from either vendor uses `/` or `:`.
    public static func isLocalModel(_ id: String) -> Bool {
        id.contains("/") || id.contains(":")
    }

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
