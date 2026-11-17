import SwiftUI

struct IssueDetailView: View {
    let comicID: Int64
    @Environment(AppModel.self) private var model
    @State private var comic: Comic?
    @State private var tags: [Tag] = []
    @State private var paths: [ReadingPath] = []
    @State private var newTag = ""
    @State private var editing = false
    @State private var pickingCover = false
    @State private var notes = ""
    @State private var tint: Color = Theme.accent

    var body: some View {
        Group {
            if let comic {
                ScrollView { content(comic).padding(Theme.gutter) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle(comic?.title ?? "")
        .task(id: model.revision) { await load() }
        .sheet(isPresented: $editing) { if let comic { EditComicSheet(comic: comic) } }
        .sheet(isPresented: $pickingCover) { if let comic { CoverPickerSheet(comic: comic) } }
    }

    private func content(_ c: Comic) -> some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(spacing: 14) {
                CoverImage(c).coverFrame(width: 260).shadow(color: tint.opacity(0.4), radius: 24, y: 12)
                if c.pageCount > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressLine(value: c.isFinished ? 1 : c.progress, color: c.isFinished ? Theme.finished : Theme.accent)
                        Text(c.isFinished ? "Read" : c.isStarted ? "Page \(c.currentPage + 1) of \(c.pageCount)" : "Unread · \(c.pageCount) pages")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 260)
                } else {
                    Label("This file couldn't be read. Try Scan again; if it persists the file may be damaged.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).frame(width: 260)
                }
            }

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PublisherBadge(publisher: c.publisher)
                        Button(c.series) { openSeries(c) }.buttonStyle(.link).font(.headline)
                    }
                    Text(c.title).font(.system(size: 32, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button { model.open(c) } label: {
                        Label(c.isInProgress ? "Continue Reading" : c.isFinished ? "Read Again" : "Read", systemImage: "book.fill")
                    }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    Button { model.setFavorite([c], !c.isFavorite) } label: {
                        Label(c.isFavorite ? "Favorited" : "Favorite", systemImage: c.isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button { c.isFinished ? model.markUnread([c]) : model.markRead([c]) } label: {
                        Label(c.isFinished ? "Mark Unread" : "Mark Read", systemImage: c.isFinished ? "arrow.uturn.backward" : "checkmark")
                    }
                    .buttonStyle(QuietButtonStyle())
                    Menu {
                        Button(c.inReadingList ? "Remove from Reading List" : "Add to Reading List") { model.setReadingList([c], !c.inReadingList) }
                        AddToPathMenu(comics: [c])
                        Divider()
                        Button("Edit Details…") { editing = true }
                        Button("Choose Cover Page…") { pickingCover = true }
                        Button("Show in Finder") { FileOperations.revealInFinder([c.url]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { model.delete([c]); model.path.removeLast() }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).fixedSize()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                    if let n = c.issueNumber { fact("Issue", "#\(n)") }
                    if let w = c.writer { fact("Writer", w, search: true) }
                    if let p = c.penciller { fact("Artist", p, search: true) }
                    if let a = c.storyArc { fact("Story Arc", a, search: true) }
                    fact("Pages", "\(c.pageCount)")
                    fact("Format", c.fileExtension.uppercased())
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Tags")
                    FlowLayout {
                        if let era = c.folderGroup {
                            Button("#\(era)") { model.sidebar = .era(era) }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Theme.accent, in: Capsule())
                                .help("From the “\(era)” folder this comic is in")
                        }
                        ForEach(tags) { t in
                            HStack(spacing: 4) {
                                Button("#\(t.name)") { model.sidebar = .tag(t.name) }.buttonStyle(.plain)
                                Button { model.perform { try await $0.removeTag(t.id, from: c.id) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain).accessibilityLabel("Remove tag \(t.name)")
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 9).padding(.vertical, 4).background(Theme.raised, in: Capsule())
                        }
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.plain).font(.caption).frame(width: 110)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .overlay(Capsule().stroke(Theme.border))
                            .onSubmit {
                                let name = newTag; newTag = ""
                                model.perform { try await $0.addTag(name, to: [c.id]) }
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Notes")
                    TextEditor(text: $notes)
                        .font(.callout).scrollContentBackground(.hidden)
                        .padding(8).frame(minHeight: 70, maxHeight: 140)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .onChange(of: notes) { _, value in
                            let id = c.id
                            Task {
                                try? await Task.sleep(for: .milliseconds(600))
                                if value == notes { try? await Database.shared.setNotes(value.trimmed, comicID: id) }
                            }
                        }
                }

                if !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "In Reading Paths")
                        ForEach(paths) { p in
                            Button { model.sidebar = .paths; model.path = [.path(p.id)] } label: {
                                Label(p.title, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func fact(_ label: String, _ value: String, search: Bool = false) -> some View {
        Button {
            guard search else { return }
            model.sidebar = .home
            model.searchText = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(Theme.textTertiary)
                    if search { Image(systemName: "magnifyingglass").font(.system(size: 8)).foregroundStyle(Theme.textTertiary) }
                }
                Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!search)
        .help(search ? "Show every comic matching “\(value)”" : "")
    }

    private func openSeries(_ c: Comic) {
        Task {
            let group = try? await Database.shared.read { db in
                try db.scalarString("SELECT \(ComicSQL.groupName) FROM comics c WHERE c.id = ?", [c.id])
            }
            guard let name = group ?? nil,
                  let s = try? await Database.shared.seriesGroups(group: name, publisher: c.publisher).first(where: { $0.series == c.series })
            else { return }
            model.path.append(.series(s))
        }
    }

    private func load() async {
        guard let c = try? await Database.shared.comic(id: comicID) else { return }
        if comic?.id != c.id { notes = c.notes ?? "" }
        comic = c
        async let t = Database.shared.tags(comicID: comicID)
        async let p = Database.shared.pathsContaining(comicID: comicID)
        tags = (try? await t) ?? []
        paths = ((try? await p) ?? []).filter { !$0.isReadingList }
        if let color = await CoverStore.shared.accentColor(id: c.id, path: c.filePath) { tint = Color(nsColor: color) }
    }
}

struct EditComicSheet: View {
    let comic: Comic
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.comicInfoWriteBack) private var writeBackEnabled = false
    @State private var title = ""
    @State private var series = ""
    @State private var publisher = ""
    @State private var issue = ""
    @State private var year = ""
    @State private var writer = ""
    @State private var artist = ""
    @State private var arc = ""
    @State private var writeToFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Details").font(.title3.bold())
            Form {
                TextField("Title", text: $title)
                TextField("Series", text: $series)
                TextField("Publisher", text: $publisher)
                TextField("Issue", text: $issue)
                TextField("Year", text: $year)
                TextField("Writer", text: $writer)
                TextField("Artist", text: $artist)
                TextField("Story Arc", text: $arc)
                if writeBackEnabled && comic.fileExtension == "cbz" {
                    Toggle("Also save into the file's ComicInfo.xml", isOn: $writeToFile)
                }
            }
            Text("Your changes are kept when the library is rescanned.").font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(title.trimmed.isEmpty || series.trimmed.isEmpty)
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            title = comic.title; series = comic.series; publisher = comic.publisher; issue = comic.issueNumber ?? ""
            year = comic.year.map(String.init) ?? ""; writer = comic.writer ?? ""; artist = comic.penciller ?? ""; arc = comic.storyArc ?? ""
        }
    }

    private func save() {
        let e = Database.MetadataEdit(title: title.trimmed, series: series.trimmed, publisher: publisher.trimmed.isEmpty ? "Unknown" : publisher.trimmed,
                                      issueNumber: issue.trimmed.nilIfEmpty, year: Int(year.trimmed), writer: writer.trimmed.nilIfEmpty,
                                      penciller: artist.trimmed.nilIfEmpty, storyArc: arc.trimmed.nilIfEmpty)
        let url = comic.url, id = comic.id, write = writeToFile
        model.perform("Saved") { db in
            try await db.updateMetadata(e, comicID: id)
            if write {
                try ComicInfo.write(["Title": e.title, "Series": e.series, "Publisher": e.publisher, "Number": e.issueNumber,
                                     "Year": e.year.map(String.init), "Writer": e.writer, "Penciller": e.penciller, "StoryArc": e.storyArc], to: url)
            }
        }
        dismiss()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Picks any page of the comic as its cover.
struct CoverPickerSheet: View {
    let comic: Comic
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renderer: PageRenderer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a Cover Page").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                if let renderer {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 16) {
                        ForEach(0..<renderer.pageCount, id: \.self) { page in
                            PageThumb(renderer: renderer, page: page)
                                .onTapGesture { choose(page, renderer) }
                        }
                    }
                    .padding(18)
                } else {
                    ProgressView().padding(60)
                }
            }
        }
        .frame(width: 640, height: 560)
        .task {
            let path = comic.filePath
            if let doc = try? await Task.detached(operation: { try Documents.open(path) }).value { renderer = PageRenderer(document: doc) }
        }
        .onDisappear { if let renderer { Task { await renderer.close() } } }
    }

    private func choose(_ page: Int, _ renderer: PageRenderer) {
        Task {
            if let image = await renderer.image(page, maxPixel: CoverStore.coverPixels) {
                await CoverStore.shared.setCover(image, for: comic.id)
                model.libraryDidChange()
            }
            dismiss()
        }
    }
}

struct PageThumb: View {
    let renderer: PageRenderer
    let page: Int
    var width: CGFloat = 110
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Theme.raised
                if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("\(page + 1)").font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .task(id: page) { image = await renderer.thumbnail(page) }
    }
}
