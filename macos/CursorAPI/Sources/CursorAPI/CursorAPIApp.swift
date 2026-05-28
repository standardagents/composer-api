import CursorAPICore
import AppKit
import Combine
import Sparkle
import SwiftUI

@main
@MainActor
final class CursorAPIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retainedDelegate: CursorAPIAppDelegate?

    private let model = CursorAPIAppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var mainWindow: NSWindow?
    private var terminationReplyPending = false
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = CursorAPIAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        delegate.installMainMenu()
        delegate.observeModel()
        app.finishLaunching()
        delegate.installApplicationIcon()
        DispatchQueue.main.async {
            delegate.applyMenuBarMode(delegate.model.settings.menuBarOnly, revealIfRegular: true)
            delegate.model.startServerWithoutPromptIfReady()
        }
        app.run()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !model.settings.menuBarOnly, mainWindow == nil {
            revealMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.settings.menuBarOnly {
            model.setMenuBarOnly(false)
            applyMenuBarMode(false, revealIfRegular: true)
        } else {
            revealMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.settings.menuBarOnly
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else {
            return .terminateNow
        }
        terminationReplyPending = true
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopServer()
    }

    private func observeModel() {
        model.$settings
            .map(\.menuBarOnly)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                self?.applyMenuBarMode(enabled, revealIfRegular: true)
            }
            .store(in: &cancellables)

        model.$statusText
            .combineLatest(model.$isRunning, model.$settings)
            .sink { [weak self] _, _, _ in
                self?.updateStatusMenu()
            }
            .store(in: &cancellables)
    }

    private func applyMenuBarMode(_ enabled: Bool, revealIfRegular: Bool) {
        if enabled {
            installStatusItemIfNeeded()
            updateStatusMenu()
            mainWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
            if revealIfRegular {
                revealMainWindow()
            }
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarTemplateIcon()
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = CursorAPIBrand.displayName
        }
        statusItem = item
    }

    private static func menuBarTemplateIcon() -> NSImage {
        standardAgentsMenuBarBitmapIcon() ?? standardAgentsMenuBarVectorIcon()
    }

    private static func standardAgentsMenuBarBitmapIcon() -> NSImage? {
        let pointSize = NSSize(width: 18, height: 18)
        let pixelSize = 72
        let bytesPerPixel = 4
        let bytesPerRow = pixelSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: pixelSize * pixelSize * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.setFillColor(NSColor.black.cgColor)
        context.interpolationQuality = .high

        let inset = CGFloat(pixelSize) * 0.09
        let iconRect = CGRect(
            x: inset,
            y: inset,
            width: CGFloat(pixelSize) - (inset * 2),
            height: CGFloat(pixelSize) - (inset * 2)
        )

        context.saveGState()
        context.translateBy(x: iconRect.minX, y: iconRect.minY + iconRect.height)
        context.scaleBy(x: iconRect.width / 150, y: -iconRect.height / 150)
        context.addPath(standardAgentsLogoPath())
        context.fillPath(using: .winding)
        context.restoreGState()

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let templateCGImage = CGImage(
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: templateCGImage)
        representation.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(representation)
        image.isTemplate = true
        image.accessibilityDescription = CursorAPIBrand.displayName
        return image
    }

    private static func standardAgentsMenuBarVectorIcon() -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            let inset = rect.width * 0.09
            let iconRect = rect.insetBy(dx: inset, dy: inset)
            context.saveGState()
            context.setFillColor(NSColor.black.cgColor)
            context.translateBy(x: iconRect.minX, y: iconRect.minY + iconRect.height)
            context.scaleBy(x: iconRect.width / 150, y: -iconRect.height / 150)
            context.addPath(standardAgentsLogoPath())
            context.fillPath(using: .winding)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = CursorAPIBrand.displayName
        return image
    }

    private static func standardAgentsLogoPath() -> CGPath {
        let path = CGMutablePath()

        path.move(to: CGPoint(x: 44.06, y: 0))
        path.addLine(to: CGPoint(x: 44.06, y: 44.08))
        path.addLine(to: CGPoint(x: 0, y: 44.08))
        path.addLine(to: CGPoint(x: 0, y: 150))
        path.addLine(to: CGPoint(x: 105.93, y: 150))
        path.addLine(to: CGPoint(x: 105.93, y: 105.93))
        path.addLine(to: CGPoint(x: 150, y: 105.93))
        path.addLine(to: CGPoint(x: 150, y: 0))
        path.closeSubpath()

        path.move(to: CGPoint(x: 19.09, y: 130.91))
        path.addCurve(
            to: CGPoint(x: 44.05, y: 45.73),
            control1: CGPoint(x: 2.62, y: 114.44),
            control2: CGPoint(x: 13.80, y: 76.46)
        )
        path.addLine(to: CGPoint(x: 44.05, y: 105.93))
        path.addLine(to: CGPoint(x: 104.28, y: 105.93))
        path.addCurve(
            to: CGPoint(x: 19.08, y: 130.91),
            control1: CGPoint(x: 73.55, y: 136.20),
            control2: CGPoint(x: 35.57, y: 147.40)
        )
        path.closeSubpath()

        path.move(to: CGPoint(x: 105.93, y: 104.29))
        path.addLine(to: CGPoint(x: 105.93, y: 44.08))
        path.addLine(to: CGPoint(x: 45.72, y: 44.08))
        path.addCurve(
            to: CGPoint(x: 130.91, y: 19.09),
            control1: CGPoint(x: 76.46, y: 13.80),
            control2: CGPoint(x: 114.42, y: 2.60)
        )
        path.addCurve(
            to: CGPoint(x: 105.93, y: 104.29),
            control1: CGPoint(x: 147.42, y: 35.58),
            control2: CGPoint(x: 136.22, y: 73.56)
        )
        path.closeSubpath()

        return path
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu(title: CursorAPIBrand.displayName)

        let statusMenuItem = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let urlItem = NSMenuItem(title: model.baseURL, action: #selector(copyLocalAPIURL(_:)), keyEquivalent: "")
        urlItem.target = self
        menu.addItem(urlItem)
        menu.addItem(.separator())

        let fullAppItem = NSMenuItem(title: "Show Full App", action: #selector(showFullApp(_:)), keyEquivalent: "")
        fullAppItem.target = self
        menu.addItem(fullAppItem)

        let serverTitle = model.isRunning ? "Stop Server" : "Start Server"
        let serverItem = NSMenuItem(title: serverTitle, action: #selector(toggleServerFromStatusItem(_:)), keyEquivalent: "")
        serverItem.target = self
        serverItem.isEnabled = model.isRunning || model.canStartServer
        menu.addItem(serverItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(CursorAPIBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func installApplicationIcon() {
        let iconURLs = [
            Bundle.module.url(forResource: "APIForCursor", withExtension: "png"),
            Bundle.main.url(forResource: "APIForCursor", withExtension: "png"),
            Bundle.main.url(forResource: "APIForCursor", withExtension: "icns")
        ].compactMap(\.self)

        for iconURL in iconURLs {
            guard let icon = NSImage(contentsOf: iconURL) else {
                continue
            }
            icon.isTemplate = false
            NSApplication.shared.applicationIconImage = icon
            return
        }
    }

    private func revealMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if let window = mainWindow {
            window.contentViewController = NSHostingController(rootView: CursorAPIAppRootView(model: model))
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

    @objc private func showFullApp(_ sender: Any?) {
        model.setMenuBarOnly(false)
        applyMenuBarMode(false, revealIfRegular: true)
    }

    @objc private func copyLocalAPIURL(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.baseURL, forType: .string)
    }

    @objc private func toggleServerFromStatusItem(_ sender: Any?) {
        if model.isRunning {
            model.stopServer()
        } else {
            model.startServerWithoutPromptIfReady()
        }
        updateStatusMenu()
    }

    @objc private func minimizeMainWindow(_ sender: Any?) {
        mainWindow?.miniaturize(sender)
    }

    @objc private func zoomMainWindow(_ sender: Any?) {
        mainWindow?.performZoom(sender)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: CursorAPIBrand.displayName)
        appMenu.addItem(withTitle: "About \(CursorAPIBrand.displayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updatesItem = appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = self
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

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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
