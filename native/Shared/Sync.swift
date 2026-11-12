import Foundation

/// Multi-device sync: keeps every linked screen on the same song, row, and beat.
///
/// Transport: PeerLink (MultipeerConnectivity) links nearby copies of the app and moves
/// JSON between them. The messages are the same JSON the web-view builds sent, in the
/// same units (ms on each device's own monotonic clock), so this build and the older
/// web-view build still link with each other.
///
/// Clocks: every device has its own Clock. Each pair of devices pings, NTP-style, and
/// keeps the offset from the lowest-round-trip sample in a sliding window (the radio
/// adds jitter; the fastest round trip has the least). A timeline sent by a peer is in
/// that peer's clock; toLocal() converts it. Clocks drift a few ms per minute, so pings
/// continue all song long and onOffset lets the app re-anchor a running bar.
/// The wire Sync talks over: PeerLink in the app, a fake in tests.
protocol PeerTransport: AnyObject {
    var onMessage: ((String, String) -> Void)? { get set }
    var onPeers: (([(id: String, name: String)]) -> Void)? { get set }
    func start()
    func send(_ json: String, to id: String, reliable: Bool)
}

final class Sync {
    typealias Message = [String: Any]

    struct Peer {
        var name: String
        var samples: [(rtt: Double, off: Double)] = []
        var off: Double?
        var rtt: Double?
        var seq = 0.0
        var timer: Timer?
    }

    private let link: PeerTransport
    private(set) var peers: [String: Peer] = [:]
    private var handlers: [String: [(Message, String) -> Void]] = [:]
    private var offsetHandlers: [(String) -> Void] = []
    private var peerHandlers: [([(id: String, name: String)]) -> Void] = []
    private(set) var enabled = true
    private var pingSeq = 0, sendSeq = 0

    private let window = 12        // samples kept per peer (~12 s at the steady ping rate)
    private let pingInterval = 1.0 // steady ping rate (s)
    private let burst = 6          // fast pings right after a peer connects
    private let burstInterval = 0.12

    init(link: PeerTransport) {
        self.link = link
        link.onMessage = { [weak self] json, peer in self?.receive(json, from: peer) }
        link.onPeers = { [weak self] list in self?.setPeers(list) }
    }

    func start() { link.start() }

    // MARK: sending

    private func post(_ msg: Message, to peer: String = "", reliable: Bool = true) {
        guard enabled,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        link.send(json, to: peer, reliable: reliable)
    }

    func send(_ type: String, _ body: Message) {
        var b = body; b["t"] = type; sendSeq += 1; b["n"] = sendSeq
        post(b)
    }

    func send(to peer: String, _ type: String, _ body: Message) {
        var b = body; b["t"] = type; sendSeq += 1; b["n"] = sendSeq
        post(b, to: peer)
    }

    func on(_ type: String, _ fn: @escaping (Message, String) -> Void) { handlers[type, default: []].append(fn) }
    func onOffset(_ fn: @escaping (String) -> Void) { offsetHandlers.append(fn) }
    func onPeers(_ fn: @escaping ([(id: String, name: String)]) -> Void) { peerHandlers.append(fn) }

    var count: Int { peers.count }
    var list: [(id: String, name: String)] { peers.map { (id: $0.key, name: $0.value.name) }.sorted { $0.id < $1.id } }

    /// A time in `peer`'s clock -> my clock; nil until the first pong comes back.
    func toLocal(_ t: Double, from peer: String) -> Double? {
        guard let off = peers[peer]?.off else { return nil }
        return t - off
    }

    // MARK: clock offset (peer clock - my clock, ms)

    private func ping(_ id: String) {
        pingSeq += 1
        post(["t": "ping", "id": pingSeq, "a": HostClock.now()], to: id, reliable: false)
    }

    private func onPong(_ m: Message, _ id: String) {
        guard var p = peers[id], let a = num(m["a"]), let b = num(m["b"]) else { return }
        let c = HostClock.now(), rtt = c - a
        guard rtt >= 0, rtt <= 2000 else { return }
        // the peer stamped b when it replied; assume each way took half the round trip
        p.samples.append((rtt, b - (a + c) / 2))
        if p.samples.count > window { p.samples.removeFirst() }
        let best = p.samples.min { $0.rtt < $1.rtt }!
        let prev = p.off
        p.off = best.off
        p.rtt = best.rtt
        peers[id] = p
        if prev == nil || abs(best.off - prev!) > 0.5 { offsetHandlers.forEach { $0(id) } }
    }

    private func startPinging(_ id: String) {
        peers[id]?.timer?.invalidate()
        var n = 0
        func tick() {
            guard peers[id] != nil else { return }
            ping(id)
            n += 1
            let t = Timer(timeInterval: n < burst ? burstInterval : pingInterval, repeats: false) { [weak self] _ in
                guard self != nil else { return }
                tick()
            }
            RunLoop.main.add(t, forMode: .common)
            peers[id]?.timer = t
        }
        tick()
    }

    // MARK: receiving

    private func receive(_ json: String, from id: String) {
        guard enabled,
              let data = json.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? Message,
              let type = m["t"] as? String else { return }
        if type == "ping" {
            post(["t": "pong", "a": m["a"] ?? 0, "b": HostClock.now()], to: id, reliable: false)
            return
        }
        if type == "pong" { onPong(m, id); return }
        if let n = num(m["n"]), n > 0, peers[id] != nil {   // drop anything older than this peer already sent
            if n <= peers[id]!.seq { return }
            peers[id]!.seq = n
        }
        handlers[type]?.forEach { $0(m, id) }
    }

    /// PeerLink calls this with the full list of connected peers whenever it changes.
    private func setPeers(_ list: [(id: String, name: String)]) {
        let ids = Set(list.map(\.id))
        for p in list where peers[p.id] == nil {
            peers[p.id] = Peer(name: p.name)
            if enabled { startPinging(p.id) }
        }
        for id in peers.keys where !ids.contains(id) {
            peers[id]?.timer?.invalidate()
            peers[id] = nil
        }
        peerHandlers.forEach { $0(list) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        for id in peers.keys {
            peers[id]?.timer?.invalidate()
            peers[id]?.samples = []
            peers[id]?.off = nil
            if on { startPinging(id) }
        }
        peerHandlers.forEach { $0(list) }
    }
}

/// JSON numbers arrive as NSNumber (Int or Double); read either as Double.
func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}
