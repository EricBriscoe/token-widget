import Foundation

public enum UsageFormat {
    /// Missing rates leave a partial cost total; generated tokens stay complete.
    public static func value(for breakdown: PeriodBreakdown, metric: Metric, compact: Bool = false) -> String {
        if metric == .cost, breakdown.hasUnpricedModels,
           breakdown.models.allSatisfy(\.isUnpriced) { return "No rate" }
        let value = compact
            ? compactValue(breakdown.value(for: metric), metric: metric)
            : self.value(breakdown.value(for: metric), metric: metric)
        guard metric == .cost else { return value }
        let prefix = breakdown.hasApproximateCost ? "≈" : ""
        let suffix = breakdown.hasUnpricedModels ? "+" : ""
        return prefix + value + suffix
    }

    /// `$1,284.30`. Used wherever there is room for the exact figure.
    public static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value < 10 ? 2 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// `$1.3k`. For a hero figure in a small widget, where the exact cents
    /// would not fit and would not be read anyway.
    public static func compactMoney(_ value: Double) -> String {
        switch abs(value) {
        case 100_000...:
            return String(format: "$%.0fk", value / 1_000)
        case 10_000...:
            return String(format: "$%.1fk", value / 1_000)
        case 1_000...:
            return String(format: "$%.2fk", value / 1_000)
        case 100...:
            return String(format: "$%.0f", value)
        default:
            return String(format: "$%.2f", value)
        }
    }

    /// `800.7M`. Token counts are only ever meaningful to one decimal.
    public static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch abs(number) {
        case 1_000_000_000...:
            return String(format: "%.2fB", number / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", number / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", number / 1_000)
        case 1_000...:
            return String(format: "%.1fK", number / 1_000)
        default:
            return String(Int(number))
        }
    }

    public static func value(_ amount: Double, metric: Metric) -> String {
        switch metric {
        case .cost: return money(amount)
        case .tokens: return tokens(Int(amount))
        }
    }

    public static func compactValue(_ amount: Double, metric: Metric) -> String {
        switch metric {
        case .cost: return compactMoney(amount)
        case .tokens: return tokens(Int(amount))
        }
    }

    /// Joins names into readable English: `A`, `A and B`, `A, B and C`, and past
    /// `limit` names `A, B, C and 2 more`. The old call site joined with commas
    /// and appended a singular verb, which read as "X, Y has no published rate".
    public static func list(_ names: [String], limit: Int = 3) -> String {
        if names.isEmpty { return "" }
        if names.count == 1 { return names[0] }
        if names.count <= limit {
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        // "more" rather than "others" so the tail needs no singular/plural form.
        return "\(names.prefix(limit).joined(separator: ", ")) and \(names.count - limit) more"
    }

    /// One line explaining why the period's total is lower than what was
    /// spent, or nil when nothing is missing.
    ///
    /// Both gaps read as $0 in the chart but have different causes, so they are
    /// worded differently: a named model the price book has no rate for is
    /// something a rate could fix, while unattributed tokens are usage the
    /// transcript never tied to any model.
    public static func uncostedNote(for breakdown: PeriodBreakdown) -> String? {
        let unpriced = breakdown.unpricedModels.map(\.displayName).sorted()
        let unattributed = breakdown.unattributedModels
            .reduce(0) { $0 + $1.counts.billedTotal }

        var parts: [String] = []
        if !unpriced.isEmpty {
            let verb = unpriced.count == 1 ? "has" : "have"
            parts.append("\(list(unpriced)) \(verb) no published rate")
        }
        if unattributed > 0 {
            parts.append("\(tokens(unattributed)) tokens name no model")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    /// "updated 4 min ago", so a stale widget is obvious rather than silently wrong.
    public static func relativeAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) hr ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}
