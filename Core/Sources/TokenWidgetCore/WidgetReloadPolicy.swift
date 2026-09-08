import Foundation

/// Keep no-op scans and bursts of transcript writes from spending WidgetKit's
/// limited reload budget. Changes deferred by the interval stay pending because
/// comparisons are against the last requested snapshot, not the last scan.
public struct WidgetReloadPolicy {
    private let minimumInterval: TimeInterval
    private var lastRequestedAt: Date?
    private var days: [DayID: Set<ModelEntry>] = [:]
    private var colors: [String: ModelColor]?
    private var priceDate: Date?
    private var day: DayID?

    public init(minimumInterval: TimeInterval = 15 * 60) {
        self.minimumInterval = minimumInterval
    }

    public mutating func shouldReload(
        snapshot: UsageSnapshot, pricesFetchedAt: Date?, now: Date = Date()
    ) -> Bool {
        let today = DayID(now)
        let content = snapshot.days.reduce(into: [DayID: Set<ModelEntry>]()) {
            $0[$1.day, default: []].formUnion($1.entries)
        }
        if let lastRequestedAt {
            guard content != days || snapshot.modelColors != colors || pricesFetchedAt != priceDate || today != day else { return false }
            guard now.timeIntervalSince(lastRequestedAt) >= minimumInterval else { return false }
        }
        lastRequestedAt = now
        days = content
        colors = snapshot.modelColors
        priceDate = pricesFetchedAt
        day = today
        return true
    }
}
