import Foundation

public enum UsageFormat {
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
