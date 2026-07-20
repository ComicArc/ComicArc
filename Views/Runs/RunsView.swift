extension Notification.Name {
    static let runDeleted = Notification.Name("runDeleted")
}

import SwiftUI

// MARK: - Runs list (left panel)

struct RunsListView: View {
    @Binding var selectedRun: Run?
    @State private var runs:          [Run]   = []
    @State private var isLoading      = true
    @State private var showingCreate  = false
    @State private var newRunTitle    = ""
    @State private var newRunDesc     = ""
    @State private var draggedRunId:  Int64?
    @State private var dropTargetRunId: Int64?

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("RUNS")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .kerning(1)
                Spacer()
                Button { showingCreate = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.brandGold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runs.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 42)).foregroundStyle(.quaternary)
                    Text("No Reading Orders Yet").font(.headline).foregroundStyle(.secondary)
                    Text("Group comics into an ordered reading path to track multi-series arcs.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Create Reading Order") { showingCreate = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(runs) { run in
                            let isTarget = dropTargetRunId == run.id && draggedRunId != run.id
                            RunListCard(
                                run: run,
                                isSelected: selectedRun?.id == run.id,
                                onCoverChanged: { Task { await loadRuns() } }
                            ) { selectedRun = run }
                            .background(isTarget ? Design.brandGold.opacity(0.12) : Color.clear)
                            .onDrag {
                                draggedRunId = run.id
                                return NSItemProvider(object: NSString(string: String(run.id)))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetRunId = active ? run.id : nil }
                                    )) { _, _ in
                                guard let fromId = draggedRunId,
                                      let fromIdx = runs.firstIndex(where: { $0.id == fromId }),
                                      let toIdx = runs.firstIndex(where: { $0.id == run.id }) else { return false }
                                var list = runs
                                let moved = list.remove(at: fromIdx)
                                list.insert(moved, at: toIdx)
                                runs = list
                                DatabaseManager.shared.reorderRuns(orderedIds: list.map(\.id))
                                draggedRunId = nil; dropTargetRunId = nil
                                return true
                            }
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task { await loadRuns() }
        .onReceive(NotificationCenter.default.publisher(for: .runDeleted)) { _ in
            Task { await loadRuns()
                if let sel = selectedRun, !runs.contains(sel) { selectedRun = nil }
            }
        }
        .sheet(isPresented: $showingCreate) { createSheet }
    }

    private var createSheet: some View {
        VStack(spacing: 20) {
            Text("New Run").font(.title2.bold())
            TextField("Title", text: $newRunTitle).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $newRunDesc).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingCreate = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Create") { createRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newRunTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
    }

    private func createRun() {
        let title = newRunTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        LibraryViewModel.shared.createRun(title: title, description: newRunDesc)
        newRunTitle = ""; newRunDesc = ""
        showingCreate = false
        Task { await loadRuns() }
    }

    private func loadRuns() async {
        isLoading = true
        let r = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.allRuns()
        }.value
        runs = r; isLoading = false
    }
}

// MARK: - Run list card

struct RunListCard: View {
    let run:        Run
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
                    Text(run.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !run.description.isEmpty {
                        Text(run.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let r = run.rating, r > 0 {
                            HStack(spacing: 1) {
                                ForEach(1...r, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Design.brandGold)
                                }
                            }
                        }
                        if run.comicCount > 0 {
                            Text("\(run.readCount)/\(run.comicCount) read")
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
        .accessibilityLabel(run.description.isEmpty ? run.title : "\(run.title), \(run.description)")
        .accessibilityValue(run.comicCount > 0 ? "\(run.readCount) of \(run.comicCount) read" : "Empty")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Choose Existing Cover…") { showCoverPicker = true }
            Button("Custom Image…") { pickCoverImage() }
            if run.coverImagePath != nil {
                Button("Remove Custom Cover") {
                    LibraryViewModel.shared.clearRunCover(runId: run.id)
                    onCoverChanged()
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(title: "Choose Cover for \(run.title)") { comic in
                LibraryViewModel.shared.setRunCover(runId: run.id, usingCoverOf: comic, onDone: onCoverChanged)
            }
        }
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let path = run.coverImagePath, let img = PlatformImage.fromFile(path) {
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Design.surfaceBg
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 14)).foregroundStyle(.tertiary)
            }
        }
    }

    private func pickCoverImage() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(run.title)",
            prompt: "Set Cover"
        ) { urls in
            if let url = urls.first {
                LibraryViewModel.shared.setRunCover(runId: run.id, imageURL: url)
                onCoverChanged()
            }
        }
    }
}

// MARK: - Run detail (right panel)

struct RunDetailView: View {
    let run:      Run
    let onDelete: () -> Void

    @State private var currentRun:      Run
    @State private var items:           [RunItem] = []
    @State private var itemsLoading     = true
    @State private var showingAddComics = false
    @State private var runRating:       Int       = 0
    @State private var showReviewSheet  = false
    @State private var reviewText:      String    = ""
    @State private var showEditSheet    = false

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
            // Page header
            runPageHeader
            Rectangle().fill(Design.borderColor).frame(height: 1)

            // Section title: "READING ORDER [count]"
            HStack(spacing: 8) {
                Text("READING ORDER")
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

            // Items list
            if itemsLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("No Comics Yet").font(.headline).foregroundStyle(.secondary)
                    Text("Add comics to build your reading order.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Button("Add Comics") { showingAddComics = true }
                        .buttonStyle(.borderedProminent).tint(Design.brandGold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showingAddComics) {
            AddComicsToRunView(run: run) { loadItems() }
        }
        .sheet(isPresented: $showReviewSheet) {
            reviewSheet
        }
        .sheet(isPresented: $showEditSheet) {
            EditRunView(run: $currentRun)
        }
    }

    // MARK: - Page header (matches Python run_detail.html .page-header)

    private var runPageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left: title + description + buy link
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
                    Link("Find / Buy This Run", destination: url)
                        .font(.caption)
                        .foregroundStyle(Design.brandGold.opacity(0.8))
                }
            }

            Spacer(minLength: 10)

            // Right: star rating + action buttons
            VStack(alignment: .trailing, spacing: 10) {
                StarRating(rating: runRating) { star in
                    let newVal = star == runRating ? 0 : star
                    runRating  = newVal
                    LibraryViewModel.shared.setRunRating(run.id,
                                                        rating: newVal,
                                                        review: reviewText.isEmpty ? nil : reviewText)
                }

                HStack(spacing: 6) {
                    if let comic = firstUnfinished {
                        Button {
                            LibraryViewModel.shared.openReader(comic)
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

                    Button(role: .destructive) {
                        LibraryViewModel.shared.deleteRunWithUndo(run)
                        onDelete()
                    } label: {
                        Text("Delete Run")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Design.navBackground)
    }

    // MARK: - Review sheet

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rate & Review: \(run.title)")
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

            if let link = run.buyLink {
                HStack {
                    Text("Buy Link:").foregroundStyle(.secondary).font(.caption)
                    Text(link).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                Button("Cancel") { showReviewSheet = false }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    LibraryViewModel.shared.setRunRating(run.id,
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

    // MARK: - Helpers

    private func reorder(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        LibraryViewModel.shared.reorderRun(runId: run.id, orderedIds: items.map(\.id))
    }

    private func loadItems() {
        let runId = run.id
        itemsLoading = true
        Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.runItems(runId: runId)
            await MainActor.run { items = rows; itemsLoading = false }
        }
    }
}

// MARK: - Run item row

struct RunItemRow: View {
    let item:     RunItem
    let runId:    Int64
    let onChange: () -> Void

    @State private var showNotes    = false
    @State private var notesText:   String    = ""
    @State private var thumbnail:   PlatformImage?  = nil

    var body: some View {
        HStack(spacing: 12) {
            // Position badge
            Text("#\(item.position + 1)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)

            statusIcon

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

            // Info column
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(item.comic.title)
                    .font(.body)
                    .lineLimit(1)

                // Publisher + series
                HStack(spacing: 6) {
                    PublisherBadge(publisher: item.comic.publisher)
                    if item.comic.series != "General" {
                        Text(item.comic.series)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Progress bar
                if item.comic.isStarted && !item.comic.isFinished {
                    ProgressView(value: item.comic.progressPercent)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                }

                // Notes preview
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Notes button
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

            // Drag handle
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
            Button("Remove from Reading Order", role: .destructive) {
                LibraryViewModel.shared.removeFromRunWithUndo(runId: runId, items: [item], onRestored: onChange)
                onChange()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("#\(item.position + 1) \(item.comic.title)")
        .accessibilityValue(item.comic.isFinished ? "Read" : item.comic.isStarted ? "In progress" : "Unread")
        .accessibilityHint("Double-tap to open")
        .accessibilityAddTraits(.isButton)
        // Collapsing the row into one element (above) hides the visible Notes button and
        // context-menu actions from VoiceOver entirely unless re-exposed here.
        .accessibilityAction(named: item.notes.isEmpty ? "Add Notes" : "Edit Notes") {
            notesText = item.notes
            showNotes = true
        }
        .accessibilityAction(named: item.comic.isFinished ? "Mark as Unread" : "Mark as Read") {
            if item.comic.isFinished { LibraryViewModel.shared.markUnread(item.comic) }
            else { LibraryViewModel.shared.markRead(item.comic) }
            onChange()
        }
        .accessibilityAction(named: "Remove from Reading Order") {
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

// MARK: - Edit Run sheet

struct EditRunView: View {
    @Binding var run: Run
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var description: String
    @State private var buyLink:     String

    init(run: Binding<Run>) {
        self._run    = run
        _title       = State(initialValue: run.wrappedValue.title)
        _description = State(initialValue: run.wrappedValue.description)
        _buyLink     = State(initialValue: run.wrappedValue.buyLink ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Run")
                .font(.title2.bold())
                .padding(24)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description)
                    TextField("Buy / Info Link (URL)", text: $buyLink)
                        .autocorrectionDisabled()
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
        let l = buyLink.trimmingCharacters(in: .whitespaces)
        LibraryViewModel.shared.updateRun(id: run.id, title: t, description: d, buyLink: l.isEmpty ? nil : l)
        run.title       = t
        run.description = d
        run.buyLink     = l.isEmpty ? nil : l
        dismiss()
    }
}

// MARK: - Add Comics to Run

struct AddComicsToRunView: View {
    let run:   Run
    let onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allComics:    [(comic: Comic, searchKey: String)] = []
    @State private var alreadyInRun: Set<Int64>  = []
    @State private var selected      = Set<Int64>()
    @State private var search        = ""

    private var filtered: [Comic] {
        let candidates = allComics.filter { !alreadyInRun.contains($0.comic.id) }
        guard !search.isEmpty else { return candidates.map(\.comic) }
        let q = search.lowercased()
        return candidates.filter { $0.searchKey.contains(q) }.map(\.comic)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to \"\(run.title)\"").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selected.isEmpty ? "" : "(\(selected.count))")") {
                    LibraryViewModel.shared.addToRun(runId: run.id, comicIds: Array(selected))
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
            let runId = run.id
            let (comics, inRun) = await Task.detached(priority: .userInitiated) {
                (DatabaseManager.shared.allComics(), DatabaseManager.shared.comicIdsInRun(runId: runId))
            }.value
            allComics    = comics.map { (comic: $0, searchKey: "\($0.title) \($0.series)".lowercased()) }
            alreadyInRun = inRun
        }
    }
}

// MARK: - Cross-platform wrapper used by iPad content column

struct RunsView: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        NavigationStack {
            RunsListView(selectedRun: $vm.selectedRun)
                .navigationTitle("Reading Orders")
        }
    }
}
