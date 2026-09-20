import SwiftUI
import XCTest
@testable import TokenWidgetCore

final class ChartAxisTests: XCTestCase {
    /// Measure rendered ink, not just the data indices: Charts can move axis
    /// labels independently of the bars when it chooses automatic anchors.
    @MainActor
    func testFirstDayLabelIsCenteredUnderFirstBar() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = DayID(year: 2026, month: 9, day: 1)
        let snapshot = UsageSnapshot(days: [
            DaySummary(day: day, entries: [
                ModelEntry(provider: .claudeCode, model: "claude-opus-5", fast: false,
                           counts: TokenCounts(output: 100, messages: 1))
            ])
        ])
        let breakdown = UsageQuery(snapshot: snapshot, priceBook: .builtIn, calendar: calendar)
            .breakdown(.month, metric: .tokens, now: day.date(calendar: calendar))
        XCTAssertEqual(breakdown.points.count, 30)
        XCTAssertEqual(breakdown.points[0].shortLabel, "1")
        XCTAssertEqual(breakdown.points[0].tokens, 100)
        XCTAssertEqual(breakdown.points[1].tokens, 0)

        let renderer = ImageRenderer(content: UsageBarChart(
            breakdown: breakdown, palette: ChartPalette(snapshot: snapshot), metric: .tokens,
            showsValueAxis: false, maxBucketLabels: 8, collapseSegments: true, uniformColor: .red
        ).frame(width: 300, height: 120).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var barXs: [Int] = []
        var labelXs: [Int] = []
        // The first tick is isolated from the next tick (day 5).
        for y in 0..<height {
            for x in 0..<90 {
                let i = (y * width + x) * 4
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                if r > 200 && g < 100 && b < 100 { barXs.append(x) }
                // Ignore pale grid lines; the only dark neutral ink is label 1.
                if max(r, g, b) - min(r, g, b) < 40 && max(r, g, b) < 180 {
                    labelXs.append(x)
                }
            }
        }
        let barCenter = Double(try XCTUnwrap(barXs.min()) + XCTUnwrap(barXs.max())) / 2
        let labelCenter = Double(try XCTUnwrap(labelXs.min()) + XCTUnwrap(labelXs.max())) / 2
        XCTAssertEqual(labelCenter, barCenter, accuracy: 3, "Day 1 must align with its bar within one point")
    }
}
