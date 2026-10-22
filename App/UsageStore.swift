import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import TokenWidgetCore
import UniformTypeIdentifiers
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot? { didSet { cachedBreakdown = nil } }
    @Published private(set) var palette = ChartPalette(models: [])
    @Published private(set) var isScanning = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var lastError: String?

    @Published var range: RangeKind = .week { didSet { offset = 0 } }
    @Published var metric: Metric = .cost { didSet { cachedBreakdown = nil } }
    @Published var offset: Int = 0 { didSet { cachedBreakdown = nil } }

    /// Rates in force. Starts from whatever is cached on disk so the first paint
    /// is priced, then gets rebuilt when the day's refresh lands.
    @Published private(set) var priceBook: PriceBook = .shared { didSet { cachedBreakdown = nil } }
    @Published private(set) var pricesFetchedAt: Date? = OpenRouterPriceService().cached()?.fetchedAt

    private let store = SharedStore()
    private let prices = OpenRouterPriceService()
    private let providers: [TranscriptProvider] = [ClaudeCodeProvider(), CodexProvider(), PiProvider()]
    private var widgetReloadPolicy = WidgetReloadPolicy()
    private var watcher: DirectoryWatcher?
    private var watchedRoots: [URL] = []
    private var refreshTimer: Timer?
    /// Set while a scan is running so filesystem churn during the scan queues
    /// exactly one follow-up rather than a scan per event.
    private var rescanQueued = false
    private var cachedBreakdown: PeriodBreakdown?

    /// Cached because the dashboard reads it many times per render.
    var breakdown: PeriodBreakdown {
        if let cachedBreakdown { return cachedBreakdown }
        let breakdown = UsageQuery(snapshot: snapshot ?? UsageSnapshot(), priceBook: priceBook)
            .breakdown(range, offset: offset, metric: metric)
        cachedBreakdown = breakdown
        return breakdown
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
        // Reconcile periodically in case FSEvents missed a write, and start
        // watching a provider installed after launch. With nothing changed a
        // pass costs one directory walk and writes nothing.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startWatching()
                self?.rescan()
                self?.refreshPrices()
            }
        }
        refreshTimer?.tolerance = 60
    }

    /// Pulls published rates from OpenRouter, at most once a day.
    ///
    /// Deliberately not awaited before the first scan: the chart paints from the
    /// cached rates immediately, and only rescans if the fetch changed
    /// something. A failed fetch leaves the cache in place.
    func refreshPrices(force: Bool = false) {
        // Checked in memory so the periodic pass does not decode the cached
        // price list only to learn it is still fresh.
        if !force, let pricesFetchedAt, Date().timeIntervalSince(pricesFetchedAt) < PriceCatalog.maxAge { return }
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
        let current = snapshot
        Task.detached(priority: .utility) { [weak self] in
            // Throttled: the scanner reports once per transcript, and every
            // update re-renders the menu and the dashboard.
            var lastReported = Date.distantPast
            do {
                let result = try scanner.scan(skippingUnchanged: current) { update in
                    guard Date().timeIntervalSince(lastReported) > 0.25 else { return }
                    lastReported = Date()
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
        // The window on screen is relative to today, which may have changed.
        cachedBreakdown = nil

        if let result {
            snapshot = result
            palette = ChartPalette(snapshot: result)
        }
        // Checked on unchanged passes too, so the widget still rolls over at midnight.
        if let snapshot, widgetReloadPolicy.shouldReload(snapshot: snapshot, pricesFetchedAt: pricesFetchedAt) {
            WidgetCenter.shared.reloadAllTimelines()
        }

        if rescanQueued {
            rescanQueued = false
            rescan()
        }
    }

    /// Watches only roots that exist. Watching a missing root's nearest
    /// ancestor could mean the whole home folder; the periodic pass calls this
    /// again so a provider installed later is picked up.
    private func startWatching() {
        let roots = providers.flatMap(\.presentRoots)
        guard roots != watchedRoots else { return }
        watchedRoots = roots
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
