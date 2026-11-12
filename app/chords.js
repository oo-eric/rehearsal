// Chord playback: chord symbol -> notes -> a patch (pad, keys, organ, pluck) + bass,
// on the Web Audio clock.
// Classic script (no modules). app.js calls Chords.play() from the tempo scheduler, so
// chords land on the same beat timeline as the click (and on linked screens).
//
// Parser handles the charts' spellings: F#m, E/G#, Dmaj7, Bm7(9), F#(7)sus4/D,
// A7(b9)/Eb, G#mb13/E, Ano3, Gno3(6), Eadd9, A#dim/F#, C#m7(9,b13), G5 ...
// Anything it can't read (N.C., "(rest)") plays nothing.
(function () {
  "use strict";

  var PC = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  // scale degree -> semitones above the root (7 = dominant 7th; maj7 handled separately)
  var DEG = { 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 10, 9: 14, 11: 17, 13: 21 };

  function pitchClass(s) {
    var m = /^([A-G])([#b]?)/.exec(s);
    if (!m) return null;
    return (PC[m[1]] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0) + 12) % 12;
  }

  // -> { root, bass, tones: [semitones above root] } or null
  function parse(name) {
    if (!name) return null;
    var root = pitchClass(name);
    if (root == null) return null;
    var rest = name.replace(/^[A-G][#b]?/, ""), bass = root;
    var slash = /\/([A-G][#b]?)$/.exec(rest);
    if (slash) { bass = pitchClass(slash[1]); rest = rest.slice(0, slash.index); }

    var paren = "", pm = /\(([^)]*)\)/g, x;
    while ((x = pm.exec(rest))) paren += "," + x[1];
    var main = rest.replace(/\([^)]*\)/g, "");

    var third = 4, fifth = 7, ext = [], maj = false;
    var tok = /maj|dim|aug|\+|sus[24]?|no3|add|m|[b#]?\d+/g, t, add = false;
    while ((t = tok.exec(main))) {
      var w = t[0];
      if (w === "maj") { maj = true; continue; }
      if (w === "m") { third = 3; continue; }
      if (w === "dim") { third = 3; fifth = 6; continue; }
      if (w === "aug" || w === "+") { fifth = 8; continue; }
      if (w === "sus2") { third = 2; continue; }
      if (w === "sus4" || w === "sus") { third = 5; continue; }
      if (w === "no3") { third = null; continue; }
      if (w === "add") { add = true; continue; }
      number(w, add, true);
      add = false;
    }
    paren.split(",").forEach(function (w) { w = w.trim(); if (w) number(w, true, false); });

    function number(w, isAdd, inMain) {
      var acc = w[0] === "b" ? -1 : w[0] === "#" ? 1 : 0, d = +w.replace(/^[b#]/, "");
      if (d === 5 && inMain && !acc && !isAdd) { third = null; return; }          // power chord
      if (d === 5 && acc) { fifth = 7 + acc; return; }                             // b5 / #5
      if (d === 7) {
        // dim7 is a double-flat 7th; "maj" anywhere means a major 7th
        ext.push(maj ? 11 : (third === 3 && fifth === 6 && inMain && /dim/.test(main)) ? 9 : 10);
        return;
      }
      if (DEG[d] == null) return;
      ext.push(DEG[d] + acc);
      // a plain 9/11/13 in the symbol implies the 7th under it (C9, Cmaj9), "add9" doesn't
      if (inMain && !isAdd && !acc && d >= 9) ext.push(maj ? 11 : 10);
    }

    var tones = [0];
    if (third != null) tones.push(third);
    if (fifth != null) tones.push(fifth);
    return { root: root, bass: bass, tones: tones.concat(ext) };
  }

  // Pitch classes folded into one octave window: chords voice-lead on their own
  // (every chord sits in the same range) and nothing gets muddy or shrill.
  var LOW = 53, BASS_LOW = 36;    // F3..E4 pad, C2..B2 bass
  function voicing(ch) {
    var seen = {}, notes = [];
    ch.tones.forEach(function (st) {
      var pc = (ch.root + st) % 12;
      if (seen[pc]) return;
      seen[pc] = true;
      notes.push(LOW + ((pc - LOW) % 12 + 12) % 12);
    });
    notes.sort(function (a, b) { return a - b; });
    return { pad: notes, bass: BASS_LOW + ((ch.bass - BASS_LOW) % 12 + 12) % 12 };
  }

  function hz(midi) { return 440 * Math.pow(2, (midi - 69) / 12); }

  // ---- patches ---------------------------------------------------------------------
  // Each patch voices the pad notes from t to end (seconds) into dest; o.spb = seconds
  // per beat. Levels are balanced so switching patches doesn't jump in volume.

  function env(ac, t, attack, peak, end, rel) {
    var g = ac.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + attack);
    g.gain.setValueAtTime(peak, end);
    g.gain.exponentialRampToValueAtTime(0.0001, end + rel);
    return g;
  }

  function osc(ac, type, f, t, stop, detune) {
    var o = ac.createOscillator();
    o.type = type;
    o.frequency.value = f;
    if (detune) o.detune.value = detune;
    o.start(t); o.stop(stop);
    return o;
  }

  var PATCHES = {
    // soft and sustained: two detuned saws per note through a lowpass
    pad: function (ac, dest, notes, t, end) {
      var rel = 0.18, lp = ac.createBiquadFilter();
      lp.type = "lowpass"; lp.frequency.value = 1500; lp.Q.value = 0.4;
      var g = env(ac, t, 0.04, 0.32 / notes.length, end, rel);
      lp.connect(g); g.connect(dest);
      notes.forEach(function (n) {
        osc(ac, "sawtooth", hz(n), t, end + rel + 0.02, -7).connect(lp);
        osc(ac, "sawtooth", hz(n), t, end + rel + 0.02, 7).connect(lp);
      });
    },

    // electric piano: FM bell (modulator at 1x, index decaying) that fades while held
    keys: function (ac, dest, notes, t, end) {
      var rel = 0.25, stop = end + rel + 0.02, peak = 0.38 / notes.length;
      notes.forEach(function (n, i) {
        var f = hz(n + 12), at = t + i * 0.004;   // up an octave: EP sits brighter
        var car = osc(ac, "sine", f, at, stop), mod = osc(ac, "sine", f, at, stop);
        var idx = ac.createGain();               // modulation depth in Hz
        idx.gain.setValueAtTime(f * 2.2, at);
        idx.gain.exponentialRampToValueAtTime(f * 0.15, at + 0.6);
        mod.connect(idx); idx.connect(car.frequency);
        var g = ac.createGain();
        g.gain.setValueAtTime(0.0001, at);
        g.gain.exponentialRampToValueAtTime(peak, at + 0.005);
        g.gain.exponentialRampToValueAtTime(peak * 0.25, at + 1.8);   // decays like a tine
        g.gain.setTargetAtTime(peak * 0.15, at + 1.8, 1.5);
        g.gain.cancelScheduledValues(end);
        g.gain.setTargetAtTime(0.0001, end, rel / 4);
        car.connect(g); g.connect(dest);
      });
    },

    // drawbar organ (16' 8' 4' 2 2/3') with a slow Leslie-ish tremolo
    organ: function (ac, dest, notes, t, end) {
      var rel = 0.06, stop = end + rel + 0.02;
      var g = env(ac, t, 0.008, 0.2 / notes.length, end, rel);
      var trem = ac.createGain(); trem.gain.value = 1;
      var lfo = osc(ac, "sine", 5.8, t, stop), depth = ac.createGain();
      depth.gain.value = 0.12;
      lfo.connect(depth); depth.connect(trem.gain);
      g.connect(trem); trem.connect(dest);
      var bars = [[0.5, 0.6], [1, 1], [2, 0.55], [3, 0.3]];
      notes.forEach(function (n) {
        bars.forEach(function (b) {
          var a = ac.createGain(); a.gain.value = b[1];
          osc(ac, "sine", hz(n) * b[0], t, stop).connect(a);
          a.connect(g);
        });
      });
    },

    // strummed: re-strums every beat, down on the beat / up between, brighter accent on
    // the chord change. The one patch with rhythm, for locking in a groove.
    pluck: function (ac, dest, notes, t, end, o) {
      var spb = o.spb || 0.5, hits = Math.max(1, Math.round((end + 0.03 - t) / spb));
      for (var h = 0; h < hits; h++) {
        var ht = t + h * spb, hend = Math.min(end, ht + spb - 0.01);
        var order = h % 2 ? notes.slice().reverse() : notes;
        var accent = h === 0 ? 1 : 0.7, n = order.length;
        order.forEach(function (note, i) {
          var at = ht + i * 0.012, lp = ac.createBiquadFilter();
          lp.type = "lowpass"; lp.Q.value = 1.5;
          lp.frequency.setValueAtTime(accent > 0.9 ? 4200 : 3000, at);
          lp.frequency.exponentialRampToValueAtTime(700, at + 0.25);
          var g = ac.createGain(), pk = 0.5 * accent / n;
          g.gain.setValueAtTime(0.0001, at);
          g.gain.exponentialRampToValueAtTime(pk, at + 0.003);
          g.gain.exponentialRampToValueAtTime(pk * 0.2, at + 0.45);
          g.gain.setTargetAtTime(0.0001, Math.max(at + 0.01, hend), 0.02);
          var sv = osc(ac, "sawtooth", hz(note), at, hend + 0.15);
          var tr = osc(ac, "triangle", hz(note) * 2, at, hend + 0.15);
          sv.connect(lp); tr.connect(lp); lp.connect(g); g.connect(dest);
        });
      }
    }
  };
  var ORDER = ["pad", "keys", "organ", "pluck"];
  var NAMES = { pad: "Pad", keys: "Keys", organ: "Organ", pluck: "Pluck" };

  // round sine bass with a little pluck, on the root (or the slash note)
  function bass(ac, dest, midi, t, end) {
    var g = ac.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.45, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.25, t + 0.25);
    g.gain.setValueAtTime(0.25, end);
    g.gain.exponentialRampToValueAtTime(0.0001, end + 0.08);
    osc(ac, "sine", hz(midi), t, end + 0.1).connect(g);
    g.connect(dest);
  }

  // Play `name` on `ac` into `dest` from time t for dur seconds.
  // o = { patch: "pad"|"keys"|"organ"|"pluck", spb: seconds per beat }. False if silent.
  function play(ac, dest, name, t, dur, o) {
    o = o || {};
    var ch = parse(name);
    if (!ch) return false;
    var v = voicing(ch), end = t + Math.max(0.12, dur - 0.03);
    (PATCHES[o.patch] || PATCHES.pad)(ac, dest, v.pad, t, end, o);
    bass(ac, dest, v.bass, t, end);
    return true;
  }

  window.Chords = { parse: parse, voicing: voicing, play: play, patches: ORDER, names: NAMES };
})();
