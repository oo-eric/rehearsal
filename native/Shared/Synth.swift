import AVFoundation
import os

/// The click, the chord patches (pad, keys, organ, pluck) and the bass, rendered
/// sample by sample from a fixed pool of voices.
///
/// Timing: everything is scheduled ahead (~150 ms) at an exact time on `HostClock`. The
/// render callback notes which HostClock time its buffer will be *heard* at (host time +
/// output latency), so a beat lands on the right sample, and a Mac and an iPad with
/// different speaker latencies click together.
///
/// `SynthCore` is the renderer with no audio hardware attached (tests render it
/// offline); `Synth` wires it to AVAudioEngine.
final class SynthCore {
    static let patches = ["pad", "keys", "organ", "pluck"]
    static let patchNames = ["pad": "Pad", "keys": "Keys", "organ": "Organ", "pluck": "Pluck"]

    let sampleRate: Double
    var chordVolume = Config.chordVolume

    // MARK: voices

    private enum Wave: UInt8 { case sine, saw, triangle, fm }

    /// One oscillator with its own envelope (and optionally a lowpass and tremolo).
    /// Plain values only: the render thread never allocates or retains.
    private struct Voice {
        var active = false
        var chordBus = false            // chords + bass (fades on stop/jump); false = click
        var start: Int64 = 0            // first sample
        var noteOff: Int64 = 0          // release starts
        var stop: Int64 = 0             // hard stop
        var killAt: Int64 = .max        // fast fade (silence) starts
        var wave = Wave.sine
        var dt = 0.0                    // frequency / sampleRate
        var phase = 0.0
        // FM (keys): modulator at the carrier frequency, index in Hz decaying over time
        var modPhase = 0.0
        var idx0 = 0.0, idxMul = 1.0, idxN: Int64 = 0, idx = 0.0
        // envelope: exponential attack -> exponential decay -> sustain (or glide to a
        // target) -> exponential release
        var level = 0.0001
        var attackN: Int64 = 0, attackMul = 1.0
        var decayN: Int64 = 0, decayMul = 1.0
        var susTarget = 0.0, susK = 1.0, glide = false
        var relK = 1.0
        var gain = 1.0                  // fixed scale (drawbar, harmonic level)
        // lowpass (pad, pluck): RBJ biquad, cutoff can sweep exponentially
        var filter = false
        var cut = 0.0, cutMul = 1.0, cutN: Int64 = 0, qLin = 1.0
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
        // tremolo (organ)
        var tremDepth = 0.0, tremDt = 0.0, tremPhase = 0.0
    }

    private let capacity = 768
    private let voices: UnsafeMutablePointer<Voice>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var cursor: Int64 = 0                       // next sample to render
    // HostClock ms at which sample `refSample` is heard; set by the render callback
    private var refSample: Int64 = 0
    private var refMs = 0.0
    private var hasRef = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        voices = .allocate(capacity: capacity)
        voices.initialize(repeating: Voice(), count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        voices.deallocate()
        lock.deallocate()
    }

    private func withLock<T>(_ f: () -> T) -> T {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return f()
    }

    // MARK: time

    /// Core time (seconds on the sample clock) heard at HostClock time `ms`.
    /// Nil until the first buffer has rendered.
    func coreTime(atMs ms: Double) -> Double? {
        withLock {
            guard hasRef else { return nil }
            return Double(refSample) / sampleRate + (ms - refMs) / 1000
        }
    }

    /// Core time now (what is being heard), for offline rendering: the cursor.
    var renderedTime: Double { withLock { Double(cursor) / sampleRate } }

    private func sample(_ t: Double) -> Int64 { Int64((t * sampleRate).rounded()) }

    private func add(_ vs: [Voice]) {
        withLock {
            var i = 0
            for v in vs {
                while i < capacity && voices[i].active { i += 1 }
                if i == capacity { return }          // pool full: drop the rest
                voices[i] = v
                voices[i].active = true
                i += 1
            }
        }
    }

    /// Fade out every chord/bass voice (ringing or scheduled) over 80 ms. Clicks stay.
    func silenceChords(at t: Double? = nil) {
        withLock {
            let at = t.map(sample) ?? cursor
            for i in 0..<capacity where voices[i].active && voices[i].chordBus {
                voices[i].killAt = min(voices[i].killAt, at)
            }
        }
    }

    // MARK: voice builders

    private static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    private func voice(_ wave: Wave, _ f: Double, t: Double, stop: Double, chord: Bool = true) -> Voice {
        var v = Voice()
        v.wave = wave
        v.dt = f / sampleRate
        v.start = sample(t)
        v.stop = sample(stop)
        v.noteOff = v.stop
        v.chordBus = chord
        return v
    }

    /// Exponential attack 0.0001 -> peak over `attack` s, then optionally an exponential
    /// decay to `sus` lasting `decay` s, then hold (or glide toward `glideTo` with time
    /// constant `tau`). Release from `off` with time constant `relTau`.
    private func envelope(_ v: inout Voice, attack: Double, peak: Double, decay: Double = 0, sus: Double? = nil,
                          glideTo: Double? = nil, tau: Double = 1, off: Double, relTau: Double) {
        v.attackN = max(1, sample(attack))
        v.attackMul = pow(peak / 0.0001, 1 / Double(v.attackN))
        v.level = 0.0001
        if decay > 0, let s = sus {
            v.decayN = max(1, sample(decay))
            v.decayMul = pow(s / peak, 1 / Double(v.decayN))
        }
        if let g = glideTo {
            v.glide = true
            v.susTarget = g
            v.susK = exp(-1 / (tau * sampleRate))
        }
        v.noteOff = sample(off)
        v.relK = exp(-1 / (relTau * sampleRate))
    }

    /// Release time constant that takes `level` to 0.0001 in `seconds` (an exponential
    /// ramp to silence, as the web version's exponentialRampToValueAtTime did).
    private static func relTau(from level: Double, over seconds: Double) -> Double {
        seconds / log(max(level, 0.0002) / 0.0001)
    }

    private func lowpass(_ v: inout Voice, cutoff: Double, to end: Double? = nil, over: Double = 0, qDb: Double) {
        v.filter = true
        v.cut = cutoff
        v.qLin = pow(10, qDb / 20)            // Web Audio's lowpass Q is in dB
        if let e = end, over > 0 {
            v.cutN = sample(over)
            v.cutMul = pow(e / cutoff, 1 / Double(max(1, v.cutN)))
        }
        Self.coefficients(&v, sampleRate)
    }

    private static func coefficients(_ v: inout Voice, _ sr: Double) {
        let w0 = 2 * Double.pi * min(v.cut, sr * 0.45) / sr
        let alpha = sin(w0) / (2 * v.qLin), c = cos(w0), a0 = 1 + alpha
        v.b0 = (1 - c) / 2 / a0
        v.b1 = (1 - c) / a0
        v.b2 = v.b0
        v.a1 = -2 * c / a0
        v.a2 = (1 - alpha) / a0
    }

    // MARK: sounds

    func click(at t: Double, accent: Bool) {
        var v = voice(.sine, accent ? 1760 : 1100, t: t, stop: t + 0.07, chord: false)
        envelope(&v, attack: 0.002, peak: accent ? 0.9 : 0.5, decay: 0.058, sus: 0.0001, off: t + 0.07, relTau: 0.005)
        add([v])
    }

    /// Play `name` from core time t for dur seconds. False if it plays nothing.
    @discardableResult
    func play(chord name: String, at t: Double, dur: Double, patch: String, spb: Double,
              chords: Bool = true, bass: Bool = true) -> Bool {
        guard chords || bass, let ch = ChordTheory.parse(name) else { return false }
        let v = ChordTheory.voicing(ch), end = t + max(0.12, dur - 0.03)
        var out: [Voice] = []
        if chords {
            let notes = v.pad.map(Double.init)
            switch patch {
            case "keys": out += keys(notes, t, end)
            case "organ": out += organ(notes, t, end)
            case "pluck": out += pluck(notes, t, end, spb)
            default: out += pad(notes, t, end)
            }
        }
        if bass { out += bassNote(Double(v.bass), t, end) }
        let vol = chordVolume
        add(out.map { var x = $0; x.gain *= vol; return x })
        return true
    }

    /// Soft and sustained: two detuned saws per note through a lowpass.
    private func pad(_ notes: [Double], _ t: Double, _ end: Double) -> [Voice] {
        let rel = 0.18, peak = 0.32 / Double(notes.count)
        var out: [Voice] = []
        for n in notes {
            for cents in [-7.0, 7.0] {
                var v = voice(.saw, Self.hz(n) * pow(2, cents / 1200), t: t, stop: end + rel + 0.02)
                envelope(&v, attack: 0.04, peak: peak, off: end, relTau: Self.relTau(from: peak, over: rel))
                lowpass(&v, cutoff: 1500, qDb: 0.4)
                out.append(v)
            }
        }
        return out
    }

    /// Electric piano: FM bell (modulator at 1x, index decaying), fading while held.
    private func keys(_ notes: [Double], _ t: Double, _ end: Double) -> [Voice] {
        let rel = 0.25, peak = 0.38 / Double(notes.count)
        return notes.enumerated().map { i, n in
            let f = Self.hz(n + 12), at = t + Double(i) * 0.004    // up an octave: EP sits brighter
            var v = voice(.fm, f, t: at, stop: end + rel + 0.02)
            v.idx0 = f * 2.2
            v.idxN = sample(0.6)
            v.idxMul = pow(0.15 / 2.2, 1 / Double(v.idxN))
            v.idx = v.idx0
            envelope(&v, attack: 0.005, peak: peak, decay: 1.795, sus: peak * 0.25,   // decays like a tine
                     glideTo: peak * 0.15, tau: 1.5, off: end, relTau: rel / 4)
            return v
        }
    }

    /// Drawbar organ (16' 8' 4' 2 2/3') with a slow Leslie-ish tremolo.
    private func organ(_ notes: [Double], _ t: Double, _ end: Double) -> [Voice] {
        let rel = 0.06, peak = 0.2 / Double(notes.count), stop = end + rel + 0.02
        var out: [Voice] = []
        for n in notes {
            for (mult, amp) in [(0.5, 0.6), (1.0, 1.0), (2.0, 0.55), (3.0, 0.3)] {
                var v = voice(.sine, Self.hz(n) * mult, t: t, stop: stop)
                envelope(&v, attack: 0.008, peak: peak, off: end, relTau: Self.relTau(from: peak, over: rel))
                v.gain = amp
                v.tremDepth = 0.12
                v.tremDt = 5.8 / sampleRate
                out.append(v)
            }
        }
        return out
    }

    /// Strummed: re-strums every beat, down on the beat / up between, brighter accent on
    /// the chord change. The one patch with rhythm, for locking in a groove.
    private func pluck(_ notes: [Double], _ t: Double, _ end: Double, _ spb: Double) -> [Voice] {
        let spb = spb > 0 ? spb : 0.5
        let hits = max(1, Int(((end + 0.03 - t) / spb).rounded()))
        var out: [Voice] = []
        for h in 0..<hits {
            let ht = t + Double(h) * spb, hend = min(end, ht + spb - 0.01)
            let order = h % 2 == 1 ? notes.reversed() : notes
            let accent = h == 0 ? 1.0 : 0.7, pk = 0.5 * accent / Double(notes.count)
            for (i, n) in order.enumerated() {
                let at = ht + Double(i) * 0.012
                for (wave, f) in [(Wave.saw, Self.hz(n)), (Wave.triangle, Self.hz(n) * 2)] {
                    var v = voice(wave, f, t: at, stop: hend + 0.15)
                    envelope(&v, attack: 0.003, peak: pk, decay: 0.447, sus: pk * 0.2,
                             off: max(at + 0.01, hend), relTau: 0.02)
                    lowpass(&v, cutoff: accent > 0.9 ? 4200 : 3000, to: 700, over: 0.25, qDb: 1.5)
                    out.append(v)
                }
            }
        }
        return out
    }

    /// Round bass on the root (or slash note): sine plus a quiet 2nd and 3rd harmonic,
    /// because C2-B2 is below what phone and iPad speakers reproduce and the harmonics
    /// let the ear hear the note anyway.
    private func bassNote(_ midi: Double, _ t: Double, _ end: Double) -> [Voice] {
        [(1.0, 1.0), (2.0, 0.35), (3.0, 0.12)].map { mult, amp in
            var v = voice(.sine, Self.hz(midi) * mult, t: t, stop: end + 0.1)
            envelope(&v, attack: 0.01, peak: 0.4, decay: 0.24, sus: 0.22, off: end,
                     relTau: Self.relTau(from: 0.22, over: 0.08))
            v.gain = amp
            return v
        }
    }

    // MARK: render

    /// Render `frames` mono samples into `out`, heard starting at HostClock time `heardMs`
    /// (nil offline). Called on the audio thread.
    func render(_ out: UnsafeMutablePointer<Float>, frames: Int, heardMs: Double?) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if let ms = heardMs { refSample = cursor; refMs = ms; hasRef = true }
        for i in 0..<frames { out[i] = 0 }
        let from = cursor, to = cursor + Int64(frames)
        let killN = sampleRate * 0.08
        for vi in 0..<capacity where voices[vi].active {
            let v = voices + vi
            if v.pointee.start >= to { continue }
            var n = max(from, v.pointee.start)
            let killEnd = v.pointee.killAt == .max ? Int64.max : v.pointee.killAt + Int64(killN)
            while n < to {
                if n >= v.pointee.stop || n >= killEnd {
                    v.pointee.active = false
                    break
                }
                out[Int(n - from)] += Float(Self.tick(v, n, sampleRate, killN))
                n += 1
            }
        }
        cursor = to
        for i in 0..<frames { out[i] = max(-1, min(1, out[i])) }
    }

    /// One sample of one voice at absolute sample n.
    @inline(__always)
    private static func tick(_ v: UnsafeMutablePointer<Voice>, _ n: Int64, _ sr: Double, _ killN: Double) -> Double {
        let pos = n - v.pointee.start
        // envelope
        if n >= v.pointee.noteOff {
            v.pointee.level *= v.pointee.relK
        } else if pos < v.pointee.attackN {
            v.pointee.level *= v.pointee.attackMul
        } else if pos < v.pointee.attackN + v.pointee.decayN {
            v.pointee.level *= v.pointee.decayMul
        } else if v.pointee.glide {
            v.pointee.level = v.pointee.susTarget + (v.pointee.level - v.pointee.susTarget) * v.pointee.susK
        }
        var amp = v.pointee.level * v.pointee.gain
        if n >= v.pointee.killAt { amp *= max(0, 1 - Double(n - v.pointee.killAt) / killN) }
        if v.pointee.tremDepth > 0 {
            amp *= 1 + v.pointee.tremDepth * sin(2 * .pi * v.pointee.tremPhase)
            v.pointee.tremPhase += v.pointee.tremDt
            if v.pointee.tremPhase >= 1 { v.pointee.tremPhase -= 1 }
        }

        // oscillator
        let p = v.pointee.phase, dt = v.pointee.dt
        var s: Double
        var step = dt
        switch v.pointee.wave {
        case .sine:
            s = sin(2 * .pi * p)
        case .saw:
            s = 2 * p - 1 - polyBLEP(p, dt)
        case .triangle:
            s = p < 0.5 ? 4 * p - 1 : 3 - 4 * p
        case .fm:
            s = sin(2 * .pi * p)
            let m = sin(2 * .pi * v.pointee.modPhase)
            v.pointee.modPhase += dt
            if v.pointee.modPhase >= 1 { v.pointee.modPhase -= 1 }
            if pos < v.pointee.idxN { v.pointee.idx *= v.pointee.idxMul }
            step = dt + v.pointee.idx * m / sr          // instantaneous frequency f + idx*sin
        }
        var ph = p + step
        ph -= floor(ph)
        v.pointee.phase = ph

        // filter
        if v.pointee.filter {
            if pos < v.pointee.cutN {
                v.pointee.cut *= v.pointee.cutMul
                if pos & 15 == 0 { coefficients(&v.pointee, sr) }
            }
            let y = v.pointee.b0 * s + v.pointee.z1
            v.pointee.z1 = v.pointee.b1 * s - v.pointee.a1 * y + v.pointee.z2
            v.pointee.z2 = v.pointee.b2 * s - v.pointee.a2 * y
            s = y
        }
        return s * amp
    }

    /// Band-limited step correction for the saw (keeps it from aliasing like a kazoo).
    @inline(__always)
    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }
}

/// SynthCore on the speakers.
final class Synth {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private(set) var core: SynthCore
    private var latencyMs = 0.0
    private var started = false

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        core = SynthCore(sampleRate: rate > 0 ? rate : 48000)
        // Headphones in/out, a new output device: the engine stops itself. Start it again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.restart() }
        #if os(iOS)
        // A phone call or Siri interrupts the session; pick back up when it ends.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.restart()
            }
        }
        #endif
    }

    /// Start the engine (idempotent). The app starts it at launch, so the very first
    /// count-in click already knows when its buffer will be heard.
    func start() {
        guard !started else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 && rate != core.sampleRate { core = SynthCore(sampleRate: rate) }
        let core = self.core
        let fmt = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2)!
        let lat = outputLatencyMs()
        latencyMs = lat
        let src = AVAudioSourceNode(format: fmt) { _, ts, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let stamp = ts.pointee
            let host = stamp.mFlags.contains(.hostTimeValid) ? HostClock.ms(hostTime: stamp.mHostTime) : HostClock.now()
            core.render(left, frames: Int(frames), heardMs: host + lat)
            for b in 1..<buffers.count {
                if let d = buffers[b].mData { memcpy(d, left, Int(frames) * MemoryLayout<Float>.size) }
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        node = src
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("Synth: engine failed to start: \(error)")
            engine.detach(src)
            node = nil
        }
    }

    private func restart() {
        guard started || node != nil else { return }
        engine.stop()
        if let n = node { engine.detach(n) }
        node = nil
        started = false
        start()
    }

    private func outputLatencyMs() -> Double {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return (s.outputLatency + s.ioBufferDuration) * 1000
        #else
        return engine.outputNode.presentationLatency * 1000
        #endif
    }

    // Scheduling in HostClock ms. Before the first buffer renders there is no mapping yet;
    // those few ms of sound are skipped (the timeline leads by >= 80 ms anyway).

    func click(atMs ms: Double, accent: Bool) {
        start()
        if let t = core.coreTime(atMs: ms) { core.click(at: t, accent: accent) }
    }

    func play(chord: String, atMs ms: Double, dur: Double, patch: String, spb: Double, chords: Bool, bass: Bool) {
        start()
        if let t = core.coreTime(atMs: ms) {
            core.play(chord: chord, at: t, dur: dur, patch: patch, spb: spb, chords: chords, bass: bass)
        }
    }

    func silenceChords() {
        guard started else { return }
        core.silenceChords(at: core.coreTime(atMs: HostClock.now()))
    }
}
