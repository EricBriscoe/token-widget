import Foundation

/// An LLM harness whose local logs we can read.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// Token counts for one bucket. `thinking` is a *subset* of `output` and is
/// tracked for display only; adding it to a total would double-count.
public struct TokenCounts: Codable, Sendable, Hashable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int
    public var thinking: Int
    public var webSearches: Int
    public var messages: Int

    public init(
        input: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        thinking: Int = 0,
        webSearches: Int = 0,
        messages: Int = 0
    ) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.thinking = thinking
        self.webSearches = webSearches
        self.messages = messages
    }

    /// Every token the API bills for. Thinking is excluded because it is
    /// already counted inside `output`.
    public var billedTotal: Int {
        input + cacheWrite5m + cacheWrite1h + cacheRead + output
    }

    /// Tokens that entered the model as context, however they were priced.
    public var totalInput: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
        lhs.output += rhs.output
        lhs.thinking += rhs.thinking
        lhs.webSearches += rhs.webSearches
        lhs.messages += rhs.messages
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        var copy = lhs
        copy += rhs
        return copy
    }

    // Short keys: a snapshot holds one of these per model per day, so the
    // field names dominate the encoded size.
    private enum CodingKeys: String, CodingKey {
        case input = "i"
        case cacheWrite5m = "w5"
        case cacheWrite1h = "w1"
        case cacheRead = "r"
        case output = "o"
        case thinking = "t"
        case webSearches = "s"
        case messages = "m"
    }
}

/// Identifies a distinct billing lane: the same model at standard and fast
/// speed is priced differently, so the two are never merged.
public struct ModelKey: Codable, Sendable, Hashable {
    public let provider: Provider
    public let model: String
    public let fast: Bool

    public init(provider: Provider, model: String, fast: Bool = false) {
        self.provider = provider
        self.model = model
        self.fast = fast
    }

    /// Human-facing name: `claude-opus-5` becomes `Opus 5`.
    public var displayName: String {
        let base = ModelKey.prettify(model)
        return fast ? "\(base) (fast)" : base
    }

    static func prettify(_ model: String) -> String {
        // Local models arrive as `org/Model-Name-GGUF`; keep the leaf.
        if let slash = model.lastIndex(of: "/") {
            return String(model[model.index(after: slash)...])
        }
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

/// One billable assistant message, already normalized.
public struct UsageRecord: Sendable {
    public let timestamp: Date
    public let key: ModelKey
    public let counts: TokenCounts
    /// Stable hash of the request/message identity, used to drop the copies
    /// that appear when a session is resumed or forked into a sidechain.
    public let dedupKey: UInt64
    public let projectPath: String?

    public init(
        timestamp: Date,
        key: ModelKey,
        counts: TokenCounts,
        dedupKey: UInt64,
        projectPath: String?
    ) {
        self.timestamp = timestamp
        self.key = key
        self.counts = counts
        self.dedupKey = dedupKey
        self.projectPath = projectPath
    }
}

/// A calendar day encoded as `yyyymmdd`, which sorts correctly as an integer
/// and does not drift when the machine changes time zone.
public struct DayID: Codable, Sendable, Hashable, Comparable, RawRepresentable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = (c.year ?? 1970) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }

    public init(year: Int, month: Int, day: Int) {
        rawValue = year * 10_000 + month * 100 + day
    }

    public var year: Int { rawValue / 10_000 }
    public var month: Int { (rawValue / 100) % 100 }
    public var day: Int { rawValue % 100 }

    /// First instant of this day in the given calendar.
    public func date(calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    /// `yyyymm00`, used to roll days up into months for the year view.
    public var monthID: Int { year * 10_000 + month * 100 }

    public static func < (lhs: DayID, rhs: DayID) -> Bool { lhs.rawValue < rhs.rawValue }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
}
