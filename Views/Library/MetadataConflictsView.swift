import SwiftUI

/// The user-facing surface for Layer 1's conflict detection: comics whose current series/
/// publisher/issue_number disagrees with what their own ComicInfo.xml says, surfaced for manual
/// review instead of either side being silently applied. Mirrors `ReadingOrderManagerView`'s
/// established shape for "here's a batch of automatically-produced findings, confirm or reject
/// each."
struct MetadataConflictsView: View {
    @EnvironmentObject var vm: LibraryViewModel

    private var groupedRows: [(key: Int64, comic: Comic, rows: [MetadataConflictRow])] {
        let grouped = Dictionary(grouping: vm.pendingMetadataConflicts) { $0.comic.id }
        return grouped.values.compactMap { rows -> (key: Int64, comic: Comic, rows: [MetadataConflictRow])? in
            guard let comic = rows.first?.comic else { return nil }
            return (key: comic.id, comic: comic, rows: rows)
        }.sorted { $0.comic.title < $1.comic.title }
    }

    var body: some View {
        Group {
            if vm.pendingMetadataConflicts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Text("These comics' embedded ComicInfo.xml disagrees with how they're currently filed. Review each field and choose which value is right -- nothing here has been changed yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(groupedRows, id: \.key) { group in
                            ConflictGroupCard(comic: group.comic, rows: group.rows) { row, apply in
                                vm.resolveMetadataConflict(row, apply: apply)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Design.appBackground)
        .navigationTitle("Needs Review")
        .task { vm.refreshDuplicates() }
    }

    private var emptyState: some View {
        EmptyStateView(icon: "checkmark.circle", title: "Nothing to Review",
                        message: "Every already-imported comic's series and publisher agree with its own ComicInfo.xml.")
    }
}

private struct ConflictGroupCard: View {
    let comic: Comic
    let rows: [MetadataConflictRow]
    let onResolve: (MetadataConflictRow, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                MiniComicCard(comic: comic).frame(width: 70, height: 100)
                VStack(alignment: .leading, spacing: 4) {
                    Text(comic.title).font(.subheadline.bold()).lineLimit(2)
                    Text(URL(fileURLWithPath: comic.filePath).lastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }

            ForEach(rows) { row in
                ConflictFieldRow(row: row, onResolve: onResolve)
            }
        }
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
    }
}

private struct ConflictFieldRow: View {
    let row: MetadataConflictRow
    let onResolve: (MetadataConflictRow, Bool) -> Void

    private var fieldLabel: String {
        switch row.conflict.field {
        case "series":       return "Series"
        case "publisher":    return "Publisher"
        case "issue_number": return "Issue Number"
        default:              return row.conflict.field.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fieldLabel).font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(row.conflict.currentValue ?? "—").font(.subheadline).strikethrough()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(row.conflict.proposedValue ?? "—").font(.subheadline.bold())
                Text("(\(row.conflict.proposedSource))").font(.caption2).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(fieldLabel): currently \(row.conflict.currentValue ?? "empty"), \(row.conflict.proposedSource) suggests \(row.conflict.proposedValue ?? "empty")")
            HStack(spacing: 8) {
                Button {
                    onResolve(row, false)
                } label: {
                    Label("Keep Current", systemImage: "checkmark")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Keep current \(fieldLabel.lowercased()): \(row.conflict.currentValue ?? "empty")")

                Button {
                    onResolve(row, true)
                } label: {
                    Label("Use \(row.conflict.proposedSource) Value", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Design.brandGold)
                .accessibilityLabel("Use \(row.conflict.proposedSource) value for \(fieldLabel.lowercased()): \(row.conflict.proposedValue ?? "empty")")
            }
            .padding(.top, 2)
        }
        .padding(.top, 8)
    }
}
