import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
    @State private var showResolveSafeConfirm = false

    private var filteredGroups: [[Comic]] {
        guard !vm.searchText.isEmpty else { return vm.duplicateGroups }
        let q = vm.searchText.lowercased()
        return vm.duplicateGroups.filter { group in
            group.contains {
                $0.series.lowercased().contains(q) ||
                $0.title.lowercased().contains(q) ||
                $0.publisher.lowercased().contains(q)
            }
        }
    }

    /// The unambiguous case: every member is byte-for-byte the same file (shared, non-nil hash),
    /// not just the same series/issue/type -- safe to auto-resolve without per-group review,
    /// unlike the general groups above which can legitimately be different printings/variants.
    private var hashIdenticalGroups: [[Comic]] {
        vm.duplicateGroups.filter { group in
            guard group.count > 1, let hash = group.first?.fileHash, !hash.isEmpty else { return false }
            return group.allSatisfy { $0.fileHash == hash }
        }
    }

    private var safeResolveDeleteCount: Int {
        hashIdenticalGroups.reduce(0) { $0 + $1.count - 1 }
    }

    var body: some View {
        // Hoisted so each is filtered once per render instead of once per reference below --
        // both are re-derived from `vm.duplicateGroups` on every access since they're computed
        // properties.
        let groups = filteredGroups
        let identicalGroups = hashIdenticalGroups
        Group {
            if vm.duplicateGroups.isEmpty {
                emptyState
            } else if groups.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if !identicalGroups.isEmpty {
                            safeResolveHeader(count: identicalGroups.count)
                        }
                        // Keyed by the group's own content (comic ids), not positional offset --
                        // if a group resolves/rescans while this view is visible, an offset-keyed
                        // ForEach would match the wrong data onto an already-initialized row's
                        // @State, leaving it showing the previous group's now-stale content.
                        ForEach(groups, id: \.self) { group in
                            if let first = group.first {
                                // The GCD-verified canonical name, not just whichever comic in the
                                // group happens to be first -- a duplicate group is by definition
                                // one identity, so it should never display under two different
                                // names depending on which member's own match happened to succeed.
                                DuplicateGroupCard(publisher: first.publisher, series: ComicFileNaming.displaySeriesName(for: group),
                                                    issueNumber: first.issueNumber ?? "", comics: group)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Design.appBackground)
        .navigationTitle("Possible Duplicates")
        .confirmationDialog(
            "Resolve \(identicalGroups.count) safe duplicate group\(identicalGroups.count == 1 ? "" : "s")?",
            isPresented: $showResolveSafeConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(safeResolveDeleteCount) File\(safeResolveDeleteCount == 1 ? "" : "s")", role: .destructive) {
                let toDelete = hashIdenticalGroups.flatMap { group -> [Comic] in
                    guard let keeper = recommendedKeeper(in: group) else { return [] }
                    return group.filter { $0.id != keeper.id }
                }
                vm.delete(toDelete, fileService: fileService)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These groups are byte-for-byte identical copies of the same file. One copy of each will be kept; the rest move to Trash and can be restored from Settings.")
        }
    }

    private func safeResolveHeader(count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Design.brandGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) group\(count == 1 ? "" : "s") are exact duplicate files")
                    .font(.subheadline.bold())
                Text("Same file, byte-for-byte -- safe to auto-resolve, keeping one copy of each.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resolve All Safe Duplicates") { showResolveSafeConfirm = true }
                .buttonStyle(.borderedProminent).tint(Design.brandGold)
        }
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
    }

    private var noMatchesState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 52)).foregroundStyle(.quaternary)
            Text("No Matching Duplicates").font(.title3.bold()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 52)).foregroundStyle(.quaternary)
            Text("No Duplicates Found").font(.title3.bold()).foregroundStyle(.secondary)
            Text("Comics that share the same publisher, series, and issue number will show up here.")
                .font(.subheadline).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Byte size on disk, used to break ties between otherwise-equal copies when picking a keeper.
private func fileSize(_ comic: Comic) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: comic.filePath)[.size] as? Int64) ?? 0
}

/// The single "which copy should we keep" heuristic, shared between the per-group manual picker
/// (`DuplicateGroupCard`) and the batch "Resolve All Safe Duplicates" action above -- more pages,
/// then larger file size, wins.
private func recommendedKeeper(in comics: [Comic]) -> Comic? {
    comics.max { a, b in (a.pageCount, fileSize(a)) < (b.pageCount, fileSize(b)) }
}

private struct DuplicateGroupCard: View {
    let publisher: String
    let series: String
    let issueNumber: String
    @State var comics: [Comic]
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService

    // Computed once (on appear / whenever `comics` actually changes) instead of as a computed
    // property re-evaluated on every access -- `recommendedId` used to be read once per row
    // inside the ForEach below, and each read did its own O(n) file-size stat() sweep over the
    // whole group, turning a single render into O(n^2) blocking main-thread file I/O.
    @State private var recommendedId: Int64?
    @State private var pendingKeepOnly: Comic?
    @State private var pendingDeleteSingle: Comic?

    private func recomputeRecommendedId() {
        recommendedId = recommendedKeeper(in: comics)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(publisher) — \(series) #\(issueNumber)")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                ForEach(comics) { comic in
                    let isRecommended = comic.id == recommendedId
                    VStack(alignment: .leading, spacing: 6) {
                        MiniComicCard(comic: comic).frame(width: 120, height: 172)
                            .overlay(alignment: .topTrailing) {
                                if isRecommended && comics.count > 1 {
                                    Image(systemName: "star.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Design.brandGold, .black.opacity(0.6))
                                        .padding(4)
                                        .accessibilityLabel("Recommended keeper")
                                }
                            }
                        Text(URL(fileURLWithPath: comic.filePath).lastPathComponent)
                            .font(.caption).lineLimit(2)
                            .foregroundStyle(.secondary)
                        Text("\(comic.pageCount) pages")
                            .font(.caption2).foregroundStyle(.tertiary)

                        if isRecommended && comics.count > 1 {
                            Button {
                                pendingKeepOnly = comic
                            } label: {
                                Label("Keep This, Delete Others", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Design.brandGold)
                        }
                        Button(role: .destructive) {
                            pendingDeleteSingle = comic
                        } label: {
                            Label("Delete This One", systemImage: "trash")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(width: 150)
                }
            }
        }
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .onAppear { recomputeRecommendedId() }
        .onChange(of: comics) { _, _ in recomputeRecommendedId() }
        .confirmationDialog(
            "Delete the other \(comics.count - 1) cop\(comics.count - 1 == 1 ? "y" : "ies")?",
            isPresented: Binding(get: { pendingKeepOnly != nil }, set: { if !$0 { pendingKeepOnly = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Others", role: .destructive) {
                guard let keeper = pendingKeepOnly else { return }
                let others = comics.filter { $0.id != keeper.id }
                vm.delete(others, fileService: fileService)
                comics = [keeper]
                pendingKeepOnly = nil
            }
            Button("Cancel", role: .cancel) { pendingKeepOnly = nil }
        } message: {
            Text("Deleted comics move to Trash and can be restored from Settings.")
        }
        .confirmationDialog(
            "Delete this comic?",
            isPresented: Binding(get: { pendingDeleteSingle != nil }, set: { if !$0 { pendingDeleteSingle = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDeleteSingle else { return }
                vm.delete([target])
                comics.removeAll { $0.id == target.id }
                pendingDeleteSingle = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSingle = nil }
        } message: {
            Text("Deleted comics move to Trash and can be restored from Settings.")
        }
    }
}
