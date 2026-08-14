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

    private let store = SharedStore()
    private let providers: [TranscriptProvider] = [ClaudeCodeProvider(), CodexProvider()]
    private var watcher: DirectoryWatcher?
    /// Set while a scan is running so filesystem churn during the scan queues
    /// exactly one follow-up rather than a scan per event.
    private var rescanQueued = false

    var breakdown: PeriodBreakdown {
        UsageQuery(snapshot: snapshot ?? UsageSnapshot()).breakdown(range, offset: offset, metric: metric)
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func start() {
        snapshot = store.loadSnapshot()
        if let snapshot { palette = ChartPalette(snapshot: snapshot) }
        rescan()
        startWatching()
    }

    func rescan() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        lastError = nil

        let scanner = UsageScanner(providers: providers, store: store)
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
        let roots = providers.flatMap(\.presentRoots)
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

        store.reset()
        snapshot = nil
        palette = ChartPalette(models: [])
        rescan()
    }

    func restorePreviousHistory() {
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Merge a previously exported history into this one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let merged = try store.importHistory(from: url)
            snapshot = merged
            palette = ChartPalette(snapshot: merged)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SharedContainer.snapshotURL])
    }

    func step(by delta: Int) {
        offset = min(0, offset + delta)
    }
}
