import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit

/// While Friends is open, find the other phone and add each other when they touch.
@MainActor
@Observable
final class FriendTap {
    private(set) var status = "Hold the tops of your phones together"
    private let engine = TapEngine()

    func start(code: String, name: String, skip: Set<String>, onAdd: @escaping (String) async -> Bool) {
        status = "Hold the tops of your phones together"
        engine.start(code: code, name: name, skip: skip) { [weak self] next in
            self?.status = next
        } onAdd: { code in
            await onAdd(code)
        }
    }

    func stop() {
        engine.stop()
    }
}

private final class TapEngine: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate, NISessionDelegate {
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private var peerID: MCPeerID?
    private var ni: NISession?
    private var peerToken: NIDiscoveryToken?
    private var myCode = ""
    private var myName = ""
    private var skip: Set<String> = []
    private var onStatus: ((String) -> Void)?
    private var onAdd: ((String) async -> Bool)?
    private var sentHello = false
    private var handedOff = false
    private var closeReads = 0
    private var theirCode: String?
    private let service = "steps-friends"

    func start(
        code: String,
        name: String,
        skip: Set<String>,
        onStatus: @escaping (String) -> Void,
        onAdd: @escaping (String) async -> Bool
    ) {
        stop()
        myCode = code
        myName = name
        self.skip = skip
        self.onStatus = onStatus
        self.onAdd = onAdd
        let peer = MCPeerID(displayName: code)
        peerID = peer
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        if NISession.isSupported {
            let ni = NISession()
            ni.delegate = self
            self.ni = ni
        }
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["c": code], serviceType: service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        ni?.invalidate()
        advertiser = nil
        browser = nil
        session = nil
        ni = nil
        peerToken = nil
        theirCode = nil
        sentHello = false
        handedOff = false
        closeReads = 0
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard peerID.displayName != myCode, !skip.contains(peerID.displayName), let session else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        report("Allow Steps to find devices on the local network, then open Friends again.")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        report("Allow Steps to find devices on the local network, then open Friends again.")
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let theirs = info?["c"] ?? peerID.displayName
        guard theirs != myCode, !skip.contains(theirs), let session else { return }
        guard myCode < theirs else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        report("Phone nearby — bring them closer")
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        closeReads = 0
        if !handedOff {
            report("Hold the tops of your phones together")
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        sendHello(to: session)
        report("Phone nearby — bring them closer")
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let hello = try? JSONDecoder().decode(Hello.self, from: data),
              hello.code != myCode,
              !skip.contains(hello.code) else { return }
        theirCode = hello.code
        if let tokenData = hello.token,
           let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) {
            peerToken = token
            runNearby(token)
        } else if !handedOff {
            report("This phone can’t sense a tap. Use Scan or Enter code.")
        }
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard !handedOff, let code = theirCode else { return }
        guard let distance = nearbyObjects.compactMap(\.distance).min() else { return }
        if distance < 0.35 {
            closeReads += 1
            if closeReads >= 2 {
                finish(code: code)
            }
        } else {
            closeReads = 0
            report("Bring the phones closer")
        }
    }

    func sessionWasSuspended(_ session: NISession) {}

    func sessionSuspensionEnded(_ session: NISession) {
        if let peerToken { runNearby(peerToken) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {}

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}

    private func sendHello(to session: MCSession) {
        guard !sentHello, !session.connectedPeers.isEmpty else { return }
        var tokenData: Data?
        if let token = ni?.discoveryToken {
            tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }
        let hello = Hello(code: myCode, name: myName, token: tokenData)
        guard let data = try? JSONEncoder().encode(hello) else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            sentHello = true
        } catch {
            sentHello = false
        }
    }

    private func runNearby(_ token: NIDiscoveryToken) {
        guard NISession.isSupported else { return }
        if ni == nil {
            let ni = NISession()
            ni.delegate = self
            self.ni = ni
        }
        ni?.run(NINearbyPeerConfiguration(peerToken: token))
    }

    private func finish(code: String) {
        guard !handedOff else { return }
        handedOff = true
        report("Adding…")
        let add = onAdd
        Task { @MainActor in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let ok = await add?(code) ?? false
            self.report(ok ? "Added." : "Couldn’t add them. Hold the phones together again.")
            if !ok { self.handedOff = false }
        }
    }

    private func report(_ text: String) {
        let update = onStatus
        Task { @MainActor in update?(text) }
    }
}

private struct Hello: Codable {
    var code: String
    var name: String
    var token: Data?
}
