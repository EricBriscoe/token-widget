import AppKit
import SwiftUI
import TokenWidgetCore

@main
struct TokenWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppDelegate.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("Token Widget", systemImage: "chart.bar.fill", isInserted: $showMenuBarIcon) {
            MenuBarMenu(store: delegate.store) { delegate.showDashboard() }
        }
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var store: UsageStore
    let openDashboard: () -> Void

    var body: some View {
        if let snapshot = store.snapshot {
            Text("Updated \(UsageFormat.relativeAge(of: snapshot.generatedAt))")
        }

        Button("Open Dashboard", action: openDashboard)
        Button("Rescan Now") { store.rescan() }
            .disabled(store.isScanning)

        Divider()

        Button("Quit Token Widget") { NSApp.terminate(nil) }
    }
}
