import AppKit
import SwiftUI

/// Opens the polish editor in its own window.
///
/// A sheet is clamped to the width of the window that presents it, and the
/// capture window is deliberately narrow — so the editor was being squeezed into
/// a third of the room it needs. A second SwiftUI `WindowGroup` isn't an option
/// either: in this SwiftPM-built executable, adding one stops the primary window
/// from being presented at all. Hosting an `NSWindow` directly sidesteps both and
/// gives the editor the workspace it deserves: resizable, full-screenable, and
/// open alongside the recorder rather than on top of it.
@MainActor
enum EditorWindow {
    private static var open: [String: NSWindow] = [:]

    static func show(for url: URL) {
        // Re-opening the same clip should raise the window you already have,
        // not stack a second copy of it.
        if let existing = open[url.path] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = url.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 620)
        window.tabbingMode = .disallowed
        window.center()

        window.contentView = NSHostingView(
            rootView: EditorView(sourceURL: url) { [weak window] in window?.close() })

        open[url.path] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { open[url.path] = nil }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
