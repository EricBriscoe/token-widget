import SwiftUI

@main
struct TokenWidgetApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        WindowGroup("Token Widget") {
            DashboardView()
                .environmentObject(store)
                .task { store.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Transcripts") { store.rescan() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Export History…") { store.exportHistory() }
                Button("Import History…") { store.importHistory() }
                Button("Restore Previous History") { store.restorePreviousHistory() }
                Button("Show Data Folder in Finder") { store.revealDataFolder() }

                Divider()

                Button("Rebuild History from Transcripts…") { store.rebuildHistory() }
            }
        }
    }
}
