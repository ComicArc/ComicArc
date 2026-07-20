import SwiftUI

// MARK: - Possible duplicates

// Groups of comics that share the same publisher + series + issue number — most likely the
// same issue imported twice under different filenames (a re-rip, a rescan after a rename, a
// variant cover kept alongside the original). Detection is heuristic: two genuinely different
// printings that happen to share an issue number will also show up here, so this view only
// ever surfaces candidates — it never deletes or merges anything automatically.
struct DuplicatesView: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Group {
            if vm.duplicateGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(vm.duplicateGroups.enumerated()), id: \.offset) { _, group in
                            if let first = group.first {
                                DuplicateGroupCard(publisher: first.publisher, series: first.series,
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

private struct DuplicateGroupCard: View {
    let publisher: String
    let series: String
    let issueNumber: String
    @State var comics: [Comic]
    @EnvironmentObject var vm: LibraryViewModel

    // Best-effort quality signal: page count is the strongest proxy for a complete, correctly
    // extracted copy (a bad rip commonly drops pages or fails extraction partway through);
    // file size breaks ties between two copies with the same page count, since a larger file
    // at the same page count usually means higher-resolution scans. Neither is exact — this is
    // a suggestion the user can override, never an automatic delete.
    private func fileSize(_ comic: Comic) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: comic.filePath)[.size] as? Int64) ?? 0
    }
    private var recommendedId: Int64? {
        comics.max { a, b in
            (a.pageCount, fileSize(a)) < (b.pageCount, fileSize(b))
        }?.id
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
                                let others = comics.filter { $0.id != comic.id }
                                vm.delete(others)
                                comics = [comic]
                            } label: {
                                Label("Keep This, Delete Others", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Design.brandGold)
                        }
                        Button(role: .destructive) {
                            vm.delete([comic])
                            comics.removeAll { $0.id == comic.id }
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
    }
}
