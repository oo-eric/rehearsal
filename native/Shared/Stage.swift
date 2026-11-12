import Foundation
import WebKit

/// The WKWebView that runs the display, plus the JS <-> native bridge.
///
/// JS -> native: `webkit.messageHandlers.rehearsal.postMessage({cmd: ...})`
///   - "fullscreen": toggle the window (Mac) / no-op on iPad (always full screen)
///   - "midiStatus": list MIDI devices in the pedal-setup panel
///   - "sync": relay {msg, to, reliable} to linked devices (PeerLink)
/// native -> JS: `Input.fromNative(bytes, deviceName)` for MIDI, `Input.note(...)` for the panel,
///   `Sync.fromNative(json, peer)` / `Sync.setPeers([...])` for linked devices.
final class Stage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onFullscreen: (() -> Void)?
    private let midi = MIDIInput()
    private let link = PeerLink()
    private var songsSource = ""

    override init() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        config.userContentController = content
        // The click track starts from a key press; never make audio wait for a tap.
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        content.add(self, name: "rehearsal")
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView.setValue(false, forKey: "drawsBackground") // no white flash before the page paints
        #endif
        midi.onMessage = { [weak self] bytes, from in self?.sendMIDI(bytes, from: from) }
        midi.start()
        link.onMessage = { [weak self] json, peer in
            self?.webView.evaluateJavaScript("window.Sync && Sync.fromNative(\(Self.js(json)), \(Self.js(peer)))", completionHandler: nil)
        }
        link.onPeers = { [weak self] _ in self?.sendPeers() }
        link.start()
    }

    private func sendPeers() {
        let list = link.peers.map { ["id": $0.id, "name": $0.name] }
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.Sync && Sync.setPeers(\(json))", completionHandler: nil)
    }

    func load() {
        let prepared = WebRoot.prepare()
        songsSource = prepared.songsSource
        webView.loadFileURL(prepared.root.appendingPathComponent("index.html"), allowingReadAccessTo: prepared.root)
    }

    // MARK: JS bridge

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "fullscreen": onFullscreen?()
        case "midiStatus":
            midi.connectAll()
            let list = midi.sourceNames.isEmpty ? "(none connected)" : midi.sourceNames.joined(separator: ", ")
            note("midi", "MIDI devices: \(list)")
        case "sync":
            guard let msg = body["msg"] as? String else { return }
            link.send(msg, to: body["to"] as? String ?? "", reliable: body["reliable"] as? Bool ?? true)
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("app", "Songs loaded from \(songsSource)")
        sendPeers()   // a reload (⌘R) starts the page with no peer list
    }

    private func sendMIDI(_ bytes: [UInt8], from: String) {
        let arr = "[" + bytes.map(String.init).joined(separator: ",") + "]"
        webView.evaluateJavaScript("window.Input && Input.fromNative(\(arr), \(Self.js(from)))", completionHandler: nil)
    }

    func sendKey(_ name: String, detail: String) {
        webView.evaluateJavaScript("window.Input && Input.fromNativeKey(\(Self.js(name)), \(Self.js(detail)))", completionHandler: nil)
    }

    private func note(_ kind: String, _ detail: String) {
        webView.evaluateJavaScript("window.Input && Input.note(\(Self.js(kind)), \(Self.js(detail)))", completionHandler: nil)
    }

    /// Encode a Swift string as a JS string literal.
    static func js(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
