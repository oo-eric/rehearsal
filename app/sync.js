// Multi-device sync: keeps every linked screen on the same song, row, and beat.
// Classic script (no modules) so it runs from file:// like the rest of the app.
//
// Transport: the native Mac/iPad/iPhone app (native/Shared/PeerLink.swift) links nearby
// copies of itself with MultipeerConnectivity and relays JSON between them. In a plain
// browser there is no transport, so Sync stays inert and the app runs solo as before.
//
// Clocks: every device has its own performance.now(). Each pair of devices pings,
// NTP-style, and keeps the offset from the lowest-round-trip sample in a sliding window
// (the bridge adds jitter; the fastest round trip has the least). A timeline sent by a
// peer is in that peer's clock; toLocal() converts it. Clocks drift a few ms per minute,
// so pings continue all song long and onOffset() lets the app re-anchor a running bar.
(function () {
  "use strict";

  var host = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rehearsal;
  var peers = {};        // id -> { name, samples: [{rtt, off}], off, rtt, timer }
  var handlers = {};     // message type -> [fn(msg, peerId)]
  var offsetHandlers = [], peerHandlers = [];
  var enabled = true;
  var pingSeq = 0, sendSeq = 0;

  var WINDOW = 12;        // samples kept per peer (~12 s at the steady ping rate)
  var PING_MS = 1000;     // steady ping rate
  var BURST = 6;          // fast pings right after a peer connects
  var BURST_MS = 120;

  function now() { return performance.now(); }

  function post(msg, toPeer, reliable) {
    if (!host || !enabled) return;
    host.postMessage({ cmd: "sync", msg: JSON.stringify(msg), to: toPeer || "", reliable: reliable !== false });
  }

  function emit(list, a, b) { for (var i = 0; i < list.length; i++) list[i](a, b); }

  // ---- clock offset (peer clock - my clock, ms) ------------------------------------
  function ping(id) {
    post({ t: "ping", id: ++pingSeq, a: now() }, id, false);
  }

  function onPong(m, id) {
    var p = peers[id];
    if (!p) return;
    var c = now(), rtt = c - m.a;
    if (rtt < 0 || rtt > 2000) return;
    // the peer stamped b when it replied; assume the trip each way took half the rtt
    p.samples.push({ rtt: rtt, off: m.b - (m.a + c) / 2 });
    if (p.samples.length > WINDOW) p.samples.shift();
    var best = p.samples[0];
    for (var i = 1; i < p.samples.length; i++) if (p.samples[i].rtt < best.rtt) best = p.samples[i];
    var had = p.off != null, prev = p.off;
    p.off = best.off;
    p.rtt = best.rtt;
    if (!had || Math.abs(p.off - prev) > 0.5) emit(offsetHandlers, id, had ? p.off - prev : null);
  }

  function startPinging(id) {
    var p = peers[id], n = 0;
    clearTimeout(p.timer);
    (function tick() {
      if (!peers[id]) return;
      ping(id);
      n++;
      p.timer = setTimeout(tick, n < BURST ? BURST_MS : PING_MS);
    })();
  }

  // ---- native entry points ------------------------------------------------------------
  function fromNative(json, id) {
    if (!enabled) return;
    var m;
    try { m = JSON.parse(json); } catch (e) { return; }
    if (m.t === "ping") { post({ t: "pong", a: m.a, b: now() }, id, false); return; }
    if (m.t === "pong") { onPong(m, id); return; }
    var p = peers[id];
    if (p && m.n) {               // drop anything older than what this peer already sent
      if (m.n <= p.seq) return;
      p.seq = m.n;
    }
    var list = handlers[m.t];
    if (list) emit(list, m, id);
  }

  // Native calls this with the full list of connected peers whenever it changes.
  function setPeers(list) {
    var seen = {};
    for (var i = 0; i < list.length; i++) {
      var id = list[i].id;
      seen[id] = true;
      if (!peers[id]) {
        peers[id] = { name: list[i].name, samples: [], off: null, rtt: null, timer: 0, seq: 0 };
        if (enabled) startPinging(id);
      }
    }
    for (var k in peers) {
      if (peers.hasOwnProperty(k) && !seen[k]) { clearTimeout(peers[k].timer); delete peers[k]; }
    }
    emit(peerHandlers, list);
  }

  function setEnabled(on) {
    enabled = !!on;
    for (var id in peers) {
      if (!peers.hasOwnProperty(id)) continue;
      clearTimeout(peers[id].timer);
      peers[id].samples = []; peers[id].off = null;
      if (enabled) startPinging(id);
    }
    emit(peerHandlers, list());
  }

  function list() {
    var out = [];
    for (var id in peers) if (peers.hasOwnProperty(id)) out.push({ id: id, name: peers[id].name, off: peers[id].off, rtt: peers[id].rtt });
    return out;
  }

  window.Sync = {
    available: !!host,
    enabled: function () { return enabled && !!host; },
    setEnabled: setEnabled,
    now: now,
    peers: list,
    count: function () { return list().length; },
    // a time in `id`'s clock -> my clock; null until the first pong comes back
    toLocal: function (t, id) { var p = peers[id]; return p && p.off != null ? t - p.off : null; },
    send: function (type, body) { body.t = type; body.n = ++sendSeq; post(body, "", true); },
    sendTo: function (id, type, body) { body.t = type; body.n = ++sendSeq; post(body, id, true); },
    on: function (type, fn) { (handlers[type] = handlers[type] || []).push(fn); },
    onOffset: function (fn) { offsetHandlers.push(fn); },
    onPeers: function (fn) { peerHandlers.push(fn); },
    // native -> JS
    fromNative: fromNative,
    setPeers: setPeers
  };
})();
