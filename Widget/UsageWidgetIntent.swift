import AppIntents
import Foundation
import TokenWidgetCore
import WidgetKit

/// The range a widget instance shows. Each option names its bucket size so the
/// choice in the edit sheet says what the chart will look like.
enum RangeOption: String, AppEnum {
    case week, month, quarter, year

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Range" }

    static var caseDisplayRepresentations: [RangeOption: DisplayRepresentation] {
        [
            .week: "Week (by day)",
            .month: "Month (by day)",
            .quarter: "Quarter (by week)",
            .year: "Year (by month)"
        ]
    }

    var kind: RangeKind { RangeKind(rawValue: rawValue) ?? .week }
}

enum MetricOption: String, AppEnum {
    case cost, tokens

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Measure" }

    static var caseDisplayRepresentations: [MetricOption: DisplayRepresentation] {
        [.cost: "Cost", .tokens: "Tokens"]
    }

    var metric: Metric { Metric(rawValue: rawValue) ?? .cost }
}

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Token Usage" }
    static var description: IntentDescription {
        IntentDescription("Token usage and spend from your local Claude Code and Codex transcripts.")
    }

    @Parameter(title: "Range", default: .week)
    var range: RangeOption

    @Parameter(title: "Show", default: .cost)
    var metric: MetricOption

    init() {}

    init(range: RangeOption, metric: MetricOption) {
        self.range = range
        self.metric = metric
    }
}

/// Which period each range is currently parked on.
///
/// Stored in the App Group so the buttons on the widget and a relaunch of the
/// app agree. Keyed per range, so stepping back through weeks does not also
/// move the year view.
enum PeriodOffsetStore {
    /// Far enough back to cover any plausible history, without letting a stuck
    /// button walk off into empty space forever.
    static let floor = -520

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedContainer.appGroupID)
    }

    private static func key(_ range: RangeOption) -> String { "period.offset.\(range.rawValue)" }

    static func offset(for range: RangeOption) -> Int {
        let value = defaults?.integer(forKey: key(range)) ?? 0
        return min(0, max(floor, value))
    }

    static func shift(_ range: RangeOption, by delta: Int) {
        let next = min(0, max(floor, offset(for: range) + delta))
        defaults?.set(next, forKey: key(range))
    }

    static func reset(_ range: RangeOption) {
        defaults?.removeObject(forKey: key(range))
    }
}

/// Steps the visible period backwards or forwards from a widget button.
struct ShiftPeriodIntent: AppIntent {
    static var title: LocalizedStringResource { "Change Period" }

    @Parameter(title: "Delta")
    var delta: Int

    @Parameter(title: "Range")
    var rangeValue: String

    init() {}

    init(delta: Int, range: RangeOption) {
        self.delta = delta
        self.rangeValue = range.rawValue
    }

    func perform() async throws -> some IntentResult {
        let range = RangeOption(rawValue: rangeValue) ?? .week
        PeriodOffsetStore.shift(range, by: delta)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Jumps back to the current period.
struct ResetPeriodIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Current Period" }

    @Parameter(title: "Range")
    var rangeValue: String

    init() {}

    init(range: RangeOption) {
        self.rangeValue = range.rawValue
    }

    func perform() async throws -> some IntentResult {
        PeriodOffsetStore.reset(RangeOption(rawValue: rangeValue) ?? .week)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
