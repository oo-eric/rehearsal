import Foundation
import MultipeerConnectivity
#if os(iOS)
import UIKit
#endif

/// Links every OO Rehearsal app nearby (Mac, iPad, iPhone) into one session and relays
/// JSON between them. The sync logic (clock offsets, who leads, the beat timeline)
/// lives in Sync.swift and Rehearsal.swift; this is only the wire.
///
/// MultipeerConnectivity finds peers over Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth, so
/// it works in a rehearsal room with no router and no internet. Every app both
/// advertises and browses; of any two, the one with the smaller peer name sends the
/// invitation, so they never invite each other at once. Invitations are accepted
/// without asking: anything running this app nearby is the band.
final class PeerLink: NSObject, PeerTransport, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    /// `_oo-rehearsal._tcp` / `._udp` must be listed under NSBonjourServices in Info.plist.
    static let serviceType = "oo-rehearsal"
    private static let protocolVersion = "1"

    /// (json, peer id). Called on the main queue.
    var onMessage: ((String, String) -> Void)?
    /// Connected peers changed: [(id, display name)]. Called on the main queue.
    var onPeers: (([(id: String, name: String)]) -> Void)?

    private let me: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var nearby = Set<MCPeerID>()   // seen by the browser (main queue)

    override init() {
        // A short random tag keeps two devices with the same name ("iPad") apart and
        // makes each launch a fresh identity, so a relaunch never fights its old ghost.
        let tag = String(UUID().uuidString.prefix(4))
        me = MCPeerID(displayName: String(Self.deviceName().prefix(40)) + " #" + tag)
        // No encryption: chart positions only, and the handshake is faster without it.
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .none)
        let info = ["v": Self.protocolVersion]
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    var peers: [(id: String, name: String)] {
        session.connectedPeers.map { (id: $0.displayName, name: Self.shortName($0.displayName)) }
    }

    /// Send to one peer (by id) or, with an empty id, to all. Unreliable is for clock
    /// pings: a retransmitted ping is worse than a lost one.
    func send(_ json: String, to id: String, reliable: Bool) {
        let targets = id.isEmpty ? session.connectedPeers : session.connectedPeers.filter { $0.displayName == id }
        guard !targets.isEmpty, let data = json.data(using: .utf8) else { return }
        try? session.send(data, toPeers: targets, with: reliable ? .reliable : .unreliable)
    }

    // MARK: browsing / inviting

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["v"] == Self.protocolVersion else { return }
        DispatchQueue.main.async {
            self.nearby.insert(peer)
            self.inviteIfMine(peer)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        DispatchQueue.main.async { self.nearby.remove(peer) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("PeerLink browse failed: \(error)")
    }

    private func inviteIfMine(_ peer: MCPeerID) {
        guard me.displayName < peer.displayName,
              !session.connectedPeers.contains(peer) else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("PeerLink advertise failed: \(error)")
    }

    // MARK: session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.onPeers?(self.peers)
            // Dropped but still in range (Wi-Fi blip): the inviting side tries again.
            if state == .notConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.nearby.contains(peerID) { self.inviteIfMine(peerID) }
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.onMessage?(json, peerID.displayName) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    // MARK: names

    private static func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name          // "iPad" / "iPhone" on iOS 16+ without an entitlement
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// "Eric's iPad #3F2A" -> "Eric's iPad" for display.
    private static func shortName(_ id: String) -> String {
        guard let r = id.range(of: " #", options: .backwards) else { return id }
        return String(id[..<r.lowerBound])
    }
}
