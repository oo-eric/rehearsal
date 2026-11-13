import Foundation

/// A played part from a Standard MIDI File, in chart beats rather than seconds, so it
/// follows whatever tempo the band is practising at (loops and the speed trainer too).
///
/// Files are found by name: `midi/<song slug>-bass.mid`. Today only bass parts exist;
/// when a song has one it replaces the generated root-note bass.
///
/// Lining it up: a DAW export starts at the DAW's bar 1, which is often a bar or two of
/// lead-in before the chart's first bar (and the chart's bar numbers don't say how much:
/// Digital Love Glitch's chart starts at "bar 2", Totally Fine's at "bar 1", and both
/// files have exactly one bar of lead-in). So the part is lined up by ear: try each
/// whole-bar shift and keep the one where the most chord changes land on that chord's
/// bass note. The right shift wins by a mile (Totally Fine: 133/133 vs 51/132).
struct PartNote {
    let beat: Double     // chart beat the note starts on (0 = the chart's first downbeat)
    let len: Double      // beats
    let note: Int        // MIDI note as played (the file's, plus `transpose`)
    let vel: Int
}

struct MidiPart {
    let notes: [PartNote]          // sorted by beat
    let source: String

    /// How far ahead of a beat a played note can sit and still belong to it (humanized
    /// parts push some notes early; Digital Love Glitch's earliest is 0.12 beats ahead).
    static let pushed = 0.125

    /// DAW bass parts are written an octave above where they sound (Logic's bass
    /// instruments play them down an octave), so they come in an octave lower here.
    static let transpose = -12

    /// Notes starting in [from, to) chart beats.
    func notes(from: Double, to: Double) -> ArraySlice<PartNote> {
        var lo = 0, hi = notes.count
        while lo < hi { let mid = (lo + hi) / 2; if notes[mid].beat < from - 1e-6 { lo = mid + 1 } else { hi = mid } }
        var end = lo
        while end < notes.count && notes[end].beat < to - 1e-6 { end += 1 }
        return notes[lo..<end]
    }

    let leadIn: Int                // bars of the file before the chart's first bar
    let fit: (hits: Int, of: Int)  // chord changes that start on their bass note

    /// Read a .mid for `song`: every note on every track, ticks -> quarter beats, shifted
    /// by the best-fitting whole number of bars. Notes before the chart (lead-in) are dropped.
    static func load(_ url: URL, for song: Song) throws -> MidiPart {
        let smf = try MidiFile(Data(contentsOf: url))
        // Chord changes to listen for: (chart beat, bass pitch class)
        var changes: [(Double, Int)] = []
        for (bi, bar) in song.bars.enumerated() {
            var at = song.barStart[bi]
            for c in bar.chords {
                if let ch = ChordTheory.parse(c.c) { changes.append((at, ch.bass)) }
                at += c.b
            }
        }
        func shifted(_ bars: Int) -> [PartNote] {
            let offset = Double(bars) * smf.beatsPerBar
            return smf.notes.compactMap { n in
                let b = n.beat - offset
                return b < -pushed ? nil : PartNote(beat: b, len: n.len, note: n.note + transpose, vel: n.vel)
            }
        }
        var best: MidiPart?
        for bars in 0...8 {
            let part = MidiPart(notes: shifted(bars), source: url.lastPathComponent, leadIn: bars, fit: (0, 0))
            var hits = 0, of = 0
            for (at, pc) in changes {
                guard let low = part.notes(from: at - pushed, to: at + pushed).min(by: { $0.note < $1.note }) else { continue }
                of += 1
                if low.note % 12 == pc { hits += 1 }
            }
            // ties go to the smaller shift (a file with no lead-in, or no chords to judge by)
            if best == nil || hits > best!.fit.hits {
                best = MidiPart(notes: part.notes, source: part.source, leadIn: bars, fit: (hits, of))
            }
        }
        return best!
    }
}

/// Just enough of the Standard MIDI File format: header, tracks, running status, notes
/// (note-off or note-on with velocity 0 ends one), and the first time signature.
struct MidiFile {
    struct Note { let beat: Double; let len: Double; let note: Int; let vel: Int }
    private(set) var notes: [Note] = []
    private(set) var beatsPerBar = 4.0       // in quarter notes, from the first time signature

    enum Problem: Error { case notMidi, truncated, smpteTiming }

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var p = 0
        func u32() throws -> Int {
            guard p + 4 <= b.count else { throw Problem.truncated }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }

        guard b.count >= 14, b[0...3] == [0x4D, 0x54, 0x68, 0x64] else { throw Problem.notMidi }   // MThd
        p = 4
        let hlen = try u32()
        let ntracks = u16(10), division = u16(12)
        guard division & 0x8000 == 0 else { throw Problem.smpteTiming }
        let ppq = Double(division)
        p = 8 + hlen
        var sawTimeSig = false

        for _ in 0..<ntracks {
            guard p + 8 <= b.count else { throw Problem.truncated }
            let isTrack = b[p...p + 3] == [0x4D, 0x54, 0x72, 0x6B]          // MTrk
            p += 4
            let len = try u32(), end = min(b.count, p + len)
            defer { p = end }
            guard isTrack else { continue }
            var tick = 0, status: UInt8 = 0
            var on: [Int: (tick: Int, vel: Int)] = [:]      // key: channel << 8 | note
            func vlq() -> Int {
                var v = 0
                while p < end { let c = b[p]; p += 1; v = v << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
                return v
            }
            while p < end {
                tick += vlq()
                guard p < end else { break }
                if b[p] & 0x80 != 0 { status = b[p]; p += 1 }        // else running status
                switch status {
                case 0xFF:                                             // meta
                    guard p < end else { break }
                    let type = b[p]; p += 1
                    let n = vlq()
                    if type == 0x58, n >= 2, !sawTimeSig, p + 1 < end {
                        beatsPerBar = Double(b[p]) * 4 / pow(2, Double(b[p + 1]))
                        sawTimeSig = true
                    }
                    p += n
                case 0xF0, 0xF7:                                       // sysex
                    p += vlq()
                default:
                    let kind = status & 0xF0, ch = Int(status & 0x0F)
                    let size = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                    guard p + size <= end else { p = end; break }
                    let d1 = Int(b[p]), d2 = size > 1 ? Int(b[p + 1]) : 0
                    p += size
                    let key = ch << 8 | d1
                    if kind == 0x90 && d2 > 0 {
                        if let o = on[key] { close(o, tick, d1, ppq) }    // retrigger: end the old one
                        on[key] = (tick, d2)
                    } else if kind == 0x80 || kind == 0x90, let o = on.removeValue(forKey: key) {
                        close(o, tick, d1, ppq)
                    }
                }
            }
            for (key, o) in on { close(o, tick, key & 0xFF, ppq) }   // never released: to track end
        }
        notes.sort { $0.beat < $1.beat || ($0.beat == $1.beat && $0.note < $1.note) }
    }

    private mutating func close(_ o: (tick: Int, vel: Int), _ tick: Int, _ note: Int, _ ppq: Double) {
        notes.append(Note(beat: Double(o.tick) / ppq, len: Double(tick - o.tick) / ppq, note: note, vel: o.vel))
    }
}
