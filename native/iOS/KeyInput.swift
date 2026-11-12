import UIKit

/// Catches every hardware key press app-wide and hands it to `onKey` as a web-style
/// key name ("ArrowRight", "PageDown", " ", "p", "Shift+ArrowLeft"), so the
/// Config.swift bindings work no matter what has focus. Cmd/Ctrl/Option combos pass through.
final class RehearsalApplication: UIApplication {
    static var onKey: ((_ name: String, _ detail: String) -> Void)?

    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent, let handler = Self.onKey {
            var swallowed = false
            for press in presses.allPresses {
                guard let key = press.key else { continue }
                if !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty { continue }
                swallowed = true
                if press.phase == .began {
                    let name = Self.webName(key)
                    let detail = String(format: "HID 0x%02X", key.keyCode.rawValue)
                    handler(name, detail)
                }
            }
            if swallowed { return }
        }
        super.sendEvent(event)
    }

    static func webName(_ key: UIKey) -> String {
        let named: [UIKeyboardHIDUsage: String] = [
            .keyboardRightArrow: "ArrowRight", .keyboardLeftArrow: "ArrowLeft",
            .keyboardUpArrow: "ArrowUp", .keyboardDownArrow: "ArrowDown",
            .keyboardPageUp: "PageUp", .keyboardPageDown: "PageDown",
            .keyboardHome: "Home", .keyboardEnd: "End",
            .keyboardReturnOrEnter: "Enter", .keypadEnter: "Enter", .keyboardReturn: "Enter",
            .keyboardSpacebar: " ", .keyboardDeleteOrBackspace: "Backspace",
            .keyboardEscape: "Escape", .keyboardTab: "Tab",
        ]
        let shift = key.modifierFlags.contains(.shift)
        if let n = named[key.keyCode] { return shift ? "Shift+" + n : n }
        let chars = key.characters
        if chars.count == 1 { return chars.lowercased() == chars ? chars : chars.lowercased() }
        return chars.isEmpty ? String(format: "HID-0x%02X", key.keyCode.rawValue) : chars
    }
}
