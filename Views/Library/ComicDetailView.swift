import SwiftUI

struct ComicDetailView: View {
    let comic: Comic
    @State private var current:         Comic
    @State private var tags:            [Tag]    = []
    @State private var newTagText:      String   = ""
    @State private var thumbnail:       PlatformImage? = nil
    @State private var showingEdit:     Bool     = false
    @State private var reviewDraft:     String   = ""
    @State private var appearsInRuns:   [Run]    = []
    @State private var missingIssues:   [String] = []
    @State private var allShelves:      [Shelf]  = []
    @State private var comicShelfIds:   [Int64]  = []

    init(comic: Comic) {
        self.comic   = comic
        _current     = State(initialValue: comic)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                metaGrid
                Divider()
                tagsSection
                Divider()
                shelvesSection
                Divider()
                reviewSection
                if !missingIssues.isEmpty {
                    Divider()
                    gapWarningSection
                }
                if !appearsInRuns.isEmpty {
                    Divider()
                    runsSection
                }
                if let notes = current.notes, !notes.isEmpty {
                    Divider()
                    notesSection(notes)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 280)
        .task { loadData() }
        .onChange(of: comic) { _, c in
            current = c; tags = []; thumbnail = nil; appearsInRuns = []; reviewDraft = ""
            loadData()
        }
        .sheet(isPresented: $showingEdit, onDismiss: { loadData() }) {
            EditComicView(comic: $current)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            coverThumbnail

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(current.title).font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { showingEdit = true } label: {
                        Image(systemName: "pencil.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit metadata")
                }

                Text("\(current.publisher) · \(current.series)")
                    .foregroundStyle(.secondary).font(.subheadline)

                if let issue = current.issueNumber {
                    Text("Issue #\(issue)").foregroundStyle(.secondary).font(.caption)
                }

                ratingAndActions

                if current.pageCount > 0 { progressBar }

                HStack(spacing: 8) {
                    Button("Open in Reader") { LibraryViewModel.shared.openReader(current) }
                        .buttonStyle(.borderedProminent).controlSize(.small)

                    Button {
                        if current.isFinished {
                            current.progress = 0
                            LibraryViewModel.shared.markUnread(current)
                        } else {
                            let p = max(0, current.pageCount - 1)
                            current.progress = p
                            LibraryViewModel.shared.markRead(current)
                        }
                    } label: {
                        Label(current.isFinished ? "Mark Unread" : "Mark Read",
                              systemImage: current.isFinished ? "arrow.counterclockwise" : "checkmark")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let img = thumbnail {
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 110, height: 165).comicCardStyle()
        } else {
            RoundedRectangle(cornerRadius: Design.cardCorner)
                .fill(Color(.secondarySystemFill))
                .frame(width: 110, height: 165)
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
        }
    }

    private var ratingAndActions: some View {
        HStack(spacing: 10) {
            StarRating(rating: current.rating) { star in
                let newRating = star == current.rating ? 0 : star
                LibraryViewModel.shared.setRating(current, rating: newRating)
                current.rating = newRating
            }

            Button {
                current.isFavorite.toggle()
                LibraryViewModel.shared.toggleFavorite(current)
            } label: {
                Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(current.isFavorite ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(current.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Button {
                current.inReadingList.toggle()
                LibraryViewModel.shared.toggleReadingList(current)
            } label: {
                Image(systemName: current.inReadingList ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(current.inReadingList ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(current.inReadingList ? "Remove from Reading List" : "Add to Reading List")
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: current.progressPercent).progressViewStyle(.linear)
            Text(progressLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var progressLabel: String {
        if current.isFinished   { return "Finished" }
        if current.progress > 0 { return "Page \(current.progress + 1) of \(current.pageCount)" }
        return "Unread · \(current.pageCount) pages"
    }

    // MARK: - Meta grid

    private var metaGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  alignment: .leading, spacing: 12) {
            if let w = current.writer      { metaCell("Writer",    w) }
            if let p = current.penciller   { metaCell("Penciller", p) }
            if let y = current.year        { metaCell("Year",      "\(y)") }
            if let s = current.storyArc    { metaCell("Story Arc", s) }
            if let l = current.languageIso { metaCell("Language",  l.uppercased()) }
            metaCell("Pages", "\(current.pageCount)")
            metaCell("Added", shortDate(current.addedAt))
        }
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            if !tags.isEmpty {
                FlowLayout(items: tags, spacing: 6) { tag in
                    tagChip(tag)
                }
            }
            HStack(spacing: 6) {
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag() }
                Button("Add") { addTag() }
                    .controlSize(.small)
                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tagChip(_ tag: Tag) -> some View {
        HStack(spacing: 4) {
            Text(tag.name).font(.caption)
            Button { removeTag(tag) } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Shelves

    private var shelvesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shelves").font(.headline)
            FlowLayout(items: allShelves, spacing: 6) { shelf in
                ShelfChip(
                    shelf: shelf,
                    isOn: comicShelfIds.contains(shelf.id),
                    onToggle: {
                        if comicShelfIds.contains(shelf.id) {
                            LibraryViewModel.shared.removeFromShelf(comicId: current.id, shelfId: shelf.id)
                            comicShelfIds.removeAll { $0 == shelf.id }
                        } else {
                            LibraryViewModel.shared.addToShelf(comicId: current.id, shelfId: shelf.id)
                            comicShelfIds.append(shelf.id)
                        }
                    }
                )
            }
        }
    }

    // MARK: - Review

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Review").font(.headline)
            TextEditor(text: $reviewDraft)
                .frame(minHeight: 72, maxHeight: 120)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                #if os(macOS)
                .background(Color(NSColor.textBackgroundColor))
                .border(Color(NSColor.separatorColor), width: 0.5)
                #else
                .background(Color(.systemBackground))
                .border(Color(UIColor.separator), width: 0.5)
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Spacer()
                Button("Save Review") {
                    let text = reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    LibraryViewModel.shared.setReview(current, review: text.isEmpty ? nil : text)
                    current.review = text.isEmpty ? nil : text
                }
                .controlSize(.small)
                .disabled(reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (current.review ?? ""))
            }
        }
    }

    // MARK: - Series gap detection

    private var gapWarningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Missing Issues Detected").font(.headline).foregroundStyle(.orange)
            }
            Text("Your library is missing these issue numbers from **\(current.series)**:")
                .font(.caption).foregroundStyle(.secondary)
            Text(missingIssues.prefix(12).joined(separator: ", ") + (missingIssues.count > 12 ? " …" : ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Appears in Runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appears in Runs").font(.headline)
            ForEach(appearsInRuns) { run in
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(Design.brandBlue)
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(.subheadline)
                        if !run.description.isEmpty {
                            Text(run.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let r = run.rating, r > 0 {
                        HStack(spacing: 1) {
                            ForEach(1...r, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.system(size: 7))
                                    .foregroundStyle(Design.brandGold)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Notes

    private func notesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Data loading

    private func loadData() {
        let comicId = current.id
        let series  = current.series
        let pub     = current.publisher
        reviewDraft = current.review ?? ""
        ThumbnailCache.shared.thumbnail(for: current) { thumbnail = $0 }
        Task.detached(priority: .userInitiated) {
            let t   = DatabaseManager.shared.tags(for: comicId)
            let r   = DatabaseManager.shared.runsContaining(comicId: comicId)
            let mi  = DatabaseManager.shared.missingIssueNumbers(series: series, publisher: pub)
            let sh  = DatabaseManager.shared.allShelves()
            let csh = DatabaseManager.shared.shelvesForComic(comicId: comicId)
            await MainActor.run {
                tags = t; appearsInRuns = r; missingIssues = mi; allShelves = sh; comicShelfIds = csh
            }
        }
    }

    private func addTag() {
        let name = newTagText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        LibraryViewModel.shared.addTag(name: name, to: current)
        newTagText = ""
        let comicId = current.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
        LibraryViewModel.shared.reload()
    }

    private func removeTag(_ tag: Tag) {
        LibraryViewModel.shared.removeTag(tagId: tag.id, from: current)
        let comicId = current.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
        LibraryViewModel.shared.reload()
    }

    private static let inputDateFormatters: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"].map {
        let f = DateFormatter(); f.dateFormat = $0; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static let outputDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f
    }()

    private func shortDate(_ s: String) -> String {
        for f in Self.inputDateFormatters {
            if let d = f.date(from: s) { return Self.outputDateFormatter.string(from: d) }
        }
        return String(s.prefix(10))
    }
}

// MARK: - Edit comic sheet

struct EditComicView: View {
    @Binding var comic: Comic
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var series:      String
    @State private var publisher:   String
    @State private var issueNumber: String
    @State private var notes:       String

    init(comic: Binding<Comic>) {
        self._comic   = comic
        _title        = State(initialValue: comic.wrappedValue.title)
        _series       = State(initialValue: comic.wrappedValue.series)
        _publisher    = State(initialValue: comic.wrappedValue.publisher)
        _issueNumber  = State(initialValue: comic.wrappedValue.issueNumber ?? "")
        _notes        = State(initialValue: comic.wrappedValue.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Comic")
                .font(.title2.bold())
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Series", text: $series)
                    TextField("Publisher", text: $publisher)
                    TextField("Issue #", text: $issueNumber)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 440)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let s = series.trimmingCharacters(in: .whitespaces).isEmpty ? "General" : series.trimmingCharacters(in: .whitespaces)
        let p = publisher.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown" : publisher.trimmingCharacters(in: .whitespaces)
        let i = issueNumber.trimmingCharacters(in: .whitespaces)
        let n = notes.trimmingCharacters(in: .whitespaces)

        LibraryViewModel.shared.updateMeta(comicId: comic.id, fields: [
            ("title",        t),
            ("series",       s),
            ("publisher",    p),
            ("issue_number", i.isEmpty ? nil : i),
            ("notes",        n.isEmpty ? nil : n)
        ])
        comic.title       = t
        comic.series      = s
        comic.publisher   = p
        comic.issueNumber = i.isEmpty ? nil : i
        comic.notes       = n.isEmpty ? nil : n

        LibraryViewModel.shared.reload()
        dismiss()
    }
}

// MARK: - Shelf chip

struct ShelfChip: View {
    let shelf:    Shelf
    let isOn:     Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9)) }
                Text(shelf.name).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? Design.brandBlue.opacity(0.25) : Design.surfaceBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isOn ? Design.brandBlue.opacity(0.5) : Design.borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout

struct FlowLayout<T: Identifiable, Content: View>: View {
    let items:   [T]
    let spacing: CGFloat
    let content: (T) -> Content

    var body: some View {
        GeometryReader { geo in
            let rows = computeRows(width: geo.size.width)
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { item in content(item) }
                    }
                }
            }
        }
        .frame(minHeight: 28)
    }

    private func computeRows(width: CGFloat) -> [[T]] {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        #else
        let font = UIFont.systemFont(ofSize: UIFont.smallSystemFontSize)
        #endif
        var rows: [[T]] = [[]]
        var rowWidth: CGFloat = 0

        for item in items {
            let name: String
            if let t = item as? Tag { name = t.name }
            else if let s = item as? Shelf { name = s.name }
            else { name = "" }
            let textW  = (name as NSString).size(withAttributes: [.font: font]).width
            let itemW  = textW + 36 + spacing  // padding (8+8) + close button (~12) + gap
            if rowWidth + itemW > width && !rows.last!.isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(item)
            rowWidth += itemW
        }
        return rows.filter { !$0.isEmpty }
    }
}
