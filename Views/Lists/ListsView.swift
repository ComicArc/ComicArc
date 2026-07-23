extension Notification.Name {
    static let listDeleted = Notification.Name("listDeleted")
    static let listUpdated = Notification.Name("listUpdated")
}

import SwiftUI

struct ListsListView: View {
    @Binding var selectedList: ComicList?
    @State private var lists:          [ComicList] = []
    @State private var isLoading       = true
    @State private var showingCreate   = false
    @State private var newListTitle    = ""
    @State private var newListDesc     = ""
    @State private var draggedListId:  Int64?
    @State private var dropTargetListId: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LISTS")
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
                .accessibilityLabel("Create List")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lists.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "trophy")
                        .font(.system(size: 42)).foregroundStyle(.quaternary)
                    Text("No Lists Yet").font(.headline).foregroundStyle(.secondary)
                    Text("Build a curated collection or ranking, like \"Best Vertigo Runs\" — no reading order required.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Create List") { showingCreate = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lists) { list in
                            let isTarget = dropTargetListId == list.id && draggedListId != list.id
                            ListCard(
                                list: list,
                                isSelected: selectedList?.id == list.id,
                                onCoverChanged: { Task { await loadLists() } }
                            ) { selectedList = list }
                            .background(isTarget ? Design.brandGold.opacity(0.12) : Color.clear)
                            .onDrag {
                                draggedListId = list.id
                                return NSItemProvider(object: NSString(string: String(list.id)))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetListId = active ? list.id : nil }
                                    )) { _, _ in
                                guard let fromId = draggedListId,
                                      let fromIdx = lists.firstIndex(where: { $0.id == fromId }),
                                      let toIdx = lists.firstIndex(where: { $0.id == list.id }) else { return false }
                                var arr = lists
                                let moved = arr.remove(at: fromIdx)
                                arr.insert(moved, at: toIdx)
                                lists = arr
                                DatabaseManager.shared.reorderLists(orderedIds: arr.map(\.id))
                                draggedListId = nil; dropTargetListId = nil
                                return true
                            }
                            // Drag-and-drop is the only way to reorder Lists, which is both a
                            // hard accessibility gap (no keyboard/VoiceOver path at all) and slow
                            // for a long list (dragging across many rows). These give a faster,
                            // non-drag alternative for everyone.
                            .contextMenu {
                                Button("Move to Top") { moveList(list, to: 0) }
                                    .disabled(lists.first?.id == list.id)
                                Button("Move Up") { moveList(list, by: -1) }
                                    .disabled(lists.first?.id == list.id)
                                Button("Move Down") { moveList(list, by: 1) }
                                    .disabled(lists.last?.id == list.id)
                                Button("Move to Bottom") { moveList(list, to: lists.count - 1) }
                                    .disabled(lists.last?.id == list.id)
                            }
                            .accessibilityActions {
                                Button("Move Up") { moveList(list, by: -1) }
                                Button("Move Down") { moveList(list, by: 1) }
                                Button("Move to Top") { moveList(list, to: 0) }
                                Button("Move to Bottom") { moveList(list, to: lists.count - 1) }
                            }
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task { await loadLists() }
        .onReceive(NotificationCenter.default.publisher(for: .listDeleted)) { _ in
            Task { await loadLists()
                if let sel = selectedList, !lists.contains(sel) { selectedList = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .listUpdated)) { _ in
            // Renaming/re-rating a List in its detail view only updates that view's own local
            // @State copy and the DB -- without this, this sidebar list's row keeps showing the
            // pre-edit title/rating until an unrelated reload happens.
            Task { await loadLists() }
        }
        .sheet(isPresented: $showingCreate) { createSheet }
    }

    private var createSheet: some View {
        VStack(spacing: 20) {
            Text("New List").font(.title2.bold())
            TextField("Title", text: $newListTitle).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $newListDesc).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingCreate = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Create") { createList() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newListTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
    }

    private func createList() {
        let title = newListTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        LibraryViewModel.shared.createList(title: title, description: newListDesc)
        newListTitle = ""; newListDesc = ""
        showingCreate = false
        Task { await loadLists() }
    }

    private func loadLists() async {
        isLoading = true
        let r = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.allLists()
        }.value
        lists = r; isLoading = false
    }

    private func moveList(_ list: ComicList, by delta: Int) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        moveList(list, to: idx + delta)
    }

    private func moveList(_ list: ComicList, to newIndex: Int) {
        guard let fromIdx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        let clamped = max(0, min(newIndex, lists.count - 1))
        guard clamped != fromIdx else { return }
        var arr = lists
        let moved = arr.remove(at: fromIdx)
        arr.insert(moved, at: clamped)
        lists = arr
        DatabaseManager.shared.reorderLists(orderedIds: arr.map(\.id))
    }
}

struct ListCard: View {
    let list:       ComicList
    let isSelected: Bool
    var onCoverChanged: () -> Void = {}
    let onSelect:   () -> Void

    @State private var isHovered = false
    @State private var showCoverPicker = false
    @Environment(\.fileService) private var fileService

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? Design.brandGold : Color.clear)
                    .frame(width: 3)

                coverThumbnail
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 10)

                VStack(alignment: .leading, spacing: 5) {
                    Text(list.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.textPrimary)
                        .lineLimit(1)

                    if !list.description.isEmpty {
                        Text(list.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let r = list.rating, r > 0 {
                            HStack(spacing: 1) {
                                ForEach(1...r, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Design.brandGold)
                                }
                            }
                        }
                        if list.comicCount > 0 {
                            Text("\(list.comicCount) comic\(list.comicCount == 1 ? "" : "s")")
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
        .accessibilityLabel(list.description.isEmpty ? list.title : "\(list.title), \(list.description)")
        .accessibilityValue(list.comicCount > 0 ? "\(list.comicCount) comics" : "Empty")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Choose Existing Cover…") { showCoverPicker = true }
            Button("Custom Image…") { pickCoverImage() }
            if list.coverImagePath != nil {
                Button("Remove Custom Cover") {
                    LibraryViewModel.shared.clearListCover(listId: list.id)
                    onCoverChanged()
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(title: "Choose Cover for \(list.title)") { comic in
                LibraryViewModel.shared.setListCover(listId: list.id, usingCoverOf: comic, onDone: onCoverChanged)
            }
        }
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let path = list.coverImagePath, let img = PlatformImage.fromFile(path) {
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Design.surfaceBg
                Image(systemName: "trophy")
                    .font(.system(size: 14)).foregroundStyle(.tertiary)
            }
        }
    }

    private func pickCoverImage() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(list.title)",
            prompt: "Set Cover"
        ) { urls in
            if let url = urls.first {
                LibraryViewModel.shared.setListCover(listId: list.id, imageURL: url)
                onCoverChanged()
            }
        }
    }
}

struct ListDetailView: View {
    let list:     ComicList
    let onDelete: () -> Void

    @State private var currentList:     ComicList
    @State private var items:           [ListItem] = []
    @State private var itemsLoading     = true
    @State private var showingAddComics = false
    @State private var listRating:      Int        = 0
    @State private var showReviewSheet  = false
    @State private var reviewText:      String     = ""
    @State private var showEditSheet    = false

    init(list: ComicList, onDelete: @escaping () -> Void) {
        self.list     = list
        self.onDelete = onDelete
        _currentList  = State(initialValue: list)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            listPageHeader
            Rectangle().fill(Design.borderColor).frame(height: 1)

            HStack(spacing: 8) {
                Text("LIST")
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
                    Text("Add comics to build your list.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Button("Add Comics") { showingAddComics = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        ListItemRow(item: item, listId: list.id, onChange: loadItems)
                    }
                    .onMove { from, to in reorder(from: from, to: to) }
                    .onDelete { indices in
                        let removed = indices.map { items[$0] }
                        LibraryViewModel.shared.removeFromListWithUndo(listId: list.id, items: removed, onRestored: loadItems)
                        loadItems()
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            loadItems()
            listRating = list.rating ?? 0
            reviewText = list.review ?? ""
        }
        .onChange(of: list) { _, l in
            currentList = l
            listRating  = l.rating ?? 0
            reviewText  = l.review ?? ""
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in
            // The reader is a ZStack overlay, not a navigation push, so this view is never
            // told a comic in it was just read -- refresh progress so rows don't show stale
            // read/unread state after the user finishes a comic and closes the reader.
            loadItems()
        }
        .sheet(isPresented: $showingAddComics) {
            AddComicsToListView(list: list) { loadItems() }
        }
        .sheet(isPresented: $showReviewSheet) {
            reviewSheet
        }
        .sheet(isPresented: $showEditSheet) {
            EditListView(list: $currentList)
        }
    }

    private var listPageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(currentList.title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(0.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !currentList.description.isEmpty {
                    Text(currentList.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 10) {
                StarRating(rating: listRating) { star in
                    let newVal = star == listRating ? 0 : star
                    listRating = newVal
                    LibraryViewModel.shared.setListRating(list.id,
                                                        rating: newVal,
                                                        review: reviewText.isEmpty ? nil : reviewText)
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

                    Button(role: .destructive) {
                        LibraryViewModel.shared.deleteListWithUndo(list)
                        onDelete()
                    } label: {
                        Text("Delete List")
                            .foregroundStyle(.red)
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
            Text("Rate & Review: \(list.title)")
                .font(.title2.bold())

            Text("Rating").font(.headline)
            StarRating(rating: listRating) { star in
                listRating = star == listRating ? 0 : star
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
                    LibraryViewModel.shared.setListRating(list.id,
                                                        rating: listRating,
                                                        review: reviewText.isEmpty ? nil : reviewText)
                    showReviewSheet = false
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440)
    }

    private func reorder(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        LibraryViewModel.shared.reorderList(listId: list.id, orderedIds: items.map(\.id))
    }

    private func loadItems() {
        let listId = list.id
        itemsLoading = true
        Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.listItems(listId: listId)
            await MainActor.run { items = rows; itemsLoading = false }
        }
    }
}

struct ListItemRow: View {
    let item:     ListItem
    let listId:   Int64
    let onChange: () -> Void

    @State private var showNotes    = false
    @State private var notesText:   String    = ""
    @State private var thumbnail:   PlatformImage?  = nil

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(item.position + 1)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)

            Group {
                if let img = thumbnail {
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.1)
                        .overlay(
                            Image(systemName: "book.closed")
                                .font(.caption2).foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 36, height: 54)
            .comicCardStyle()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.comic.title)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    PublisherBadge(publisher: item.comic.publisher)
                    if item.comic.series != "General" {
                        Text(item.comic.series)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if item.comic.isStarted && !item.comic.isFinished {
                    ProgressView(value: item.comic.progressPercent)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                }

                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                notesText = item.notes
                showNotes = true
            } label: {
                Image(systemName: item.notes.isEmpty ? "note.text.badge.plus" : "note.text")
                    .foregroundStyle(item.notes.isEmpty ? .quaternary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Edit notes")
            .popover(isPresented: $showNotes, arrowEdge: .trailing) {
                notesPopover
            }

            Image(systemName: "line.3.horizontal").foregroundStyle(.quaternary)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Open") { LibraryViewModel.shared.openReader(item.comic) }
            Divider()
            if item.comic.isFinished {
                Button("Mark as Unread") {
                    LibraryViewModel.shared.markUnread(item.comic)
                    onChange()
                }
            } else {
                Button("Mark as Read") {
                    LibraryViewModel.shared.markRead(item.comic)
                    onChange()
                }
            }
            Divider()
            Button("Remove from List", role: .destructive) {
                LibraryViewModel.shared.removeFromListWithUndo(listId: listId, items: [item], onRestored: onChange)
                onChange()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("#\(item.position + 1) \(item.comic.title)")
        .accessibilityValue(item.comic.isFinished ? "Read" : item.comic.isStarted ? "In progress" : "Unread")
        .accessibilityHint("Double-tap to open")
        .accessibilityAddTraits(.isButton)

        .accessibilityAction(named: item.notes.isEmpty ? "Add Notes" : "Edit Notes") {
            notesText = item.notes
            showNotes = true
        }
        .accessibilityAction(named: item.comic.isFinished ? "Mark as Unread" : "Mark as Read") {
            if item.comic.isFinished { LibraryViewModel.shared.markUnread(item.comic) }
            else { LibraryViewModel.shared.markRead(item.comic) }
            onChange()
        }
        .accessibilityAction(named: "Remove from List") {
            LibraryViewModel.shared.removeFromListWithUndo(listId: listId, items: [item], onRestored: onChange)
            onChange()
        }
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.comic) { thumbnail = $0 } }
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes").font(.headline)
            TextEditor(text: $notesText)
                .frame(width: 260, height: 100)
                .border(Design.borderColor)
            HStack {
                Button("Cancel") { showNotes = false }
                Spacer()
                Button("Save") {
                    LibraryViewModel.shared.setListItemNotes(item.id, notes: notesText)
                    onChange()
                    showNotes = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

struct EditListView: View {
    @Binding var list: ComicList
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var description: String

    init(list: Binding<ComicList>) {
        self._list   = list
        _title       = State(initialValue: list.wrappedValue.title)
        _description = State(initialValue: list.wrappedValue.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit List")
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
        LibraryViewModel.shared.updateList(id: list.id, title: t, description: d)
        list.title       = t
        list.description = d
        dismiss()
    }
}

struct AddComicsToListView: View {
    let list:  ComicList
    let onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allComics:     [(comic: Comic, searchKey: String)] = []
    @State private var alreadyInList: Set<Int64>  = []
    @State private var selected       = Set<Int64>()
    @State private var search         = ""

    private var filtered: [Comic] {
        let candidates = allComics.filter { !alreadyInList.contains($0.comic.id) }
        guard !search.isEmpty else { return candidates.map(\.comic) }
        let q = search.lowercased()
        return candidates.filter { $0.searchKey.contains(q) }.map(\.comic)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to \"\(list.title)\"").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selected.isEmpty ? "" : "(\(selected.count))")") {
                    // Order by the picker's own list order, not Set iteration order (which is
                    // unspecified) -- otherwise multi-selecting several comics lands them in the
                    // list in an arbitrary order unrelated to anything the user saw or chose.
                    let orderedIds = allComics.map(\.comic.id).filter { selected.contains($0) }
                    LibraryViewModel.shared.addToList(listId: list.id, comicIds: orderedIds)
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
            let listId = list.id
            let (comics, inList) = await Task.detached(priority: .userInitiated) {
                (DatabaseManager.shared.allComics(), DatabaseManager.shared.comicIdsInList(listId: listId))
            }.value
            allComics     = comics.map { (comic: $0, searchKey: "\($0.title) \($0.series)".lowercased()) }
            alreadyInList = inList
        }
    }
}

struct ListsView: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        NavigationStack {
            ListsListView(selectedList: $vm.selectedList)
                .navigationTitle("Lists")
        }
    }
}
