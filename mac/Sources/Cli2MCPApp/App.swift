import AppKit
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func showMainWindow() {
        let window: NSWindow

        if let existing = mainWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "cli2mcp"
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ContentView()
                    .frame(minWidth: 900, minHeight: 600)
            )
            window.center()
            mainWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

@main
private enum Cli2MCPAppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        delegate.showMainWindow()

        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
