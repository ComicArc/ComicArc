import Foundation
import MultipeerConnectivity
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Local, cloud-free sync between a Mac and an iPad on the same network, over
/// MultipeerConnectivity -- no account, no server, nothing leaves the local network. Syncs reading
/// progress (last-write-wins page, sticky finished flag) and Reading Paths (additive merge by
/// title), matched by file hash rather than database id, since ids are meaningless across two
/// independently-scanned libraries. Tags and manual issue orders stay local.
@MainActor
final class PeerSyncService: NSObject, ObservableObject {
    static let shared = PeerSyncService()

    private static let serviceType = "comicarc-sync"

    private let myPeerId: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    @Published var isActive = false
    @Published var discoveredPeers: [MCPeerID] = []
    @Published var connectedPeerName: String?
    @Published var isSyncing = false
    @Published var lastSyncSummary: String?
    @Published var lastError: String?
    @Published var pendingInvitationFrom: MCPeerID?
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?

    private override init() {
        myPeerId = MCPeerID(displayName: Self.deviceName())
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    private static func deviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    /// Starts both browsing (to find nearby devices) and advertising (so nearby devices can find
    /// this one) -- either device can be the one that taps "Connect" first.
    func start() {
        guard !isActive else { return }
        isActive = true
        lastError = nil
        discoveredPeers = []

        let b = MCNearbyServiceBrowser(peer: myPeerId, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b

        let a = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session.disconnect()
        isActive = false
        discoveredPeers = []
        connectedPeerName = nil
    }

    func connect(to peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    func acceptPendingInvitation() {
        pendingInvitationHandler?(true, session)
        pendingInvitationFrom = nil
        pendingInvitationHandler = nil
    }

    func declinePendingInvitation() {
        pendingInvitationHandler?(false, nil)
        pendingInvitationFrom = nil
        pendingInvitationHandler = nil
    }

    private struct SyncProgressItem: Codable {
        let fileHash: String
        let progress: Int
        let pageCount: Int
        let lastRead: String
        var finished: Bool? = nil     // optional: older versions don't send it
    }
    private struct SyncPath: Codable {
        let title: String
        let description: String
        let comicHashes: [String]
    }
    private struct SyncPayload: Codable {
        let progress: [SyncProgressItem]
        var paths: [SyncPath]? = nil  // optional: older versions don't send it
    }

    private func sendMySnapshot(to peer: MCPeerID) {
        let snapshot = DatabaseManager.shared.progressSyncSnapshot()
        let paths = DatabaseManager.shared.pathSyncSnapshot()
        let payload = SyncPayload(
            progress: snapshot.map {
                SyncProgressItem(fileHash: $0.fileHash, progress: $0.progress, pageCount: $0.pageCount,
                                 lastRead: $0.lastRead, finished: $0.finished)
            },
            paths: paths.map { SyncPath(title: $0.title, description: $0.description, comicHashes: $0.hashes) }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }
}

extension PeerSyncService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                connectedPeerName = peerID.displayName
                isSyncing = true
                sendMySnapshot(to: peerID)
            case .notConnected:
                if connectedPeerName == peerID.displayName { connectedPeerName = nil }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else { return }
        let items = payload.progress.map {
            (fileHash: $0.fileHash, progress: $0.progress, lastRead: $0.lastRead, finished: $0.finished ?? false)
        }
        let paths = (payload.paths ?? []).map { (title: $0.title, description: $0.description, hashes: $0.comicHashes) }
        Task { @MainActor in
            let count = DatabaseManager.shared.applySyncedProgress(items)
            let pathResult = DatabaseManager.shared.applySyncedPaths(paths)
            isSyncing = false
            var parts: [String] = []
            if count > 0 { parts.append("\(count) comic\(count == 1 ? "" : "s") updated") }
            if pathResult.created > 0 { parts.append("\(pathResult.created) Reading Path\(pathResult.created == 1 ? "" : "s") added") }
            if pathResult.added > 0 { parts.append("\(pathResult.added) path entr\(pathResult.added == 1 ? "y" : "ies") added") }
            lastSyncSummary = parts.isEmpty
                ? "Already up to date with \(peerID.displayName)."
                : parts.joined(separator: ", ") + " from \(peerID.displayName)."
            LibraryViewModel.shared.reload()
            LibraryViewModel.shared.refreshRuns()
            NotificationCenter.default.post(name: .runUpdated, object: nil)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerSyncService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !discoveredPeers.contains(peerID) { discoveredPeers.append(peerID) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            discoveredPeers.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in lastError = error.localizedDescription }
    }
}

extension PeerSyncService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            pendingInvitationFrom = peerID
            pendingInvitationHandler = invitationHandler
        }
    }
}
