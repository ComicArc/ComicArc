import SwiftUI

/// Your own reading orders across any series, like playlists.
struct ReadingPathsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    ScreenHeader(title: "Reading Paths", subtitle: "Your own reading orders, across any series")
                    Spacer()
                    Button { NewPathPrompt.ask { title in createAndOpen(title) } } label: { Label("New Path", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle())
                }
                if model.readingPaths.isEmpty {
                    EmptyState(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "No Reading Paths yet",
                               message: "Make a path for a crossover event, a character's history, or a run you want to read in order. Add comics from any comic's menu.",
                               action: ("New Reading Path", { NewPathPrompt.ask { createAndOpen($0) } }))
                        .frame(minHeight: 380)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 22)], alignment: .leading, spacing: 26) {
                        ForEach(model.readingPaths) { p in
                            PathCard(path: p)
                                .onTapGesture { model.path.append(.path(p.id)) }
                                .contextMenu {
                                    Button("Rename…") {
                                        NewPathPrompt.ask(title: "Rename Reading Path", initial: p.title) { t in
                                            model.perform { try await $0.updatePath(p.id, title: t, description: p.description) }
                                        }
                                    }
                                    Button("Delete Reading Path", role: .destructive) { delete(p) }
                                }
                        }
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
    }

    private func createAndOpen(_ title: String) {
        Task {
            guard let id = try? await Database.shared.createPath(title: title) else { return }
            model.libraryDidChange()
            model.path.append(.path(id))
        }
    }

    private func delete(_ p: ReadingPath) {
        Task {
            let items = (try? await Database.shared.pathItems(p.id)) ?? []
            try? await Database.shared.deletePath(p.id)
            model.libraryDidChange()
            model.showToast("Deleted “\(p.title)”") {
                if let id = try? await Database.shared.createPath(title: p.title, description: p.description) {
                    _ = try? await Database.shared.addToPath(id, comicIDs: items.map(\.comic.id))
                    for item in items where !item.notes.isEmpty {
                        if let new = try? await Database.shared.pathItems(id).first(where: { $0.comic.id == item.comic.id }) {
                            try? await Database.shared.setPathItemNotes(new.id, notes: item.notes)
                        }
                    }
                }
                model.libraryDidChange()
            }
        }
    }
}

private struct PathCard: View {
    let path: ReadingPath
    @State private var coverPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if let first = path.firstComicID, let coverPath {
                    CoverImage(comicID: first, path: coverPath, customPath: path.coverImagePath)
                } else {
                    Theme.raised
                    Image(systemName: path.isReadingList ? "bookmark.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.largeTitle).foregroundStyle(Theme.accent.opacity(0.6))
                }
            }
            .coverFrame(width: 150)
            .overlay(alignment: .bottom) {
                if path.count > 0 { ProgressLine(value: Double(path.finished) / Double(path.count), color: Theme.finished).padding(6) }
            }
            .hoverLift()
            Text(path.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Text(path.count == 0 ? "Empty" : "\(path.finished) of \(path.count) read").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: path.firstComicID) {
            guard let id = path.firstComicID else { return }
            coverPath = try? await Database.shared.read { try $0.scalarString("SELECT file_path FROM comics WHERE id = ?", [id]) }
        }
    }
}

struct PathDetailView: View {
    let pathID: Int64
    @Environment(AppModel.self) private var model
    @State private var items: [ReadingPathItem] = []
    @State private var adding = false
    @State private var editingNotes: ReadingPathItem?

    private var path: ReadingPath? { model.readingPaths.first { $0.id == pathID } }
    private var resume: ReadingPathItem? {
        items.first { $0.comic.isInProgress } ?? items.first { !$0.comic.isFinished } ?? items.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                ScreenHeader(title: path?.title ?? "Reading Path", subtitle: subtitle)
                Spacer()
                if let resume {
                    Button { model.open(resume.comic, pathID: pathID) } label: {
                        Label(items.contains { $0.comic.isStarted || $0.comic.isFinished } ? "Continue" : "Start Reading", systemImage: "book.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                }
                Button { adding = true } label: { Label("Add Comics", systemImage: "plus") }.buttonStyle(QuietButtonStyle())
                Menu {
                    Button("Rename…") {
                        guard let p = path else { return }
                        NewPathPrompt.ask(title: "Rename Reading Path", initial: p.title) { t in
                            model.perform { try await $0.updatePath(p.id, title: t, description: p.description) }
                        }
                    }
                    Button("Choose Cover Image…") { pickCover() }
                    if path?.coverImagePath != nil {
                        Button("Use First Comic as Cover") { model.perform { try await $0.setPathCover(pathID, imagePath: nil) } }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(Theme.gutter)

            if items.isEmpty {
                EmptyState(icon: "plus.square.on.square", title: "This path is empty",
                           message: "Add comics here, or from any comic's menu with Add to Reading Path.",
                           action: ("Add Comics", { adding = true }))
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PathRow(index: index + 1, item: item)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(item.comic, pathID: pathID) }
                            .contextMenu {
                                Button("Read") { model.open(item.comic, pathID: pathID) }
                                Button("Show Details") { model.path.append(.comic(item.comic.id)) }
                                Button(item.notes.isEmpty ? "Add Note…" : "Edit Note…") { editingNotes = item }
                                Divider()
                                Button(item.comic.isFinished ? "Mark as Unread" : "Mark as Read") {
                                    item.comic.isFinished ? model.markUnread([item.comic]) : model.markRead([item.comic])
                                }
                                Divider()
                                Button("Remove from Path", role: .destructive) { remove([item]) }
                            }
                    }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                        let ids = items.map(\.id)
                        model.perform { try await $0.reorderPath(pathID, itemIDs: ids) }
                    }
                    .onDelete { remove($0.map { items[$0] }) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle(path?.title ?? "")
        .task(id: model.revision) { items = (try? await Database.shared.pathItems(pathID)) ?? [] }
        .sheet(isPresented: $adding) { ComicPicker(pathID: pathID, existing: Set(items.map(\.comic.id))) }
        .sheet(item: $editingNotes) { item in NoteSheet(item: item) }
    }

    private var subtitle: String {
        let read = items.filter(\.comic.isFinished).count
        return items.isEmpty ? "No comics yet" : "\(items.count) comics · \(read) read · double-click to read, drag to reorder"
    }

    private func remove(_ removed: [ReadingPathItem]) {
        let ids = removed.map(\.comic.id)
        let title = path?.title ?? ""
        Task {
            try? await Database.shared.removeFromPath(pathID, comicIDs: ids)
            model.libraryDidChange()
            model.showToast(removed.count == 1 ? "Removed “\(removed[0].comic.title)”" : "Removed \(removed.count) comics") {
                model.addToPath(removed.map(\.comic), pathID: pathID, title: title)
            }
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let path = CoverStore.shared.importCustomImage(from: url, name: "run_\(pathID)") else { return }
        Task { await CoverStore.shared.invalidateFile(path) }
        model.perform { try await $0.setPathCover(pathID, imagePath: path) }
    }
}

private struct PathRow: View {
    let index: Int
    let item: ReadingPathItem
    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 28, alignment: .trailing)
            Image(systemName: item.comic.isFinished ? "checkmark.circle.fill" : item.comic.isInProgress ? "circle.lefthalf.filled" : "circle")
                .foregroundStyle(item.comic.isFinished ? Theme.finished : item.comic.isInProgress ? Theme.accent : Theme.textTertiary)
            CoverImage(item.comic).frame(width: 34, height: 51).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.comic.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    PublisherBadge(publisher: item.comic.publisher)
                    Text(item.comic.series).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
            }
            Spacer()
            if item.comic.isInProgress { ProgressLine(value: item.comic.progress).frame(width: 80) }
        }
        .padding(.vertical, 4)
    }
}

private struct NoteSheet: View {
    let item: ReadingPathItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note for \(item.comic.title)").font(.headline)
            TextEditor(text: $text).frame(height: 110).padding(4).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = text.trimmed, id = item.id
                    model.perform { try await $0.setPathItemNotes(id, notes: t) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { text = item.notes }
    }
}

/// Search the library and add comics to a path, in the order you pick them.
private struct ComicPicker: View {
    let pathID: Int64
    let existing: Set<Int64>
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Comic] = []
    @State private var picked: [Comic] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Comics").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                    let title = model.readingPaths.first { $0.id == pathID }?.title ?? ""
                    model.addToPath(picked, pathID: pathID, title: title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
            .padding(16)
            TextField("Search by title, series, issue, year…", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 16)
            List(results) { c in
                let isPicked = picked.contains(c)
                HStack(spacing: 10) {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle").foregroundStyle(isPicked ? Theme.accent : Theme.textTertiary)
                    CoverImage(c).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 3))
                    VStack(alignment: .leading) {
                        Text(c.title).lineLimit(1)
                        Text(c.series).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if existing.contains(c.id) { Text("In path").font(.caption).foregroundStyle(Theme.textTertiary) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !existing.contains(c.id) else { return }
                    if let i = picked.firstIndex(of: c) { picked.remove(at: i) } else { picked.append(c) }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 600)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(150))
            results = (try? await Database.shared.comics(ComicFilter(search: query.trimmed.isEmpty ? nil : query, limit: 300))) ?? []
        }
    }
}

/// Starred pages, shown as the page itself; click to jump straight to it.
struct HighlightsView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Highlight] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Highlights", subtitle: "Pages you starred while reading")
                if loaded && items.isEmpty {
                    EmptyState(icon: "star", title: "No highlights yet", message: "While reading, press H (or the star) to save a page here.")
                        .frame(minHeight: 360)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 22)], alignment: .leading, spacing: 26) {
                    ForEach(items) { h in
                        VStack(alignment: .leading, spacing: 6) {
                            HighlightPage(highlight: h)
                                .coverFrame(width: 190)
                                .hoverLift()
                                .onTapGesture { model.open(h.comic, page: h.bookmark.page) }
                            Text(h.bookmark.label.isEmpty ? h.comic.title : h.bookmark.label)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                            Text("\(h.comic.series) · page \(h.bookmark.page + 1)").font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        .frame(width: 190, alignment: .leading)
                        .contextMenu {
                            Button("Open at This Page") { model.open(h.comic, page: h.bookmark.page) }
                            Button("Rename…") {
                                NewPathPrompt.ask(title: "Name This Highlight", placeholder: "Label", initial: h.bookmark.label) { label in
                                    model.perform { try await $0.setHighlight(comicID: h.comic.id, page: h.bookmark.page, on: true, label: label) }
                                }
                            }
                            Button("Remove from Highlights", role: .destructive) {
                                model.perform { try await $0.setHighlight(comicID: h.comic.id, page: h.bookmark.page, on: false) }
                            }
                        }
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .task(id: model.revision) { items = (try? await Database.shared.highlights()) ?? []; loaded = true }
    }
}

private struct HighlightPage: View {
    let highlight: Highlight
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Theme.raised
            if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit) }
        }
        .task(id: highlight.id) {
            let path = highlight.comic.filePath, page = highlight.bookmark.page
            image = await Task.detached(priority: .userInitiated) {
                guard let doc = try? Documents.open(path), let src = try? doc.page(page) else { return nil }
                defer { doc.close() }
                return ImageDecoder.decode(src, maxPixelSize: 600)
            }.value
        }
    }
}
