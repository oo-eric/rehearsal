import Foundation
import Combine

/// The rehearsal display's brain: navigation, page mode, the tempo timeline, practice
/// tools (speed, loops, speed trainer), chord/bass playback, and linked-device sync.
/// The views only draw what's published here; every input arrives as an `Action`.
final class Rehearsal: ObservableObject {
    // MARK: published state

    @Published private(set) var songs: [Song] = []
    @Published private(set) var song: Song?
    @Published private(set) var row = 0          // flat row index
    @Published private(set) var bar = -1         // flat bar index lit in tempo mode
    @Published private(set) var beat = -1
    @Published private(set) var tempo = false
    @Published private(set) var click = Config.clickOnStart
    @Published private(set) var chords: Bool
    @Published private(set) var bass: Bool
    @Published private(set) var patch: String
    @Published private(set) var loop: Loop?      // bars repeated in tempo mode
    @Published private(set) var ramp = 0        // speed trainer: + bpm each loop pass, up to the chart tempo
    @Published private(set) var curBpm = 0.0     // bpm of the beat now playing (differs while ramping)
    @Published private(set) var pass = 0         // loop pass now playing (0 = first time through)
    @Published private(set) var page = false     // page mode: the pedal turns a screenful
    @Published private(set) var pageRow = 0      // flat row the displayed page starts at
    @Published private(set) var pedalTempo = false   // page mode has measured a tempo from the pedal
    @Published private(set) var countIn: Int?    // big count-in number, or nil
    @Published private(set) var setBpms: [String: Int]   // per-song set tempo (slug -> bpm)

    // overlays
    @Published private(set) var tempoOpen = false
    @Published private(set) var pickerOpen = false
    @Published private(set) var learnOpen = false
    @Published private(set) var pickSel = 0
    @Published private(set) var toast: String?
    @Published private(set) var learnLog: [LearnEntry] = []
    @Published private(set) var idle = false     // hide the key hints after a few quiet seconds
    @Published private(set) var peerNames: [String] = []
    @Published private(set) var linkEnabled = true
    @Published private(set) var songsSource = ""

    struct Loop: Equatable {
        let from: Int, to: Int
        let kind: String       // "section" | "line"
        let label: String
    }

    struct LearnEntry: Identifiable {
        let id = UUID()
        let kind: String
        let detail: String
        let action: String?
        let info: Bool
    }

    static let maxRows = 6     // longer sections scroll: a window of rows that follows the current one

    // MARK: collaborators

    var onFullscreen: (() -> Void)?
    var onMidiStatus: (() -> [String])?
    let synth: Synth?
    let sync: Sync?

    init(synth: Synth?, sync: Sync?) {
        self.synth = synth
        self.sync = sync
        saved = Saved.load()
        chords = saved.chords ?? false
        bass = saved.bass ?? (saved.chords ?? false)
        patch = SynthCore.patches.contains(saved.patch ?? "") ? saved.patch! : Config.chordPatch
        setBpms = saved.bpm
        wireSync()
    }

    // MARK: persistence (per device)

    struct Saved: Codable {
        var slug: String?
        var row: Int?
        var bpm: [String: Int] = [:]
        var chords: Bool?
        var bass: Bool?
        var patch: String?

        static let key = "oo-rehearsal-v1"
        static func load() -> Saved {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(Saved.self, from: d) else { return Saved() }
            return s
        }
        func store() {
            if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Saved.key) }
        }
    }
    private var saved: Saved
    private func persist() { saved.bpm = setBpms; saved.store() }

    // MARK: boot

    /// Load the songs and open where this device left off. Tests pass their own songs.
    func boot(_ library: (songs: [Song], source: String)? = nil) {
        let lib = library ?? SongLibrary.load()
        songs = lib.songs
        songsSource = lib.source
        note("app", "Songs loaded from \(lib.source)")
        for s in songs { if let p = s.bassPart { note("app", "\(s.title): bass from \(p.source), \(p.notes.count) notes, \(p.leadIn)-bar lead-in skipped, \(p.fit.hits)/\(p.fit.of) chord changes on the root") } }
        guard !songs.isEmpty else { return }
        wake()
        if let slug = saved.slug { openSong(slug, row: saved.row ?? 0) }
        else { openSong(songs[0].slug, row: 0); openPicker() }
        lastChange = 0   // opening the last song at launch isn't a change worth pushing to others
        sync?.start()
    }

    /// Re-read songs.js (Mac: View > Reload Songs) and stay on the same spot.
    func reloadSongs() {
        let slug = song?.slug, r = row
        let lib = SongLibrary.load()
        songs = lib.songs
        songsSource = lib.source
        note("app", "Songs loaded from \(lib.source)")
        if let s = slug { openSong(s, row: r) }
    }

    // MARK: derived

    func bpmOf(_ s: Song) -> Int { setBpms[s.slug] ?? s.bpm }
    /// What's playing right now (a ramping loop runs ahead of the song's set tempo).
    var nowBpm: Int {
        guard let s = song else { return 0 }
        return tempo && curBpm > 0 ? Int(curBpm.rounded()) : bpmOf(s)
    }

    /// Normally the window slides one row at a time to follow the current line. In page
    /// mode it stops sliding: the section is cut into fixed screenfuls, so the display
    /// holds still and then flips, and the pedal is the only thing that turns it.
    func pageBounds(_ sec: ChartSection, _ inSec: Int) -> (start: Int, shown: Int) {
        let n = sec.rows.count, m = Self.maxRows
        if page {
            let start = inSec / m * m
            return (start, min(m, n - start))
        }
        if n <= m { return (0, n) }
        return (max(0, min(n - m, inSec - 1)), m)
    }

    /// The row the display is anchored on (page mode: only navigation moves it).
    var anchorRow: Int { page ? pageRow : row }

    /// First and last flat row of the page on screen.
    func pageRows() -> (Int, Int) {
        guard let s = song else { return (0, 0) }
        let a = s.rows[anchorRow], sec = s.sections[a.sec], b = pageBounds(sec, a.inSec)
        let first = s.firstRowOfSection[a.sec] + b.start
        return (first, first + b.shown - 1)
    }

    // MARK: navigation

    func goRow(_ target: Int) {
        guard let s = song else { return }
        let idx = max(0, min(s.rows.count - 1, target))
        row = idx
        if page { pageRow = idx; markPage() }   // only navigation moves the page, never the beat
        saved.row = idx
        persist()
        let f = s.rows[idx]
        if let L = loop, f.firstBar > L.to || f.lastBar < L.from { loop = nil; showToast("Loop off") }
        if tempo { tempoJump(f.firstBar) }
        share()
    }

    func goSection(_ delta: Int) {
        guard let s = song else { return }
        let cur = s.rows[row].sec
        var target = max(0, min(s.sections.count - 1, cur + delta))
        // "back" from mid-section goes to the top of the current section first
        if delta < 0 && s.rows[row].inSec > 0 { target = cur }
        goRow(s.firstRowOfSection[target])
    }

    func openSong(_ slug: String, row r: Int) {
        guard let next = songs.first(where: { $0.slug == slug }) ?? songs.first else { return }
        tempoStop()
        song = next
        row = max(0, min(next.rows.count - 1, r))
        pageRow = row                 // openSong bypasses goRow, so anchor the page here too
        turnEst = []; turnAt = 0      // a new song is a new tempo; forget the old pages
        pedalTempo = false
        saved.slug = next.slug
        saved.row = row
        persist()
        pickerOpen = false
        share()
    }

    // MARK: page mode
    // One pedal press = one screenful. The gap between presses is a whole page of music,
    // a far steadier tempo measurement than tapping a beat: divide it by the beats
    // actually on that page and you get what the band is really playing.

    private var turnAt = 0.0, turnBeats = 0.0, turnEst: [Double] = []

    private func beatsBetween(_ first: Int, _ last: Int) -> Double {
        guard let s = song else { return 0 }
        var n = 0.0
        for i in s.rows[first].firstBar...s.rows[last].lastBar { n += s.bars[i].beats }
        return n
    }

    /// Remember where this page started and how long it is, for the next press to measure.
    private func markPage() {
        let pr = pageRows()
        turnAt = HostClock.now()
        turnBeats = beatsBetween(pr.0, pr.1)
    }

    private func measureTurn() {
        guard turnAt > 0, turnBeats > 0 else { return }
        let bpm = turnBeats * 60000 / (HostClock.now() - turnAt)
        // Out of range means it was not a page turn in time: a pause, a false step, a
        // restart. Drop the history rather than yanking the tempo somewhere absurd.
        if bpm < 40 || bpm > 260 { turnEst = []; pedalTempo = false; return }
        turnEst.append(bpm)
        if turnEst.count > 3 { turnEst.removeFirst() }
        pedalTempo = true
        setBpm(turnEst.reduce(0, +) / Double(turnEst.count))
    }

    private func turnPage(_ delta: Int) {
        guard let s = song else { return }
        let pr = pageRows()
        if delta > 0 {
            measureTurn()
            goRow(pr.1 + 1)                    // first row after this page; goRow clamps
        } else {
            turnEst = []; pedalTempo = false   // going back is not a tempo measurement
            // Back from mid-page restarts this page; back again leaves it. Same shape as
            // prevSection: a fumbled page costs one press, not a lost place.
            if row > pr.0 { goRow(pr.0); return }
            if pr.0 == 0 { goRow(0); return }
            let prev = s.rows[pr.0 - 1]        // land on the start of the page before
            let b = pageBounds(s.sections[prev.sec], prev.inSec)
            goRow(s.firstRowOfSection[prev.sec] + b.start)
        }
    }

    private func togglePage() {
        guard let s = song else { return }
        page.toggle()
        if page {
            pageRow = row
            turnEst = []; turnAt = 0; pedalTempo = false
            // Lines can only light themselves if the timeline is running. No count-in: in
            // page mode the band is already playing when the first page goes up.
            if !tempo {
                curBpm = 0; pass = 0
                startRun(Run(fromBar: s.rows[row].firstBar, t0: HostClock.now() + lead(80),
                             bpm: Double(bpmOf(s)), countIn: 0, loop: runLoop()))
            }
            markPage()
            showToast("Page mode · pedal turns the page")
        } else {
            showToast("Page mode off")
        }
        share()
    }

    // MARK: tempo mode: one beat timeline, sounds placed on the audio clock
    // A run is { fromBar, t0, bpm, countIn, loop }: t0 is the HostClock ms of its first
    // beat. The whole timeline follows from those numbers, so linked devices that agree
    // on the run (t0 converted to each one's own clock, see Sync) show the same bar and
    // click the same beat. Times stay in HostClock ms and become sample positions only
    // when a sound is scheduled ~150 ms ahead, so the two clocks can't drift apart.

    struct LoopSpan: Equatable { let from: Int, to: Int, ramp: Int }
    struct Run {
        var fromBar: Int
        var t0: Double
        var bpm: Double
        var countIn: Int
        var loop: LoopSpan?
        var peer: String? = nil       // set when following a linked device's run
        var t0Peer: Double? = nil     // that run's t0 in the leader's clock
    }
    struct Event {
        var t: Double
        var bar = -1                  // -1 = count-in
        var beat = 0
        var count = 0                 // count-in number shown
        var bpm = 0.0
        var pass = 0
        var chord = ""
        var cb = 0.0                  // beats the chord starting on this beat lasts (0 = none starts)
        var end = false
    }

    private(set) var run: Run?
    private var events: [Event] = []
    private var evIdx = 0, schedIdx = 0, schedUntil = -Double.infinity
    private var timer: Timer?
    private let ahead = 150.0, late = 30.0   // ms: schedule this far ahead; skip sounds this far past
    private let maxEvents = 6000             // beats (over 20 minutes of looping)

    /// The whole timeline follows from the run. A loop repeats bars from..to; with a
    /// ramp, each pass is `ramp` bpm faster until the chart tempo.
    private func buildEvents(_ r: Run) -> [Event] {
        guard let s = song else { return [] }
        var list: [Event] = []
        var bpm = r.bpm, spb = 60000 / bpm, t = r.t0
        let cap = max(Double(s.bpm), r.bpm)
        for c in 0..<(r.countIn * 4) {
            list.append(Event(t: t, bar: -1, beat: c % 4, count: c % 4 + 1, bpm: bpm))
            t += spb
        }
        var b = r.fromBar, pass = 0
        if let L = r.loop, b < L.from || b > L.to { b = L.from }
        while b < s.bars.count && list.count < maxEvents {
            var starts: [Double: ChordCell] = [:], acc = 0.0
            for ch in s.bars[b].chords { starts[acc] = ch; acc += ch.b }
            for k in 0..<Int(s.bars[b].beats.rounded(.up)) {
                let st = starts[Double(k)]
                list.append(Event(t: t, bar: b, beat: k, bpm: bpm, pass: pass, chord: st?.c ?? "", cb: st?.b ?? 0))
                t += spb
            }
            b += 1
            if let L = r.loop, b > L.to {
                b = L.from
                pass += 1
                if L.ramp != 0 { bpm = min(cap, r.bpm + Double(pass * L.ramp)); spb = 60000 / bpm }
            }
        }
        list.append(Event(t: t, end: true))
        return list
    }

    /// Start (or replace) the running timeline. reanchor = same run nudged by a few ms
    /// (clock-offset update from a linked device): don't replay beats already scheduled.
    private func startRun(_ r: Run, reanchor: Bool = false) {
        run = r
        events = buildEvents(r)
        evIdx = 0
        let now = HostClock.now()
        var skipTo = now - late
        if reanchor { skipTo = max(skipTo, schedUntil + 30000 / r.bpm) }   // half a beat
        else { schedUntil = -.infinity }
        schedIdx = 0
        while schedIdx < events.count - 1 && events[schedIdx].t < skipTo { schedIdx += 1 }
        if !reanchor { set(\.bar, -1); set(\.beat, -1) }
        set(\.tempo, true)
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    private func tick() { schedule(); frame() }

    private func schedule() {
        let now = HostClock.now()
        while schedIdx < events.count && events[schedIdx].t < now + ahead {
            let ev = events[schedIdx]
            if !ev.end && ev.t >= now - late, let synth = synth {
                if click { synth.click(atMs: ev.t, accent: ev.beat == 0) }
                // A song with a played bass part (midi/<slug>-bass.mid) uses it instead
                // of the generated root notes.
                let part = bass && ev.bar >= 0 ? song?.bassPart : nil
                if (chords || (bass && part == nil)) && ev.cb > 0 {
                    synth.play(chord: ev.chord, atMs: ev.t, dur: ev.cb * 60 / ev.bpm, patch: patch,
                               spb: 60 / ev.bpm, chords: chords, bass: bass && part == nil)
                }
                if let part = part, let s = song {
                    let b0 = s.barStart[ev.bar] + Double(ev.beat)
                    let barEnd = s.barStart[ev.bar] + s.bars[ev.bar].beats
                    let spbMs = 60000 / ev.bpm, pushed = MidiPart.pushed
                    // a beat owns the notes played just ahead of it too: a downbeat pushed
                    // early still sounds when a loop comes back around to it
                    for n in part.notes(from: b0 - pushed, to: min(b0 + 1, barEnd) - pushed) {
                        // notes keep their written length, even across a loop's end
                        synth.bass(note: n.note, atMs: ev.t + (n.beat - b0) * spbMs,
                                   dur: n.len * spbMs / 1000, vel: n.vel)
                    }
                }
                schedUntil = ev.t
            }
            schedIdx += 1
        }
    }

    private func frame() {
        guard tempo, let s = song else { return }
        let now = HostClock.now()
        while evIdx + 1 < events.count && events[evIdx + 1].t <= now { evIdx += 1 }
        guard evIdx < events.count else { return }
        let ev = events[evIdx]
        guard ev.t <= now else { return }
        if ev.end { tempoStop(); return }
        if ev.bar < 0 {
            set(\.countIn, ev.count)
            set(\.beat, ev.beat)
            return
        }
        set(\.countIn, nil)
        guard ev.bar != bar || ev.beat != beat else { return }
        set(\.bar, ev.bar)
        set(\.beat, ev.beat)
        set(\.curBpm, ev.bpm)
        set(\.pass, ev.pass)
        var r = s.bars[ev.bar].row
        // Page mode: the band may still be finishing the page when the measured tempo has
        // already run past it. Hold the highlight on the last line rather than turning
        // early -- a page turned too soon loses everyone's place.
        if page {
            let pr = pageRows()
            r = max(pr.0, min(pr.1, r))
        }
        if r != row { row = r; saved.row = r; persist() }
    }

    /// Publish only real changes: the frame timer runs at 120 Hz.
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<Rehearsal, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    /// Lead time before the first beat. Linked: long enough for the message to reach the
    /// other devices, so they don't join a beat late.
    private func lead(_ ms: Double) -> Double { (sync?.count ?? 0) > 0 ? max(ms, 200) : ms }

    private func runLoop() -> LoopSpan? { loop.map { LoopSpan(from: $0.from, to: $0.to, ramp: ramp) } }

    private func tempoStart() {
        guard let s = song else { return }
        curBpm = 0; pass = 0
        startRun(Run(fromBar: s.rows[row].firstBar, t0: HostClock.now() + lead(80), bpm: Double(bpmOf(s)),
                     countIn: Config.countInBars, loop: runLoop()))
    }

    /// Jump while running: restart the timeline at `bar`, right away, no count-in.
    private func tempoJump(_ bar: Int) {
        guard let s = song else { return }
        let spb = 60000 / Double(bpmOf(s))
        curBpm = 0; pass = 0
        synth?.silenceChords()
        startRun(Run(fromBar: bar, t0: HostClock.now() + lead(min(spb, 120)), bpm: Double(bpmOf(s)),
                     countIn: 0, loop: runLoop()))
    }

    /// Change tempo/loop without losing the groove: the new timeline picks up on the next
    /// downbeat that hasn't been scheduled yet, so the bar you're in plays out as it was.
    private func retime(_ bpm: Double? = nil) {
        guard tempo, let s = song else { return }
        let min = HostClock.now() + lead(ahead + 10)
        var e: Event?
        for i in evIdx..<events.count {
            let ev = events[i]
            if ev.end { break }
            if ev.bar >= 0 && ev.beat == 0 && ev.t >= min { e = ev; break }
        }
        guard let next = e, bar >= 0 else {        // count-in, or the song is ending: just jump
            tempoJump(bar >= 0 ? bar : s.rows[row].firstBar)
            return
        }
        startRun(Run(fromBar: next.bar, t0: next.t, bpm: bpm ?? next.bpm, countIn: 0, loop: runLoop()))
    }

    private func tempoStop() {
        synth?.silenceChords()
        timer?.invalidate(); timer = nil
        run = nil
        set(\.tempo, false)
        set(\.curBpm, 0); set(\.pass, 0)
        set(\.bar, -1); set(\.beat, -1)
        set(\.countIn, nil)
    }

    // MARK: tempo controls: set, nudge, percent, tap, loop, speed trainer
    // The set tempo is remembered per song (0 / Reset goes back to the chart's).

    func setBpm(_ value: Double) {
        guard let s = song else { return }
        let v = max(40, min(260, Int(value.rounded())))
        if v == s.bpm { setBpms[s.slug] = nil } else { setBpms[s.slug] = v }
        persist()
        retime(Double(v))
        share()
    }

    func nudgeTempo(_ d: Int) { setBpm(Double(nowBpm + d)) }

    private var taps: [Double] = []
    func tap() {
        guard let s = song else { return }
        let now = HostClock.now()
        if let last = taps.last, now - last > 2000 { taps = [] }
        taps.append(now)
        if taps.count > 6 { taps.removeFirst() }
        if taps.count < 3 { showToast("Tap \(taps.count)…"); return }
        let avg = (taps.last! - taps.first!) / Double(taps.count - 1)
        setBpm(60000 / avg)
        showToast("Tap tempo \(bpmOf(s))")
    }

    private func loopFor(_ kind: String) -> Loop? {
        guard let s = song else { return nil }
        let cur = s.rows[row]
        if kind == "line" {
            return Loop(from: cur.firstBar, to: cur.lastBar, kind: "line",
                        label: "bars \(s.bars[cur.firstBar].num)–\(s.bars[cur.lastBar].num)")
        }
        let sec = s.sections[cur.sec], first = s.firstRowOfSection[cur.sec]
        let last = s.rows[first + sec.rows.count - 1]
        return Loop(from: s.rows[first].firstBar, to: last.lastBar, kind: "section", label: sec.name)
    }

    func toggleLoop(_ kind: String = "section") {
        loop = loop?.kind == kind ? nil : loopFor(kind)
        showToast(loop.map { "Loop " + $0.label } ?? "Loop off")
        retime()
        share()
    }

    func setRamp(_ n: Int) {
        ramp = n
        if loop != nil { retime() }
        share()
    }

    // MARK: sounds (per device, remembered)

    private func toggleClick() {
        click.toggle()
        synth?.start()
    }

    private func toggleChords() {
        chords.toggle()
        saved.chords = chords
        persist()
        if chords { synth?.start() } else { synth?.silenceChords() }
        showToast(chords ? "Chords on" + (tempo ? "" : (Theme.keyHints ? " (they play in tempo mode, P)" : " (they play in tempo mode)")) : "Chords off")
    }

    /// Bass is its own sound: on with the chords for the full guide, or alone (with the
    /// click) to lock in with the drummer without a pad covering the guitars.
    private func toggleBass() {
        bass.toggle()
        saved.bass = bass
        persist()
        if bass { synth?.start() } else { synth?.silenceChords() }
        let played = song?.bassPart != nil ? " · played part" : ""
        showToast(bass ? "Bass on" + played + (tempo ? "" : (Theme.keyHints ? " (it plays in tempo mode, P)" : " (it plays in tempo mode)")) : "Bass off")
    }

    /// Pick a patch (or the next one). Takes effect on the next chord change; turns
    /// chords on, since picking a sound means you want to hear it.
    func setPatch(_ p: String? = nil) {
        let list = SynthCore.patches
        patch = p ?? list[((list.firstIndex(of: patch) ?? -1) + 1) % list.count]
        saved.patch = patch
        if !chords { chords = true; saved.chords = true; synth?.start() }
        persist()
        showToast("Chords: " + (SynthCore.patchNames[patch] ?? patch))
    }

    // MARK: toast, idle

    private var toastWork: DispatchWorkItem?
    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    private var idleWork: DispatchWorkItem?
    /// Keys or the mouse moved: show the hints again, hide them after 3 s.
    func wake() {
        set(\.idle, false)
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.idle = true }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    // MARK: song picker

    func openPicker() {
        tempoStop()
        pickSel = songs.firstIndex(where: { $0.slug == song?.slug }) ?? 0
        pickerOpen = true
        share()
    }

    func closePicker() { if song != nil { pickerOpen = false } }
    func pick(_ i: Int) { if songs.indices.contains(i) { openSong(songs[i].slug, row: 0) } }

    // MARK: panels

    func toggleTempoPanel() { tempoOpen.toggle() }
    func toggleLearn() { learnOpen.toggle() }

    // MARK: input
    // Every input arrives here: keyboard (named like the web's KeyboardEvent.key), tap
    // position, MIDI bytes. Each is reported to the learn panel, then mapped to an Action.

    private func report(_ kind: String, _ detail: String, _ action: Action?, info: Bool = false) {
        guard learnOpen || info else { return }
        learnLog.insert(LearnEntry(kind: kind, detail: detail, action: action?.rawValue, info: info), at: 0)
        if learnLog.count > 12 { learnLog.removeLast(learnLog.count - 12) }
    }

    /// A status line for the learn panel (not an input).
    func note(_ kind: String, _ detail: String) { report(kind, detail, nil, info: true) }

    /// Returns true if the key did something (so the Mac doesn't beep).
    @discardableResult
    func key(_ name: String, detail: String, isRepeat: Bool = false) -> Bool {
        wake()
        // keys that only mean something inside an overlay
        if learnOpen && name == "m" { midiStatus() }
        if pickerOpen && name == "Enter" { pick(pickSel); return true }
        let action = Config.action(forKey: name)
        report("key", "\(name)   (\(detail))", action)
        if let a = action, !isRepeat || a == .faster || a == .slower { fire(a) }
        return action != nil
    }

    /// Tap/click on the page area: x as a fraction of the width. Always one line, even in
    /// page mode (swipe for whole pages).
    func pointer(x: Double) {
        guard Config.pointer, !anyOverlay else { return }
        let back = x < 1.0 / 3
        report("pointer", (back ? "left" : "right") + " side tap", back ? .prev : .next)
        stepLine(back ? -1 : 1)
    }

    /// Horizontal swipe on the page area: +1 = next screenful (finger moved left), -1 = back.
    func swipe(_ delta: Int) {
        guard Config.pointer, !anyOverlay else { return }
        report("pointer", delta > 0 ? "swipe left" : "swipe right", delta > 0 ? .next : .prev)
        if page { turnPage(delta) } else { scrollPage(delta) }
    }

    private var anyOverlay: Bool { tempoOpen || pickerOpen || learnOpen }

    private func stepLine(_ delta: Int) {
        goRow(row + delta)
        // In page mode goRow re-marks the page clock; a line tap isn't a page turn, so
        // don't let the next pedal press measure tempo from it.
        if page { turnAt = 0; turnEst = []; pedalTempo = false }
    }

    /// Outside page mode the window slides with the current line, so "a page" is the rows
    /// on screen now. Forward lands just past them (the old last line stays on top as
    /// context); back is the mirror image, and crosses into the previous section's last
    /// screenful from a section's first line.
    private func scrollPage(_ delta: Int) {
        guard let s = song else { return }
        if delta > 0 { goRow(pageRows().1 + 1); return }
        let cur = s.rows[row], step = Self.maxRows - 1
        // inSec 1 shows the same window as 0; land on the section's top line instead
        func land(_ sec: Int, _ inSec: Int) { goRow(s.firstRowOfSection[sec] + (inSec <= 1 ? 0 : inSec)) }
        if cur.inSec > 0 { land(cur.sec, max(0, cur.inSec - step)); return }
        guard cur.sec > 0 else { goRow(0); return }
        land(cur.sec - 1, max(0, s.sections[cur.sec - 1].rows.count - step))
    }

    func midi(_ d: [UInt8], from: String) {
        guard d.count >= 2 else { return }
        let status = d[0] & 0xF0, ch = Int(d[0] & 0x0F) + 1, number = Int(d[1])
        var value = d.count > 2 ? Int(d[2]) : 127
        let type: String
        switch status {
        case 0xB0: type = "cc"
        case 0x90: type = "note"
        case 0xC0: type = "pc"; value = 127
        default: return
        }
        let action = Config.action(midiType: type, number: number)
        report("midi", "\(type) \(number) value \(value) (ch \(ch))" + (from.isEmpty ? "" : "  from \(from)"), action)
        if let a = action, value >= 64 { fire(a) }
    }

    private func midiStatus() {
        let names = onMidiStatus?() ?? []
        note("midi", "MIDI devices: " + (names.isEmpty ? "(none connected)" : names.joined(separator: ", ")))
    }

    func fire(_ action: Action) {
        if learnOpen { if action == .learn { toggleLearn() }; return }   // learn panel swallows input
        if pickerOpen {
            switch action {
            case .next: pickSel = min(songs.count - 1, pickSel + 1)
            case .prev: pickSel = max(0, pickSel - 1)
            case .nextSection: pick(pickSel)
            case .songs: closePicker()
            case .fullscreen: onFullscreen?()
            default: break
            }
            return
        }
        guard let s = song else { return }
        if action == .songs && tempoOpen { tempoOpen = false; return }   // Esc closes the panel
        switch action {
        case .next: if page { turnPage(1) } else { goRow(row + 1) }
        case .prev: if page { turnPage(-1) } else { goRow(row - 1) }
        case .nextSection: goSection(1)
        case .prevSection: goSection(-1)
        case .restart: goRow(0)
        case .play: if tempo { tempoStop() } else { tempoStart() }; share()
        case .click: toggleClick()
        case .chords: toggleChords()
        case .patch: setPatch()
        case .bass: toggleBass()
        case .faster: nudgeTempo(1)
        case .slower: nudgeTempo(-1)
        case .faster5: nudgeTempo(5)
        case .slower5: nudgeTempo(-5)
        case .tempoReset: setBpm(Double(s.bpm)); showToast("Chart tempo \(s.bpm)")
        case .tap: tap()
        case .loop: toggleLoop("section")
        case .tempo: toggleTempoPanel()
        case .songs: openPicker()
        case .fullscreen: onFullscreen?()
        case .learn: toggleLearn()
        case .link: toggleLink()
        case .page: togglePage()
        }
    }

    // MARK: linked devices
    // Whoever acts last leads: every song/row/play/stop/jump/tempo change goes out as a
    // full snapshot and every linked device adopts it. Sounds stay per device.
    // A device that links up mid-song gets a "hello" snapshot, adopted only if it is
    // newer than the last change made here (so two idle devices don't swap songs).

    private var lastChange = 0.0, applying = false
    private var pending: (m: Sync.Message, peer: String)?
    private var warned = Set<String>(), known = Set<String>()

    private func snapshot() -> Sync.Message {
        guard let s = song else { return [:] }
        var m: Sync.Message = ["slug": s.slug, "row": row, "bars": s.bars.count, "at": lastChange,
                               "bpm": bpmOf(s), "ramp": ramp]
        m["loop"] = loop.map { ["from": $0.from, "to": $0.to, "kind": $0.kind, "label": $0.label] } ?? NSNull()
        if let r = run {
            m["run"] = ["fromBar": r.fromBar, "t0": r.t0, "bpm": r.bpm, "countIn": r.countIn,
                        "loop": r.loop.map { ["from": $0.from, "to": $0.to, "ramp": $0.ramp] as [String: Any] } ?? NSNull()]
        } else {
            m["run"] = NSNull()
        }
        return m
    }

    private func share() {
        guard !applying, song != nil else { return }
        lastChange = HostClock.wall()
        pending = nil
        if let sync = sync, sync.enabled { sync.send("state", snapshot()) }
    }

    private func applyState(_ m: Sync.Message, from peer: String) {
        pending = nil
        guard let slug = m["slug"] as? String else { return }
        guard songs.contains(where: { $0.slug == slug }) else {
            warnOnce("slug:" + slug, "A linked device is on “\(slug)”, which this one doesn't have. Update songs.js.")
            return
        }
        applying = true
        defer { applying = false }
        lastChange = num(m["at"]) ?? 0
        let mRow = Int(num(m["row"]) ?? 0)
        if song?.slug != slug { openSong(slug, row: mRow) }
        pickerOpen = false
        guard let s = song else { return }
        if let bars = num(m["bars"]), Int(bars) != s.bars.count {
            warnOnce("bars:" + s.slug, "A linked device has a different chart for \(s.title) (\(Int(bars)) bars here vs \(s.bars.count)). Update songs.js on both.")
        }
        // the band's tempo and loop, not this device's own
        if let b = num(m["bpm"]), b > 0 {
            if Int(b) == s.bpm { setBpms[s.slug] = nil } else { setBpms[s.slug] = Int(b) }
        }
        if let L = m["loop"] as? [String: Any], let f = num(L["from"]), let t = num(L["to"]) {
            loop = Loop(from: Int(f), to: Int(t), kind: L["kind"] as? String ?? "section", label: L["label"] as? String ?? "")
        } else {
            loop = nil
        }
        ramp = Int(num(m["ramp"]) ?? 0)
        if let rm = m["run"] as? [String: Any], let peerT0 = num(rm["t0"]) {
            let fromBar = Int(num(rm["fromBar"]) ?? 0)
            let barRow = s.bars[min(fromBar, s.bars.count - 1)].row
            if let t0 = sync?.toLocal(peerT0, from: peer) {
                var rl: LoopSpan?
                if let L = rm["loop"] as? [String: Any], let f = num(L["from"]), let t = num(L["to"]) {
                    rl = LoopSpan(from: Int(f), to: Int(t), ramp: Int(num(L["ramp"]) ?? 0))
                }
                let r = Run(fromBar: fromBar, t0: t0, bpm: num(rm["bpm"]) ?? Double(bpmOf(s)),
                            countIn: Int(num(rm["countIn"]) ?? 0), loop: rl, peer: peer, t0Peer: peerT0)
                startRun(r, reanchor: run?.peer == peer && run?.t0Peer == peerT0)
                row = barRow
            } else {
                // no clock offset yet: show the spot, start on the first pong
                pending = (m, peer)
                if tempo { tempoStop() }
                row = min(barRow, s.rows.count - 1)
            }
        } else {
            if tempo { tempoStop() }
            row = max(0, min(s.rows.count - 1, mRow))
        }
        pageRow = row                 // a page-mode follower turns with the leader
        saved.row = row
        persist()
    }

    private func warnOnce(_ key: String, _ text: String) {
        guard !warned.contains(key) else { return }
        warned.insert(key)
        note("sync", text)
    }

    private func wireSync() {
        guard let sync = sync else { return }
        linkEnabled = sync.enabled
        sync.on("state") { [weak self] m, peer in self?.applyState(m, from: peer) }
        sync.on("hello") { [weak self] m, peer in
            guard let self = self, (num(m["at"]) ?? 0) > self.lastChange else { return }
            self.applyState(m, from: peer)
        }
        sync.onOffset { [weak self] peer in
            guard let self = self else { return }
            if let p = self.pending, p.peer == peer { self.applyState(p.m, from: peer); return }
            // Clocks drift a few ms a minute: keep a followed run anchored to the leader's clock.
            if var r = self.run, r.peer == peer, let tp = r.t0Peer, let t0 = self.sync?.toLocal(tp, from: peer),
               abs(t0 - r.t0) > 1 {
                r.t0 = t0
                self.startRun(r, reanchor: true)
            }
        }
        sync.onPeers { [weak self] list in
            guard let self = self else { return }
            self.peerNames = list.map(\.name)
            // introduce ourselves to anyone new; their side decides whether we're newer
            if self.song != nil && self.lastChange > 0 {
                for p in list where !self.known.contains(p.id) { sync.send(to: p.id, "hello", self.snapshot()) }
            }
            self.known = Set(list.map(\.id))
        }
    }

    private func toggleLink() {
        guard let sync = sync else { return }
        sync.setEnabled(!sync.enabled)
        linkEnabled = sync.enabled
        note("sync", sync.enabled ? "Linked: following other OO Rehearsal screens nearby." : "Unlinked: this screen goes solo.")
        if sync.enabled { share() }   // take the lead from wherever this screen is
    }
}
