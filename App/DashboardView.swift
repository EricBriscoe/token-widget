import SwiftUI
import TokenWidgetCore

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(AppDelegate.showMenuBarIconKey) private var showMenuBarIcon = true

    private var breakdown: PeriodBreakdown { store.breakdown }

    private var headlineValue: Double {
        breakdown.value(for: store.metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider().overlay(ChartColor.gridline)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    chart
                    modelTable
                    notes
                }
                .padding(20)
            }
        }
        .background(ChartColor.surface)
        .frame(minWidth: 860, minHeight: 560)
    }

    // MARK: - Controls

    /// One filter row above everything it scopes.
    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $store.range) {
                ForEach(RangeKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Picker("", selection: $store.metric) {
                ForEach(Metric.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Spacer()

            HStack(spacing: 4) {
                Button { store.step(by: -1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous period")
                    .accessibilityLabel("Previous period")
                Button { store.offset = 0 } label: { Text("Now") }
                    .disabled(store.offset == 0)
                Button { store.step(by: 1) } label: { Image(systemName: "chevron.right") }
                    .help("Next period")
                    .accessibilityLabel("Next period")
                    .disabled(store.offset >= 0)
            }
            .buttonStyle(.bordered)
            .fixedSize()

            Button {
                store.rescan()
            } label: {
                if store.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning)
            .help("Rescan transcripts")
            .accessibilityLabel("Rescan transcripts")

            Menu {
                Button("Export History…") { store.exportHistory() }
                Button("Import History…") { store.importHistory() }
                Button("Restore Previous History") { store.restorePreviousHistory() }
                Button("Show Data Folder in Finder") { store.revealDataFolder() }
                Divider()
                Button("Rebuild History from Transcripts…") { store.rebuildHistory() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .help("History actions")
            .accessibilityLabel("History actions")
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(breakdown.window.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChartColor.secondaryInk)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // Proportional figures on the hero number, not tabular.
                Text(UsageFormat.value(for: breakdown, metric: store.metric))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(ChartColor.primaryInk)

                VStack(alignment: .leading, spacing: 2) {
                    // The headline already carries the selected measure, so the
                    // supporting line shows the other one rather than repeating it.
                    switch store.metric {
                    case .cost: Text("\(UsageFormat.tokens(breakdown.totals.output)) tokens generated")
                    case .tokens: Text(UsageFormat.value(for: breakdown, metric: .cost))
                    }
                    Text("\(breakdown.totals.messages) messages")
                }
                .font(.system(size: 12))
                .foregroundStyle(ChartColor.secondaryInk)

                if breakdown.window.isCurrent {
                    Text("in progress")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChartColor.gridline, in: Capsule())
                        .foregroundStyle(ChartColor.secondaryInk)
                }
            }

            if breakdown.hasUnpricedModels {
                Text("Cost excludes \(breakdown.models.filter(\.isUnpriced).map(\.displayName).joined(separator: ", ")).\(store.metric == .cost ? " Select Tokens to see all generated activity." : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(ChartColor.secondaryInk)
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            if breakdown.isEmpty {
                emptyState
            } else {
                UsageBarChart(
                    breakdown: breakdown,
                    palette: store.palette,
                    metric: store.metric,
                    maxBucketLabels: 12
                )
                .frame(height: 240)

                UsageLegend(
                    models: breakdown.models,
                    palette: store.palette,
                    metric: store.metric,
                    total: headlineValue,
                    limit: 8
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No usage recorded in this period")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChartColor.secondaryInk)
            if let first = store.snapshot?.firstDay {
                Text("History starts \(first.year)-\(String(format: "%02d", first.month))-\(String(format: "%02d", first.day)).")
                    .font(.system(size: 11))
                    .foregroundStyle(ChartColor.mutedInk)
            }
        }
        .frame(height: 240, alignment: .topLeading)
    }

    // MARK: - Table

    /// The table twin of the chart: every value on screen without relying on
    /// colour, which is also the relief for the light-mode contrast warning.
    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breakdown")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChartColor.primaryInk)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Model")
                    Text("Cost").gridColumnAlignment(.trailing)
                    Text("Share").gridColumnAlignment(.trailing)
                    Text("Input").gridColumnAlignment(.trailing)
                    Text("Cache write").gridColumnAlignment(.trailing)
                    Text("Cache read").gridColumnAlignment(.trailing)
                    Text("Output").gridColumnAlignment(.trailing)
                    Text("Msgs").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChartColor.mutedInk)

                Divider().overlay(ChartColor.gridline).gridCellColumns(8)

                ForEach(breakdown.models) { model in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(store.palette.color(for: model.key))
                                .frame(width: 8, height: 8)
                            Text(model.displayName)
                            if model.isLocal { tag("local") }
                            if model.isUnpriced { tag("no rate") }
                            if model.isApproximate { tag("estimated") }
                        }
                        Text(model.isUnpriced ? "–" : UsageFormat.money(model.cost))
                        Text(headlineValue > 0 && !(store.metric == .cost && model.isUnpriced) ? "\(Int((model.value(for: store.metric) / headlineValue * 100).rounded()))%" : "–")
                        Text(UsageFormat.tokens(model.counts.input))
                        Text(UsageFormat.tokens(model.counts.cacheWrite5m + model.counts.cacheWrite1h))
                        Text(UsageFormat.tokens(model.counts.cacheRead))
                        Text(UsageFormat.tokens(model.counts.output))
                        Text("\(model.counts.messages)")
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(ChartColor.primaryInk)
                }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(ChartColor.gridline, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(ChartColor.secondaryInk)
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = store.progress {
                Text("Scanning \(progress.filesProcessed) of \(progress.filesTotal) transcripts…")
            }
            if let error = store.lastError {
                Text(error).foregroundStyle(.red)
            }
            if let snapshot = store.snapshot {
                Text("\(snapshot.totalMessages) messages across \(snapshot.days.count) days · scanned \(snapshot.filesScanned) transcripts in \(String(format: "%.1f", snapshot.scanDuration))s · updated \(UsageFormat.relativeAge(of: snapshot.generatedAt))")

                // Scoped to the period on screen, and listed whatever the
                // size of the gap: this view has the room the widget's single
                // footnote line does not.
                if let note = UsageFormat.uncostedNote(for: breakdown) {
                    Text("\(note); those tokens are charted but contribute $0 to the total.")
                }
            }

            HStack(spacing: 6) {
                if let fetched = store.pricesFetchedAt {
                    Text("Rates for \(store.pricedModelCount) models from OpenRouter, updated \(UsageFormat.relativeAge(of: fetched)).")
                } else {
                    Text("Using built-in rates because OpenRouter's price list has not been fetched yet.")
                }
                Button("Refresh") { store.refreshPrices(force: true) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            if breakdown.models.contains(where: \.isLocal) {
                Text("Local models have no per-token cost.")
            }
            if breakdown.hasApproximateCost {
                Text("Estimated rates used for \(breakdown.models.filter(\.isApproximate).map(\.displayName).joined(separator: ", ")).")
            }

            Text("Costs estimate API list prices, not your subscription bill. GPT-6 Astra estimates exclude the surcharge for requests above 272K input tokens.")

            Text("Recorded days are kept after Claude Code deletes the transcripts they came from, so history grows the longer this runs. It has to scan at least once inside Claude Code's retention window (30 days by default) to capture a given day.")

            Toggle("Open at login and keep the widget fresh", isOn: Binding(
                get: { store.isLaunchAtLoginEnabled },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            Toggle("Show the menu bar icon", isOn: $showMenuBarIcon)
                .toggleStyle(.checkbox)

            if !showMenuBarIcon {
                Text("With the icon hidden, open Token Widget again from Finder or Spotlight to get back to this window.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(ChartColor.mutedInk)
    }
}
