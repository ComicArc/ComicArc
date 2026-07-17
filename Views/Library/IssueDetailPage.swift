import SwiftUI

struct IssueDetailPage: View {
    let comic:  Comic
    let onBack: () -> Void

    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService

    @State private var current:        Comic
    @State private var tags:           [Tag]    = []
    @State private var newTagText:     String   = ""
    @State private var thumbnail:      PlatformImage? = nil
    @State private var showingEdit:    Bool     = false
    @State private var reviewDraft:    String   = ""
    @State private var appearsInRuns:  [Run]    = []
    @State private var missingIssues:  [String] = []
    @State private var allShelves:     [Shelf]  = []
    @State private var comicShelfIds:  [Int64]  = []

    init(comic: Comic, onBack: @escaping () -> Void) {
        self.comic  = comic
        self.onBack = onBack
        _current    = State(initialValue: comic)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Design.borderColor).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    mainColumns
                    supplementarySection
                }
            }
        }
        .background(Design.appBackground)
        .onKeyPress(.escape) {
            guard !showingEdit else { return .ignored }
            withAnimation(.easeInOut(duration: 0.2)) { onBack() }
            return .handled
        }
        .task { loadData() }
        .onChange(of: comic) { _, c in
            current = c
            thumbnail = nil
            loadData()
        }
        .sheet(isPresented: $showingEdit, onDismiss: { loadData() }) {
            EditComicView(comic: $current)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { onBack() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Library")
                }
                .foregroundStyle(Design.brandBlue)
            }
            .buttonStyle(.plain)
            .help("Back to library (Escape)")

            Spacer()

            Text(current.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Button { showingEdit = true } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                if current.isFinished {
                    current.progress = 0
                    vm.markUnread(current)
                } else {
                    current.progress = max(0, current.pageCount - 1)
                    vm.markRead(current)
                }
            } label: {
                Label(current.isFinished ? "Mark Unread" : "Mark Read",
                      systemImage: current.isFinished ? "arrow.counterclockwise" : "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button { vm.openReader(current) } label: {
                Label("Open in Reader", systemImage: "book.fill")
            }
            .goldButton()
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Design.navBackground)
    }

    // MARK: - Main two-column layout

    private var mainColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            coverColumn
                .frame(width: 340)

            Rectangle().fill(Design.borderColor).frame(width: 1)

            detailColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cover column

    private var coverColumn: some View {
        VStack(spacing: 28) {
            // Cover image
            Group {
                if let img = thumbnail {
                    Image(platformImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Design.cardBg)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.secondary)
                                Text(current.series)
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                            }
                        }
                }
            }
            .frame(width: 256, height: 372)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Design.borderColor, lineWidth: 1)
            )

            // Progress
            if current.pageCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: current.progressPercent)
                        .progressViewStyle(.linear)
                        .tint(Design.brandGold)
                    HStack {
                        Text(progressLabel)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if current.pageCount > 0 {
                            Text("\(current.pageCount) pages")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 256)
            }

            // Star rating (large)
            StarRatingLarge(rating: current.rating) { star in
                let newR = star == current.rating ? 0 : star
                current.rating = newR
                vm.setRating(current, rating: newR)
            }

            // Action icons
            HStack(spacing: 28) {
                iconAction(
                    icon: current.isFavorite ? "heart.fill" : "heart",
                    color: current.isFavorite ? .red : .secondary,
                    label: current.isFavorite ? "Favorited" : "Favorite"
                ) {
                    current.isFavorite.toggle()
                    vm.toggleFavorite(current)
                }

                iconAction(
                    icon: current.inReadingList ? "bookmark.fill" : "bookmark",
                    color: current.inReadingList ? Design.brandBlue : .secondary,
                    label: current.inReadingList ? "In List" : "Reading List"
                ) {
                    current.inReadingList.toggle()
                    vm.toggleReadingList(current)
                }

                iconAction(
                    icon: "photo",
                    color: .secondary,
                    label: "Cover"
                ) { changeCover() }
            }
        }
        .padding(40)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.navBackground.opacity(0.4))
    }

    private func iconAction(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title block
            VStack(alignment: .leading, spacing: 10) {
                Text(current.title)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    PublisherBadge(publisher: current.publisher)
                    Text("·").foregroundStyle(.tertiary)
                    Text(current.series).foregroundStyle(.secondary).font(.subheadline)
                    if let issue = current.issueNumber {
                        Text("·").foregroundStyle(.tertiary)
                        Text("#\(issue)").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 32)

            divider

            // Metadata grid
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading, spacing: 12
            ) {
                if let w = current.writer      { metaCell("Writer",    w) }
                if let p = current.penciller   { metaCell("Penciller", p) }
                if let y = current.year        { metaCell("Year",      "\(y)") }
                metaCell("Pages", "\(current.pageCount)")
                if let s = current.storyArc    { metaCell("Arc",       s) }
                if let l = current.languageIso { metaCell("Language",  l.uppercased()) }
                metaCell("Added", String(current.addedAt.prefix(10)))
            }
            .padding(.horizontal, 40).padding(.vertical, 28)

            divider

            // Shelves
            sectionBlock("Shelves") {
                if allShelves.isEmpty {
                    Text("Loading…").font(.caption).foregroundStyle(.tertiary)
                } else {
                    FlowLayout(items: allShelves, spacing: 8) { shelf in
                        ShelfChip(
                            shelf: shelf,
                            isOn: comicShelfIds.contains(shelf.id),
                            onToggle: {
                                if comicShelfIds.contains(shelf.id) {
                                    vm.removeFromShelf(comicId: current.id, shelfId: shelf.id)
                                    comicShelfIds.removeAll { $0 == shelf.id }
                                } else {
                                    vm.addToShelf(comicId: current.id, shelfId: shelf.id)
                                    comicShelfIds.append(shelf.id)
                                }
                            }
                        )
                    }
                }
            }

            divider

            // Tags
            sectionBlock("Tags") {
                VStack(alignment: .leading, spacing: 10) {
                    if !tags.isEmpty {
                        FlowLayout(items: tags, spacing: 6) { tag in
                            tagChip(tag)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Add tag…", text: $newTagText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit { addTag() }
                        Button("Add") { addTag() }
                            .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            divider

            // Review
            sectionBlock("My Review") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $reviewDraft)
                        .frame(minHeight: 100, maxHeight: 180)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .background(Design.surfaceBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.borderColor))
                    HStack {
                        Spacer()
                        Button("Save Review") {
                            let text = reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            vm.setReview(current, review: text.isEmpty ? nil : text)
                            current.review = text.isEmpty ? nil : text
                        }
                        .disabled(reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (current.review ?? ""))
                    }
                }
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: - Supplementary (full-width below columns)

    @ViewBuilder
    private var supplementarySection: some View {
        if !missingIssues.isEmpty || !appearsInRuns.isEmpty || current.notes != nil {
            Rectangle().fill(Design.borderColor).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                if !missingIssues.isEmpty {
                    gapSection
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }

                if !appearsInRuns.isEmpty {
                    Rectangle().fill(Design.borderColor).frame(width: 1)
                    runsSection
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }

                if let notes = current.notes, !notes.isEmpty {
                    Rectangle().fill(Design.borderColor).frame(width: 1)
                    notesSection(notes)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }
            }
        }
    }

    private var gapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Missing Issues", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
            Text("Your library is missing these issue numbers from **\(current.series)**:")
                .font(.caption).foregroundStyle(.secondary)
            Text(missingIssues.prefix(16).joined(separator: ", ") + (missingIssues.count > 16 ? " …" : ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(16)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2)))
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appears in Runs")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            ForEach(appearsInRuns) { run in
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(Design.brandBlue).font(.subheadline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(.subheadline)
                        if !run.description.isEmpty {
                            Text(run.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func notesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle().fill(Design.borderColor).frame(height: 1)
            .padding(.horizontal, 40)
    }

    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .kerning(1.2)
                .textCase(.uppercase)
            content()
        }
        .padding(.horizontal, 40).padding(.vertical, 24)
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .kerning(0.5)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.borderColor))
    }

    private func tagChip(_ tag: Tag) -> some View {
        HStack(spacing: 4) {
            Text(tag.name).font(.caption)
            Button { removeTag(tag) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Remove tag \(tag.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Design.brandBlue.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Design.brandBlue.opacity(0.3)))
    }

    private var progressLabel: String {
        if current.isFinished   { return "Finished" }
        if current.progress > 0 { return "Page \(current.progress + 1) of \(current.pageCount)" }
        return "Unread"
    }

    // MARK: - Data

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
        vm.addTag(name: name, to: current)
        newTagText = ""
        let comicId = current.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
        vm.reload()
    }

    private func removeTag(_ tag: Tag) {
        vm.removeTag(tagId: tag.id, from: current)
        let comicId = current.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
        vm.reload()
    }

    private func changeCover() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(current.title)",
            prompt: "Set Cover"
        ) { urls in
            guard let url = urls.first else { return }
            ThumbnailCache.shared.setCustomCover(comicId: self.current.id, imageURL: url)
            self.thumbnail = nil
            ThumbnailCache.shared.thumbnail(for: self.current) { self.thumbnail = $0 }
        }
    }
}
