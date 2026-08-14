import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Chart colours and ink.
///
/// The categorical slots are the validated eight-hue order: on the light and
/// dark surfaces below it clears the lightness band, chroma floor, adjacent CVD
/// separation, and the normal-vision floor. Three light-mode slots fall under
/// 3:1 against the surface, which is why every chart here also ships visible
/// values (legend rows and the breakdown table) rather than relying on hue.
public enum ChartColor {
    // Surfaces the palette was validated against.
    public static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)
    public static let primaryInk = dynamic(light: 0x0b0b0b, dark: 0xffffff)
    public static let secondaryInk = dynamic(light: 0x52514e, dark: 0xc3c2b7)
    public static let mutedInk = dynamic(light: 0x898781, dark: 0x898781)
    public static let gridline = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)
    public static let baseline = dynamic(light: 0xc3c2b7, dark: 0x383835)

    /// The eight categorical slots, in the fixed validated order.
    static let slots: [Color] = [
        dynamic(light: 0x2a78d6, dark: 0x3987e5),  // blue
        dynamic(light: 0xeb6834, dark: 0xd95926),  // orange
        dynamic(light: 0x1baf7a, dark: 0x199e70),  // aqua
        dynamic(light: 0xeda100, dark: 0xc98500),  // yellow
        dynamic(light: 0xe87ba4, dark: 0xd55181),  // magenta
        dynamic(light: 0x008300, dark: 0x008300),  // green
        dynamic(light: 0x4a3aa7, dark: 0x9085e9),  // violet
        dynamic(light: 0xe34948, dark: 0xe66767)   // red
    ]

    /// Anything past the eighth series folds in here rather than getting a
    /// generated ninth hue.
    static let other = dynamic(light: 0x898781, dark: 0x898781)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? dark : light)
        })
        #else
        return Color(rgbHex: light)
        #endif
    }
}

/// Maps models to colour slots.
///
/// The assignment is built from every model in the snapshot, not just the ones
/// in the visible window, so changing the date range never repaints the series
/// a reader has already learned. Known models take slots in a fixed published
/// order; anything else is appended alphabetically.
public struct ChartPalette: Sendable {
    /// Fixed order so a given model keeps its colour across runs.
    private static let canonicalOrder = [
        "claude-fable-5",
        "claude-mythos-5",
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-haiku-4-5"
    ]

    private let slotByModel: [ModelKey: Int]

    public init(models: [ModelKey]) {
        let ranked = models.sorted { lhs, rhs in
            let left = Self.canonicalOrder.firstIndex(of: lhs.model) ?? Int.max
            let right = Self.canonicalOrder.firstIndex(of: rhs.model) ?? Int.max
            if left != right { return left < right }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            // Standard before fast, so the common lane keeps the leading colour.
            return !lhs.fast && rhs.fast
        }
        var assignment: [ModelKey: Int] = [:]
        for (index, key) in ranked.enumerated() { assignment[key] = index }
        slotByModel = assignment
    }

    public init(snapshot: UsageSnapshot) {
        var keys = Set<ModelKey>()
        for day in snapshot.days {
            for entry in day.entries { keys.insert(entry.key) }
        }
        self.init(models: Array(keys))
    }

    public func color(for key: ModelKey) -> Color {
        guard let slot = slotByModel[key], slot < ChartColor.slots.count else { return ChartColor.other }
        return ChartColor.slots[slot]
    }

    /// True when this model was folded into "Other" instead of getting a hue.
    public func isOverflow(_ key: ModelKey) -> Bool {
        (slotByModel[key] ?? Int.max) >= ChartColor.slots.count
    }
}

#if canImport(AppKit)
extension NSColor {
    convenience init(rgbHex hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
#endif

extension Color {
    init(rgbHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}
