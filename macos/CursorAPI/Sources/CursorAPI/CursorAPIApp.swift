import CursorAPICore
import AppKit
import SwiftUI

@main
@MainActor
final class CursorAPIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retainedDelegate: CursorAPIAppDelegate?

    private let model = CursorAPIAppModel()
    private var mainWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = CursorAPIAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        delegate.installMainMenu()
        app.finishLaunching()
        DispatchQueue.main.async {
            delegate.revealMainWindow()
            delegate.model.startServerWithoutPromptIfReady()
        }
        app.run()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if mainWindow == nil {
            revealMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func revealMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if let window = mainWindow {
            show(window)
            return
        }

        let window = NSWindow(
            contentRect: Self.defaultWindowFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = CursorAPIBrand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CursorAPIAppRootView(model: model))
        mainWindow = window
        show(window)
    }

    private func show(_ window: NSWindow) {
        let frame = window.frame.width < 100 || window.frame.height < 100 ? Self.defaultWindowFrame() : window.frame
        window.setFrame(frame, display: true)
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private static func defaultWindowFrame() -> NSRect {
        let size = NSSize(width: 893, height: 592)
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else {
            return
        }
        mainWindow = nil
    }

    @objc private func closeMainWindow(_ sender: Any?) {
        mainWindow?.performClose(sender)
    }

    @objc private func showMainWindow(_ sender: Any?) {
        revealMainWindow()
    }

    @objc private func minimizeMainWindow(_ sender: Any?) {
        mainWindow?.miniaturize(sender)
    }

    @objc private func zoomMainWindow(_ sender: Any?) {
        mainWindow?.performZoom(sender)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: CursorAPIBrand.displayName)
        appMenu.addItem(withTitle: "About \(CursorAPIBrand.displayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(CursorAPIBrand.displayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(CursorAPIBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(closeMainWindow(_:)), keyEquivalent: "w")
        closeWindowItem.target = self
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showWindowItem = windowMenu.addItem(withTitle: "Show \(CursorAPIBrand.displayName)", action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        showWindowItem.target = self
        windowMenu.addItem(.separator())
        let minimizeItem = windowMenu.addItem(withTitle: "Minimize", action: #selector(minimizeMainWindow(_:)), keyEquivalent: "m")
        minimizeItem.target = self
        let zoomItem = windowMenu.addItem(withTitle: "Zoom", action: #selector(zoomMainWindow(_:)), keyEquivalent: "")
        zoomItem.target = self
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

private struct CursorAPIAppRootView: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 760, minHeight: 560)
    }
}
