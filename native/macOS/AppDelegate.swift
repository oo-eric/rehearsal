import AppKit
import IOKit.pwr_mgt
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let stage = Stage()
    private var sleepAssertion = IOPMAssertionID(0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "OO Rehearsal"
        window.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = stage.webView
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("StageWindow")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(stage.webView)

        stage.onFullscreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        stage.load()

        // Keep the display awake while the app is open (replaces `caffeinate -d`).
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "OO Rehearsal is on screen" as CFString,
                                    &sleepAssertion)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: menu

    @objc private func reload(_ sender: Any?) { stage.load() }

    @objc private func showSongsFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([WebRoot.userSongsFolder()])
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let name = "OO Rehearsal"

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        let r = viewMenu.addItem(withTitle: "Reload Songs", action: #selector(reload(_:)), keyEquivalent: "r")
        r.target = self
        viewMenu.addItem(.separator())
        let sf = viewMenu.addItem(withTitle: "Show Songs Folder", action: #selector(showSongsFolder(_:)), keyEquivalent: "")
        sf.target = self
        viewItem.submenu = viewMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu
        return main
    }
}
