import SwiftUI

struct ReadingOrderManagerView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var dismissedIds: Set<Int64> = []
    @State private var visibleGroups: [(key: String, comics: [Comic])] = []

    private func recomputeVisibleGroups() {
        let visible = vm.autoPlacedIssues.filter { !dismissedIds.contains($0.id) }
        let grouped = Dictionary(grouping: visible) { "\($0.publisher), \($0.series)" }
        visibleGroups = grouped.sorted { $0.key < $1.key }.map { (key: $0.key, comics: $0.value) }
    }

    var body: some View {
        Group {
            if visibleGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Text("These annuals, specials, and other extras were placed automatically using cover date, story arc, or other signals. Review each and tell ComicArc whether the placement looks right.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(visibleGroups, id: \.key) { group in
                            SuggestionGroupCard(
                                title: group.key, comics: group.comics,
                                onLooksRight: { comic in
                                    vm.confirmAutoPlacement(comic)
                                    dismissedIds.insert(comic.id)
                                },
                                onNotRight: { comic in
                                    vm.rejectAutoPlacement(comic)
                                    dismissedIds.insert(comic.id)
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Design.appBackground)
        .navigationTitle("Reading Order Suggestions")
        .task { vm.refreshDuplicates() }
        .onChange(of: vm.autoPlacedIssues) { _, _ in recomputeVisibleGroups() }
        .onChange(of: dismissedIds) { _, _ in recomputeVisibleGroups() }
        .onAppear { recomputeVisibleGroups() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 52)).foregroundStyle(.quaternary)
            Text("Nothing to Review").font(.title3.bold()).foregroundStyle(.secondary)
            Text("Annuals and specials that get automatically placed by Intelligent Reading Order will show up here so you can confirm or correct them.")
                .font(.subheadline).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SuggestionGroupCard: View {
    let title: String
    let comics: [Comic]
    let onLooksRight: (Comic) -> Void
    let onNotRight: (Comic) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)

            ForEach(comics) { comic in
                HStack(alignment: .top, spacing: 14) {
                    MiniComicCard(comic: comic).frame(width: 70, height: 100)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(comic.title).font(.subheadline.bold()).lineLimit(2)
                        HStack(spacing: 6) {
                            ConfidenceBadge(confidence: comic.readingOrderConfidence ?? 0)
                            Text(comic.readingOrderReason ?? "Placed automatically")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button {
                                onLooksRight(comic)
                            } label: {
                                Label("Looks Right", systemImage: "checkmark")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Design.brandGold)
                            .accessibilityLabel("\(comic.title) looks right")

                            Button(role: .destructive) {
                                onNotRight(comic)
                            } label: {
                                Label("Not Right", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("\(comic.title) is not right")
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
    }
}

private struct ConfidenceBadge: View {
    let confidence: Int

    private var color: Color {
        switch confidence {
        case 85...:   return .green
        case 60..<85: return Design.brandGold
        default:      return .orange
        }
    }

    var body: some View {
        Text("\(confidence)%")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
