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

struct TierListsListView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Binding var selectedTierList: TierList?
    @State private var tierLists:      [TierList] = []
    @State private var isLoading       = true
    @State private var showingCreate   = false
    @State private var newTitle        = ""
    @State private var newDesc         = ""
    @State private var draggedId:      Int64?
    @State private var dropTargetId:   Int64?
    @State private var pendingDelete:  TierList?

    private var filteredTierLists: [TierList] {
        guard !vm.searchText.isEmpty else { return tierLists }
        let q = vm.searchText.lowercased()
        return tierLists.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TIER LISTS")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(1)
                Spacer()
                Button { showingCreate = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.brandGold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create Tier List")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tierLists.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 42)).foregroundStyle(.quaternary)
                    Text("No Tier Lists Yet").font(.headline).foregroundStyle(.secondary)
                    Text("Rank your comics into S/A/B/C/D/F tiers, like \"Best Batman Runs.\"")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Create Tier List") { showingCreate = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if filteredTierLists.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 42)).foregroundStyle(.quaternary)
                    Text("No matching tier lists.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredTierLists) { tierList in
                            let isTarget = dropTargetId == tierList.id && draggedId != tierList.id
                            TierListCard(tierList: tierList, isSelected: selectedTierList?.id == tierList.id) {
                                selectedTierList = tierList
                            }
                            .background(isTarget ? Design.brandGold.opacity(0.12) : Color.clear)
                            .onDrag {
                                draggedId = tierList.id
                                return NSItemProvider(object: NSString(string: String(tierList.id)))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetId = active ? tierList.id : nil }
                                    )) { _, _ in
                                guard let fromId = draggedId,
                                      let fromIdx = tierLists.firstIndex(where: { $0.id == fromId }),
                                      let toIdx = tierLists.firstIndex(where: { $0.id == tierList.id }) else { return false }
                                var arr = tierLists
                                let moved = arr.remove(at: fromIdx)
                                arr.insert(moved, at: toIdx)
                                tierLists = arr
                                vm.reorderTierLists(orderedIds: arr.map(\.id))
                                draggedId = nil; dropTargetId = nil
                                return true
                            }
                            .contextMenu {
                                Button("Move to Top") { moveTierList(tierList, to: 0) }
                                    .disabled(tierLists.first?.id == tierList.id)
                                Button("Move Up") { moveTierList(tierList, by: -1) }
                                    .disabled(tierLists.first?.id == tierList.id)
                                Button("Move Down") { moveTierList(tierList, by: 1) }
                                    .disabled(tierLists.last?.id == tierList.id)
                                Button("Move to Bottom") { moveTierList(tierList, to: tierLists.count - 1) }
                                    .disabled(tierLists.last?.id == tierList.id)
                                Divider()
                                Button("Delete Tier List", role: .destructive) { pendingDelete = tierList }
                            }
                            .accessibilityActions {
                                Button("Move Up") { moveTierList(tierList, by: -1) }
                                Button("Move Down") { moveTierList(tierList, by: 1) }
                                Button("Move to Top") { moveTierList(tierList, to: 0) }
                                Button("Move to Bottom") { moveTierList(tierList, to: tierLists.count - 1) }
                            }
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .tierListDeleted)) { _ in
            Task { await load()
                if let sel = selectedTierList, !tierLists.contains(sel) { selectedTierList = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tierListUpdated)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showingCreate) { createSheet }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Tier List", role: .destructive) {
                guard let target = pendingDelete else { return }
                vm.deleteTierList(target.id)
                if selectedTierList?.id == target.id { selectedTierList = nil }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The comics themselves are not affected -- only this ranking is removed.")
        }
    }

    private var createSheet: some View {
        VStack(spacing: 20) {
            Text("New Tier List").font(.title2.bold())
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $newDesc).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingCreate = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Create") { createTierList() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
    }

    private func createTierList() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        vm.createTierList(title: title, description: newDesc)
        newTitle = ""; newDesc = ""
        showingCreate = false
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        tierLists = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.allTierLists()
        }.value
        isLoading = false
    }

    private func moveTierList(_ tierList: TierList, by delta: Int) {
        guard let idx = tierLists.firstIndex(where: { $0.id == tierList.id }) else { return }
        moveTierList(tierList, to: idx + delta)
    }

    private func moveTierList(_ tierList: TierList, to newIndex: Int) {
        guard let fromIdx = tierLists.firstIndex(where: { $0.id == tierList.id }) else { return }
        let clamped = max(0, min(newIndex, tierLists.count - 1))
        guard clamped != fromIdx else { return }
        var arr = tierLists
        let moved = arr.remove(at: fromIdx)
        arr.insert(moved, at: clamped)
        tierLists = arr
        vm.reorderTierLists(orderedIds: arr.map(\.id))
    }
}

private struct TierListCard: View {
    let tierList:   TierList
    let isSelected: Bool
    let onSelect:   () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? Design.brandGold : Color.clear)
                    .frame(width: 3)

                ZStack {
                    Design.surfaceBg
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 14)).foregroundStyle(.tertiary)
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 10)

                VStack(alignment: .leading, spacing: 5) {
                    Text(tierList.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.textPrimary)
                        .lineLimit(1)

                    if !tierList.description.isEmpty {
                        Text(tierList.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if tierList.comicCount > 0 {
                            Text("\(tierList.comicCount) comic\(tierList.comicCount == 1 ? "" : "s")")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(isSelected ? Design.brandBlue.opacity(0.12) : (isHovered ? Design.surfaceBg : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(tierList.description.isEmpty ? tierList.title : "\(tierList.title), \(tierList.description)")
        .accessibilityValue(tierList.comicCount > 0 ? "\(tierList.comicCount) comics" : "Empty")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct TierListDetailView: View {
    let tierList: TierList
    let onDelete: () -> Void

    @State private var currentTierList: TierList
    @State private var items:           [TierListItem] = []
    @State private var itemsLoading     = true
    @State private var showingAddComics = false
    @State private var showEditSheet    = false
    @State private var showDeleteConfirm = false
    @State private var draggedItemId:   Int64?
    @State private var dropTargetTier:  String?

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
                Text("TIER LIST")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                    .kerning(1.5)
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
                VStack(spacing: 14) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("No Comics Yet").font(.headline).foregroundStyle(.secondary)
                    Text("Add comics, then drag them between tiers to rank them.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Button("Add Comics") { showingAddComics = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task { loadItems() }
        .onChange(of: tierList) { _, tl in
            currentTierList = tl
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in
            // The reader is a ZStack overlay, not a navigation push, so this view is never told a
            // comic in it was just read -- refresh so progress bars don't show stale state.
            loadItems()
        }
        .sheet(isPresented: $showingAddComics) {
            AddComicsToTierListView(tierList: tierList) { loadItems() }
        }
        .sheet(isPresented: $showEditSheet) {
            EditTierListView(tierList: $currentTierList)
        }
        .confirmationDialog(
            "Delete \"\(currentTierList.title)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Tier List", role: .destructive) {
                LibraryViewModel.shared.deleteTierList(currentTierList.id)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The comics themselves are not affected -- only this ranking is removed.")
        }
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

            HStack(spacing: 6) {
                Button("Edit") { showEditSheet = true }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Text("Delete Tier List").foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Design.navBackground)
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
            await MainActor.run { items = rows; itemsLoading = false }
        }
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
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
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

struct EditTierListView: View {
    @Binding var tierList: TierList
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var description: String

    init(tierList: Binding<TierList>) {
        self._tierList = tierList
        _title         = State(initialValue: tierList.wrappedValue.title)
        _description   = State(initialValue: tierList.wrappedValue.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Tier List")
                .font(.title2.bold())
                .padding(24)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 400)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let d = description.trimmingCharacters(in: .whitespaces)
        LibraryViewModel.shared.updateTierList(id: tierList.id, title: t, description: d)
        tierList.title       = t
        tierList.description = d
        dismiss()
    }
}

struct AddComicsToTierListView: View {
    let tierList: TierList
    let onAdd:    () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allComics:      [(comic: Comic, searchKey: String)] = []
    @State private var alreadyInList:  Set<Int64> = []
    @State private var selected        = Set<Int64>()
    @State private var search          = ""

    private var filtered: [Comic] {
        let candidates = allComics.filter { !alreadyInList.contains($0.comic.id) }
        guard !search.isEmpty else { return candidates.map(\.comic) }
        let q = search.lowercased()
        return candidates.filter { $0.searchKey.contains(q) }.map(\.comic)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to \"\(tierList.title)\"").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selected.isEmpty ? "" : "(\(selected.count))")") {
                    let orderedIds = allComics.map(\.comic.id).filter { selected.contains($0) }
                    LibraryViewModel.shared.addToTierList(tierListId: tierList.id, comicIds: orderedIds)
                    onAdd(); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding()

            Divider()

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal).padding(.vertical, 8)

            List(filtered, selection: $selected) { comic in
                HStack(spacing: 10) {
                    PublisherBadge(publisher: comic.publisher)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comic.title).font(.body)
                        Text(comic.series).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(comic.id)
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 520)
        .task {
            let tierListId = tierList.id
            let (comics, inList) = await Task.detached(priority: .userInitiated) {
                (DatabaseManager.shared.allComics(), DatabaseManager.shared.comicIdsInTierList(tierListId: tierListId))
            }.value
            allComics     = comics.map { (comic: $0, searchKey: "\($0.title) \($0.series)".lowercased()) }
            alreadyInList = inList
        }
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
