import SwiftUI
import AppKit

@main
struct DoddyApp: App {
    @StateObject private var manager = DownloadManager.shared

    init() {
        // Chrome launches this same binary with --host (via a tiny wrapper script)
        // to act as the native messaging host. It never reaches the UI.
        if CommandLine.arguments.contains("--host") {
            HostMode.run()
        }
        // Only one Doddy at a time: if another copy is already running, bring it forward and quit this one.
        let bid = Bundle.main.bundleIdentifier ?? "io.github.bunduuk.doddy"
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated && $0.activationPolicy != .prohibited }) {
            other.activate(options: [.activateAllWindows])
            exit(0)
        }
        Installer.registerHost()
        Notifier.requestPermission()
        UpdateChecker.checkIfDue()
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DockMode.install()
        }
    }

    var body: some Scene {
        Window("Doddy", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 780, minHeight: 480)
        }

        MenuBarExtra {
            MenuView().environmentObject(manager)
        } label: {
            Image(nsImage: MenuBarIcon.image(active: manager.activeCount > 0))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SetupView().frame(width: 520).padding()
        }
    }
}


/// The menu bar ignores SwiftUI font sizes on symbols, so the icon is drawn at a fixed size here.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let name = active ? "arrow.down.circle.fill" : "arrow.down.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 17.5, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Doddy")?.withSymbolConfiguration(config)
        let img = base ?? NSImage()
        img.isTemplate = true
        return img
    }
}
