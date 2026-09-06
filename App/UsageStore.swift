import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import TokenWidgetCore
import UniformTypeIdentifiers
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var palette = ChartPalette(models: [])
    @Published private(set) var isScanning = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var lastError: String?

    @Published var range: RangeKind = .week { didSet { offset = 0 } }
    @Published var metric: Metric = .cost
    @Published var offset: Int = 0

    /// Rates in force. Starts from whatever is cached on disk so the first paint
    /// is priced, then gets rebuilt when the day's refresh lands.
    @Published private(set) var priceBook: PriceBook = .shared
    @Published private(set) var pricesFetchedAt: Date? = OpenRouterPriceService().cached()?.fetchedAt

    private let store = SharedStore()
    private let prices = OpenRouterPriceService()
    private let providers: [TranscriptProvider] = [ClaudeCodeProvider(), CodexProvider()]
    private var watcher: DirectoryWatcher?
    private var refreshTimer: Timer?
    /// Set while a scan is running so filesystem churn during the scan queues
    /// exactly one follow-up rather than a scan per event.
    private var rescanQueued = false

    var breakdown: PeriodBreakdown {
        UsageQuery(snapshot: snapshot ?? UsageSnapshot(), priceBook: priceBook)
            .breakdown(range, offset: offset, metric: metric)
    }

    var pricedModelCount: Int { priceBook.catalogModelCount }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func start() {
        snapshot = store.loadSnapshot()
        if let snapshot { palette = ChartPalette(snapshot: snapshot) }
        startWatching()
        rescan()
        refreshPrices()
        // Reconcile periodically when a filesystem writer misses FSEvents.
        // Unchanged transcripts are skipped by the incremental scanner.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rescan()
                self?.refreshPrices()
            }
        }
    }

    /// Pulls published rates from OpenRouter, at most once a day.
    ///
    /// Deliberately not awaited before the first scan: the chart paints from the
    /// cached rates immediately, and only rescans if the fetch changed
    /// something. A failed fetch leaves the cache in place.
    func refreshPrices(force: Bool = false) {
        let service = prices
        Task { [weak self] in
            guard let catalog = await service.refreshIfNeeded(force: force) else { return }
            self?.applyPrices(catalog)
        }
    }

    private func applyPrices(_ catalog: PriceCatalog) {
        guard catalog.fetchedAt != pricesFetchedAt else { return }
        pricesFetchedAt = catalog.fetchedAt
        priceBook = .builtIn.withCatalog(catalog)
        // Which models count as unpriced is recorded in the snapshot, so a new
        // catalog means that classification has to be redone.
        rescan()
    }

    func rescan() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        lastError = nil

        let scanner = UsageScanner(providers: providers, store: store, priceBook: priceBook)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try scanner.scan { update in
                    Task { @MainActor [weak self] in self?.progress = update }
                }
                await self?.finish(with: result, error: nil)
            } catch {
                await self?.finish(with: nil, error: error.localizedDescription)
            }
        }
    }

    private func finish(with result: UsageSnapshot?, error: String?) {
        isScanning = false
        progress = nil
        lastError = error

        if let result {
            snapshot = result
            palette = ChartPalette(snapshot: result)
            // Push the new numbers to any placed widget rather than waiting for
            // its own timeline to come round.
            WidgetCenter.shared.reloadAllTimelines()
        }

        if rescanQueued {
            rescanQueued = false
            rescan()
        }
    }

    private func startWatching() {
        let roots = providers.flatMap(\.roots)
        watcher = DirectoryWatcher(paths: roots) { [weak self] in
            Task { @MainActor [weak self] in self?.rescan() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Could not change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Throws away the aggregated history and rebuilds it from whatever
    /// transcripts still exist on disk.
    ///
    /// Confirmed first: Claude Code prunes transcripts on its own schedule, so
    /// any day older than that is only recorded here and cannot be rebuilt.
    func rebuildHistory() {
        guard canChangeHistory else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Rebuild history from transcripts?"
        let recorded = snapshot?.days.count ?? 0
        let earliest = snapshot?.firstDay.map { "\($0.year)-\(String(format: "%02d", $0.month))-\(String(format: "%02d", $0.day))" } ?? "—"
        alert.informativeText = """
        This discards the \(recorded) recorded days (starting \(earliest)) and counts only the transcripts still on disk.

        Claude Code deletes its transcripts after its retention period, so older days cannot be recovered by rescanning. A copy is kept as snapshot.previous.json, and Restore Previous History will put it back.
        """
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard canChangeHistory else { return }
        do {
            try store.reset()
        } catch {
            lastError = "Rebuild failed: \(error.localizedDescription)"
            return
        }
        snapshot = nil
        palette = ChartPalette(models: [])
        rescan()
    }

    func restorePreviousHistory() {
        guard canChangeHistory else { return }
        guard let restored = store.restoreBackup() else {
            lastError = "There is no previous history to restore."
            return
        }
        snapshot = restored
        palette = ChartPalette(snapshot: restored)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "token-widget-history.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save a copy of the recorded usage history."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportHistory(to: url)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    func importHistory() {
        guard canChangeHistory else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Merge a previously exported history into this one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard canChangeHistory else { return }
            let merged = try store.importHistory(from: url)
            snapshot = merged
            palette = ChartPalette(snapshot: merged)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    private var canChangeHistory: Bool {
        guard !isScanning else {
            lastError = "Wait for the current scan to finish before changing history."
            return false
        }
        return true
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SharedContainer.snapshotURL])
    }

    func step(by delta: Int) {
        offset = min(0, offset + delta)
    }
}
