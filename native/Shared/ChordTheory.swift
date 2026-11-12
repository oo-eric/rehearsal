import Foundation

/// Chord symbol -> notes. Reads the charts' spellings: F#m, E/G#, Dmaj7, Bm7(9),
/// F#(7)sus4/D, A7(b9)/Eb, G#mb13/E, Ano3, Gno3(6), Eadd9, A#dim/F#, C#m7(9,b13), G5 ...
/// Anything it can't read (N.C., "(rest)") is nil, and plays nothing.
enum ChordTheory {
    struct Chord: Equatable {
        let root: Int        // pitch class 0-11
        let bass: Int        // pitch class of the lowest note (slash bass, or the root)
        let tones: [Int]     // semitones above the root
    }

    struct Voicing: Equatable {
        let pad: [Int]       // MIDI notes, ascending, in one octave window
        let bass: Int        // MIDI note
    }

    private static let pc: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    /// scale degree -> semitones above the root (7 = dominant 7th; maj7 handled separately)
    private static let deg: [Int: Int] = [2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 10, 9: 14, 11: 17, 13: 21]
    private static let token = try! NSRegularExpression(pattern: "maj|dim|aug|\\+|sus[24]?|no3|add|m|[b#]?\\d+")
    private static let parens = try! NSRegularExpression(pattern: "\\(([^)]*)\\)")

    /// "F#" / "Eb..." -> pitch class and how many characters the note name took.
    private static func pitchClass(_ s: Substring) -> (Int, Int)? {
        guard let first = s.first, let base = pc[first] else { return nil }
        let second = s.dropFirst().first
        let acc = second == "#" ? 1 : second == "b" ? -1 : 0
        return ((base + acc + 12) % 12, acc == 0 ? 1 : 2)
    }

    static func parse(_ name: String) -> Chord? {
        guard !name.isEmpty, let (root, len) = pitchClass(Substring(name)) else { return nil }
        var rest = String(name.dropFirst(len))
        var bass = root
        // slash bass: "/G#" at the very end
        if let slash = rest.range(of: "/", options: .backwards) {
            let after = rest[slash.upperBound...]
            if let (b, l) = pitchClass(after), l == after.count {
                bass = b
                rest = String(rest[..<slash.lowerBound])
            }
        }

        var paren: [String] = []
        let ns = rest as NSString
        for m in parens.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            paren += ns.substring(with: m.range(at: 1)).split(separator: ",").map { String($0) }
        }
        let main = parens.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: ns.length), withTemplate: "")

        var third: Int? = 4, fifth: Int? = 7, ext: [Int] = [], maj = false
        let isDimSymbol = main.contains("dim")

        func number(_ w: String, isAdd: Bool, inMain: Bool) {
            let acc = w.hasPrefix("b") ? -1 : w.hasPrefix("#") ? 1 : 0
            guard let d = Int(acc == 0 ? w : String(w.dropFirst())) else { return }
            if d == 5 && inMain && acc == 0 && !isAdd { third = nil; return }   // power chord
            if d == 5 && acc != 0 { fifth = 7 + acc; return }                  // b5 / #5
            if d == 7 {
                // dim7 is a double-flat 7th; "maj" anywhere means a major 7th
                ext.append(maj ? 11 : (third == 3 && fifth == 6 && inMain && isDimSymbol) ? 9 : 10)
                return
            }
            guard let semis = deg[d] else { return }
            ext.append(semis + acc)
            // a plain 9/11/13 in the symbol implies the 7th under it (C9, Cmaj9); "add9" doesn't
            if inMain && !isAdd && acc == 0 && d >= 9 { ext.append(maj ? 11 : 10) }
        }

        var add = false
        let mns = main as NSString
        for m in token.matches(in: main, range: NSRange(location: 0, length: mns.length)) {
            let w = mns.substring(with: m.range)
            switch w {
            case "maj": maj = true
            case "m": third = 3
            case "dim": third = 3; fifth = 6
            case "aug", "+": fifth = 8
            case "sus2": third = 2
            case "sus4", "sus": third = 5
            case "no3": third = nil
            case "add": add = true
            default:
                number(w, isAdd: add, inMain: true)
                add = false
            }
        }
        for w in paren {
            let t = w.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { number(t, isAdd: true, inMain: false) }
        }

        var tones = [0]
        if let t = third { tones.append(t) }
        if let f = fifth { tones.append(f) }
        return Chord(root: root, bass: bass, tones: tones + ext)
    }

    /// Pitch classes folded into one octave window, so every chord sits in the same
    /// range (they voice-lead on their own) and nothing gets muddy or shrill.
    static let padLow = 53, bassLow = 36       // F3..E4 pad, C2..B2 bass

    static func voicing(_ ch: Chord) -> Voicing {
        var seen = Set<Int>(), notes: [Int] = []
        for st in ch.tones {
            let p = (ch.root + st) % 12
            if seen.contains(p) { continue }
            seen.insert(p)
            notes.append(padLow + ((p - padLow) % 12 + 12) % 12)
        }
        notes.sort()
        return Voicing(pad: notes, bass: bassLow + ((ch.bass - bassLow) % 12 + 12) % 12)
    }
}
