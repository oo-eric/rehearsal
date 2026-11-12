import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var core: AppCore!
    private var sleepAssertion = IOPMAssertionID(0)
    private var monitors: [Any] = []
    private var idleSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        core = AppCore()
        let model = core.model

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "OO Rehearsal"
        window.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: StageView(model: model))
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("StageWindow")
        window.makeKeyAndOrderFront(nil)

        model.onFullscreen = { [weak self] in self?.window.toggleFullScreen(nil) }

        // Every key goes to the rehearsal (pedals, clickers, the keyboard). Cmd/Ctrl/Option
        // combos are left to the menus (Cmd-Q, Cmd-R, Ctrl-Cmd-F).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
            guard let model = model else { return e }
            if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
            model.key(Self.webName(e), detail: "keyCode \(e.keyCode)", isRepeat: e.isARepeat)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak model] e in
            model?.wake()
            return e
        } as Any)
        // A few quiet seconds: hide the pointer along with the key hints.
        idleSub = model.$idle.sink { idle in if idle { NSCursor.setHiddenUntilMouseMoves(true) } }

        // Keep the display awake while the app is open (replaces `caffeinate -d`).
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "OO Rehearsal is on screen" as CFString,
                                    &sleepAssertion)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        listenForTestCommands()
        #endif
    }

    #if DEBUG
    /// Debug builds only: drive the app from a shell and snapshot the window, for tests.
    /// Post a distributed notification "oo.rehearsal.test" whose object is one of
    ///   key:<name>     a key press, e.g. key:p, key:ArrowRight
    ///   tap:<x>        a tap at x (0-1 of the width) on the page area
    ///   snap:<path>    write the window's content to a PNG
    ///   size:<w>x<h>   resize the window
    ///   audio:<path>   write the audio engine's render position to a file
    private func listenForTestCommands() {
        DistributedNotificationCenter.default().addObserver(forName: .init("oo.rehearsal.test"), object: nil,
                                                            queue: .main) { [weak self] n in
            guard let self = self, let cmd = n.object as? String,
                  let colon = cmd.firstIndex(of: ":") else { return }
            let verb = cmd[..<colon], arg = String(cmd[cmd.index(after: colon)...])
            switch verb {
            case "key": self.core.model.key(arg, detail: "test")
            case "tap": self.core.model.pointer(x: Double(arg) ?? 0.9)
            case "size":
                let p = arg.split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { self.window.setContentSize(NSSize(width: p[0], height: p[1])) }
            case "audio":   // how far the audio engine has rendered, and where "now" maps
                let core = self.core.model.synth?.core
                let line = "rendered \(core?.renderedTime ?? -1) now \(core?.coreTime(atMs: HostClock.now()) ?? -1)\n"
                try? line.write(toFile: arg, atomically: true, encoding: .utf8)
            case "snap":
                guard let v = self.window.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            default: break
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The web's KeyboardEvent.key names, so Config.keys reads the same on every platform.
    static func webName(_ e: NSEvent) -> String {
        let named: [UInt16: String] = [
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            116: "PageUp", 121: "PageDown", 115: "Home", 119: "End",
            36: "Enter", 76: "Enter", 49: " ", 51: "Backspace", 117: "Delete", 53: "Escape", 48: "Tab",
        ]
        let shift = e.modifierFlags.contains(.shift)
        if let n = named[e.keyCode] { return shift ? "Shift+" + n : n }
        let chars = e.charactersIgnoringModifiers ?? ""
        if chars.count == 1 { return chars.lowercased() }
        return chars.isEmpty ? "keyCode-\(e.keyCode)" : chars
    }

    // MARK: menu

    @objc private func reload(_ sender: Any?) { core.model.reloadSongs() }

    @objc private func showSongsFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([SongLibrary.userSongsFolder()])
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
