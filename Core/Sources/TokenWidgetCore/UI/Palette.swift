import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Shared surfaces and ink. Model swatches are generated separately in OKLCH.
public enum ChartColor {
    public static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)
    public static let primaryInk = dynamic(light: 0x0b0b0b, dark: 0xffffff)
    public static let secondaryInk = dynamic(light: 0x52514e, dark: 0xc3c2b7)
    public static let mutedInk = dynamic(light: 0x898781, dark: 0x898781)
    public static let gridline = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)
    public static let baseline = dynamic(light: 0xc3c2b7, dark: 0x383835)
    /// A collapsed sparkline represents the total, not an individual model.
    static let aggregate = dynamic(light: 0x2a78d6, dark: 0x3987e5)

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

/// The app and widget resolve the same saved, model-only assignments. All
/// historical models participate, so changing the visible range changes no hue.
public struct ChartPalette: Sendable {
    private let assignments: [String: ModelColor]

    public init(models: [ModelKey]) {
        assignments = ModelColorAllocator.assign(models: models)
    }

    public init(snapshot: UsageSnapshot) {
        assignments = ModelColorAllocator.assign(
            models: snapshot.days.flatMap { $0.entries.map(\.key) },
            preserving: snapshot.modelColors ?? [:]
        )
    }

    public func color(for key: ModelKey) -> Color {
        let swatch = swatch(for: key)
        return ChartColor.dynamic(light: swatch.light, dark: swatch.dark)
    }

    func swatch(for key: ModelKey) -> ModelColor {
        if let color = assignments[key.colorIdentity] { return color }
        // A caller may ask about a model not yet present in its snapshot.
        return ModelColorAllocator.assign(models: [key], preserving: assignments)[key.colorIdentity]!
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
