// Rehearsal display: navigation, rendering, tempo mode.
// Classic script (no modules, no build step) so it runs from file:// on any Mac browser.
(function () {
  "use strict";

  var SONGS = window.SONGS || [];
  var CFG = window.REHEARSAL_CONFIG || {};
  var $ = function (id) { return document.getElementById(id); };

  // ---- persistence (per-viewer convenience only; app works without it) -----------
  var STORE_KEY = "oo-rehearsal-v1";
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch (e) { saved = {}; }
  saved.bpm = saved.bpm || {};
  function persist() {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(saved)); } catch (e) { /* private mode etc. */ }
  }

  // ---- song model: flatten sections -> rows -> bars ----------------------------------
  function prepare(song) {
    if (song._rows) return song;
    var rows = [], bars = [], running = 1;
    song.sections.forEach(function (sec, si) {
      var barNum = sec.from || running;
      sec._firstRow = rows.length;
      sec.rows.forEach(function (row, ri) {
        var flat = { sec: si, inSec: ri, row: row, firstBar: bars.length };
        row.bars.forEach(function (chords) {
          var beats = chords.reduce(function (n, c) { return n + c.b; }, 0) || 4;
          bars.push({ row: rows.length, chords: chords, beats: beats, num: barNum++ });
        });
        flat.lastBar = bars.length - 1;
        rows.push(flat);
      });
      running = barNum;
    });
    song._rows = rows;
    song._bars = bars;
    return song;
  }

  var state = {
    song: null,
    row: 0,          // flat row index
    bar: -1,         // flat bar index lit in tempo mode
    beat: -1,
    tempo: false,
    click: CFG.clickOnStart !== false,
    chords: saved.chords === true,   // play the chart's chords in tempo mode (per device)
    loop: null,      // { from, to, kind: "section"|"line", label } bars repeated in tempo mode
    ramp: 0,         // speed trainer: + bpm each loop pass, up to the chart tempo
    curBpm: 0,       // bpm of the beat now playing (differs from bpmOf while ramping)
    pass: 0          // loop pass now playing (0 = first time through)
  };

  function bpmOf(song) { return saved.bpm[song.slug] || song.bpm; }
  // what's playing right now (a ramping loop runs ahead of the song's set tempo)
  function nowBpm() { return state.tempo && state.curBpm ? state.curBpm : bpmOf(state.song); }

  // ---- rendering ----------------------------------------------------------------
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function chordsText(row) {
    return row.bars.map(function (b) {
      return b.map(function (c) { return c.c || "N.C."; }).join(" ");
    }).join("  ·  ");
  }

  function renderHeader() {
    var s = state.song;
    $("song-title").textContent = s.title;
    var bpm = nowBpm(), pct = Math.round(bpm / s.bpm * 100);
    $("song-meta").textContent = [s.key, bpm + " bpm" + (bpm !== s.bpm ? " (" + pct + "%)" : "")].filter(Boolean).join(" · ");
    var sound = [state.click && "click", state.chords && "chords"].filter(Boolean).join(" + ") || "silent";
    var mode = state.tempo ? "Tempo · " + sound : "Page-turn" + (state.chords ? " · chords" : "");
    if (state.loop) {
      mode += " · loop " + state.loop.label + (state.tempo && state.pass ? " ×" + (state.pass + 1) : "");
    }
    $("mode").textContent = mode;
    document.body.classList.toggle("tempo", state.tempo);
    document.body.classList.toggle("looping", !!state.loop);
    renderTempo();
  }

  function renderMap() {
    var s = state.song, cur = s._rows[state.row].sec, map = $("map");
    map.textContent = "";
    s.sections.forEach(function (sec, i) {
      var pill = el("span", i < cur ? "done" : i === cur ? "now" : "", sec.name);
      pill.title = sec.name + (sec.from ? " (bars " + sec.from + "–" + sec.to + ")" : "");
      map.appendChild(pill);
    });
  }

  var MAX_ROWS = 6;  // longer sections scroll: a window of rows that follows the current one
  var renderedKey = "", renderedSong = null;

  function windowStart(sec, inSec) {
    var n = sec.rows.length;
    if (n <= MAX_ROWS) return 0;
    return Math.max(0, Math.min(n - MAX_ROWS, inSec - 1));  // keep one row of context above
  }

  function renderStage(force) {
    var s = state.song, cur = s._rows[state.row], sec = s.sections[cur.sec];
    var rowsEl = $("rows");
    var start = windowStart(sec, cur.inSec), shown = Math.min(sec.rows.length, MAX_ROWS);
    var key = cur.sec + ":" + start;

    if (force || renderedKey !== key || renderedSong !== s) {
      renderedKey = key;
      renderedSong = s;
      $("section-name").textContent = sec.name;
      var range = sec.from ? "bars " + sec.from + "–" + sec.to : "";
      $("section-bars").textContent = [range].concat(sec.notes || []).filter(Boolean).join("  ·  ");

      rowsEl.textContent = "";
      var avail = rowsEl.clientHeight || window.innerHeight * 0.6;
      var more = start + shown < sec.rows.length;
      var rowh = Math.min((avail - (more ? 28 : 0)) / Math.max(shown, 1), avail / 2.6);
      document.documentElement.style.setProperty("--rowh", Math.floor(rowh) + "px");

      sec.rows.slice(start, start + shown).forEach(function (row, wi) {
        var ri = start + wi;
        var flatIdx = sec._firstRow + ri, flat = s._rows[flatIdx];
        var r = el("div", "row");
        r.dataset.flat = flatIdx;
        var grid = el("div", "bars");
        grid.style.gridTemplateColumns = "repeat(" + Math.max(4, row.bars.length) + ", 1fr)";
        row.bars.forEach(function (chords, bi) {
          var bar = s._bars[flat.firstBar + bi];
          var b = el("div", "bar");
          b.dataset.bar = flat.firstBar + bi;
          b.appendChild(el("span", "n", String(bar.num)));
          chords.forEach(function (c, ci) {
            var cls = "chord" + (c.c ? "" : " nc") + (chords.length > 1 ? " split" : "") + (c.c.length > 6 ? " long" : "");
            var cd = el("div", cls, c.c || "N.C.");
            cd.style.flex = c.b + " 1 0";
            cd.dataset.idx = ci;
            b.appendChild(cd);
          });
          grid.appendChild(b);
        });
        r.appendChild(grid);
        var lyLen = row.lyrics.join(" ").length;
        var ly = el("div", "lyrics" + (row.lyrics.length ? "" : " empty") + (lyLen > 72 || row.lyrics.length > 1 ? " long" : ""));
        if (row.lyrics.length) {
          row.lyrics.forEach(function (line) { ly.appendChild(el("div", "", line)); });
        } else {
          ly.appendChild(el("div", "", "(instrumental)"));
        }
        if (row.note) ly.appendChild(el("div", "cue", row.note));
        r.appendChild(ly);
        rowsEl.appendChild(r);
      });
      fitText(rowsEl.querySelectorAll(".lyrics, .chord"));
      if (more) {
        var m = el("div", "", "▼ " + (sec.rows.length - start - shown) + " more row" + (sec.rows.length - start - shown > 1 ? "s" : "") + " in " + sec.name);
        m.id = "more";
        rowsEl.appendChild(m);
      }
      renderMap();
      renderNext();
    }

    // row + bar highlighting (cheap; runs every beat in tempo mode)
    var rowEls = rowsEl.querySelectorAll(".row");
    for (var i = 0; i < rowEls.length; i++) {
      var f = +rowEls[i].dataset.flat;
      rowEls[i].className = "row " + (f < state.row ? "past" : f === state.row ? "current" : "future");
    }
    var lit = rowsEl.querySelectorAll(".bar.now, .chord.on");
    for (var j = 0; j < lit.length; j++) lit[j].classList.remove("now", "on");
    if (state.tempo && state.bar >= 0) {
      var barEl = rowsEl.querySelector('.bar[data-bar="' + state.bar + '"]');
      if (barEl) {
        barEl.classList.add("now");
        var bar = s._bars[state.bar], acc = 0, which = 0;
        for (var k = 0; k < bar.chords.length; k++) {
          if (state.beat >= acc) which = k;
          acc += bar.chords[k].b;
        }
        var cEl = barEl.querySelector('.chord[data-idx="' + which + '"]');
        if (cEl && bar.chords.length > 1) cEl.classList.add("on");
      }
    }
  }

  // Shrink any lyric line or chord name that doesn't fit its box (long verses, odd chords).
  function fitText(nodes) {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i], size = parseFloat(getComputedStyle(n).fontSize), guard = 0;
      while ((n.scrollHeight > n.clientHeight + 1 || n.scrollWidth > n.clientWidth + 1) && size > 10 && guard++ < 30) {
        size *= 0.92;
        n.style.fontSize = size + "px";
      }
    }
  }

  function renderNext() {
    var s = state.song, cur = s._rows[state.row].sec, nxt = s.sections[cur + 1];
    if (nxt) {
      $("next-name").textContent = nxt.name;
      $("next-chords").textContent = nxt.rows.length ? chordsText(nxt.rows[0]) : "";
    } else {
      $("next-name").textContent = "End";
      $("next-chords").textContent = "";
    }
  }

  function renderBeats() {
    var dots = $("beats").children;
    for (var i = 0; i < dots.length; i++) {
      dots[i].className = (state.tempo && i === state.beat) ? "on" + (i === 0 ? " one" : "") : "";
    }
  }

  function render(force) {
    renderHeader();
    renderStage(force);
    renderBeats();
  }

  // ---- navigation ---------------------------------------------------------------
  function goRow(idx) {
    var s = state.song;
    idx = Math.max(0, Math.min(s._rows.length - 1, idx));
    state.row = idx;
    saved.row = idx;
    persist();
    var L = state.loop, f = s._rows[idx];
    if (L && (f.firstBar > L.to || f.lastBar < L.from)) { state.loop = null; toast("Loop off"); }
    if (state.tempo) tempoJump(f.firstBar);
    render();
    share();
  }

  function goSection(delta) {
    var s = state.song, cur = s._rows[state.row].sec;
    var target = Math.max(0, Math.min(s.sections.length - 1, cur + delta));
    // "back" from mid-section goes to the top of the current section first
    if (delta < 0 && s._rows[state.row].inSec > 0) target = cur;
    goRow(s.sections[target]._firstRow);
  }

  function openSong(slug, row) {
    var song = null;
    for (var i = 0; i < SONGS.length; i++) if (SONGS[i].slug === slug) song = SONGS[i];
    if (!song) song = SONGS[0];
    if (!song) return;
    tempoStop();
    state.song = prepare(song);
    state.row = Math.max(0, Math.min(song._rows.length - 1, row || 0));
    saved.slug = song.slug;
    saved.row = state.row;
    persist();
    closePicker();
    render(true);
    share();
  }

  // ---- tempo mode: one beat timeline, clicks placed on the audio clock --------------
  // A run is { fromBar, t0, bpm, countIn }: t0 is the performance.now() ms of its first
  // beat. The whole timeline follows from those four numbers, so linked devices that
  // agree on the run (t0 converted to each one's own clock, see sync.js) show the same
  // bar and click the same beat. Times stay in performance.now() ms and become audio
  // time only when a click is scheduled ~150 ms ahead, so the two clocks can't drift
  // apart over a long song.
  var audio = null, events = [], evIdx = 0, schedIdx = 0, schedUntil = -Infinity;
  var timer = null, raf = 0, run = null;
  var AHEAD = 150, LATE = 30;  // ms: schedule this far ahead; skip clicks this far past

  function ensureAudio() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    if (!audio) audio = new AC();
    if (audio.state === "suspended") audio.resume();
    return audio;
  }

  // performance.now() ms -> the audio-context time that is *heard* then. The output
  // timestamp includes the device's output latency, which differs between a Mac's
  // speakers and an iPad's, so linked devices click together.
  function audioTimeAt(ms) {
    var ts = audio.getOutputTimestamp && audio.getOutputTimestamp();
    var t = ts && ts.performanceTime > 0
      ? ts.contextTime + (ms - ts.performanceTime) / 1000
      : audio.currentTime + (ms - performance.now()) / 1000;
    return Math.max(t, audio.currentTime);
  }

  // Chords go through one bus so a stop or a jump can fade out whatever is ringing.
  var bus = null;
  function chordBus() {
    if (!bus) { bus = audio.createGain(); bus.gain.value = CFG.chordVolume == null ? 0.8 : CFG.chordVolume; bus.connect(audio.destination); }
    return bus;
  }
  function silenceChords() {
    if (!bus) return;
    var b = bus, t = audio.currentTime;
    bus = null;
    b.gain.cancelScheduledValues(t);
    b.gain.setValueAtTime(b.gain.value, t);
    b.gain.linearRampToValueAtTime(0, t + 0.08);
    setTimeout(function () { b.disconnect(); }, 400);
  }

  function toggleChords() {
    state.chords = !state.chords;
    saved.chords = state.chords;
    persist();
    if (state.chords) ensureAudio(); else if (audio) silenceChords();
    toast(state.chords ? "Chords on" + (state.tempo ? "" : " (they play in tempo mode, P)") : "Chords off");
    renderHeader();
  }

  function clickAt(t, accent) {
    if (!state.click || !audio) return;
    var o = audio.createOscillator(), g = audio.createGain();
    o.frequency.value = accent ? 1760 : 1100;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(accent ? 0.9 : 0.5, t + 0.002);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.06);
    o.connect(g); g.connect(audio.destination);
    o.start(t); o.stop(t + 0.07);
  }

  // The whole timeline follows from the run. A loop repeats bars from..to; with a
  // ramp, each pass is `ramp` bpm faster until the chart tempo. Capped at MAX_EVENTS
  // beats (over 20 minutes of looping), after which it stops like the end of a song.
  var MAX_EVENTS = 6000;
  function buildEvents(r) {
    var s = state.song, L = r.loop, bpm = r.bpm, spb = 60000 / bpm, t = r.t0, list = [];
    var cap = Math.max(s.bpm, r.bpm);
    for (var c = 0; c < r.countIn * 4; c++) {
      list.push({ t: t, bar: -1, beat: c % 4, count: c % 4 + 1, bpm: bpm, pass: 0, cb: 0 });
      t += spb;
    }
    var b = r.fromBar, pass = 0;
    if (L && (b < L.from || b > L.to)) b = L.from;
    while (b < s._bars.length && list.length < MAX_EVENTS) {
      var ch = s._bars[b].chords, starts = {}, acc = 0;
      for (var j = 0; j < ch.length; j++) { starts[acc] = ch[j]; acc += ch[j].b; }
      for (var k = 0; k < s._bars[b].beats; k++) {
        // cb = beats the chord starting on this beat lasts (0 = no chord starts here)
        var st = starts[k];
        list.push({ t: t, bar: b, beat: k, bpm: bpm, pass: pass, chord: st ? st.c : "", cb: st ? st.b : 0 });
        t += spb;
      }
      b++;
      if (L && b > L.to) {
        b = L.from;
        pass++;
        if (L.ramp) { bpm = Math.min(cap, r.bpm + pass * L.ramp); spb = 60000 / bpm; }
      }
    }
    list.push({ t: t, end: true });
    return list;
  }

  // Start (or replace) the running timeline. reanchor = same run nudged by a few ms
  // (clock-offset update from a linked device): don't click beats already scheduled.
  function startRun(r, reanchor) {
    ensureAudio();
    run = r;
    events = buildEvents(r);
    evIdx = 0;
    var now = performance.now(), skipTo = now - LATE;
    if (reanchor) skipTo = Math.max(skipTo, schedUntil + 30000 / r.bpm);  // half a beat
    else schedUntil = -Infinity;
    schedIdx = 0;
    while (schedIdx < events.length - 1 && events[schedIdx].t < skipTo) schedIdx++;
    if (!reanchor) { state.bar = -1; state.beat = -1; }
    state.tempo = true;
    clearInterval(timer);
    timer = setInterval(schedule, 25);
    schedule();
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(frame);
  }

  function schedule() {
    var now = performance.now();
    while (schedIdx < events.length && events[schedIdx].t < now + AHEAD) {
      var ev = events[schedIdx];
      if (!ev.end && ev.t >= now - LATE && audio) {
        clickAt(audioTimeAt(ev.t), ev.beat === 0);
        if (state.chords && ev.cb) Chords.play(audio, chordBus(), ev.chord, audioTimeAt(ev.t), ev.cb * 60 / ev.bpm);
        schedUntil = ev.t;
      }
      schedIdx++;
    }
  }

  function frame() {
    if (!state.tempo) return;
    var now = performance.now();
    while (evIdx + 1 < events.length && events[evIdx + 1].t <= now) evIdx++;
    var ev = events[evIdx];
    if (ev && ev.t <= now) {
      if (ev.end) { tempoStop(); render(); return; }
      var ci = $("countin");
      if (ev.bar < 0) {
        ci.hidden = false;
        ci.textContent = String(ev.count);
        state.beat = ev.beat;
        renderBeats();
      } else {
        ci.hidden = true;
        if (ev.bar !== state.bar || ev.beat !== state.beat) {
          state.bar = ev.bar;
          state.beat = ev.beat;
          if (ev.bpm !== state.curBpm || ev.pass !== state.pass) {
            state.curBpm = ev.bpm; state.pass = ev.pass;
            renderHeader();
          }
          var r = state.song._bars[ev.bar].row;
          if (r !== state.row) { state.row = r; saved.row = r; persist(); }
          renderStage();
          renderBeats();
        }
      }
    }
    raf = requestAnimationFrame(frame);
  }

  // Lead time before the first beat. Linked: long enough for the message to reach the
  // other devices, so they don't join a beat late.
  function lead(ms) { return Sync.count() ? Math.max(ms, 200) : ms; }

  function runLoop() {
    var L = state.loop;
    return L ? { from: L.from, to: L.to, ramp: state.ramp } : null;
  }

  function tempoStart() {
    state.curBpm = 0; state.pass = 0;
    startRun({
      fromBar: state.song._rows[state.row].firstBar,
      t0: performance.now() + lead(80),
      bpm: bpmOf(state.song),
      countIn: CFG.countInBars == null ? 1 : CFG.countInBars,
      loop: runLoop()
    });
    render();
  }

  // Jump while running: restart the timeline at `bar`, right away, no count-in.
  function tempoJump(bar) {
    var spb = 60000 / bpmOf(state.song);
    state.curBpm = 0; state.pass = 0;
    if (audio) silenceChords();
    startRun({ fromBar: bar, t0: performance.now() + lead(Math.min(spb, 120)), bpm: bpmOf(state.song), countIn: 0, loop: runLoop() });
  }

  // Change tempo/loop without losing the groove: the new timeline picks up on the next
  // downbeat that hasn't been scheduled yet, so the bar you're in plays out as it was.
  function retime(bpm) {
    if (!state.tempo) return;
    var now = performance.now(), min = now + lead(AHEAD + 10), e = null;
    for (var i = evIdx; i < events.length; i++) {
      var ev = events[i];
      if (ev.end) break;
      if (ev.bar >= 0 && ev.beat === 0 && ev.t >= min) { e = ev; break; }
    }
    if (!e || state.bar < 0) {          // count-in, or the song is ending: just jump
      tempoJump(state.bar >= 0 ? state.bar : state.song._rows[state.row].firstBar);
      return;
    }
    startRun({ fromBar: e.bar, t0: e.t, bpm: bpm || e.bpm, countIn: 0, loop: runLoop() });
  }

  function tempoStop() {
    if (audio) silenceChords();
    state.tempo = false;
    state.curBpm = 0; state.pass = 0;
    run = null;
    state.bar = -1; state.beat = -1;
    clearInterval(timer); timer = null;
    cancelAnimationFrame(raf);
    $("countin").hidden = true;
  }

  // ---- tempo controls: set, nudge, percent, tap, loop, speed trainer ------------------
  // The set tempo is remembered per song (0 / Reset goes back to the chart's).
  function setBpm(v) {
    var s = state.song;
    v = Math.max(40, Math.min(260, Math.round(v)));
    if (v === s.bpm) delete saved.bpm[s.slug]; else saved.bpm[s.slug] = v;
    persist();
    retime(v);
    renderHeader();
    share();
  }
  function nudgeTempo(d) { setBpm(nowBpm() + d); }

  var taps = [];
  function tap() {
    var now = performance.now();
    if (taps.length && now - taps[taps.length - 1] > 2000) taps = [];
    taps.push(now);
    if (taps.length > 6) taps.shift();
    if (taps.length < 3) { toast("Tap " + taps.length + "…"); return; }
    var avg = (taps[taps.length - 1] - taps[0]) / (taps.length - 1);
    setBpm(60000 / avg);
    toast("Tap tempo " + bpmOf(state.song));
  }

  function loopFor(kind) {
    var s = state.song, cur = s._rows[state.row];
    if (kind === "line") {
      return { from: cur.firstBar, to: cur.lastBar, kind: "line", label: "bars " + s._bars[cur.firstBar].num + "–" + s._bars[cur.lastBar].num };
    }
    var sec = s.sections[cur.sec], last = s._rows[sec._firstRow + sec.rows.length - 1];
    return { from: s._rows[sec._firstRow].firstBar, to: last.lastBar, kind: "section", label: sec.name };
  }

  function toggleLoop(kind) {
    kind = kind || "section";
    state.loop = state.loop && state.loop.kind === kind ? null : loopFor(kind);
    toast(state.loop ? "Loop " + state.loop.label : "Loop off");
    retime();
    renderHeader();
    share();
  }

  function setRamp(n) {
    state.ramp = n;
    if (state.loop) retime();
    renderHeader();
    share();
  }

  // ---- tempo panel (B, or tap the bpm) ----------------------------------------------
  function tempoOpen() { return !$("tempo").hidden; }
  function toggleTempo() { $("tempo").hidden = !$("tempo").hidden; renderTempo(); }

  function renderTempo() {
    if (!state.song || !tempoOpen()) return;
    var s = state.song, set = bpmOf(s), bpm = nowBpm();
    $("t-bpm").textContent = bpm;
    $("t-pct").textContent = Math.round(bpm / s.bpm * 100) + "% of " + s.bpm + " (chart)" +
      (bpm !== set ? " · set " + set : "");
    $("t-loop").textContent = state.loop ? "Looping " + state.loop.label : "Not looping";
    var btns = $("tempo").querySelectorAll("[data-act]");
    for (var i = 0; i < btns.length; i++) {
      var a = btns[i].getAttribute("data-act").split(":"), on = false;
      if (a[0] === "pct") on = set === Math.round(s.bpm * a[1] / 100);
      if (a[0] === "loop") on = !!state.loop && state.loop.kind === a[1];
      if (a[0] === "ramp") on = state.ramp === +a[1];
      if (a[0] === "sound") on = !!state[a[1]];
      btns[i].classList.toggle("on", on);
    }
  }

  $("tempo").addEventListener("click", function (e) {
    if (e.target === $("tempo")) { toggleTempo(); return; }   // tap outside the panel
    var b = e.target.closest && e.target.closest("[data-act]");
    if (!b || !state.song) return;
    var a = b.getAttribute("data-act").split(":");
    if (a[0] === "bpm") nudgeTempo(+a[1]);
    else if (a[0] === "pct") setBpm(state.song.bpm * a[1] / 100);
    else if (a[0] === "tap") tap();
    else if (a[0] === "loop") toggleLoop(a[1]);
    else if (a[0] === "ramp") setRamp(+a[1]);
    else if (a[0] === "play") Input.fire("play", "pointer");
    else if (a[0] === "sound") Input.fire(a[1], "pointer");
  });

  var toastT = 0;
  function toast(text) {
    var t = $("toast");
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastT);
    toastT = setTimeout(function () { t.hidden = true; }, 1400);
  }

  // ---- song picker -----------------------------------------------------------------
  var pickSel = 0;

  function openPicker() {
    tempoStop();
    var list = $("song-list");
    list.textContent = "";
    SONGS.forEach(function (s, i) {
      var li = el("li");
      li.appendChild(el("span", "", s.title));
      li.appendChild(el("span", "m", [s.key, s.bpm + " bpm"].filter(Boolean).join(" · ")));
      li.addEventListener("click", function () { openSong(s.slug, 0); });
      list.appendChild(li);
      if (state.song && s.slug === state.song.slug) pickSel = i;
    });
    $("picker").hidden = false;
    markPick();
    render();
    share();
  }
  function closePicker() { $("picker").hidden = true; }
  function pickerOpen() { return !$("picker").hidden; }
  function markPick() {
    var items = $("song-list").children;
    for (var i = 0; i < items.length; i++) items[i].className = i === pickSel ? "sel" : "";
    if (items[pickSel] && items[pickSel].scrollIntoView) items[pickSel].scrollIntoView({ block: "nearest" });
  }

  // ---- learn panel ----------------------------------------------------------------
  function learnOpen() { return !$("learn").hidden; }
  function toggleLearn() {
    $("learn").hidden = !$("learn").hidden;
    $("midi-tip").style.display = Input.midiSupported ? "" : "none";
    if (Input.native) $("midi-tip").textContent = " · M to list MIDI devices";
    $("midi-line").textContent = Input.native
      ? "MIDI pedals: always on in this app. Plug one in (USB or Bluetooth MIDI) and step on it. M lists connected devices."
      : Input.midiSupported
      ? "MIDI pedals: supported in this browser (press M to turn on)."
      : "MIDI pedals: not supported in this browser. Keyboard-style pedals and clickers work everywhere; MIDI pedals need Chrome.";
  }
  Input.onRaw(function (ev) {
    if (!learnOpen()) return;
    var li = el("li");
    li.appendChild(el("b", "", ev.kind + "  "));
    li.appendChild(document.createTextNode(ev.detail));
    if (!ev.info) {
      li.appendChild(document.createTextNode("  →  "));
      li.appendChild(el("i", "", ev.action || "no action"));
    }
    var log = $("learn-log");
    log.insertBefore(li, log.firstChild);
    while (log.children.length > 12) log.removeChild(log.lastChild);
  });

  // Keys that only mean something inside an overlay (capture phase, before Input sees them).
  window.addEventListener("keydown", function (e) {
    if (learnOpen() && (e.key === "m" || e.key === "M")) { Input.enableMidi(); e.preventDefault(); }
    if (pickerOpen() && e.key === "Enter") {
      e.preventDefault(); e.stopPropagation();
      openSong(SONGS[pickSel].slug, 0);
    }
  }, true);

  // ---- action dispatch ---------------------------------------------------------------
  Input.on(function (action) {
    if (learnOpen()) { if (action === "learn") toggleLearn(); return; }  // learn panel swallows input
    if (pickerOpen()) {
      if (action === "next") { pickSel = Math.min(SONGS.length - 1, pickSel + 1); markPick(); }
      else if (action === "prev") { pickSel = Math.max(0, pickSel - 1); markPick(); }
      else if (action === "nextSection") openSong(SONGS[pickSel].slug, 0);
      else if (action === "songs" && state.song) closePicker();
      else if (action === "fullscreen") toggleFullscreen();
      return;
    }
    if (!state.song) return;
    if (action === "songs" && tempoOpen()) { toggleTempo(); return; }   // Esc closes the panel
    switch (action) {
      case "next": goRow(state.row + 1); break;
      case "prev": goRow(state.row - 1); break;
      case "nextSection": goSection(1); break;
      case "prevSection": goSection(-1); break;
      case "restart": goRow(0); break;
      case "play": if (state.tempo) { tempoStop(); render(); } else tempoStart(); share(); break;
      case "click": state.click = !state.click; ensureAudio(); renderHeader(); break;
      case "chords": toggleChords(); break;
      case "faster": nudgeTempo(1); break;
      case "slower": nudgeTempo(-1); break;
      case "faster5": nudgeTempo(5); break;
      case "slower5": nudgeTempo(-5); break;
      case "tempoReset": setBpm(state.song.bpm); toast("Chart tempo " + state.song.bpm); break;
      case "tap": tap(); break;
      case "loop": toggleLoop("section"); break;
      case "tempo": toggleTempo(); break;
      case "songs": openPicker(); break;
      case "fullscreen": toggleFullscreen(); break;
      case "learn": toggleLearn(); break;
      case "link": toggleLink(); break;
    }
    keepAwake();
  });

  // ---- touch targets (iPad with no keyboard) ------------------------------------------
  // Tap the song title for the song list, the mode label for tempo mode, and outside
  // a panel to close it. The rest of the screen is the left/right page-turn zones.
  $("top").addEventListener("click", function (e) {
    var at = function (sel) { return e.target.closest && e.target.closest(sel); };
    Input.fire(at("#link") ? "link" : at("#status") ? "play" : at("#song-meta") ? "tempo" : "songs", "pointer");
  });
  ["picker", "learn"].forEach(function (id) {
    $(id).addEventListener("click", function (e) {
      if (e.target !== $(id)) return;          // taps inside the panel do their own thing
      if (id === "learn") toggleLearn(); else if (state.song) closePicker();
    });
  });

  // ---- fullscreen, idle cursor, screen wake ------------------------------------------
  function toggleFullscreen() {
    if (Input.native) { Input.post({ cmd: "fullscreen" }); return; }
    var d = document, de = d.documentElement;
    var fs = d.fullscreenElement || d.webkitFullscreenElement;
    if (fs) (d.exitFullscreen || d.webkitExitFullscreen).call(d);
    else if (de.requestFullscreen) de.requestFullscreen();
    else if (de.webkitRequestFullscreen) de.webkitRequestFullscreen();
  }

  var idleTimer = 0;
  function wake() {
    document.body.classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(function () { document.body.classList.add("idle"); }, 3000);
  }
  document.addEventListener("mousemove", wake);
  document.addEventListener("keydown", wake);

  var wakeLock = null;
  function keepAwake() {
    if (wakeLock || !navigator.wakeLock) return;
    navigator.wakeLock.request("screen").then(function (l) {
      wakeLock = l;
      l.addEventListener("release", function () { wakeLock = null; });
    }, function () { /* not allowed here; see README for caffeinate */ });
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") keepAwake();
  });

  var resizeT = 0;
  window.addEventListener("resize", function () {
    clearTimeout(resizeT);
    resizeT = setTimeout(function () { if (state.song) render(true); }, 120);
  });

  // ---- linked devices (sync.js) --------------------------------------------------------
  // Whoever acts last leads: every song/row/play/stop/jump/tempo change goes out as a
  // full snapshot and every linked device adopts it. The click on/off stays per device.
  // A device that links up mid-song gets a "hello" snapshot, adopted only if it is
  // newer than the last change made here (so two idle devices don't swap songs).
  var lastChange = 0, applying = false, pending = null, warned = {}, known = {};

  function snapshot() {
    var s = state.song;
    return {
      slug: s.slug, row: state.row, bars: s._bars.length, at: lastChange,
      bpm: bpmOf(s), loop: state.loop, ramp: state.ramp,
      run: run && { fromBar: run.fromBar, t0: run.t0, bpm: run.bpm, countIn: run.countIn, loop: run.loop }
    };
  }

  function share() {
    if (applying || !state.song) return;
    lastChange = Date.now();
    pending = null;
    if (Sync.enabled()) Sync.send("state", snapshot());
  }

  function hasSong(slug) {
    for (var i = 0; i < SONGS.length; i++) if (SONGS[i].slug === slug) return true;
    return false;
  }

  function applyState(m, peer) {
    pending = null;
    if (!hasSong(m.slug)) {
      warnOnce("slug:" + m.slug, "A linked device is on “" + m.slug + "”, which this one doesn't have. Update songs.js.");
      return;
    }
    applying = true;
    try {
      lastChange = m.at;
      if (!state.song || state.song.slug !== m.slug) openSong(m.slug, m.row);
      closePicker();
      var s = state.song;
      if (m.bars !== s._bars.length) {
        warnOnce("bars:" + s.slug, "A linked device has a different chart for " + s.title + " (" + m.bars + " bars here vs " + s._bars.length + "). Update songs.js on both.");
      }
      // the band's tempo and loop, not this device's own
      if (m.bpm === s.bpm) delete saved.bpm[s.slug]; else if (m.bpm) saved.bpm[s.slug] = m.bpm;
      state.loop = m.loop || null;
      state.ramp = m.ramp || 0;
      if (m.run) {
        var t0 = Sync.toLocal(m.run.t0, peer);
        if (t0 == null) {             // no clock offset yet: show the spot, start on the first pong
          pending = { m: m, peer: peer };
          if (state.tempo) tempoStop();
          state.row = Math.min(s._bars[Math.min(m.run.fromBar, s._bars.length - 1)].row, s._rows.length - 1);
        } else {
          var r = { fromBar: m.run.fromBar, t0: t0, bpm: m.run.bpm, countIn: m.run.countIn, loop: m.run.loop || null, peer: peer, t0Peer: m.run.t0 };
          startRun(r, !!(run && run.peer === peer && run.t0Peer === r.t0Peer));
          state.row = s._bars[Math.min(r.fromBar, s._bars.length - 1)].row;
        }
      } else {
        if (state.tempo) tempoStop();
        state.row = Math.max(0, Math.min(s._rows.length - 1, m.row));
      }
      saved.row = state.row;
      persist();
      render();
    } finally {
      applying = false;
    }
  }

  function warnOnce(key, text) {
    if (warned[key]) return;
    warned[key] = true;
    Input.note("sync", text);
  }

  Sync.on("state", function (m, peer) { applyState(m, peer); });
  Sync.on("hello", function (m, peer) { if (m.at > lastChange) applyState(m, peer); });

  Sync.onOffset(function (peer) {
    if (pending && pending.peer === peer) { applyState(pending.m, peer); return; }
    // Clocks drift a few ms a minute: keep a followed run anchored to the leader's clock.
    if (run && run.peer === peer) {
      var t0 = Sync.toLocal(run.t0Peer, peer);
      if (t0 != null && Math.abs(t0 - run.t0) > 1) {
        var r = {}; for (var k in run) r[k] = run[k];
        r.t0 = t0;
        startRun(r, true);
      }
    }
  });

  Sync.onPeers(function (list) {
    renderLink();
    // introduce ourselves to anyone new; their side decides whether we're newer
    if (state.song && lastChange) {
      for (var i = 0; i < list.length; i++) {
        if (!known[list[i].id]) Sync.sendTo(list[i].id, "hello", snapshot());
      }
    }
    known = {};
    for (var j = 0; j < list.length; j++) known[list[j].id] = true;
  });

  function renderLink() {
    var n = $("link");
    if (!Sync.available) { n.hidden = true; return; }
    n.hidden = false;
    var peers = Sync.peers();
    n.className = !Sync.enabled() ? "off" : peers.length ? "on" : "";
    n.textContent = !Sync.enabled() ? "Unlinked" : peers.length ? "Linked · " + (peers.length + 1) : "Solo";
    n.title = peers.map(function (p) { return p.name; }).join(", ");
  }

  function toggleLink() {
    if (!Sync.available) return;
    Sync.setEnabled(!Sync.enabled());
    Input.note("sync", Sync.enabled() ? "Linked: following other OO Rehearsal screens nearby." : "Unlinked: this screen goes solo.");
    if (Sync.enabled()) share();   // take the lead from wherever this screen is
    renderLink();
  }

  // ---- boot ------------------------------------------------------------------------
  if (!SONGS.length) {
    $("section-name").textContent = "No songs";
    $("section-bars").textContent = "songs.js is missing or empty. Run rehearsal/build.py.";
    return;
  }
  wake();
  if (saved.slug) openSong(saved.slug, saved.row || 0);
  else { openSong(SONGS[0].slug, 0); openPicker(); }
  lastChange = 0;  // opening the last song at launch isn't a change worth pushing to others
  renderLink();

  // First render can run before web fonts / final window size settle (seen in the
  // native app on relaunch): measure again once they have.
  function settle() { if (state.song) render(true); }
  window.addEventListener("load", settle);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(settle);
  setTimeout(settle, 400);

  // test hook (harmless in normal use)
  window.Rehearsal = { state: state, openSong: openSong, fire: Input.fire, run: function () { return run; } };
})();
