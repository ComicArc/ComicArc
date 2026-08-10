import SwiftUI
import UniformTypeIdentifiers

/// Everything that varies between a `Run` list screen and a `TierList` list screen -- wording,
/// icons, and the handful of operations whose underlying `LibraryViewModel` method differs by
/// name (`createRun` vs `createTierList`, etc.). `CollectionListView` owns everything that
/// doesn't vary: layout, drag-reorder, the Move Up/Down/Top/Bottom context menu (previously
/// duplicated verbatim in both `RunsListView` and `TierListsListView`), empty states, and the
/// create sheet.
@MainActor
struct CollectionListConfig<T: NamedCollection> {
    let noun: String                    // "Reading Path" / "Tier List"
    let nounPlural: String               // "Reading Paths" / "Tier Lists"
    let emptyIcon: String
    let emptyMessage: String
    let cardIcon: String                 // placeholder cover icon
    let subtitle: (T) -> String          // "3/5 read" / "5 comics"
    /// `nil` disables the list-level "Delete" context-menu item -- matches Run's existing
    /// behavior (delete only from the detail screen) vs. TierList's (delete from either).
    let deleteWithUndo: (@MainActor (T) -> Void)?
    let fetch: @MainActor () async -> [T]
    let reorder: @MainActor ([Int64]) -> Void
    let create: @MainActor (_ title: String, _ description: String) -> Void
    let setCoverFromComic: @MainActor (T, Comic, @escaping () -> Void) -> Void
    let setCoverFromURL: @MainActor (T, URL) -> Void
    let clearCover: @MainActor (T) -> Void
}

struct CollectionListView<T: NamedCollection>: View {
    let config: CollectionListConfig<T>
    @Binding var selected: T?
    /// Fires after create/delete/cover-change so the caller can also refresh whatever cached
    /// list (e.g. `vm.runs`/`vm.tierLists`) other screens read from.
    var onListChanged: () -> Void = {}
    /// Bump this (from the caller) to force a reload -- e.g. when a `.runUpdated`/`.tierListUpdated`
    /// notification fires because the detail screen changed something. Plain reassignment of
    /// `config`/`selected` doesn't itself trigger a re-fetch, since `items` is this view's own
    /// `@State`, not derived from `config` on every body evaluation.
    var reloadToken: UUID = UUID()

    @State private var items: [T] = []
    @State private var isLoading = true
    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var newDescription = ""
    @State private var draggedId: Int64?
    @State private var dropTargetId: Int64?
    @State private var pendingDelete: T?
    @EnvironmentObject private var vm: LibraryViewModel

    private var filtered: [T] {
        guard !vm.searchText.isEmpty else { return items }
        let q = vm.searchText.lowercased()
        return items.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SignageLabel(text: config.nounPlural, size: 20, kerning: 1, tint: Design.textPrimary)
                Spacer()
                Button { showingCreate = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.brandGold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create \(config.noun)")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyStateView(icon: config.emptyIcon, title: "No \(config.nounPlural) Yet", message: config.emptyMessage) {
                    Button("Create \(config.noun)") { showingCreate = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No Matching \(config.nounPlural)")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { item in
                            let isTarget = dropTargetId == item.id && draggedId != item.id
                            CollectionCard(item: item, config: config, isSelected: selected?.id == item.id,
                                           onCoverChanged: { Task { await load() } }) { selected = item }
                                .background(isTarget ? Design.brandGold.opacity(0.12) : Color.clear)
                                .onDrag {
                                    draggedId = item.id
                                    return NSItemProvider(object: NSString(string: String(item.id)))
                                }
                                .onDrop(of: [.plainText],
                                        isTargeted: Binding(get: { isTarget }, set: { active in dropTargetId = active ? item.id : nil })) { _, _ in
                                    guard let fromId = draggedId,
                                          let fromIdx = items.firstIndex(where: { $0.id == fromId }),
                                          let toIdx = items.firstIndex(where: { $0.id == item.id }) else { return false }
                                    var arr = items
                                    let moved = arr.remove(at: fromIdx)
                                    arr.insert(moved, at: toIdx)
                                    items = arr
                                    config.reorder(arr.map(\.id))
                                    draggedId = nil; dropTargetId = nil
                                    return true
                                }
                                // Drag-and-drop is the only way to reorder, which is both a hard
                                // accessibility gap (no keyboard/VoiceOver path) and slow for a
                                // long list -- these give a faster, non-drag alternative.
                                .contextMenu {
                                    Button("Move to Top") { move(item, to: 0) }.disabled(items.first?.id == item.id)
                                    Button("Move Up") { move(item, by: -1) }.disabled(items.first?.id == item.id)
                                    Button("Move Down") { move(item, by: 1) }.disabled(items.last?.id == item.id)
                                    Button("Move to Bottom") { move(item, to: items.count - 1) }.disabled(items.last?.id == item.id)
                                    if config.deleteWithUndo != nil {
                                        Divider()
                                        Button("Delete \(config.noun)", role: .destructive) { pendingDelete = item }
                                    }
                                }
                                .accessibilityActions {
                                    Button("Move Up") { move(item, by: -1) }
                                    Button("Move Down") { move(item, by: 1) }
                                    Button("Move to Top") { move(item, to: 0) }
                                    Button("Move to Bottom") { move(item, to: items.count - 1) }
                                }
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                        }
                    }
                }
            }
        }
        .ambientBackground()
        .task(id: reloadToken) { await load() }
        .sheet(isPresented: $showingCreate) { createSheet }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete \(config.noun)", role: .destructive) {
                guard let target = pendingDelete else { return }
                config.deleteWithUndo?(target)
                if selected?.id == target.id { selected = nil }
                pendingDelete = nil
                onListChanged()
                Task { await load() }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The comics themselves are not affected -- only this ranking is removed.")
        }
    }

    private var createSheet: some View {
        VStack(spacing: 20) {
            Text("New \(config.noun)").font(.title2.bold())
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $newDescription).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingCreate = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
    }

    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        config.create(title, newDescription)
        newTitle = ""; newDescription = ""
        showingCreate = false
        onListChanged()
        Task { await load() }
    }

    func load() async {
        isLoading = true
        items = await config.fetch()
        isLoading = false
    }

    private func move(_ item: T, by delta: Int) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        move(item, to: idx + delta)
    }

    private func move(_ item: T, to newIndex: Int) {
        guard let fromIdx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let clamped = max(0, min(newIndex, items.count - 1))
        guard clamped != fromIdx else { return }
        var arr = items
        let moved = arr.remove(at: fromIdx)
        arr.insert(moved, at: clamped)
        items = arr
        config.reorder(arr.map(\.id))
    }
}

private struct CollectionCard<T: NamedCollection>: View {
    let item: T
    let config: CollectionListConfig<T>
    let isSelected: Bool
    var onCoverChanged: () -> Void = {}
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var showCoverPicker = false
    @Environment(\.fileService) private var fileService

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle().fill(isSelected ? Design.brandGold : Color.clear).frame(width: 3)

                coverThumbnail
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 10)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(Design.Typography.rowTitle)
                        .foregroundStyle(Design.textPrimary)
                        .lineLimit(1)

                    if !item.description.isEmpty {
                        Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let r = item.rating, r > 0 {
                            HStack(spacing: 1) {
                                ForEach(1...r, id: \.self) { _ in
                                    Image(systemName: "star.fill").font(Design.Typography.starGlyph).foregroundStyle(Design.brandGold)
                                }
                            }
                        }
                        Text(config.subtitle(item)).font(Design.Typography.microLabel).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(Design.Typography.microGlyph)
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
        .accessibilityLabel(item.description.isEmpty ? item.title : "\(item.title), \(item.description)")
        .accessibilityValue(config.subtitle(item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Choose Existing Cover…") { showCoverPicker = true }
            Button("Custom Image…") { pickCoverImage() }
            if item.coverImagePath != nil {
                Button("Remove Custom Cover") { config.clearCover(item); onCoverChanged() }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(title: "Choose Cover for \(item.title)") { comic in
                config.setCoverFromComic(item, comic, onCoverChanged)
            }
        }
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let path = item.coverImagePath, let img = PlatformImage.fromFile(path) {
            Image(platformImage: img).comicCoverStyle().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Design.surfaceBg
                Image(systemName: config.cardIcon).font(Design.Typography.rowIcon).foregroundStyle(.tertiary)
            }
        }
    }

    private func pickCoverImage() {
        fileService.pickFiles(allowsMultiple: false, message: "Choose a cover image for \(item.title)",
                               prompt: "Set Cover", contentTypes: [.image]) { urls in
            if let url = urls.first {
                config.setCoverFromURL(item, url)
                onCoverChanged()
            }
        }
    }
}
