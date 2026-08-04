import SwiftUI
import MultipeerConnectivity

/// UI for local, cloud-free reading-progress sync -- see PeerSyncService's own doc comment for
/// why this is scoped to reading progress only, not full library sync. Shared as-is between
/// macOS and iPadOS; MultipeerConnectivity's API is identical on both platforms.
struct PeerSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = PeerSyncService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Finds other devices on your network running ComicArc and exchanges reading progress with them -- no account, no cloud, nothing leaves your network. Only which page you're on in each comic is synced; ratings, reviews, tags, and diary entries stay local to each device.")
                        .font(.caption).foregroundStyle(.secondary)

                    if sync.isActive {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(sync.connectedPeerName.map { "Connected to \($0)" } ?? "Looking for nearby devices…")
                                .font(.subheadline)
                        }

                        if !sync.discoveredPeers.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("NEARBY DEVICES").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                ForEach(sync.discoveredPeers, id: \.self) { peer in
                                    HStack {
                                        Image(systemName: "laptopcomputer.and.iphone")
                                        Text(peer.displayName)
                                        Spacer()
                                        Button("Connect") { sync.connect(to: peer) }
                                            .buttonStyle(.bordered).controlSize(.small)
                                    }
                                }
                            }
                        }

                        Button("Stop") { sync.stop() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Look for Nearby Devices…") { sync.start() }
                            .buttonStyle(.borderedProminent)
                            .tint(Design.brandGold)
                    }

                    if sync.isSyncing {
                        Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = sync.lastSyncSummary {
                        Label(summary, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if let error = sync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 420)
        .alert("Sync Request", isPresented: Binding(
            get: { sync.pendingInvitationFrom != nil },
            set: { if !$0 { sync.declinePendingInvitation() } }
        )) {
            Button("Accept") { sync.acceptPendingInvitation() }
            Button("Decline", role: .cancel) { sync.declinePendingInvitation() }
        } message: {
            Text("\(sync.pendingInvitationFrom?.displayName ?? "A device") wants to sync reading progress with you.")
        }
    }

    private var header: some View {
        HStack {
            Text("Sync with Nearby Device").font(.title3.bold())
            Spacer()
            Button("Done") { sync.stop(); dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }
}
