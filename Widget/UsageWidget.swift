import Charts
import SwiftUI
import TokenWidgetCore
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let breakdown: PeriodBreakdown
    let palette: ChartPalette
    let metric: Metric
    let range: RangeOption
    let offset: Int
    /// When the app last folded new transcripts in. Nil means it has never run.
    let generatedAt: Date?
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        entry(range: .week, metric: .cost)
    }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageEntry {
        entry(range: configuration.range, metric: configuration.metric)
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageEntry> {
        let current = entry(range: configuration.range, metric: configuration.metric)
        // The app pushes a reload whenever it folds in new data; this is the
        // fallback so a widget still refreshes if the app is not running.
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [current], policy: .after(next))
    }

    private func entry(range: RangeOption, metric: MetricOption) -> UsageEntry {
        let snapshot = SharedStore().loadSnapshot()
        let offset = PeriodOffsetStore.offset(for: range)
        let query = UsageQuery(snapshot: snapshot ?? UsageSnapshot())
        let breakdown = query.breakdown(range.kind, offset: offset, metric: metric.metric)

        return UsageEntry(
            date: Date(),
            breakdown: breakdown,
            palette: ChartPalette(snapshot: snapshot ?? UsageSnapshot()),
            metric: metric.metric,
            range: range,
            offset: offset,
            generatedAt: snapshot?.generatedAt
        )
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "dev.ericbriscoe.tokenwidget.usage",
            intent: UsageWidgetIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(ChartColor.surface, for: .widget)
        }
        .configurationDisplayName("Token Usage")
        .description("Token usage and spend over time, from your local transcripts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct TokenWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

// MARK: - Views

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(entry: entry)
        case .systemMedium: MediumUsageView(entry: entry)
        default: LargeUsageView(entry: entry)
        }
    }
}

/// A stat tile: the period total, with the trend underneath as a single-colour
/// bar per bucket. Splitting a bar this size into model segments would not be
/// readable, so identity is left to the larger sizes.
private struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.breakdown.window.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChartColor.mutedInk)
                .lineLimit(1)

            Text(UsageFormat.value(for: entry.breakdown, metric: entry.metric, compact: true))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ChartColor.primaryInk)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(entry.metric == .cost ? "\(UsageFormat.tokens(entry.breakdown.totals.output)) generated" : "across \(entry.breakdown.models.count) models")
                .font(.system(size: 9))
                .foregroundStyle(ChartColor.secondaryInk)
                .lineLimit(1)

            Spacer(minLength: 6)

            UsageBarChart(
                breakdown: entry.breakdown,
                palette: entry.palette,
                metric: entry.metric,
                showsValueAxis: false,
                showsBucketLabels: false,
                collapseSegments: true
            )
            .frame(height: 44)

            FooterNote(entry: entry)
                .padding(.top, 4)
        }
    }
}

private struct MediumUsageView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PeriodHeader(entry: entry, showsControls: true)

            HStack(alignment: .top, spacing: 12) {
                UsageBarChart(
                    breakdown: entry.breakdown,
                    palette: entry.palette,
                    metric: entry.metric,
                    maxBucketLabels: 7
                )

                UsageLegend(
                    models: entry.breakdown.models,
                    palette: entry.palette,
                    metric: entry.metric,
                    total: entry.breakdown.value(for: entry.metric),
                    showsShare: false,
                    limit: 4
                )
                .frame(width: 132)
            }

            FooterNote(entry: entry)
        }
    }
}

private struct LargeUsageView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var labelBudget: Int { family == .systemExtraLarge ? 14 : 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeriodHeader(entry: entry, showsControls: true)

            UsageBarChart(
                breakdown: entry.breakdown,
                palette: entry.palette,
                metric: entry.metric,
                maxBucketLabels: labelBudget
            )
            .frame(minHeight: 120)

            Divider().overlay(ChartColor.gridline)

            UsageLegend(
                models: entry.breakdown.models,
                palette: entry.palette,
                metric: entry.metric,
                total: entry.breakdown.value(for: entry.metric),
                limit: family == .systemExtraLarge ? 8 : 5
            )

            Spacer(minLength: 0)
            FooterNote(entry: entry)
        }
    }
}

private struct PeriodHeader: View {
    let entry: UsageEntry
    let showsControls: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.breakdown.window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChartColor.secondaryInk)
                    .lineLimit(1)

                Text(UsageFormat.value(for: entry.breakdown, metric: entry.metric))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ChartColor.primaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 4)

            if showsControls {
                HStack(spacing: 2) {
                    Button(intent: ShiftPeriodIntent(delta: -1, range: entry.range)) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    if entry.offset != 0 {
                        Button(intent: ResetPeriodIntent(range: entry.range)) {
                            Image(systemName: "smallcircle.filled.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    Button(intent: ShiftPeriodIntent(delta: 1, range: entry.range)) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.offset >= 0)
                    .opacity(entry.offset >= 0 ? 0.3 : 1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChartColor.secondaryInk)
            }
        }
    }
}

/// Says how fresh the numbers are, and flags anything the price book could not
/// price so a zero is never read as free usage.
///
/// Both checks are scoped to the period on screen. The snapshot-wide lists say
/// whether *any* day on record had a gap, which on a one-week card means a model
/// last used in January can sit on top of a total it contributed nothing to.
/// The warning also has to clear `hasMaterialUncostedUsage`: this is a single
/// 9pt line, and spending it on a tenth of a cent buries how stale the data is.
private struct FooterNote: View {
    let entry: UsageEntry

    var body: some View {
        Group {
            if entry.generatedAt == nil {
                Text("Open Token Widget to scan your transcripts")
            } else if entry.metric == .cost && entry.breakdown.hasMaterialUncostedUsage,
                      let note = UsageFormat.uncostedNote(for: entry.breakdown) {
                Text(note)
            } else if entry.breakdown.isEmpty {
                Text("No usage recorded in this period")
            } else if entry.metric == .cost && entry.breakdown.hasApproximateCost {
                Text("Estimated API cost")
            } else if let generatedAt = entry.generatedAt {
                Text("Scanned \(generatedAt, style: .relative) ago")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(ChartColor.mutedInk)
        .lineLimit(1)
    }
}
