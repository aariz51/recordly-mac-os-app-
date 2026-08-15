import SwiftUI
import AppKit

/// A SwiftPM-built executable does not automatically become a regular foreground
/// GUI app, so it can launch without a window-server connection and never show its
/// window. This delegate forces `.regular` activation and brings the app forward.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM-bundled executable can launch as a background process; force it to
        // become a normal foreground app so its window is presented and activatable.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ReclipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Reclip") {
            ContentView()
                .frame(minWidth: 480, minHeight: 560)
        }
        // Content sets the floor, not the ceiling: the window can grow, and the
        // capture column stays centred and readable at any width.
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .defaultSize(width: 520, height: 720)
    }
}
