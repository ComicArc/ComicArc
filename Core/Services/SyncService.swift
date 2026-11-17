import Foundation
import MultipeerConnectivity
import Observation

/// Mac ↔ iPad sync over the local network (no account or server). Exchanges reading progress
/// (latest wins; finished is sticky) and Reading Paths (merged by title, never deleted), matched by
/// file fingerprint. The wire format matches earlier versions so older devices still sync.
@MainActor @Observable
final class SyncService: NSObject {
    static let shared = SyncService()
    private static let serviceType = "comicarc-sync"

    private(set) var isActive = false
    private(set) var peers: [MCPeerID] = []
    private(set) var connectedPeer: String?
    private(set) var isSyncing = false
    private(set) var summary: String?
    private(set) var error: String?
    private(set) var invitationFrom: MCPeerID?

    @ObservationIgnored private let me = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    @ObservationIgnored private lazy var session: MCSession = {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var invitationHandler: ((Bool, MCSession?) -> Void)?

    func start() {
        guard !isActive else { return }
        isActive = true; error = nil; peers = []
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        b.delegate = self; b.startBrowsingForPeers(); browser = b
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        a.delegate = self; a.startAdvertisingPeer(); advertiser = a
    }

    func stop() {
        browser?.stopBrowsingForPeers(); browser = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        session.disconnect()
        isActive = false; peers = []; connectedPeer = nil; isSyncing = false
    }

    func connect(_ peer: MCPeerID) {
        isSyncing = true
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func respondToInvitation(accept: Bool) {
        invitationHandler?(accept, accept ? session : nil)
        invitationHandler = nil; invitationFrom = nil
        if accept { isSyncing = true }
    }

    // MARK: - Payload

    private struct Progress: Codable { let fileHash: String; let progress: Int; let pageCount: Int; let lastRead: String; var finished: Bool? }
    private struct Path: Codable { let title: String; let description: String; let comicHashes: [String] }
    private struct Payload: Codable { let progress: [Progress]; var paths: [Path]? }

    private func send(to peer: MCPeerID) {
        Task {
            guard let payload = try? await Database.shared.read({ db -> Payload in
                let progress = try db.query("""
                    SELECT c.file_hash, rp.current_page, c.page_count, rp.last_read, rp.finished_at IS NOT NULL
                    FROM reading_progress rp JOIN comics c ON c.id = rp.comic_id
                    WHERE c.deleted_at IS NULL AND c.file_hash IS NOT NULL AND (rp.current_page > 0 OR rp.finished_at IS NOT NULL)
                    """) { Progress(fileHash: $0.string(0) ?? "", progress: $0.int(1), pageCount: $0.int(2),
                                    lastRead: $0.string(3) ?? "", finished: $0.bool(4)) }
                let rows = try db.query("""
                    SELECT r.title, COALESCE(r.description,''), c.file_hash FROM runs r
                    JOIN run_items ri ON ri.run_id = r.id JOIN comics c ON c.id = ri.comic_id
                    WHERE c.deleted_at IS NULL AND c.file_hash IS NOT NULL ORDER BY r.id, ri.position
                    """) { ($0.string(0) ?? "", $0.string(1) ?? "", $0.string(2) ?? "") }
                var paths: [Path] = []
                for row in rows {
                    if paths.last?.title == row.0 { paths[paths.count - 1] = Path(title: row.0, description: row.1, comicHashes: paths.last!.comicHashes + [row.2]) }
                    else { paths.append(Path(title: row.0, description: row.1, comicHashes: [row.2])) }
                }
                return Payload(progress: progress, paths: paths)
            }), let data = try? JSONEncoder().encode(payload) else { return }
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    private func receive(_ data: Data, from peer: String) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        Task {
            let result = try? await Database.shared.write { db -> (Int, Int, Int) in
                try db.transaction {
                    var updated = 0, createdPaths = 0, addedItems = 0
                    for p in payload.progress {
                        guard let id = try db.first("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL", [p.fileHash], { $0.int64(0) }) else { continue }
                        let local = try db.first("SELECT last_read, finished_at IS NOT NULL FROM reading_progress WHERE comic_id = ?", [id]) { ($0.string(0) ?? "", $0.bool(1)) }
                        if local == nil || p.lastRead > local!.0 {
                            try db.run("""
                                INSERT INTO reading_progress (comic_id, current_page, last_read) VALUES (?,?,?)
                                ON CONFLICT(comic_id) DO UPDATE SET current_page = excluded.current_page, last_read = excluded.last_read
                                """, [id, p.progress, p.lastRead])
                            updated += 1
                        }
                        if p.finished == true && local?.1 != true {
                            try db.run("UPDATE reading_progress SET finished_at = COALESCE(finished_at, datetime('now')) WHERE comic_id = ?", [id])
                            if !(local == nil || p.lastRead > local!.0) { updated += 1 }
                        }
                    }
                    for path in payload.paths ?? [] {
                        var pathID = try db.first("SELECT id FROM runs WHERE title = ? ORDER BY id", [path.title]) { $0.int64(0) }
                        if pathID == nil {
                            try db.run("INSERT INTO runs (title, description, position) VALUES (?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM runs))",
                                       [path.title, path.description])
                            pathID = db.lastInsertRowID; createdPaths += 1
                        }
                        var existing = Set(try db.query("SELECT comic_id FROM run_items WHERE run_id = ?", [pathID!]) { $0.int64(0) })
                        var next = try db.scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?", [pathID!])
                        for hash in path.comicHashes {
                            guard let id = try db.first("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL", [hash], { $0.int64(0) }),
                                  existing.insert(id).inserted else { continue }
                            try db.run("INSERT INTO run_items (run_id, comic_id, position) VALUES (?,?,?)", [pathID!, id, next])
                            next += 1; addedItems += 1
                        }
                    }
                    return (updated, createdPaths, addedItems)
                }
            }
            isSyncing = false
            guard let (updated, paths, items) = result else { error = "Couldn't apply changes from \(peer)."; return }
            var parts: [String] = []
            if updated > 0 { parts.append("\(updated) comic\(updated == 1 ? "" : "s") updated") }
            if paths > 0 { parts.append("\(paths) Reading Path\(paths == 1 ? "" : "s") added") }
            if items > 0 { parts.append("\(items) path entr\(items == 1 ? "y" : "ies") added") }
            summary = parts.isEmpty ? "Already up to date with \(peer)." : parts.joined(separator: ", ") + " from \(peer)."
            AppModel.shared.libraryDidChange()
        }
    }
}

extension SyncService: MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: connectedPeer = peerID.displayName; isSyncing = true; send(to: peerID)
            case .notConnected:
                if connectedPeer == peerID.displayName { connectedPeer = nil }
                if isSyncing && summary == nil { isSyncing = false }
            default: break
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        Task { @MainActor in receive(data, from: name) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Foundation.Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in if !peers.contains(peerID) { peers.append(peerID) } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in peers.removeAll { $0 == peerID } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.error = "Couldn't search for nearby devices. Check that ComicArc has Local Network access in System Settings › Privacy & Security." }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in self.invitationFrom = peerID; self.invitationHandler = invitationHandler }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.error = "Couldn't make this Mac visible to nearby devices." }
    }
}
