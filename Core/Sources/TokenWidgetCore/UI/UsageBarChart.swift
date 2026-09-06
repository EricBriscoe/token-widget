import Charts
import SwiftUI

/// A stacked bar per bucket, one colour per model.
///
/// Stacking is computed by hand rather than with `stacking: .standard` so each
/// segment can carry the 2pt surface gap and the rounded data-end at the top of
/// the stack. The gap is taken off the top of every segment except the topmost,
/// so the height of the whole bar still reads as the true total.
public struct UsageBarChart: View {
    private let breakdown: PeriodBreakdown
    private let palette: ChartPalette
    private let metric: Metric
    private let showsValueAxis: Bool
    private let showsBucketLabels: Bool
    private let maxBucketLabels: Int
    private let segmentGap: CGFloat
    private let collapseSegments: Bool
    private let uniformColor: Color?

    public init(
        breakdown: PeriodBreakdown,
        palette: ChartPalette,
        metric: Metric = .cost,
        showsValueAxis: Bool = true,
        showsBucketLabels: Bool = true,
        maxBucketLabels: Int = 7,
        segmentGap: CGFloat = 2,
        // At small sizes a stack of hues is unreadable, so the bar becomes a
        // single mark and the number above it carries the story instead.
        collapseSegments: Bool = false,
        uniformColor: Color? = nil
    ) {
        self.breakdown = breakdown
        self.palette = palette
        self.metric = metric
        self.showsValueAxis = showsValueAxis
        self.showsBucketLabels = showsBucketLabels
        self.maxBucketLabels = maxBucketLabels
        self.segmentGap = segmentGap
        self.collapseSegments = collapseSegments
        self.uniformColor = uniformColor
    }

    /// Colour and corner radius are resolved up front so the chart content
    /// builder stays trivial for the type checker.
    private struct Piece: Identifiable {
        let id: String
        let bucket: Int
        let start: Double
        let end: Double
        let color: Color
        let cornerRadius: CGFloat
    }

    /// Highest bar in the window, which sets the y domain. A flat zero window
    /// still needs a non-zero domain or the chart collapses.
    private var domainMax: Double {
        max(breakdown.peak(for: metric), 0.000_001)
    }

    public var body: some View {
        GeometryReader { geometry in
            let axisBand: CGFloat = showsBucketLabels ? 18 : 0
            let plotHeight = max(1, geometry.size.height - axisBand)
            let unitsPerPoint = domainMax / Double(plotHeight)

            Chart(pieces(unitsPerPoint: unitsPerPoint)) { piece in
                mark(for: piece, width: barWidth(plotWidth: geometry.size.width))
            }
            .chartYScale(domain: 0...domainMax)
            .chartXScale(domain: -0.5...(Double(breakdown.points.count) - 0.5))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    // Solid hairline, one shade off the surface.
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(ChartColor.gridline)
                    if showsValueAxis {
                        AxisValueLabel { axisText(valueLabel(for: value)) }
                    }
                }
            }
            .chartXAxis {
                // Empty when labels are suppressed, which draws no marks.
                AxisMarks(values: labelledBuckets) { value in
                    AxisValueLabel { axisText(bucketLabel(for: value)) }
                }
            }
        }
    }

    /// The x scale is continuous (bucket indices), so there is no band for
    /// `.ratio` to measure against, so it renders nothing. Size the bar from the
    /// plot width instead, leaving a gap either side.
    private func barWidth(plotWidth: CGFloat) -> CGFloat {
        let count = max(1, breakdown.points.count)
        let axisInset: CGFloat = showsValueAxis ? 42 : 0
        let available = max(0, plotWidth - axisInset)
        return max(2, (available / CGFloat(count)) * 0.62)
    }

    @ChartContentBuilder
    private func mark(for piece: Piece, width: CGFloat) -> some ChartContent {
        BarMark(
            x: .value("Period", piece.bucket),
            yStart: .value("From", piece.start),
            yEnd: .value("To", piece.end),
            width: .fixed(width)
        )
        .foregroundStyle(piece.color)
        // The data-end of the stack gets the 4pt round; inner segments take a
        // light 2pt so the gaps read as deliberate.
        .cornerRadius(piece.cornerRadius)
    }

    private func valueLabel(for value: AxisValue) -> String {
        guard let number = value.as(Double.self) else { return "" }
        return UsageFormat.compactValue(number, metric: metric)
    }

    private func bucketLabel(for value: AxisValue) -> String {
        guard let index = value.as(Int.self), breakdown.points.indices.contains(index) else { return "" }
        return breakdown.points[index].shortLabel
    }

    private func axisText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(ChartColor.mutedInk)
    }

    /// Evenly spaced ticks, always including the first and last bucket, so a
    /// month of days does not turn the axis into a smear.
    private var labelledBuckets: [Int] {
        guard showsBucketLabels else { return [] }
        let count = breakdown.points.count
        guard count > 0 else { return [] }
        guard count > maxBucketLabels else { return Array(0..<count) }

        let step = max(1, Int((Double(count - 1) / Double(maxBucketLabels - 1)).rounded()))
        var values = Array(stride(from: 0, to: count, by: step))
        if values.last != count - 1 {
            // Avoid crowding the final label against its neighbour.
            if let last = values.last, count - 1 - last < step / 2 { values.removeLast() }
            values.append(count - 1)
        }
        return values
    }

    private func pieces(unitsPerPoint: Double) -> [Piece] {
        let gap = Double(segmentGap) * unitsPerPoint
        // Never let a real segment vanish entirely behind its own gap.
        let minimumHeight = 1.5 * unitsPerPoint

        var result: [Piece] = []
        for (index, point) in breakdown.points.enumerated() {
            if collapseSegments {
                let total = point.value(for: metric)
                guard total > 0 else { continue }
                result.append(Piece(
                    id: "\(index)-total",
                    bucket: index,
                    start: 0,
                    end: total,
                    color: uniformColor ?? ChartColor.slots[0],
                    cornerRadius: 4
                ))
                continue
            }

            let contributing = point.segments.filter { $0.value(for: metric) > 0 }
            var cursor = 0.0
            for (position, segment) in contributing.enumerated() {
                let value = segment.value(for: metric)
                let isTop = position == contributing.count - 1
                let top = cursor + value
                // The topmost segment keeps its true top so the bar's height
                // still equals the bucket total.
                let drawnTop = isTop ? top : max(cursor + minimumHeight, top - gap)
                result.append(Piece(
                    id: "\(index)-\(segment.id)",
                    bucket: index,
                    start: cursor,
                    end: drawnTop,
                    color: uniformColor ?? palette.color(for: segment.key),
                    cornerRadius: isTop ? 4 : 2
                ))
                cursor = top
            }
        }
        return result
    }
}

/// Legend rows carrying the value beside each swatch.
///
/// This is also the relief for the light-mode contrast warning on three of the
/// palette slots: identity is never left to hue alone.
public struct UsageLegend: View {
    private let models: [ModelTotal]
    private let palette: ChartPalette
    private let metric: Metric
    private let total: Double
    private let showsShare: Bool
    private let limit: Int

    public init(
        models: [ModelTotal],
        palette: ChartPalette,
        metric: Metric,
        total: Double,
        showsShare: Bool = true,
        limit: Int = 4
    ) {
        self.models = models
        self.palette = palette
        self.metric = metric
        self.total = total
        self.showsShare = showsShare
        self.limit = limit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(models.prefix(limit)) { model in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(palette.color(for: model.key))
                        .frame(width: 8, height: 8)

                    Text(model.displayName)
                        .lineLimit(1)
                        .foregroundStyle(ChartColor.secondaryInk)

                    Spacer(minLength: 4)

                    if showsShare, total > 0, !(metric == .cost && model.isUnpriced) {
                        Text("\(Int((model.value(for: metric) / total * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(ChartColor.mutedInk)
                    }

                    Text(metric == .cost && model.isUnpriced ? "–" : UsageFormat.compactValue(model.value(for: metric), metric: metric))
                        .monospacedDigit()
                        .foregroundStyle(ChartColor.primaryInk)
                }
                .font(.system(size: 10))
            }

            if models.count > limit {
                Text("+\(models.count - limit) more")
                    .font(.system(size: 9))
                    .foregroundStyle(ChartColor.mutedInk)
            }
        }
    }
}
