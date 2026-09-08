import Foundation

/// One model's totals on one day.
public struct ModelEntry: Codable, Sendable, Hashable {
    public var provider: Provider
    public var model: String
    public var fast: Bool
    public var counts: TokenCounts

    public init(provider: Provider, model: String, fast: Bool, counts: TokenCounts) {
        self.provider = provider
        self.model = model
        self.fast = fast
        self.counts = counts
    }

    public var key: ModelKey { ModelKey(provider: provider, model: model, fast: fast) }

    private enum CodingKeys: String, CodingKey {
        case provider = "p"
        case model = "m"
        case fast = "f"
        case counts = "c"
    }
}

/// Everything recorded for a single calendar day.
public struct DaySummary: Codable, Sendable, Hashable {
    public var day: DayID
    public var entries: [ModelEntry]

    public init(day: DayID, entries: [ModelEntry]) {
        self.day = day
        self.entries = entries
    }

    public var totals: TokenCounts {
        entries.reduce(into: TokenCounts()) { $0 += $1.counts }
    }

    private enum CodingKeys: String, CodingKey {
        case day = "d"
        case entries = "e"
    }
}

/// The aggregated history the widget reads. Small enough (a few hundred KB for
/// years of data) to decode inside a widget extension's memory budget.
public struct UsageSnapshot: Codable, Sendable {
    public static let currentVersion = 3 // Persists model colours; older apps must not discard them.

    public var version: Int
    public var generatedAt: Date
    /// Ascending by day. Days with no activity are omitted.
    public var days: [DaySummary]
    /// Models seen in the logs that have no published rate, so their cost reads
    /// as zero. Surfaced in the UI so a gap is never mistaken for free usage.
    public var unpricedModels: [String]
    /// Models billed at a fallback rate (fast-mode requests with no published
    /// fast rate), whose cost is an estimate.
    public var approximateModels: [String]
    /// Models running locally, which genuinely cost nothing per token.
    public var localModels: [String]
    public var totalMessages: Int
    public var scanDuration: TimeInterval
    public var filesScanned: Int
    /// Optional for pre-palette histories. The next scan assigns and saves it.
    public var modelColors: [String: ModelColor]?

    public init(
        version: Int = UsageSnapshot.currentVersion,
        generatedAt: Date = Date(),
        days: [DaySummary] = [],
        unpricedModels: [String] = [],
        approximateModels: [String] = [],
        localModels: [String] = [],
        totalMessages: Int = 0,
        scanDuration: TimeInterval = 0,
        filesScanned: Int = 0,
        modelColors: [String: ModelColor]? = nil
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.days = days
        self.unpricedModels = unpricedModels
        self.approximateModels = approximateModels
        self.localModels = localModels
        self.totalMessages = totalMessages
        self.scanDuration = scanDuration
        self.filesScanned = filesScanned
        self.modelColors = modelColors
    }

    public var isEmpty: Bool { days.isEmpty }

    public var firstDay: DayID? { days.first?.day }
    public var lastDay: DayID? { days.last?.day }

    /// Combines two histories, taking the fuller record for any day and model
    /// both describe. Used when importing an exported history back in; adding
    /// the two together would double-count days they share.
    public static func merging(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot) -> UsageSnapshot {
        var byDay: [DayID: [ModelKey: TokenCounts]] = [:]

        for snapshot in [lhs, rhs] {
            for day in snapshot.days {
                for entry in day.entries {
                    let existing = byDay[day.day]?[entry.key]
                    if existing == nil || entry.counts.billedTotal > existing!.billedTotal {
                        byDay[day.day, default: [:]][entry.key] = entry.counts
                    }
                }
            }
        }

        let days = byDay
            .map { day, models in
                DaySummary(
                    day: day,
                    entries: models
                        .map { ModelEntry(provider: $0.key.provider, model: $0.key.model, fast: $0.key.fast, counts: $0.value) }
                        .sorted { $0.counts.billedTotal > $1.counts.billedTotal }
                )
            }
            .sorted { $0.day < $1.day }

        // Keep this machine's established colours. Imported assignments may be
        // reused only if they do not collide in either appearance.
        var colors = ModelColorAllocator.assign(models: [], preserving: lhs.modelColors ?? [:])
        for (identity, color) in (rhs.modelColors ?? [:]).sorted(by: { $0.key < $1.key }) {
            if colors[identity] == nil, color.isUsable,
               !colors.values.contains(where: { $0.light == color.light || $0.dark == color.dark }) {
                colors[identity] = color
            }
        }
        colors = ModelColorAllocator.assign(models: days.flatMap { $0.entries.map(\.key) }, preserving: colors)

        return UsageSnapshot(
            generatedAt: max(lhs.generatedAt, rhs.generatedAt),
            days: days,
            unpricedModels: Array(Set(lhs.unpricedModels + rhs.unpricedModels)).sorted(),
            approximateModels: Array(Set(lhs.approximateModels + rhs.approximateModels)).sorted(),
            localModels: Array(Set(lhs.localModels + rhs.localModels)).sorted(),
            totalMessages: days.reduce(0) { $0 + $1.totals.messages },
            scanDuration: 0,
            filesScanned: max(lhs.filesScanned, rhs.filesScanned),
            modelColors: colors
        )
    }
}

/// Builds day buckets from a stream of records.
public struct UsageAggregator {
    private var buckets: [DayID: [ModelKey: TokenCounts]] = [:]
    private let calendar: Calendar

    public private(set) var recordCount = 0

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Seed the aggregator with already-aggregated history so an incremental
    /// pass only has to fold in the new records.
    public init(resuming days: [DaySummary], calendar: Calendar = .current) {
        self.calendar = calendar
        for day in days {
            var byModel: [ModelKey: TokenCounts] = [:]
            for entry in day.entries { byModel[entry.key, default: TokenCounts()] += entry.counts }
            buckets[day.day] = byModel
        }
    }

    /// Days are bucketed in the machine's local time zone, so a message at
    /// 23:30 local lands on the day the user remembers working, not the UTC one.
    public mutating func add(_ record: UsageRecord) {
        let day = DayID(record.timestamp, calendar: calendar)
        buckets[day, default: [:]][record.key, default: TokenCounts()] += record.counts
        recordCount += 1
    }

    public func daySummaries() -> [DaySummary] {
        buckets
            .map { day, byModel in
                let entries = byModel
                    .map { ModelEntry(provider: $0.key.provider, model: $0.key.model, fast: $0.key.fast, counts: $0.value) }
                    .sorted { $0.counts.billedTotal > $1.counts.billedTotal }
                return DaySummary(day: day, entries: entries)
            }
            .sorted { $0.day < $1.day }
    }
}
