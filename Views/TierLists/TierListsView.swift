extension Notification.Name {
    static let tierListDeleted = Notification.Name("tierListDeleted")
    static let tierListUpdated = Notification.Name("tierListUpdated")
}

import SwiftUI

private func tierColor(_ tier: String) -> Color {
    switch tier {
    case "S": return .red
    case "A": return .orange
    case "B": return .yellow
    case "C": return .green
    case "D": return .blue
    default:  return .gray
    }
}

private func tierListConfig(_ vm: LibraryViewModel) -> CollectionListConfig<TierList> {
    CollectionListConfig(
        noun: "Tier List", nounPlural: "Tier Lists",
        emptyIcon: "square.stack.3d.up",
        emptyMessage: "Rank your comics into S/A/B/C/D/F tiers, like \"Best Batman Runs.\"",
        cardIcon: "square.stack.3d.up.fill",
        subtitle: { "\($0.comicCount) comic\($0.comicCount == 1 ? "" : "s")" },
        deleteWithUndo: { vm.deleteTierListWithUndo($0) },
        fetch: { await Task.detached(priority: .userInitiated) { DatabaseManager.shared.allTierLists() }.value },
        reorder: { vm.reorderTierLists(orderedIds: $0) },
        create: { title, desc in vm.createTierList(title: title, description: desc) },
        setCoverFromComic: { list, comic, done in vm.setTierListCover(tierListId: list.id, usingCoverOf: comic, onDone: done) },
        setCoverFromURL: { list, url in _ = vm.setTierListCover(tierListId: list.id, imageURL: url) },
        clearCover: { vm.clearTierListCover(tierListId: $0.id) }
    )
}

struct TierListsListView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Binding var selectedTierList: TierList?
    @State private var reloadToken = UUID()

    var body: some View {
        CollectionListView(config: tierListConfig(vm), selected: $selectedTierList,
                            onListChanged: { vm.refreshTierLists() }, reloadToken: reloadToken)
            .onReceive(NotificationCenter.default.publisher(for: .tierListDeleted)) { _ in
                vm.refreshTierLists(); reloadToken = UUID()
            }
            .onReceive(NotificationCenter.default.publisher(for: .tierListUpdated)) { _ in
                reloadToken = UUID()
            }
    }
}

struct TierListDetailView: View {
    let tierList: TierList
    let onDelete: () -> Void

    @Environment(\.fileService) private var fileService
    @State private var currentTierList: TierList
    @State private var items:           [TierListItem] = []
    @State private var itemsLoading     = true
    @State private var showingAddComics = false
    @State private var tierListRating:  Int    = 0
    @State private var showReviewSheet  = false
    @State private var reviewText:      String = ""
    @State private var showEditSheet    = false
    @State private var showDeleteConfirm = false
    @State private var exportErrorMessage: String?
    @State private var draggedItemId:   Int64?
    @State private var dropTargetTier:  String?
    @State private var shareCardURL:    URL?

    init(tierList: TierList, onDelete: @escaping () -> Void) {
        self.tierList     = tierList
        self.onDelete     = onDelete
        _currentTierList  = State(initialValue: tierList)
    }

    private func items(in tier: String) -> [TierListItem] {
        items.filter { $0.tier == tier }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Design.borderColor).frame(height: 1)

            HStack(spacing: 8) {
                SignageLabel(text: "Tier List", size: 13, kerning: 1.5)
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Design.surfaceBg)
                    .clipShape(Capsule())
                Spacer()
                Button {
                    showingAddComics = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10))
                        Text("Add Comics").font(.system(size: 12))
                    }
                    .foregroundStyle(Design.brandGold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            if itemsLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyStateView(
                    icon: "books.vertical",
                    title: "No Comics Yet",
                    message: "Add comics, then drag them between tiers to rank them."
                ) {
                    Button("Add Comics") { showingAddComics = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(ComicTier.allCases) { tier in
                            tierRow(tier.rawValue)
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                        }
                    }
                }
            }
        }
        .ambientBackground()
        .task {
            loadItems()
            tierListRating = tierList.rating ?? 0
            reviewText     = tierList.review ?? ""
        }
        .onChange(of: tierList) { _, tl in
            currentTierList = tl
            tierListRating  = tl.rating ?? 0
            reviewText      = tl.review ?? ""
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in
            // The reader is a ZStack overlay, not a navigation push, so this view is never told a
            // comic in it was just read -- refresh so progress bars don't show stale state.
            loadItems()
        }
        .sheet(isPresented: $showingAddComics) {
            AddComicsToCollectionView(
                title: tierList.title,
                alreadyInCollection: { DatabaseManager.shared.comicIdsInTierList(tierListId: tierList.id) },
                onAdd: { ids in
                    LibraryViewModel.shared.addToTierList(tierListId: tierList.id, comicIds: ids)
                    loadItems()
                }
            )
        }
        .sheet(isPresented: $showReviewSheet) {
            reviewSheet
        }
        .sheet(isPresented: $showEditSheet) {
            EditCollectionView(noun: "Tier List", item: $currentTierList) { t, d, _ in
                LibraryViewModel.shared.updateTierList(id: currentTierList.id, title: t, description: d)
                currentTierList.title = t; currentTierList.description = d
            }
        }
        .confirmationDialog(
            "Delete \"\(currentTierList.title)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Tier List", role: .destructive) {
                LibraryViewModel.shared.deleteTierListWithUndo(currentTierList)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The comics themselves are not affected -- only this ranking is removed.")
        }
        .errorAlert("Export Failed", message: $exportErrorMessage)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(currentTierList.title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(0.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !currentTierList.description.isEmpty {
                    Text(currentTierList.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 10) {
                StarRating(rating: tierListRating) { star in
                    let newVal = star == tierListRating ? 0 : star
                    tierListRating = newVal
                    LibraryViewModel.shared.setTierListRating(currentTierList.id,
                                                              rating: newVal,
                                                              review: reviewText.isEmpty ? nil : reviewText)
                    rebuildShareCard()
                }

                HStack(spacing: 6) {
                    Button("Edit") { showEditSheet = true }
                        .buttonStyle(.bordered)

                    Button { showReviewSheet = true } label: {
                        Image(systemName: "star.bubble")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rate & Review")

                    Button {
                        BackupService.exportCSV(
                            comics: items.map(\.comic), fileService: fileService,
                            filename: "\(currentTierList.title).csv"
                        ) { exportErrorMessage = $0 }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Export as CSV")

                    if let shareCardURL {
                        ShareLink(item: shareCardURL, preview: SharePreview(currentTierList.title)) {
                            Image(systemName: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Share as Image")
                    }

                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Text("Delete Tier List").foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Design.navBackground)
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reads `currentTierList` (the synced @State copy), not the immutable `tierList` init
            // parameter -- otherwise this sheet keeps showing the pre-edit title after
            // EditCollectionView updates currentTierList, since `tierList` itself never changes
            // for this view's lifetime.
            Text("Rate & Review: \(currentTierList.title)")
                .font(.title2.bold())

            Text("Rating").font(.headline)
            StarRating(rating: tierListRating) { star in
                tierListRating = star == tierListRating ? 0 : star
            }
            .scaleEffect(1.4, anchor: .leading)

            Text("Review").font(.headline)
            TextEditor(text: $reviewText)
                .frame(minHeight: 120)
                .border(Design.borderColor)

            HStack {
                Button("Cancel") { showReviewSheet = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    LibraryViewModel.shared.setTierListRating(currentTierList.id,
                                                              rating: tierListRating,
                                                              review: reviewText.isEmpty ? nil : reviewText)
                    showReviewSheet = false
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440)
    }

    @ViewBuilder
    private func tierRow(_ tier: String) -> some View {
        let rowItems = items(in: tier)
        let isTarget = dropTargetTier == tier

        HStack(alignment: .top, spacing: 0) {
            ZStack {
                tierColor(tier).opacity(0.85)
                Text(tier)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 56)
            .frame(minHeight: 88)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(rowItems) { item in
                        TierListItemCard(item: item, tierListId: tierList.id, onChange: loadItems)
                            .onDrag {
                                draggedItemId = item.id
                                return NSItemProvider(object: NSString(string: String(item.id)))
                            }
                    }
                    if rowItems.isEmpty {
                        Text("Drag comics here")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(minHeight: 88)
                    }
                }
                .padding(10)
            }
            .background(isTarget ? Design.brandGold.opacity(0.12) : Color.clear)
        }
        .frame(minHeight: 88)
        .onDrop(of: [.plainText],
                isTargeted: Binding(get: { isTarget }, set: { dropTargetTier = $0 ? tier : nil })) { _, _ in
            guard let itemId = draggedItemId else { return false }
            LibraryViewModel.shared.setTierListItemTier(itemId: itemId, tierListId: tierList.id, tier: tier)
            draggedItemId = nil
            loadItems()
            return true
        }
    }

    private func loadItems() {
        let id = tierList.id
        itemsLoading = true
        Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.tierListItems(tierListId: id)
            await MainActor.run { items = rows; itemsLoading = false; rebuildShareCard() }
        }
    }

    private func rebuildShareCard() {
        let ranked = ComicTier.allCases.flatMap { items(in: $0.rawValue) }
        let card = ShareCardView(
            title: currentTierList.title,
            subtitle: "Tier List • \(items.count) comic\(items.count == 1 ? "" : "s")",
            covers: ShareCardCovers.fromCache(ranked.map(\.comic)),
            stats: [
                ("Comics", "\(items.count)"),
                ("Rating", tierListRating > 0 ? String(repeating: "★", count: tierListRating) : "—")
            ]
        )
        shareCardURL = ShareCardRenderer.renderToTempPNG(card, filename: "TierList-\(currentTierList.id).png")
    }
}

private struct TierListItemCard: View {
    let item:       TierListItem
    let tierListId: Int64
    let onChange:   () -> Void

    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                } else {
                    Color.secondary.opacity(0.1)
                        .overlay(Image(systemName: "book.closed").font(.caption2).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 56, height: 84)
            .comicCardStyle()

            Text(item.comic.title)
                .font(.caption2)
                .lineLimit(2)
                .frame(width: 56, alignment: .leading)
        }
        .contextMenu {
            Button("Open") { LibraryViewModel.shared.openReader(item.comic) }
            Divider()
            Menu("Move to Tier") {
                ForEach(ComicTier.allCases) { tier in
                    Button(tier.rawValue) {
                        LibraryViewModel.shared.setTierListItemTier(itemId: item.id, tierListId: tierListId, tier: tier.rawValue)
                        onChange()
                    }
                }
            }
            Divider()
            Button("Remove from Tier List", role: .destructive) {
                LibraryViewModel.shared.removeFromTierList(tierListId: tierListId, comicIds: [item.comic.id])
                onChange()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.comic.title), tier \(item.tier)")
        .accessibilityAddTraits(.isButton)
        // Moving a comic between tiers is otherwise drag-and-drop only (see `tierRow`'s
        // `.onDrop`) -- a hard accessibility gap with no keyboard/VoiceOver path at all, the
        // same class of gap `ListsListView`'s own drag-reorder explicitly mitigates with
        // `.accessibilityActions`. These mirror the "Move to Tier" context menu above.
        .accessibilityActions {
            ForEach(ComicTier.allCases) { tier in
                if tier.rawValue != item.tier {
                    Button("Move to Tier \(tier.rawValue)") {
                        LibraryViewModel.shared.setTierListItemTier(itemId: item.id, tierListId: tierListId, tier: tier.rawValue)
                        onChange()
                    }
                }
            }
            Button("Remove from Tier List") {
                LibraryViewModel.shared.removeFromTierList(tierListId: tierListId, comicIds: [item.comic.id])
                onChange()
            }
        }
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.comic) { thumbnail = $0 } }
    }
}

struct TierListsView: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        NavigationStack {
            TierListsListView(selectedTierList: $vm.selectedTierList)
                .navigationTitle("Tier Lists")
        }
    }
}
