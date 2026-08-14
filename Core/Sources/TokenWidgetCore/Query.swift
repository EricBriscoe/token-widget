import Foundation

/// How far back a view reaches. Each range picks the bucket size that keeps the
/// bar count readable: a week of days, a year of months.
public enum RangeKind: String, Codable, Sendable, CaseIterable {
    case week, month, quarter, year

    public var displayName: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .quarter: return "Quarter"
        case .year: return "Year"
        }
    }

    public var granularity: Granularity {
        switch self {
        case .week, .month: return .daily
        case .quarter: return .weekly
        case .year: return .monthly
        }
    }
}

public enum Granularity: String, Codable, Sendable {
    case daily, weekly, monthly
}

public enum Metric: String, Codable, Sendable, CaseIterable {
    case cost, tokens

    public var displayName: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }
}

/// A resolved time window: which days it covers and how it is labelled.
public struct PeriodWindow: Sendable, Equatable {
    public let kind: RangeKind
    public let start: Date
    /// Exclusive.
    public let end: Date
    public let startDay: DayID
    /// Inclusive.
    public let endDay: DayID
    public let granularity: Granularity
    public let title: String
    /// True when this window contains the present moment, so the UI can avoid
    /// implying a partial period is a complete one.
    public let isCurrent: Bool
}

public struct SeriesSegment: Sendable, Identifiable, Hashable {
    public let key: ModelKey
    public let cost: Double
    public let tokens: Int

    public var id: String { "\(key.provider.rawValue)|\(key.model)|\(key.fast)" }
    public var displayName: String { key.displayName }

    public func value(for metric: Metric) -> Double {
        switch metric {
        case .cost: return cost
        case .tokens: return Double(tokens)
        }
    }
}

public struct SeriesPoint: Sendable, Identifiable {
    public let bucketStart: Date
    public let label: String
    public let shortLabel: String
    public let segments: [SeriesSegment]
    public let cost: Double
    public let tokens: Int

    public var id: Date { bucketStart }

    public func value(for metric: Metric) -> Double {
        switch metric {
        case .cost: return cost
        case .tokens: return Double(tokens)
        }
    }
}

public struct ModelTotal: Sendable, Identifiable {
    public let key: ModelKey
    public let counts: TokenCounts
    public let cost: Double
    public let pricing: PriceLookup
    public let isApproximate: Bool

    public var id: String { "\(key.provider.rawValue)|\(key.model)|\(key.fast)" }
    public var displayName: String { key.displayName }
    public var isUnpriced: Bool { pricing == .unknown }
    public var isLocal: Bool { pricing == .local }

    public func value(for metric: Metric) -> Double {
        switch metric {
        case .cost: return cost
        case .tokens: return Double(counts.billedTotal)
        }
    }
}

/// Everything a chart needs for one window.
public struct PeriodBreakdown: Sendable {
    public let window: PeriodWindow
    public let points: [SeriesPoint]
    /// Sorted by cost descending, then tokens, so colours stay stable across
    /// buckets and the legend order matches the stack order.
    public let models: [ModelTotal]
    public let totals: TokenCounts
    public let cost: Double

    public var hasUnpricedModels: Bool { models.contains(\.isUnpriced) }
    public var hasApproximateCost: Bool { models.contains(\.isApproximate) }
    public var isEmpty: Bool { totals.messages == 0 }

    public var peakValue: Double { points.map(\.cost).max() ?? 0 }

    public func peak(for metric: Metric) -> Double {
        points.map { $0.value(for: metric) }.max() ?? 0
    }
}

private extension Array {
    func contains(_ keyPath: KeyPath<Element, Bool>) -> Bool {
        contains { $0[keyPath: keyPath] }
    }
}

/// Turns a stored snapshot into chart-ready series. Lives in the shared core so
/// the app window and the widget cannot drift apart in how they compute a total.
public struct UsageQuery: Sendable {
    public let snapshot: UsageSnapshot
    public let priceBook: PriceBook
    public let calendar: Calendar

    public init(snapshot: UsageSnapshot, priceBook: PriceBook = .current, calendar: Calendar = .current) {
        self.snapshot = snapshot
        self.priceBook = priceBook
        self.calendar = calendar
    }

    // MARK: - Windows

    /// `offset` counts periods back from the present: 0 is this week/month/year,
    /// -1 the previous one.
    public func window(_ kind: RangeKind, offset: Int = 0, now: Date = Date()) -> PeriodWindow {
        let (start, end) = bounds(kind: kind, offset: offset, now: now)
        let lastInstant = end.addingTimeInterval(-1)
        return PeriodWindow(
            kind: kind,
            start: start,
            end: end,
            startDay: DayID(start, calendar: calendar),
            endDay: DayID(lastInstant, calendar: calendar),
            granularity: kind.granularity,
            title: title(kind: kind, start: start, lastInstant: lastInstant),
            isCurrent: now >= start && now < end
        )
    }

    private func bounds(kind: RangeKind, offset: Int, now: Date) -> (Date, Date) {
        switch kind {
        case .week:
            let anchor = calendar.date(byAdding: .weekOfYear, value: offset, to: now) ?? now
            let interval = calendar.dateInterval(of: .weekOfYear, for: anchor)
            return (interval?.start ?? anchor, interval?.end ?? anchor)
        case .month:
            let anchor = calendar.date(byAdding: .month, value: offset, to: now) ?? now
            let interval = calendar.dateInterval(of: .month, for: anchor)
            return (interval?.start ?? anchor, interval?.end ?? anchor)
        case .quarter:
            // Calendar's .quarter interval is unreliable, so derive it from months.
            let anchor = calendar.date(byAdding: .month, value: offset * 3, to: now) ?? now
            let month = calendar.component(.month, from: anchor)
            let firstMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: anchor)
            components.month = firstMonth
            components.day = 1
            let start = calendar.date(from: components) ?? anchor
            let end = calendar.date(byAdding: .month, value: 3, to: start) ?? anchor
            return (start, end)
        case .year:
            let anchor = calendar.date(byAdding: .year, value: offset, to: now) ?? now
            let interval = calendar.dateInterval(of: .year, for: anchor)
            return (interval?.start ?? anchor, interval?.end ?? anchor)
        }
    }

    private func title(kind: RangeKind, start: Date, lastInstant: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        switch kind {
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return "\(formatter.string(from: start)) – \(formatter.string(from: lastInstant))"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: start)
        case .quarter:
            let month = calendar.component(.month, from: start)
            let year = calendar.component(.year, from: start)
            return "Q\((month - 1) / 3 + 1) \(year)"
        case .year:
            return String(calendar.component(.year, from: start))
        }
    }

    // MARK: - Series

    public func breakdown(_ kind: RangeKind, offset: Int = 0, metric: Metric = .cost, now: Date = Date()) -> PeriodBreakdown {
        breakdown(for: window(kind, offset: offset, now: now), metric: metric)
    }

    public func breakdown(for window: PeriodWindow, metric: Metric = .cost) -> PeriodBreakdown {
        let bucketStarts = bucketStarts(for: window)

        var perBucket = [[ModelKey: (cost: Double, counts: TokenCounts)]](
            repeating: [:], count: bucketStarts.count
        )
        var perModel: [ModelKey: (cost: Double, counts: TokenCounts, approximate: Bool, pricing: PriceLookup)] = [:]
        var totals = TokenCounts()
        var totalCost = 0.0

        for day in snapshot.days where day.day >= window.startDay && day.day <= window.endDay {
            let date = day.day.date(calendar: calendar)
            guard let index = bucketIndex(for: date, in: bucketStarts) else { continue }

            for entry in day.entries {
                // Priced per day, so a rate change mid-window is respected.
                let lookup = priceBook.lookup(model: entry.model, fast: entry.fast, on: day.day)
                let cost: Double
                switch lookup.price {
                case .priced(let price): cost = price.cost(for: entry.counts)
                case .local, .unknown: cost = 0
                }

                let key = entry.key
                var bucket = perBucket[index][key] ?? (0, TokenCounts())
                bucket.cost += cost
                bucket.counts += entry.counts
                perBucket[index][key] = bucket

                var model = perModel[key] ?? (0, TokenCounts(), false, lookup.price)
                model.cost += cost
                model.counts += entry.counts
                model.approximate = model.approximate || lookup.isApproximate
                model.pricing = lookup.price
                perModel[key] = model

                totals += entry.counts
                totalCost += cost
            }
        }

        let models = perModel
            .map { ModelTotal(key: $0.key, counts: $0.value.counts, cost: $0.value.cost, pricing: $0.value.pricing, isApproximate: $0.value.approximate) }
            .sorted { lhs, rhs in
                if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                if lhs.counts.billedTotal != rhs.counts.billedTotal {
                    return lhs.counts.billedTotal > rhs.counts.billedTotal
                }
                return lhs.displayName < rhs.displayName
            }
        // Stack order follows the legend so a model keeps its colour and slot
        // across every bar in the chart.
        let order = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element.key, $0.offset) })

        let points = bucketStarts.enumerated().map { index, start -> SeriesPoint in
            let segments = perBucket[index]
                .map { SeriesSegment(key: $0.key, cost: $0.value.cost, tokens: $0.value.counts.billedTotal) }
                .sorted { (order[$0.key] ?? .max) < (order[$1.key] ?? .max) }
            return SeriesPoint(
                bucketStart: start,
                label: label(for: start, granularity: window.granularity, short: false),
                shortLabel: label(for: start, granularity: window.granularity, short: true),
                segments: segments,
                cost: segments.reduce(0) { $0 + $1.cost },
                tokens: segments.reduce(0) { $0 + $1.tokens }
            )
        }

        return PeriodBreakdown(window: window, points: points, models: models, totals: totals, cost: totalCost)
    }

    private func bucketStarts(for window: PeriodWindow) -> [Date] {
        var starts: [Date] = []
        var cursor: Date
        let step: Calendar.Component

        switch window.granularity {
        case .daily:
            cursor = calendar.startOfDay(for: window.start)
            step = .day
        case .weekly:
            cursor = calendar.dateInterval(of: .weekOfYear, for: window.start)?.start ?? window.start
            step = .weekOfYear
        case .monthly:
            cursor = calendar.dateInterval(of: .month, for: window.start)?.start ?? window.start
            step = .month
        }

        // Bounded so a bad calendar answer can never spin forever.
        while cursor < window.end, starts.count < 400 {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return starts
    }

    private func bucketIndex(for date: Date, in starts: [Date]) -> Int? {
        guard let first = starts.first, date >= first else { return nil }
        var low = 0
        var high = starts.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= date {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private func label(for date: Date, granularity: Granularity, short: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        switch granularity {
        case .daily:
            formatter.setLocalizedDateFormatFromTemplate(short ? "d" : "MMMd")
        case .weekly:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        case .monthly:
            formatter.setLocalizedDateFormatFromTemplate(short ? "MMMMM" : "MMM")
        }
        return formatter.string(from: date)
    }
}
