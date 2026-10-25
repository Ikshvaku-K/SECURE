import Foundation
@preconcurrency import MultipeerConnectivity

enum NearbyLinkEvent {
    case connected(MCPeerID)
    case disconnected(MCPeerID)
    case received(Data, from: MCPeerID)
}

/// Carries bytes between this phone and nearby phones. Untrusted: every payment message is signed and checked
/// by `PeerConnection`.
protocol NearbyLink: AnyObject {
    func start()
    func stop()
    func send(_ data: Data, to peer: MCPeerID) throws
}

/// Finds nearby phones running S.E.C.U.R.E and keeps an encrypted, reliable session with each. Works without
/// internet: MultipeerConnectivity uses Bluetooth and peer-to-peer Wi-Fi.
final class MultipeerLink: NSObject, NearbyLink {
    static let serviceType = "secure-pay"

    private let me: MCPeerID
    /// Random per launch; the phone with the smaller ID sends the invitation, so two phones don't invite each other.
    private let instanceID = UUID().uuidString
    /// MCSession is thread-safe; delegate callbacks read it on MultipeerConnectivity's own queue.
    private nonisolated(unsafe) let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let onEvent: (NearbyLinkEvent) -> Void

    init(displayName: String, onEvent: @escaping (NearbyLinkEvent) -> Void) {
        me = MCPeerID(displayName: String(displayName.prefix(40)).isEmpty ? "S.E.C.U.R.E" : String(displayName.prefix(40)))
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["id": instanceID], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        self.onEvent = onEvent
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

    func send(_ data: Data, to peer: MCPeerID) throws {
        try session.send(data, toPeers: [peer], with: .reliable)
    }
}

extension MultipeerLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: self.onEvent(.connected(peerID))
            case .notConnected: self.onEvent(.disconnected(peerID))
            case .connecting: break
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.onEvent(.received(data, from: peerID)) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                             with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                             at localURL: URL?, withError error: Error?) {}
}

extension MultipeerLink: MCNearbyServiceAdvertiserDelegate {
    /// Joining a session is harmless: nothing moves without both people approving with Face ID.
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension MultipeerLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard !self.session.connectedPeers.contains(peerID) else { return }
            // The phone with the smaller instance ID invites; the other waits for the invitation.
            if let theirs = info?["id"], theirs < self.instanceID { return }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
