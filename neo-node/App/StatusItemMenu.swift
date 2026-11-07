import AppKit

/// Right-click (or Control-click) on the menu bar icon shows a small menu with Quit.
/// SwiftUI's MenuBarExtra has no secondary-click hook, so this watches clicks on the status item's window.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // Event monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { StatusItemMenu.shared.handle(event) }
            return handled ? nil : event
        }
    }

    /// Returns true when the click was a secondary click on our menu bar icon (and the menu was shown).
    private func handle(_ event: NSEvent) -> Bool {
        let isSecondary = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isSecondary,
              let window = event.window,
              String(describing: type(of: window)).contains("StatusBarWindow"),
              let view = window.contentView else { return false }

        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit neo-node", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { StatusItemMenu.shared.install() }
    }
}
