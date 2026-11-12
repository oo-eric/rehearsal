// Chord playback: chord symbol -> notes -> a soft pad + bass on the Web Audio clock.
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

  // Play `name` on `ac` into `dest` from time t for dur seconds. Returns false if silent.
  function play(ac, dest, name, t, dur) {
    var ch = parse(name);
    if (!ch) return false;
    var v = voicing(ch), end = t + Math.max(0.12, dur - 0.03), rel = 0.18;

    // pad: two detuned saws per note through a soft lowpass
    var lp = ac.createBiquadFilter();
    lp.type = "lowpass"; lp.frequency.value = 1500; lp.Q.value = 0.4;
    var env = ac.createGain(), peak = 0.32 / v.pad.length;
    env.gain.setValueAtTime(0.0001, t);
    env.gain.exponentialRampToValueAtTime(peak, t + 0.04);
    env.gain.setValueAtTime(peak, end);
    env.gain.exponentialRampToValueAtTime(0.0001, end + rel);
    lp.connect(env); env.connect(dest);
    v.pad.forEach(function (n) {
      [-7, 7].forEach(function (cents) {
        var o = ac.createOscillator();
        o.type = "sawtooth";
        o.frequency.value = hz(n);
        o.detune.value = cents;
        o.connect(lp);
        o.start(t); o.stop(end + rel + 0.02);
      });
    });

    // bass: a round sine with a little pluck
    var bo = ac.createOscillator(), bg = ac.createGain();
    bo.type = "sine";
    bo.frequency.value = hz(v.bass);
    bg.gain.setValueAtTime(0.0001, t);
    bg.gain.exponentialRampToValueAtTime(0.45, t + 0.01);
    bg.gain.exponentialRampToValueAtTime(0.25, t + 0.25);
    bg.gain.setValueAtTime(0.25, end);
    bg.gain.exponentialRampToValueAtTime(0.0001, end + 0.08);
    bo.connect(bg); bg.connect(dest);
    bo.start(t); bo.stop(end + 0.1);
    return true;
  }

  window.Chords = { parse: parse, voicing: voicing, play: play };
})();
