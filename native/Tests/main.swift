import Foundation

// Command-line tests for everything below the UI: chord parsing (checked against the
// old JS parser's output), the synth (rendered offline), navigation and the beat
// timeline, and linked-screen sync over a fake jittery network.
//
//   ./Tests/run.sh
//
// Compiled together with Shared/*.swift (see run.sh). No XCTest: runs on Command Line
// Tools, and the band computer can run it too.

var fails = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "ok   " : "FAIL ") + msg)
    if !ok { fails += 1 }
}
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func section(_ name: String) { print("\n== \(name)") }

let here = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let demo = try! SongLibrary.parse(Data(contentsOf: here.appendingPathComponent("../app/songs.example.js")))

// MARK: - chords: same answers as app/chords.js

section("chord parsing vs the JS parser (Tests/chords-ref.json)")
do {
    let ref = try! JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("Tests/chords-ref.json"))) as! [String: Any]
    var bad: [String] = []
    for (name, v) in ref {
        let got = ChordTheory.parse(name)
        guard let want = v as? [String: Any] else {
            if got != nil { bad.append("\(name): want nil, got \(got!)") }
            continue
        }
        guard let g = got else { bad.append("\(name): got nil"); continue }
        let vo = want["voicing"] as! [String: Any], gv = ChordTheory.voicing(g)
        if g.root != want["root"] as! Int || g.bass != want["bass"] as! Int || g.tones != want["tones"] as! [Int]
            || gv.pad != vo["pad"] as! [Int] || gv.bass != vo["bass"] as! Int {
            bad.append("\(name): want \(want) got \(g) \(gv)")
        }
    }
    bad.prefix(8).forEach { print("     " + $0) }
    check(bad.isEmpty, "\(ref.count) chord symbols parse and voice like the JS version (\(bad.count) differ)")
}

// MARK: - synth, rendered offline

section("synth")
func render(_ seconds: Double, _ setup: (SynthCore) -> Void) -> [Float] {
    let core = SynthCore(sampleRate: 44100)
    setup(core)
    var out = [Float](repeating: 0, count: Int(seconds * 44100))
    out.withUnsafeMutableBufferPointer { p in
        var i = 0
        while i < p.count {
            let n = min(512, p.count - i)
            core.render(p.baseAddress! + i, frames: n, heardMs: nil)
            i += n
        }
    }
    return out
}
func stats(_ x: ArraySlice<Float>) -> (rms: Double, peak: Double) {
    var s = 0.0, pk = 0.0
    for v in x { s += Double(v * v); pk = max(pk, Double(abs(v))) }
    return (sqrt(s / Double(max(1, x.count))), pk)
}
/// Energy at one frequency (Goertzel), normalized.
func tone(_ x: ArraySlice<Float>, _ f: Double) -> Double {
    let w = 2 * Double.pi * f / 44100, c = 2 * cos(w)
    var a = 0.0, b = 0.0
    for v in x { let n = Double(v) + c * a - b; b = a; a = n }
    return sqrt(max(0, a * a + b * b - c * a * b)) / Double(x.count)
}

do {
    let spb = 60.0 / 154, prog = ["F#m", "D", "A", "E/G#", "F#m7(9,11)", "Dmaj7", "A7(b9)/Eb", "Esus4"]
    let playEnd = 0.2 + Double(prog.count) * 4 * spb
    var rmss: [Double] = []
    for p in SynthCore.patches {
        let x = render(playEnd + 1) { core in
            for (i, c) in prog.enumerated() {
                core.play(chord: c, at: 0.2 + Double(i) * 4 * spb, dur: 4 * spb, patch: p, spb: spb)
            }
        }
        let body = stats(x[Int(0.2 * 44100)..<Int(playEnd * 44100)])
        let tail = stats(x[Int((playEnd + 0.5) * 44100)...])
        rmss.append(body.rms)
        check(body.rms > 0.05 && body.peak < 0.95 && tail.peak < 0.002,
              "\(p.padding(toLength: 6, withPad: " ", startingAt: 0)) rms \(String(format: "%.3f", body.rms)) peak \(String(format: "%.2f", body.peak)) tail \(String(format: "%.1e", tail.peak))")
    }
    check(rmss.max()! / rmss.min()! < 2, "patches within 6 dB of each other")

    let gs2 = 103.83   // E/G#: the bass note
    let bassOnly = render(2.5) { $0.play(chord: "E/G#", at: 0.1, dur: 2, patch: "pad", spb: 0.4, chords: false, bass: true) }
    let chordsOnly = render(2.5) { $0.play(chord: "E/G#", at: 0.1, dur: 2, patch: "pad", spb: 0.4, chords: true, bass: false) }
    let both = render(2.5) { $0.play(chord: "E/G#", at: 0.1, dur: 2, patch: "pad", spb: 0.4) }
    let sb = stats(bassOnly[...]), sboth = stats(both[...])
    check(sb.rms > 0.02 && sb.peak < 0.9, "bass alone audible, peak \(String(format: "%.2f", sb.peak))")
    check(tone(chordsOnly[8820..<88200], gs2) < tone(bassOnly[8820..<88200], gs2) / 5, "chords-only has no G#2 bass note")
    check(sboth.peak < 0.95, "chords + bass: peak \(String(format: "%.2f", sboth.peak))")
    let none = SynthCore(sampleRate: 44100)
    check(!none.play(chord: "E", at: 0, dur: 1, patch: "pad", spb: 0.5, chords: false, bass: false)
          && !none.play(chord: "N.C.", at: 0, dur: 1, patch: "pad", spb: 0.5), "nothing to play: silent")

    let clicks = render(1) { $0.click(at: 0.1, accent: true); $0.click(at: 0.5, accent: false) }
    let c1 = stats(clicks[4410..<8000]), c2 = stats(clicks[22050..<26000]), gap = stats(clicks[12000..<20000])
    check(c1.peak > 0.7 && c2.peak > 0.35 && c2.peak < c1.peak && gap.peak < 0.001,
          "click: accent \(String(format: "%.2f", c1.peak)), beat \(String(format: "%.2f", c2.peak)), silent between")
    check(abs(Double(clicks.firstIndex { abs($0) > 0.01 }!) - 4410) < 60, "click lands on its sample (±1.4 ms)")

    let cut = render(3) { core in
        core.play(chord: "C", at: 0.1, dur: 2.5, patch: "organ", spb: 0.5)
        core.play(chord: "F", at: 1.5, dur: 1, patch: "organ", spb: 0.5)   // scheduled ahead, then stopped
        core.silenceChords(at: 1.0)
    }
    check(stats(cut[Int(0.5 * 44100)..<Int(0.9 * 44100)]).peak > 0.05 && stats(cut[Int(1.1 * 44100)...]).peak < 0.0001,
          "stop fades ringing and scheduled chords within 80 ms")
}

// MARK: - played parts (midi/<slug>-bass.mid)

section("MIDI parts")
// A hand-built file: 3/4, ppq 96, one count-in bar, then C2 on beat 0 (note-on vel 0 as
// the off, running status) and E2 on beat 1.5 for half a beat (a real note-off).
func vlq(_ v: Int) -> [UInt8] {
    var out = [UInt8(v & 0x7F)], v = v >> 7
    while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
    return out
}
let trk: [UInt8] = [0x00, 0xFF, 0x58, 0x04, 3, 2, 24, 8]               // 3/4
    + vlq(288) + [0x90, 36, 100] + vlq(96) + [36, 0]                       // bar 2 beat 0, running status off
    + vlq(48) + [0x90, 40, 70] + vlq(48) + [0x80, 40, 0]                   // beat 1.5, half a beat
    + [0x00, 0xFF, 0x2F, 0x00]
let smf: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, 0x4D, 0x54, 0x72, 0x6B,
                    0, 0, UInt8(trk.count >> 8), UInt8(trk.count & 0xFF)] + trk
let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("oo-midi-test-\(getpid())")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let threeJS = #"[{"slug":"waltz","title":"Waltz","bpm":90,"key":"C","sections":[{"name":"A","from":2,"to":3,"rows":[{"bars":[[{"c":"C","b":3}],[{"c":"E","b":3}]],"lyrics":["",""]}]}]}]"#
let waltz = try! SongLibrary.parse(Data(threeJS.utf8))
try! Data(smf).write(to: tmpDir.appendingPathComponent("waltz-bass.mid"))
SongLibrary.attachParts(waltz, dirs: [tmpDir])
let wn = waltz[0].bassPart?.notes ?? []
check(wn.count == 2 && wn[0].beat == 0 && wn[0].len == 1 && wn[0].note == 36 + MidiPart.transpose,
      "hand-built .mid: count-in bar skipped (3/4), running status + vel-0 off (\(wn.map { "\($0.note)@\($0.beat)x\($0.len)" }))")
check(wn.count == 2 && wn[1].beat == 1.5 && wn[1].len == 0.5 && wn[1].vel == 70, "note-off and velocity read")
check(waltz[0].bassPart?.notes(from: 1, to: 2).map { $0.note } == [40 + MidiPart.transpose], "notes(from:to:) finds the off-beat note")
check(demo.allSatisfy { $0.bassPart == nil }, "songs without a file keep the generated bass")

let realMid = here.appendingPathComponent("../midi/digital-love-glitch-bass.mid")
let realSongs = here.appendingPathComponent("../app/songs.js")
if FileManager.default.fileExists(atPath: realMid.path), let all = try? SongLibrary.parse(Data(contentsOf: realSongs)),
   let dlg = all.first(where: { $0.slug == "digital-love-glitch" }) {
    SongLibrary.attachParts([dlg], dirs: [realMid.deletingLastPathComponent()])
    let part = dlg.bassPart
    check(part?.notes.count == 583, "Digital Love Glitch: \(part?.notes.count ?? 0) bass notes read")
    // Line-up check: where a note starts right on a chord change, is it that chord's bass?
    var hit = 0, total = 0
    for (bi, bar) in dlg.bars.enumerated() {
        var at = dlg.barStart[bi]
        for c in bar.chords {
            if let ch = ChordTheory.parse(c.c), let n = part?.notes(from: at - 0.1, to: at + 0.1).min(by: { $0.note < $1.note }) {
                total += 1; if n.note % 12 == ch.bass { hit += 1 }
            }
            at += c.b
        }
    }
    check(total > 50 && Double(hit) / Double(total) > 0.8,
          "lined up with the chart: \(hit)/\(total) chord changes start on that chord's bass note")
    check(part?.leadIn == 1, "found the file's 1-bar lead-in")
    // Every part in midi/: it must belong to a song and line up with its chart.
    let midiDir = realMid.deletingLastPathComponent()
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: midiDir.path)) ?? []).filter { $0.hasSuffix("-bass.mid") }.sorted()
    SongLibrary.attachParts(all, dirs: [midiDir])
    for f in files {
        let slug = String(f.dropLast("-bass.mid".count))
        guard let p = all.first(where: { $0.slug == slug })?.bassPart else { check(false, "\(f): no song with slug \(slug)"); continue }
        check(p.fit.of > 50 && Double(p.fit.hits) >= 0.95 * Double(p.fit.of),
              "\(f): \(p.leadIn)-bar lead-in, \(p.fit.hits)/\(p.fit.of) chord changes on the root")
    }
} else {
    print("skip Digital Love Glitch part (needs ../midi and app/songs.js)")
}
let bassOut = render(1.0) { $0.bass(note: 45, at: 0.1, dur: 0.4, vel: 100) }
let bs = stats(bassOut[4410..<22050])
check(bs.rms > 0.02 && bs.peak < 1 && tone(bassOut[4410..<22050], 110) > tone(bassOut[4410..<22050], 220),
      "a part note sounds at its pitch (A2 110 Hz, rms \(String(format: "%.3f", bs.rms)))")
check(stats(bassOut[30870...]).rms < 0.001, "and stops after its length")

// MARK: - navigation and the beat timeline

section("navigation")
UserDefaults.standard.removeObject(forKey: Rehearsal.Saved.key)
let solo = Rehearsal(synth: nil, sync: nil)
solo.boot((demo, "test"))
let song = solo.song!
check(solo.pickerOpen && solo.row == 0, "fresh device: first song, song list open")
solo.fire(.nextSection)              // picker: opens the selected song
check(!solo.pickerOpen, "picker: Enter/] opens the song")
solo.fire(.next); solo.fire(.next)
check(solo.row == 2, "next twice -> row 2 (row \(solo.row))")
solo.fire(.prevSection)
check(solo.row == song.firstRowOfSection[song.rows[2].sec], "back from mid-section -> top of the section")
let secBefore = song.rows[solo.row].sec
solo.fire(.nextSection)
check(song.rows[solo.row].sec == min(secBefore + 1, song.sections.count - 1) && song.rows[solo.row].inSec == 0,
      "] -> top of the next section (section \(secBefore) -> \(song.rows[solo.row].sec))")
solo.fire(.restart)
check(solo.row == 0, "Home -> bar 1")
solo.fire(.loop)
check(solo.loop?.kind == "section" && solo.loop?.label == song.sections[0].name, "O loops the section (\(solo.loop?.label ?? "-"))")
solo.fire(.loop)
check(solo.loop == nil, "O again: loop off")
solo.fire(.faster); solo.fire(.faster5)
check(solo.bpmOf(song) == song.bpm + 6, "+ and . -> \(solo.bpmOf(song)) bpm")
solo.fire(.tempoReset)
check(solo.bpmOf(song) == song.bpm && solo.setBpms[song.slug] == nil, "0 -> chart tempo")
solo.fire(.patch)
check(solo.chords && solo.patch == "keys", "J -> keys, and turns chords on")
solo.fire(.bass)
check(solo.bass, "N -> bass on")

section("tempo timeline")
solo.fire(.play)
let r0 = solo.run!
let spbMs = 60000 / r0.bpm
check(r0.countIn == 1, "P starts with one bar of count-in at \(Int(r0.bpm)) bpm")
spin((r0.t0 + spbMs * 1.5 - HostClock.now()) / 1000)
check(solo.countIn == 2 && solo.bar == -1, "count-in shows 2 on beat 2 (shows \(solo.countIn.map(String.init) ?? "-"))")
spin((r0.t0 + spbMs * 6.5 - HostClock.now()) / 1000)
check(solo.bar == song.rows[0].firstBar + 0 && solo.beat == 2, "beat 7 = bar 1 beat 3 (bar \(solo.bar) beat \(solo.beat))")
spin((r0.t0 + spbMs * 12.5 - HostClock.now()) / 1000)
check(solo.bar == 2 && solo.beat == 0, "beat 13 = bar 3 beat 1 (bar \(solo.bar) beat \(solo.beat))")
solo.fire(.faster5)                       // retime: lands on a future downbeat, same grid
let r1 = solo.run!
let downbeatsLater = (r1.t0 - r0.t0) / spbMs
check(Int(r1.bpm) == Int(r0.bpm) + 5 && abs(downbeatsLater - downbeatsLater.rounded()) < 0.01 && Int(downbeatsLater.rounded()) % 4 == 0,
      "tempo change waits for the next unscheduled downbeat (\(Int(downbeatsLater.rounded())) beats on)")
solo.fire(.play)
check(!solo.tempo && solo.run == nil && solo.bar == -1, "P stops")

section("page mode")
solo.goRow(0)
solo.fire(.page)
check(solo.page && solo.tempo && solo.run?.countIn == 0, "G: page mode, timeline running, no count-in")
let pr = solo.pageRows()
solo.fire(.next)
check(solo.row == min(pr.1 + 1, song.rows.count - 1) && solo.pageRow == solo.row, "pedal turns a whole page (row \(pr.0) -> \(solo.row))")
solo.fire(.prev)
let pr2 = solo.pageRows()
check(solo.row == pr2.0, "back from the top of a page -> previous page's start")
solo.pointer(x: 0.9)
let tapRow = solo.row
check(tapRow == pr2.0 + 1, "page mode: a tap still moves one line (row \(pr2.0) -> \(tapRow))")
solo.goRow(pr2.0)
solo.swipe(1)
check(solo.row == min(pr2.1 + 1, song.rows.count - 1), "page mode: swipe left turns a whole page")
solo.fire(.page)
check(!solo.page, "G again: page mode off")

section("taps and swipes (no page mode)")
solo.goRow(0)
solo.pointer(x: 0.9); solo.pointer(x: 0.9); solo.pointer(x: 0.1)
check(solo.row == 1, "right, right, left tap -> row 1 (row \(solo.row))")
solo.goRow(0)
let sw = solo.pageRows()
solo.swipe(1)
check(solo.row == sw.1 + 1, "swipe left -> first line past the screen (row \(sw.1) -> \(solo.row))")
check(!(sw.0...sw.1).contains(solo.pageRows().1), "and the screen moved on (now \(solo.pageRows()))")
solo.swipe(-1)
check(solo.row == 0, "swipe right -> back to the screen it came from (row \(solo.row))")
solo.swipe(-1)
check(solo.row == 0, "swipe right at the top stays put")
for _ in 0..<200 { solo.swipe(1) }
check(solo.row == song.rows.count - 1, "swiping off the end stops on the last line")
solo.goRow(0)

// The demo's sections all fit on one screen; a 14-line verse exercises the sliding window.
func rows(_ n: Int) -> String { (0..<n).map { _ in #"{"bars":[[{"c":"C","b":4}]],"lyrics":["la"]}"# }.joined(separator: ",") }
let longJS = #"[{"slug":"long","title":"Long","bpm":120,"key":"C","sections":["#
    + #"{"name":"Intro","rows":["# + rows(2) + "]},"
    + #"{"name":"Verse","rows":["# + rows(14) + "]},"
    + #"{"name":"Out","rows":["# + rows(3) + "]}]}]"
let longLib = try! SongLibrary.parse(Data(longJS.utf8))
let lr = Rehearsal(synth: nil, sync: nil)
lr.boot((longLib, "test")); lr.fire(.nextSection)
let ls = lr.song!, verse = ls.firstRowOfSection[1], outro = ls.firstRowOfSection[2]
var seen: [Int] = []
lr.goRow(verse)
while ls.rows[lr.row].sec == 1 { seen.append(lr.row - verse); lr.swipe(1) }
check(seen == [0, 6, 11], "long verse: swipes land on lines \(seen) (5 new lines per screen, 1 kept for context)")
check(lr.row == outro, "and the next swipe leaves for the next section")
lr.swipe(-1)
check(lr.row - verse == 9 && lr.pageRows().1 == outro - 1, "back from the next section -> the verse's last screen (line \(lr.row - verse))")
lr.swipe(-1); let b1 = lr.row - verse
lr.swipe(-1); let b2 = lr.row - verse
check(b1 == 4 && b2 == 0, "back again -> line \(b1), then the verse's top (\(b2))")
lr.swipe(-1)
check(lr.row == 0, "back from the verse's top -> the intro")
solo.fire(.play)

// MARK: - linked screens

section("linked screens (fake network: 4 ms + exponential jitter, 10% of pings dropped)")
final class Hub {
    var ends: [String: FakeLink] = [:]
    var linked = Set<String>()
    func link(_ names: [String]) {
        linked = Set(names)
        for n in names { ends[n]!.onPeers?(names.filter { $0 != n }.map { (id: $0, name: $0) }) }
    }
}
final class FakeLink: PeerTransport {
    var onMessage: ((String, String) -> Void)?
    var onPeers: (([(id: String, name: String)]) -> Void)?
    let id: String, hub: Hub
    init(_ id: String, _ hub: Hub) { self.id = id; self.hub = hub; hub.ends[id] = self }
    func start() {}
    func send(_ json: String, to: String, reliable: Bool) {
        for (other, end) in hub.ends where other != id && hub.linked.contains(other) && hub.linked.contains(id) {
            if !to.isEmpty && to != other { continue }
            if !reliable && Double.random(in: 0..<1) < 0.1 { continue }
            let lat = 4 - log(1 - Double.random(in: 0..<1)) * 8
            DispatchQueue.main.asyncAfter(deadline: .now() + lat / 1000) { end.onMessage?(json, self.id) }
        }
    }
}
let hub = Hub()
func device(_ n: String) -> Rehearsal {
    UserDefaults.standard.removeObject(forKey: Rehearsal.Saved.key)
    let m = Rehearsal(synth: nil, sync: Sync(link: FakeLink(n, hub)))
    m.boot((try! SongLibrary.parse(Data(contentsOf: here.appendingPathComponent("../app/songs.example.js"))), "test"))
    m.closePicker()
    return m
}
let A = device("A"), B = device("B")
hub.link(["A", "B"])
spin(1.2)
check(A.peerNames == ["B"] && B.sync!.toLocal(0, from: "A") != nil, "A and B linked, clock offset measured")

A.fire(.next); A.fire(.next); A.fire(.nextSection)
spin(0.2)
check(A.row == B.row && A.song?.slug == B.song?.slug, "page turns follow (A row \(A.row), B row \(B.row))")

B.fire(.play)                              // any device can lead
spin(3)
func apart(_ x: Rehearsal, _ y: Rehearsal) -> Double { abs(x.run!.t0 - y.run!.t0) }
check(A.tempo && B.tempo, "B starts: both playing")
check(apart(A, B) < 5, "start aligned: \(String(format: "%.2f", apart(A, B))) ms apart")
check(A.bar == B.bar && A.row == B.row, "same bar now (A \(A.bar).\(A.beat), B \(B.bar).\(B.beat))")

A.fire(.nextSection)
spin(1.5)
check(A.run!.fromBar == B.run!.fromBar && apart(A, B) < 5, "jump from A: fromBar \(A.run!.fromBar)/\(B.run!.fromBar), \(String(format: "%.2f", apart(A, B))) ms")

B.fire(.faster)
spin(0.8)
check(A.run!.bpm == B.run!.bpm && apart(A, B) < 5, "tempo nudge from B: \(Int(A.run!.bpm))/\(Int(B.run!.bpm)) bpm, \(String(format: "%.2f", apart(A, B))) ms")

A.fire(.loop); A.setRamp(2)
spin(0.8)
check(A.run!.loop == B.run!.loop && B.run!.loop?.ramp == 2 && apart(A, B) < 5, "loop + speed trainer reach B on the same grid")
A.fire(.loop); A.setRamp(0)

let C = device("C")
hub.link(["A", "B", "C"])
spin(2)
check(C.tempo && C.song?.slug == A.song?.slug && apart(A, C) < 5 && C.bar == A.bar,
      "late joiner C: bar \(C.bar) vs A \(A.bar), \(C.run.map { String(format: "%.2f", abs($0.t0 - A.run!.t0)) } ?? "-") ms")

C.fire(.play)
spin(0.3)
check(!A.tempo && !B.tempo && !C.tempo, "stop from C reaches everyone")

B.fire(.link)
B.fire(.restart)
A.fire(.next)
spin(0.3)
check(B.row == 0 && A.row != 0 && !B.linkEnabled, "unlinked B stays put (A row \(A.row), B row \(B.row))")

// The wire format is the web build's: a JS "state" message drives this build too.
let jsState = #"{"slug":"\#(demo[0].slug)","row":3,"bars":\#(demo[0].bars.count),"at":\#(HostClock.wall() + 1e6),"bpm":101,"loop":null,"ramp":0,"run":null,"t":"state","n":999}"#
A.sync!.setEnabled(true)
hub.ends["B"]!.send(jsState, to: "", reliable: true)
spin(0.2)
check(A.row == 3 && A.bpmOf(A.song!) == 101, "a web-view build's state message is understood (row \(A.row), \(A.bpmOf(A.song!)) bpm)")

print(fails == 0 ? "\nall passed" : "\n\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
