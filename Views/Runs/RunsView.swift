extension Notification.Name {
    static let runDeleted = Notification.Name("runDeleted")
    static let runUpdated = Notification.Name("runUpdated")
}

import SwiftUI

private func runListConfig(_ vm: LibraryViewModel) -> CollectionListConfig<Run> {
    CollectionListConfig(
        noun: "Reading Path", nounPlural: "Reading Paths",
        emptyIcon: "list.bullet.rectangle",
        emptyMessage: "Group comics into an ordered reading path to track multi-series arcs.",
        cardIcon: "list.bullet.rectangle.portrait",
        subtitle: { $0.comicCount > 0 ? "\($0.readCount)/\($0.comicCount) read" : "Empty" },
        deleteWithUndo: nil, // Runs are only deletable from their detail screen, not the list.
        fetch: { await Task.detached(priority: .userInitiated) { DatabaseManager.shared.allRuns() }.value },
        reorder: { vm.reorderRuns(orderedIds: $0) },
        create: { title, desc in vm.createRun(title: title, description: desc) },
        setCoverFromComic: { run, comic, done in vm.setRunCover(runId: run.id, usingCoverOf: comic, onDone: done) },
        setCoverFromURL: { run, url in _ = vm.setRunCover(runId: run.id, imageURL: url) },
        clearCover: { vm.clearRunCover(runId: $0.id) }
    )
}

struct RunsListView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Binding var selectedRun: Run?
    @State private var reloadToken = UUID()

    var body: some View {
        CollectionListView(config: runListConfig(vm), selected: $selectedRun,
                            onListChanged: { vm.refreshRuns() }, reloadToken: reloadToken)
            .onReceive(NotificationCenter.default.publisher(for: .runDeleted)) { _ in
                vm.refreshRuns(); reloadToken = UUID()
            }
            .onReceive(NotificationCenter.default.publisher(for: .runUpdated)) { _ in
                // Renaming/re-rating a Run in its detail view only updates that view's own local
                // @State copy and the DB -- without this, this list's row keeps showing the
                // pre-edit title/rating until an unrelated reload happens.
                reloadToken = UUID()
            }
    }
}

struct RunDetailView: View {
    let run:      Run
    let onDelete: () -> Void

    @Environment(\.fileService) private var fileService
    @State private var currentRun:      Run
    @State private var items:           [RunItem] = []
    @State private var itemsLoading     = true
    @State private var showingAddComics = false
    @State private var runRating:       Int       = 0
    @State private var showReviewSheet  = false
    @State private var reviewText:      String    = ""
    @State private var showEditSheet    = false
    @State private var exportErrorMessage: String?
    @State private var shareCardURL:    URL?

    init(run: Run, onDelete: @escaping () -> Void) {
        self.run      = run
        self.onDelete = onDelete
        _currentRun   = State(initialValue: run)
    }

    private var firstUnfinished: Comic? {
        items.first { !$0.isFinished }?.comic ?? items.first?.comic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            runPageHeader
            Rectangle().fill(Design.borderColor).frame(height: 1)

            HStack(spacing: 8) {
                SignageLabel(text: "Reading Path", size: 13, kerning: 1.5)
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
                    message: "Add comics to build your reading path."
                ) {
                    Button("Add Comics") { showingAddComics = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
            } else {
                List {
                    ForEach(items) { item in
                        RunItemRow(item: item, runId: run.id, onChange: loadItems)
                    }
                    .onMove { from, to in reorder(from: from, to: to) }
                    .onDelete { indices in
                        let removed = indices.map { items[$0] }
                        LibraryViewModel.shared.removeFromRunWithUndo(runId: run.id, items: removed, onRestored: loadItems)
                        loadItems()
                    }
                }
                .listStyle(.inset)
            }
        }
        .ambientBackground()
        .task {
            loadItems()
            runRating  = run.rating ?? 0
            reviewText = run.review ?? ""
        }
        .onChange(of: run) { _, r in
            currentRun = r
            runRating  = r.rating ?? 0
            reviewText = r.review ?? ""
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in
            // The reader is a ZStack overlay, not a navigation push, so this view is never
            // told a comic in it was just read -- refresh progress/"first unfinished" (Resume
            // target) so they don't point at the issue the user just finished.
            loadItems()
        }
        .sheet(isPresented: $showingAddComics) {
            AddComicsToCollectionView(
                title: run.title,
                alreadyInCollection: { DatabaseManager.shared.comicIdsInRun(runId: run.id) },
                onAdd: { ids in
                    LibraryViewModel.shared.addToRun(runId: run.id, comicIds: ids)
                    loadItems()
                }
            )
        }
        .sheet(isPresented: $showReviewSheet) {
            reviewSheet
        }
        .sheet(isPresented: $showEditSheet) {
            EditCollectionView(noun: "Reading Path", item: $currentRun,
                                buyLink: Binding(get: { currentRun.buyLink ?? "" }, set: { currentRun.buyLink = $0 })) { t, d, link in
                LibraryViewModel.shared.updateRun(id: currentRun.id, title: t, description: d, buyLink: link)
                currentRun.title = t; currentRun.description = d
            }
        }
        .errorAlert("Export Failed", message: $exportErrorMessage)
    }

    private var runPageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(currentRun.title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(0.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !currentRun.description.isEmpty {
                    Text(currentRun.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let link = currentRun.buyLink, !link.isEmpty,
                   let url = URL(string: link) {
                    Link("Find / Buy This Reading Path", destination: url)
                        .font(.caption)
                        .foregroundStyle(Design.brandGold.opacity(0.8))
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 10) {
                StarRating(rating: runRating) { star in
                    let newVal = star == runRating ? 0 : star
                    runRating  = newVal
                    LibraryViewModel.shared.setRunRating(run.id,
                                                        rating: newVal,
                                                        review: reviewText.isEmpty ? nil : reviewText)
                    rebuildShareCard()
                }

                HStack(spacing: 6) {
                    if let comic = firstUnfinished {
                        Button {
                            LibraryViewModel.shared.openReader(comic, runId: run.id)
                        } label: {
                            Label(items.contains { $0.comic.isStarted } ? "Resume" : "Start Reading",
                                  systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Design.brandGold)
                        .foregroundStyle(.black)
                    }

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
                            filename: "\(currentRun.title).csv"
                        ) { exportErrorMessage = $0 }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Export as CSV")

                    if let shareCardURL {
                        ShareLink(item: shareCardURL, preview: SharePreview(currentRun.title)) {
                            Image(systemName: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Share as Image")
                    }

                    Button(role: .destructive) {
                        LibraryViewModel.shared.deleteRunWithUndo(currentRun)
                        onDelete()
                    } label: {
                        Text("Delete Reading Path")
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
            // Reads `currentRun` (the synced @State copy), not the immutable `run` init
            // parameter -- otherwise this sheet keeps showing the pre-edit title/buy link after
            // EditCollectionView updates currentRun, since `run` itself never changes for this
            // view's lifetime.
            Text("Rate & Review: \(currentRun.title)")
                .font(.title2.bold())

            Text("Rating").font(.headline)
            StarRating(rating: runRating) { star in
                runRating = star == runRating ? 0 : star
            }
            .scaleEffect(1.4, anchor: .leading)

            Text("Review").font(.headline)
            TextEditor(text: $reviewText)
                .frame(minHeight: 120)
                .border(Design.borderColor)

            if let link = currentRun.buyLink {
                HStack {
                    Text("Buy Link:").foregroundStyle(.secondary).font(.caption)
                    Text(link).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                Button("Cancel") { showReviewSheet = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    LibraryViewModel.shared.setRunRating(currentRun.id,
                                                        rating: runRating,
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
        LibraryViewModel.shared.reorderRun(runId: run.id, orderedIds: items.map(\.id))
    }

    private func loadItems() {
        let runId = run.id
        itemsLoading = true
        Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.runItems(runId: runId)
            await MainActor.run { items = rows; itemsLoading = false; rebuildShareCard() }
        }
    }

    private func rebuildShareCard() {
        let card = ShareCardView(
            title: currentRun.title,
            subtitle: "Reading Path • \(items.count) issue\(items.count == 1 ? "" : "s")",
            covers: ShareCardCovers.fromCache(items.map(\.comic)),
            stats: [
                ("Issues", "\(items.count)"),
                ("Rating", runRating > 0 ? String(repeating: "★", count: runRating) : "—")
            ]
        )
        shareCardURL = ShareCardRenderer.renderToTempPNG(card, filename: "ReadingPath-\(currentRun.id).png")
    }
}

struct RunItemRow: View {
    let item:     RunItem
    let runId:    Int64
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

            statusIcon

            Group {
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
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
            Button("Open") { LibraryViewModel.shared.openReader(item.comic, runId: runId) }
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
            Button("Remove from Reading Path", role: .destructive) {
                LibraryViewModel.shared.removeFromRunWithUndo(runId: runId, items: [item], onRestored: onChange)
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
        .accessibilityAction(named: "Remove from Reading Path") {
            LibraryViewModel.shared.removeFromRunWithUndo(runId: runId, items: [item], onRestored: onChange)
            onChange()
        }
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.comic) { thumbnail = $0 } }
    }

    private var statusIcon: some View {
        Group {
            if item.comic.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if item.comic.isStarted {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(Design.brandBlue)
            } else {
                Image(systemName: "circle").foregroundStyle(.quaternary)
            }
        }
        .font(.title3)
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
                    LibraryViewModel.shared.setRunItemNotes(item.id, notes: notesText)
                    onChange()
                    showNotes = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

struct RunsView: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        NavigationStack {
            RunsListView(selectedRun: $vm.selectedRun)
                .navigationTitle("Reading Paths")
        }
    }
}
