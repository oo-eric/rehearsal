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
    click: CFG.clickOnStart !== false
  };

  function bpmOf(song) { return saved.bpm[song.slug] || song.bpm; }

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
    $("song-meta").textContent = [s.key, bpmOf(s) + " bpm"].filter(Boolean).join(" · ");
    $("mode").textContent = state.tempo ? "Tempo " + bpmOf(s) + (state.click ? " · click" : " · silent") : "Page-turn";
    document.body.classList.toggle("tempo", state.tempo);
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
    if (state.tempo) tempoJump(s._rows[idx].firstBar);
    render();
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
  }

  // ---- tempo mode: audio-clock scheduler -----------------------------------------
  var audio = null, events = [], evIdx = 0, schedIdx = 0, timer = null, raf = 0;

  function ensureAudio() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    if (!audio) audio = new AC();
    if (audio.state === "suspended") audio.resume();
    return audio;
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

  // Build the beat timeline from `fromBar`, starting at audio time t0.
  function buildEvents(fromBar, t0, countIn) {
    var s = state.song, spb = 60 / bpmOf(s), t = t0, list = [];
    for (var c = 0; c < countIn * 4; c++) {
      list.push({ t: t, bar: -1, beat: c % 4, count: c % 4 + 1 });
      t += spb;
    }
    for (var b = fromBar; b < s._bars.length; b++) {
      for (var k = 0; k < s._bars[b].beats; k++) {
        list.push({ t: t, bar: b, beat: k });
        t += spb;
      }
    }
    list.push({ t: t, end: true });
    return list;
  }

  function schedule() {
    var now = audio.currentTime;
    while (schedIdx < events.length && events[schedIdx].t < now + 0.15) {
      var ev = events[schedIdx];
      if (!ev.end) clickAt(Math.max(ev.t, now), ev.beat === 0);
      schedIdx++;
    }
  }

  function frame() {
    if (!state.tempo) return;
    var now = audio.currentTime;
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
          var r = state.song._bars[ev.bar].row;
          if (r !== state.row) { state.row = r; saved.row = r; persist(); }
          renderStage();
          renderBeats();
        }
      }
    }
    raf = requestAnimationFrame(frame);
  }

  function tempoStart() {
    if (!ensureAudio()) return;
    state.tempo = true;
    var first = state.song._rows[state.row].firstBar;
    events = buildEvents(first, audio.currentTime + 0.08, CFG.countInBars == null ? 1 : CFG.countInBars);
    evIdx = 0; schedIdx = 0;
    state.bar = -1; state.beat = -1;
    clearInterval(timer);
    timer = setInterval(schedule, 25);
    schedule();
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(frame);
    render();
  }

  // Jump while running: restart the timeline at `bar`, on the next beat, no count-in.
  function tempoJump(bar) {
    var spb = 60 / bpmOf(state.song);
    events = buildEvents(bar, audio.currentTime + Math.min(spb, 0.12), 0);
    evIdx = 0; schedIdx = 0;
    state.bar = -1; state.beat = -1;
  }

  function tempoStop() {
    state.tempo = false;
    state.bar = -1; state.beat = -1;
    clearInterval(timer); timer = null;
    cancelAnimationFrame(raf);
    $("countin").hidden = true;
  }

  function nudgeTempo(d) {
    var s = state.song, v = Math.max(40, Math.min(260, bpmOf(s) + d));
    if (v === s.bpm) delete saved.bpm[s.slug]; else saved.bpm[s.slug] = v;
    persist();
    if (state.tempo) {
      var at = state.bar >= 0 ? Math.min(state.bar + 1, s._bars.length - 1) : s._rows[state.row].firstBar;
      tempoJump(at);
    }
    renderHeader();
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
    $("midi-line").textContent = Input.midiSupported
      ? "MIDI pedals: supported in this browser (press M to turn on)."
      : "MIDI pedals: not supported in this browser. Keyboard-style pedals and clickers work everywhere; MIDI pedals need Chrome.";
  }
  Input.onRaw(function (ev) {
    if (!learnOpen()) return;
    var li = el("li");
    li.appendChild(el("b", "", ev.kind + "  "));
    li.appendChild(document.createTextNode(ev.detail + "  →  "));
    li.appendChild(el("i", "", ev.action || "no action"));
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
    switch (action) {
      case "next": goRow(state.row + 1); break;
      case "prev": goRow(state.row - 1); break;
      case "nextSection": goSection(1); break;
      case "prevSection": goSection(-1); break;
      case "restart": goRow(0); break;
      case "play": if (state.tempo) { tempoStop(); render(); } else tempoStart(); break;
      case "click": state.click = !state.click; ensureAudio(); renderHeader(); break;
      case "faster": nudgeTempo(1); break;
      case "slower": nudgeTempo(-1); break;
      case "songs": openPicker(); break;
      case "fullscreen": toggleFullscreen(); break;
      case "learn": toggleLearn(); break;
    }
    keepAwake();
  });

  // ---- fullscreen, idle cursor, screen wake ------------------------------------------
  function toggleFullscreen() {
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

  // ---- boot ------------------------------------------------------------------------
  if (!SONGS.length) {
    $("section-name").textContent = "No songs";
    $("section-bars").textContent = "songs.js is missing or empty. Run rehearsal/build.py.";
    return;
  }
  wake();
  if (saved.slug) openSong(saved.slug, saved.row || 0);
  else { openSong(SONGS[0].slug, 0); openPicker(); }

  // test hook (harmless in normal use)
  window.Rehearsal = { state: state, openSong: openSong, fire: Input.fire };
})();
