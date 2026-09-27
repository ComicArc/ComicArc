#if os(iOS) || os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

struct iPadDetailColumn: View {
    let comic: Comic?
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showInfo = false

    var body: some View {
        Group {
            if let comic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        iPadComicHero(comic: comic)

                        HStack(spacing: 12) {
                            Button(action: { vm.openReader(comic) }) {
                                Label(comic.isStarted ? "Continue" : "Read", systemImage: "book.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isStarted ? "Continue reading \(comic.title)" : "Read \(comic.title)")

                            Button {
                                if comic.isFinished { vm.markUnread(comic) } else { vm.markRead(comic) }
                            } label: {
                                Image(systemName: comic.isFinished ? "arrow.counterclockwise" : "checkmark")
                                    .font(.title3)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isFinished ? "Mark as unread" : "Mark as read")

                            Button(action: { vm.toggleFavorite(comic) }) {
                                Image(systemName: comic.isFavorite ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(comic.isFavorite ? .red : .primary)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isFavorite ? "Remove from favorites" : "Add to favorites")

                            Button(action: { vm.toggleReadingList(comic) }) {
                                Image(systemName: comic.inReadingList ? "bookmark.fill" : "bookmark")
                                    .font(.title3)
                                    .foregroundStyle(comic.inReadingList ? Color.accentColor : .primary)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.inReadingList ? "Remove from reading list" : "Add to reading list")

                            Button { showInfo = true } label: {
                                Image(systemName: "info.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel("Metadata info")
                        }
                        .padding(.horizontal)

                        iPadComicMeta(comic: comic)
                    }
                }
                .navigationTitle(comic.title)
                .navigationBarTitleDisplayMode(.large)
                .sheet(isPresented: $showInfo) {
                    MetadataInspectorView(comicId: comic.id).environmentObject(vm)
                }
            } else {
                ContentUnavailableView("Select a Comic",
                                       systemImage: "book.closed",
                                       description: Text("Choose a comic from the library."))
            }
        }
    }
}

struct iPadComicGrid: View {
    let comics: [Comic]
    @Binding var selectedComic: Comic?
    @EnvironmentObject var vm: LibraryViewModel

    @State private var draggedId: Int64?
    @State private var dropTargetId: Int64?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            if comics.isEmpty && vm.isLoading {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<20, id: \.self) { _ in ShimmerCard() }
                }
                .padding()
            } else if comics.isEmpty {
                ContentUnavailableView("No Comics",
                                       systemImage: "books.vertical",
                                       description: Text("Import comics to get started."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(comics) { comic in
                        let isTarget = dropTargetId == comic.id && draggedId != comic.id
                        iPadComicTile(comic: comic)
                            .onTapGesture { selectedComic = comic }
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner)
                                    .stroke(Design.brandBlue, lineWidth: selectedComic?.id == comic.id ? 2 : 0)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner)
                                    .stroke(Design.brandGold, lineWidth: isTarget ? 3 : 0)
                            )
                            .onDrag {
                                draggedId = comic.id
                                return NSItemProvider(object: NSString(string: String(comic.id)))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetId = active ? comic.id : nil }
                                    )) { _, _ in
                                guard let from = draggedId else { return false }
                                vm.moveComic(id: from, before: comic.id)
                                draggedId = nil; dropTargetId = nil
                                return true
                            }
                            // Keyboard/VoiceOver alternative to the drag reorder above.
                            .accessibilityAction(named: "Move Up") {
                                guard let idx = comics.firstIndex(where: { $0.id == comic.id }), idx > 0 else { return }
                                vm.moveComic(id: comic.id, before: comics[idx - 1].id)
                            }
                            .accessibilityAction(named: "Move Down") {
                                guard let idx = comics.firstIndex(where: { $0.id == comic.id }), idx + 1 < comics.count else { return }
                                // Moving the *next* comic to before this one is equivalent to
                                // moving this comic down by one, without needing a "move after" API.
                                vm.moveComic(id: comics[idx + 1].id, before: comic.id)
                            }
                    }
                }
                .padding()
            }
        }
    }
}

struct iPadComicTile: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?
    @State private var showNewPathPrompt = false
    @State private var newPathTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img)
                        .comicCoverStyle()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Design.cardBg
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 140, height: 200)
            .comicCardStyle()

            Text(comic.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if comic.progress > 0 {
                ProgressView(value: Double(comic.progress), total: max(1, Double(comic.pageCount)))
                    .tint(Design.brandBlue)
            }
        }
        .frame(width: 140)
        .task { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
        .contextMenu {
            Button("Open") { vm.readerComic = comic }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
            Button(comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                vm.toggleFavorite(comic)
            }
            Button(comic.inReadingList ? "Remove from Reading List" : "Add to Reading List") { vm.toggleReadingList(comic) }
            Menu("Add to Reading Path") {
                ForEach(vm.runs) { run in
                    Button(run.title) { vm.addToRunWithUndo(runId: run.id, runTitle: run.title, comicIds: [comic.id]) }
                }
                if !vm.runs.isEmpty { Divider() }
                Button("New Reading Path…") { newPathTitle = ""; showNewPathPrompt = true }
            }
        }
        .alert("New Reading Path", isPresented: $showNewPathPrompt) {
            TextField("Name", text: $newPathTitle)
            Button("Create") {
                let title = newPathTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let runId = vm.createRun(title: title, description: "")
                vm.addToRunWithUndo(runId: runId, runTitle: title, comicIds: [comic.id])
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue(comic.progress > 0
            ? "Page \(comic.progress + 1) of \(comic.pageCount)"
            : "Unread")
        .accessibilityHint("Double-tap to open")
        .accessibilityAddTraits(.isButton)
    }
}

struct iPadComicHero: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                } else {
                    RoundedRectangle(cornerRadius: Design.cardCorner)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .frame(width: 140, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .shadow(radius: 4)
            .padding(.leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(comic.title).font(.title2.bold()).lineLimit(3)
                if !comic.series.isEmpty {
                    Text(comic.series).font(.subheadline).foregroundStyle(.secondary)
                }
                if !comic.publisher.isEmpty {
                    Text(comic.publisher).font(.caption).foregroundStyle(.tertiary)
                }
                if comic.pageCount > 0 {
                    Text("\(comic.pageCount) pages").font(.caption).foregroundStyle(.tertiary)
                } else if vm.brokenComicIds.contains(comic.id) {
                    Label("Corrupted or empty — try rescanning", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
        .task { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
    }
}

struct iPadComicMeta: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var tags: [Tag] = []
    @State private var newTagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal)

            if comic.progress > 0 {
                metaRow("Progress",
                        value: "Page \(comic.progress) of \(comic.pageCount)",
                        icon: "book")
                ProgressView(value: Double(comic.progress), total: max(1, Double(comic.pageCount)))
                    .tint(.accentColor)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            if let issue = comic.issueNumber  { metaRow("Issue",    value: "#\(issue)",       icon: "number") }
            if let year  = comic.year          { metaRow("Year",     value: "\(year)",         icon: "calendar") }
            if let writer = comic.writer,  !writer.isEmpty  { metaRow("Writer",   value: writer,    icon: "pencil") }
            if let pencil = comic.penciller, !pencil.isEmpty { metaRow("Penciller", value: pencil,  icon: "paintbrush") }
            if let arc    = comic.storyArc, !arc.isEmpty     { metaRow("Story Arc", value: arc,     icon: "books.vertical") }

            Divider().padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) {
                Label("Tags", systemImage: "tag").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags) { tag in
                                TagChip(name: tag.name, category: tag.category) { removeTag(tag) }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Add tag…", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 10)
        }
        .task(id: comic.id) { loadTags() }
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: String, icon: String) -> some View {
        Divider().padding(.horizontal)
        HStack {
            Label(label, systemImage: icon).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .padding()
    }

    private func loadTags() {
        let comicId = comic.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
    }

    private func addTag() {
        let name = newTagText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.addTag(name: name, to: comic)
        newTagText = ""
        loadTags()
        vm.reload()
    }

    private func removeTag(_ tag: Tag) {
        vm.removeTag(tagId: tag.id, from: comic)
        loadTags()
        vm.reload()
    }
}

#endif
