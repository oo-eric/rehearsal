// Input adapters: keyboard, pointer, MIDI -> named actions.
// Adding a new input device = adding an adapter that calls Input.fire(actionName, sourceLabel).
// Classic script (no modules) so it runs from file:// in Safari and Chrome.
(function () {
  "use strict";

  var cfg = window.REHEARSAL_CONFIG || { keys: {} };
  var handlers = [];
  var listeners = [];   // learn-panel listeners: receive every raw input event
  var midiAccess = null;
  // Set when running inside the native Mac/iPad app (native/), which handles MIDI itself.
  var host = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rehearsal;

  function fire(action, source) {
    for (var i = 0; i < handlers.length; i++) handlers[i](action, source);
  }

  // info = a status line (not an input), so the panel shows no "-> action" for it
  function report(kind, detail, action, info) {
    for (var i = 0; i < listeners.length; i++) listeners[i]({ kind: kind, detail: detail, action: action || null, info: !!info });
  }

  // ---- keyboard ---------------------------------------------------------------
  function keyName(e) {
    var k = e.key;
    if (k && k.length === 1 && k !== " ") k = k.toLowerCase();
    return (e.shiftKey && k !== "Shift" && (k.length > 1 || k === " ")) ? "Shift+" + k : k;
  }

  function keyAction(name, plain) {
    var map = cfg.keys || {};
    for (var action in map) {
      if (!map.hasOwnProperty(action)) continue;
      if (map[action].indexOf(name) !== -1) return action;
    }
    // Shift+X with no Shift binding falls back to plain X (so "+" etc. still work)
    if (plain !== name) {
      for (var a in map) {
        if (map.hasOwnProperty(a) && map[a].indexOf(plain) !== -1) return a;
      }
    }
    return null;
  }

  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return; // leave Cmd-R, Cmd-Q etc. to the browser
    var name = keyName(e);
    var plain = e.key && e.key.length === 1 && e.key !== " " ? e.key.toLowerCase() : e.key;
    var action = keyAction(name, plain);
    report("key", name + "   (code " + e.code + ", keyCode " + e.keyCode + ")", action);
    if (action) {
      e.preventDefault();
      if (!e.repeat || action === "faster" || action === "slower") fire(action, "key");
    }
  });

  // ---- pointer (mouse / trackpad / touch) ----------------------------------------
  // pointerup, not click: iOS WebKit never fires "click" for a tap on a plain element
  // when the only listener is on document, so tap-to-turn would silently do nothing on
  // an iPad. Old Safari without PointerEvent (pre-13) falls back to click.
  if (cfg.pointer) {
    var evName = window.PointerEvent ? "pointerup" : "click";
    document.addEventListener(evName, function (e) {
      if (e.isPrimary === false || (e.pointerType === "mouse" && e.button !== 0)) return;
      if (e.target.closest && e.target.closest("[data-no-nav]")) return;
      var action = e.clientX < window.innerWidth / 3 ? "prev" : "next";
      report("pointer", (action === "prev" ? "left" : "right") + " side click", action);
      fire(action, "pointer");
    });
  }

  // ---- MIDI (Chrome via Web MIDI, or the native app via CoreMIDI) ---------------------
  function midiAction(type, number) {
    var map = cfg.midi || {};
    for (var action in map) {
      if (!map.hasOwnProperty(action)) continue;
      for (var i = 0; i < map[action].length; i++) {
        var r = map[action][i];
        if (r.type === type && r.number === number) return action;
      }
    }
    return null;
  }

  function onMidi(msg) { handleMidi(msg.data, ""); }

  function handleMidi(d, from) {
    var status = d[0] & 0xf0, ch = (d[0] & 0x0f) + 1;
    var type = null, number = d[1], value = d.length > 2 ? d[2] : 127;
    if (status === 0xb0) type = "cc";
    else if (status === 0x90) type = "note";
    else if (status === 0xc0) { type = "pc"; value = 127; }
    if (!type) return;
    var action = midiAction(type, number);
    report("midi", type + " " + number + " value " + value + " (ch " + ch + ")" + (from ? "  from " + from : ""), action);
    if (action && value >= 64) fire(action, "midi");
  }

  function enableMidi() {
    if (host) { host.postMessage({ cmd: "midiStatus" }); return; } // native replies via Input.note
    if (!navigator.requestMIDIAccess) {
      report("midi", "Web MIDI not available in this browser (use Chrome for MIDI pedals)", null, true);
      return;
    }
    if (midiAccess) { report("midi", "MIDI already on", null, true); return; }
    navigator.requestMIDIAccess().then(function (access) {
      midiAccess = access;
      var names = [];
      access.inputs.forEach(function (inp) { inp.onmidimessage = onMidi; names.push(inp.name); });
      access.onstatechange = function () {
        access.inputs.forEach(function (inp) { inp.onmidimessage = onMidi; });
      };
      report("midi", "MIDI on. Inputs: " + (names.length ? names.join(", ") : "(none connected yet)"), null, true);
    }, function (err) {
      report("midi", "MIDI permission refused: " + err, null, true);
    });
  }

  window.Input = {
    on: function (fn) { handlers.push(fn); },
    onRaw: function (fn) { listeners.push(fn); },
    fire: fire,
    enableMidi: enableMidi,
    midiSupported: !!navigator.requestMIDIAccess || !!host,
    native: !!host,
    // native app entry points
    fromNative: function (bytes, from) { handleMidi(bytes, from || ""); },
    note: function (kind, detail) { report(kind, detail, null, true); },
    post: function (msg) { if (host) host.postMessage(msg); }
  };
})();
