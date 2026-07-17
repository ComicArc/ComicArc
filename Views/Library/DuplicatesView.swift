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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(publisher) — \(series) #\(issueNumber)")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                ForEach(comics) { comic in
                    VStack(alignment: .leading, spacing: 6) {
                        MiniComicCard(comic: comic).frame(width: 120, height: 172)
                        Text(URL(fileURLWithPath: comic.filePath).lastPathComponent)
                            .font(.caption).lineLimit(2)
                            .foregroundStyle(.secondary)
                        Text("\(comic.pageCount) pages")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Button(role: .destructive) {
                            vm.delete([comic])
                            comics.removeAll { $0.id == comic.id }
                        } label: {
                            Label("Delete This One", systemImage: "trash")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(width: 130)
                }
            }
        }
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
    }
}
