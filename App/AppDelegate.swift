import AppKit
import SwiftUI
import TokenWidgetCore

/// Owns the scan pipeline and the dashboard window so the app can run headless.
///
/// The dashboard is a hand-managed NSWindow rather than a SwiftUI Window scene
/// because a scene opens itself at launch, and an accessory app has to decide
/// at runtime: launched as a login item it stays invisible; launched by hand it
/// shows the dashboard.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let showMenuBarIconKey = "showMenuBarIcon"

    let store = UsageStore()

    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With the menu bar icon hidden and no window, macOS would otherwise
        // treat the app as done and terminate it, which silently stops the
        // widget from getting fresh numbers.
        ProcessInfo.processInfo.disableAutomaticTermination("keeps the desktop widget fresh")

        store.start()
        if !launchedAsLoginItem {
            showDashboard()
        }
    }

    /// Opening the app while it is already running (Finder, Spotlight, `open`)
    /// lands here. It is the way back to the dashboard when the menu bar icon
    /// is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    /// A login item is launched with an open-application Apple event that
    /// names the trigger.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func showDashboard() {
        if dashboard == nil {
            let hosting = NSHostingController(rootView: DashboardView().environmentObject(store))
            // Carries the SwiftUI minimum frame through to the window so it
            // cannot be resized below a usable layout.
            hosting.sizingOptions = [.minSize]

            let window = NSWindow(contentViewController: hosting)
            window.title = "Token Widget"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("dashboard")
            window.delegate = self
            dashboard = window
            window.center()
        }
        guard let dashboard else { return }

        // While the dashboard is open the app behaves like a normal one: Dock
        // icon, Cmd-Tab, key window. The pause between the policy flip and
        // fronting is required. In the same runloop turn, the window can land
        // behind other apps and the main menu can come up unclickable.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            dashboard.makeKeyAndOrderFront(nil)
            dashboard.orderFrontRegardless()
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // After the close finishes; flipping mid-close hides the app from
        // Cmd-Tab while its window is still on screen.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
