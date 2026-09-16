import Foundation

/// Published rates for every model OpenRouter lists, cached on disk.
///
/// This is the primary price source. It is a public, unauthenticated list of
/// list prices. The request carries no usage data and no identifier, and it is
/// the only network call the app makes.
///
/// Keyed by OpenRouter's full `vendor/model` ID rather than the bare model name,
/// because leaf names are not unique across vendors: `gpt-4o-mini` and a dozen
/// others appear under more than one. Resolving with the harness that produced
/// the record keeps that unambiguous, and a leaf that stays ambiguous resolves
/// to no price rather than to the wrong vendor's.
public struct PriceCatalog: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var fetchedAt: Date
    /// Keyed by `vendor/model`, e.g. `anthropic/claude-opus-5`.
    public var models: [String: ModelPrice]

    public init(
        version: Int = PriceCatalog.currentVersion,
        fetchedAt: Date,
        models: [String: ModelPrice]
    ) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.models = models
    }

    /// Which OpenRouter vendor a harness's models live under.
    static func vendor(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: return "anthropic"
        case .codex: return "openai"
        case .pi: return "" // Pi stores a fully qualified vendor/model ID.
        }
    }

    /// Vendors tried when the caller gives no hint, most likely first.
    private static let fallbackVendors = ["anthropic", "openai"]

    public func price(for id: String, provider: Provider?) -> ModelPrice? {
        // Transcripts spell point releases with a dash (`claude-fable-5-1`); the
        // feed keys them with a dot (`anthropic/claude-fable-5.1`). Try the exact
        // id first, then the dotted spelling of a trailing `-N-M` version.
        for candidate in PriceCatalog.spellings(of: id) {
            if let hit = price(forExact: candidate, provider: provider) { return hit }
        }
        return nil
    }

    static func spellings(of id: String) -> [String] {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let minor = parts.last, !minor.isEmpty, minor.allSatisfy(\.isNumber),
              let major = parts.dropLast().last, !major.isEmpty, major.allSatisfy(\.isNumber)
        else { return [id] }
        let dotted = parts.dropLast(2).joined(separator: "-") + "-\(major).\(minor)"
        return [id, dotted]
    }

    private func price(forExact id: String, provider: Provider?) -> ModelPrice? {
        if provider == .pi { return models[id] }
        if let provider, let hit = models["\(PriceCatalog.vendor(for: provider))/\(id)"] {
            return hit
        }
        for vendor in PriceCatalog.fallbackVendors {
            if let hit = models["\(vendor)/\(id)"] { return hit }
        }
        // No vendor hint matched. Accept a leaf name only when exactly one
        // vendor claims it, so an ambiguous name is reported as unpriced
        // instead of being billed at some other vendor's rate.
        let suffix = "/\(id)"
        var found: ModelPrice?
        for (key, price) in models where key.hasSuffix(suffix) {
            if found != nil { return nil }
            found = price
        }
        return found
    }

    public func isStale(now: Date = Date(), maxAge: TimeInterval = PriceCatalog.maxAge) -> Bool {
        now.timeIntervalSince(fetchedAt) >= maxAge
    }

    /// Rates move rarely; once a day is plenty and keeps the app effectively
    /// offline.
    public static let maxAge: TimeInterval = 24 * 60 * 60
}

// MARK: - OpenRouter

/// Fetches the OpenRouter model list and folds it into a `PriceCatalog`.
public struct OpenRouterPriceService: Sendable {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!

    private let url: URL
    private let cacheURL: URL
    private let session: URLSession

    public init(
        url: URL = OpenRouterPriceService.endpoint,
        cacheURL: URL = SharedContainer.pricesURL,
        session: URLSession = .shared
    ) {
        self.url = url
        self.cacheURL = cacheURL
        self.session = session
    }

    /// The catalog on disk, if it parses.
    public func cached() -> PriceCatalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let catalog = try? decoder.decode(PriceCatalog.self, from: data),
              catalog.version <= PriceCatalog.currentVersion
        else { return nil }
        return catalog
    }

    /// Returns the cached catalog when it is still fresh, otherwise fetches.
    ///
    /// A failed fetch keeps whatever was already cached. Stale published rates
    /// are a far smaller error than dropping every model to unpriced because
    /// the network was down.
    @discardableResult
    public func refreshIfNeeded(now: Date = Date(), force: Bool = false) async -> PriceCatalog? {
        let existing = cached()
        if !force, let existing, !existing.isStale(now: now) { return existing }

        guard let fetched = await fetch(now: now) else { return existing }
        try? write(fetched)
        return fetched
    }

    func fetch(now: Date = Date()) async -> PriceCatalog? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return Self.parse(data, now: now)
    }

    func write(_ catalog: PriceCatalog) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(catalog)
        let temporary = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: temporary)
    }

    // MARK: Parsing

    /// OpenRouter states rates in dollars per single token, as strings.
    static func parse(_ data: Data, now: Date) -> PriceCatalog? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        var models: [String: ModelPrice] = [:]
        models.reserveCapacity(payload.data.count)

        for entry in payload.data {
            // `:batch`, `:free` and `:thinking` are separately-priced variants
            // of a model that is already listed under its bare ID.
            guard !entry.id.contains(":") else { continue }
            guard let price = entry.pricing.modelPrice() else { continue }
            models[entry.id.lowercased()] = price
        }

        guard !models.isEmpty else { return nil }
        return PriceCatalog(fetchedAt: now, models: models)
    }

    private struct Payload: Decodable {
        let data: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let pricing: Pricing
    }

    private struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
        let input_cache_read: String?
        let input_cache_write: String?
        let input_cache_write_1h: String?
        let web_search: String?

        /// Per-token dollar strings into per-million-token rates.
        ///
        /// A missing or unparseable field is left nil so `ModelPrice` fills it
        /// with the vendor default rather than with zero. A model quoting no
        /// input *and* no output rate is skipped entirely: free and
        /// variably-priced entries would otherwise read as genuinely $0 usage.
        func modelPrice() -> ModelPrice? {
            guard let input = Self.perMillion(prompt), let output = Self.perMillion(completion) else { return nil }
            guard input > 0 || output > 0 else { return nil }

            return ModelPrice(
                input: input,
                output: output,
                cacheRead: Self.perMillion(input_cache_read),
                cacheWrite5m: Self.perMillion(input_cache_write),
                // OpenAI has no 1-hour cache tier. Leaving it nil lets
                // ModelPrice fall back to Anthropic's 2x multiplier, which only
                // ever applies to counts an Anthropic transcript produced.
                cacheWrite1h: Self.perMillion(input_cache_write_1h),
                webSearchPerThousandRequests: Self.perThousand(web_search)
                    ?? ModelPrice.defaultWebSearchPerThousandRequests
            )
        }

        private static func perMillion(_ raw: String?) -> Double? {
            guard let raw, let value = Double(raw), value >= 0 else { return nil }
            return value * 1_000_000
        }

        private static func perThousand(_ raw: String?) -> Double? {
            guard let raw, let value = Double(raw), value >= 0 else { return nil }
            return value * 1_000
        }
    }
}
