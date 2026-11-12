import SwiftUI

/// Built to be read from across a room on a TV or monitor. Dark only on purpose (stage
/// use), high contrast. Sizes are fractions of the screen (the web version's vh/vw), so
/// the same layout reads on a 65" TV, a Mac, an iPad and an iPhone.
enum Theme {
    static let bg = Color(hex: 0x0b0c0e)
    static let panel = Color(hex: 0x15171b)
    static let line = Color(hex: 0x2a2d33)
    static let ink = Color(hex: 0xf3f1ea)
    static let dim = Color(hex: 0x6c6f76)
    static let faint = Color(hex: 0x3b3e45)
    static let hot = Color(hex: 0xffcc33)        // current row / bar
    static let hotInk = Color(hex: 0x14110a)
    static let accent = Color(hex: 0xff5a36)     // section names, tempo mode
    static let lyric = Color(hex: 0xd9d6cc)
    static let barCurrent = Color(hex: 0x24262c)
    static let linkOn = Color(hex: 0x3fbf6f)

    enum Weight { case regular, bold, heavy, italic, boldItalic }

    /// Helvetica Neue (the web version's --sans). fixedSize: stage text never follows
    /// Dynamic Type, it follows the screen.
    static func sans(_ size: CGFloat, _ w: Weight = .regular) -> Font {
        let name: String
        switch w {
        case .regular: name = "HelveticaNeue"
        case .bold, .heavy: name = "HelveticaNeue-Bold"
        case .italic: name = "HelveticaNeue-Italic"
        case .boldItalic: name = "HelveticaNeue-BoldItalic"
        }
        return .custom(name, fixedSize: max(1, size))
    }

    /// Avenir Next Condensed (--cond): chords, section names, the count-in.
    static func cond(_ size: CGFloat, _ w: Weight = .bold) -> Font {
        let name: String
        switch w {
        case .regular, .italic: name = "AvenirNextCondensed-Regular"
        case .bold, .boldItalic: name = "AvenirNextCondensed-Bold"
        case .heavy: name = "AvenirNextCondensed-Heavy"
        }
        return .custom(name, fixedSize: max(1, size))
    }

    static let mono = { (size: CGFloat) in Font.system(size: max(1, size), design: .monospaced) }
}

/// Screen-relative units: vh = 1% of the height, vw = 1% of the width.
struct Metrics {
    let w: CGFloat, h: CGFloat
    func vh(_ n: CGFloat) -> CGFloat { h * n / 100 }
    func vw(_ n: CGFloat) -> CGFloat { w * n / 100 }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}
