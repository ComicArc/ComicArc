import SwiftUI
import UniformTypeIdentifiers

struct IssueDetailPage: View {
    let comic:  Comic
    let onBack: () -> Void

    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var current:        Comic
    @State private var tags:           [Tag]    = []
    @State private var newTagText:     String   = ""
    @State private var newTagCategory: TagCategory = .custom
    @State private var thumbnail:      PlatformImage? = nil
    /// This comic's own cover-driven accent -- scoped to just this page's cover glow/wash, never
    /// written into `Design`/`AppTheme`'s global palette, which stays the stable "home base" look
    /// everywhere else in the app.
    @State private var accentColor:    Color? = nil
    @State private var showingEdit:    Bool     = false
    @State private var showMetadataInspector: Bool = false
    @State private var reviewDraft:    String   = ""
    @State private var appearsInRuns:  [Run]    = []
    @State private var appearsInTierLists: [TierList] = []
    @State private var missingIssues:  [String] = []
    @State private var showPagePicker: Bool     = false
    @State private var coverChangeError: String?
    // Same "Add to Reading Path"/"Add to Tier List" cross-link `ComicCard`'s context menu has --
    // previously this page could only ever *show* Reading Path/Tier List membership read-only
    // (`runsSection`/`tierListsSection` below), never add to either without leaving the page.
    @State private var showNewRunPrompt = false
    @State private var newRunTitle = ""
    @State private var showNewTierListPrompt = false
    @State private var newTierListTitle = ""
    // The one truly high-traffic piece of fixed-size display text on this page -- scales with
    // Dynamic Type instead of staying pinned at 32pt regardless of the user's text-size setting.
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 32

    // Named instead of repeating the literal at both the image and its placeholder-fallback
    // sibling below -- the image's own frame also fixes the exact bounds `heroGeometry` captures
    // for the reader morph, so it can't simply be dropped in favor of the outer one alone.
    private let coverSize = CGSize(width: 256, height: 384)

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
        .ambientBackground()
        .onKeyPress(.escape) {
            guard !showingEdit else { return .ignored }
            withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { onBack() }
            return .handled
        }
        .task { loadData() }
        .onChange(of: comic) { _, c in
            current = c
            thumbnail = nil
            accentColor = nil
            loadData()
        }
        .sheet(isPresented: $showingEdit, onDismiss: { loadData() }) {
            EditComicView(comic: $current)
        }
        .sheet(isPresented: $showMetadataInspector) {
            MetadataInspectorView(comicId: current.id)
        }
        .sheet(isPresented: $showPagePicker) {
            ComicPageCoverPicker(comic: current) { image in
                ThumbnailCache.shared.setCustomCover(comicId: current.id, image: image)
                thumbnail = nil
                ThumbnailCache.shared.thumbnail(for: current) { thumbnail = $0 }
            }
        }
        .alert("New Reading Path", isPresented: $showNewRunPrompt) {
            TextField("Name", text: $newRunTitle)
            Button("Create") {
                let trimmed = newRunTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let runId = vm.createRun(title: trimmed, description: "")
                vm.addToRun(runId: runId, comicIds: [current.id])
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Tier List", isPresented: $showNewTierListPrompt) {
            TextField("Name", text: $newTierListTitle)
            Button("Create") {
                let trimmed = newTierListTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let listId = vm.createTierList(title: trimmed, description: "")
                vm.addToTierList(tierListId: listId, comicIds: [current.id])
            }
            Button("Cancel", role: .cancel) {}
        }
        .errorAlert("Couldn't Set Cover", message: $coverChangeError)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { onBack() }
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
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)

            Spacer()

            Button { showMetadataInspector = true } label: {
                Label("Metadata Inspector", systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("See exactly why ComicArc placed this issue where it did")

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
            // Same ambient-glow technique already used on the cover image itself -- a soft echo of
            // this issue's own color under the primary action, not a restyle of the button (gold
            // stays gold, the app-wide "this is the primary action" signal).
            .shadow(color: (accentColor ?? .clear).opacity(0.45), radius: 14, x: 0, y: 4)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Design.navBackground)
    }

    private var mainColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            coverColumn
                .frame(width: 340)

            Rectangle().fill(Design.borderColor).frame(width: 1)

            detailColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        // The cover spotlight, column wash, and metadata-cell borders all default to a generic
        // warm tint before `accentColor` finishes loading asynchronously -- animate the swap to
        // the comic's real color so it reads as a smooth "warming up," not an instant flash.
        .animation(Design.motion(Design.easeStandard, reduce: reduceMotion), value: accentColor)
    }

    private var coverColumn: some View {
        VStack(spacing: 28) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img)
                        .comicCoverStyle()
                        .frame(width: coverSize.width, height: coverSize.height)
                        .heroGeometry(id: current.id, in: readerNamespace)
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
            .frame(width: coverSize.width, height: coverSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // An always-on spotlight pool behind the cover -- this page's whole job is "look at
            // the comic you own," so unlike the grid's hover-gated version, this one is lit from
            // the moment the page appears.
            .background(
                RadialGradient(
                    colors: [(accentColor ?? Design.warmSpotlightDefault).opacity(0.35),
                             (accentColor ?? Design.warmSpotlightDefault).opacity(0)],
                    center: .center, startRadius: 0, endRadius: max(coverSize.width, coverSize.height) * 0.85
                )
                .frame(width: coverSize.width * 1.8, height: coverSize.height * 1.8)
                .blendMode(.screen)
                .allowsHitTesting(false)
            )
            .shadow(color: (accentColor ?? .black).opacity(accentColor != nil ? 0.4 : 0.55), radius: 24, x: 0, y: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Design.borderColor, lineWidth: 1)
            )

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

            StarRatingLarge(rating: current.rating) { star in
                let newR = star == current.rating ? 0 : star
                current.rating = newR
                vm.setRating(current, rating: newR)
            }

            HStack(spacing: 28) {
                iconAction(
                    icon: current.isFavorite ? "heart.fill" : "heart",
                    color: current.isFavorite ? .red : .secondary,
                    label: current.isFavorite ? "Favorited" : "Favorite"
                ) {
                    current.isFavorite.toggle()
                    vm.toggleFavorite(current)
                }
                .accessibilityHint(current.isFavorite ? "Double-tap to remove from favorites" : "Double-tap to add to favorites")

                iconAction(
                    icon: current.inReadingList ? "bookmark.fill" : "bookmark",
                    color: current.inReadingList ? Design.brandBlue : .secondary,
                    label: current.inReadingList ? "In List" : "Reading List"
                ) {
                    current.inReadingList.toggle()
                    vm.toggleReadingList(current)
                }
                .accessibilityHint(current.inReadingList ? "Double-tap to remove from reading list" : "Double-tap to add to reading list")

                Menu {
                    Button("Choose a Page From This Issue…") { showPagePicker = true }
                    Button("Choose Image File…") { changeCover() }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Cover").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Change Cover")
                .accessibilityHint("Choose a page from this issue or an image file to use as the cover")

                Menu {
                    Menu("Add to Reading Path") {
                        let runs = DatabaseManager.shared.allRuns()
                        ForEach(runs) { run in
                            Button(run.title) { vm.addToRun(runId: run.id, comicIds: [current.id]) }
                        }
                        if !runs.isEmpty { Divider() }
                        Button("New Reading Path…") { newRunTitle = ""; showNewRunPrompt = true }
                    }
                    Menu("Add to Tier List") {
                        let tierLists = DatabaseManager.shared.allTierLists()
                        ForEach(tierLists) { list in
                            Button(list.title) { vm.addToTierList(tierListId: list.id, comicIds: [current.id]) }
                        }
                        if !tierLists.isEmpty { Divider() }
                        Button("New Tier List…") { newTierListTitle = ""; showNewTierListPrompt = true }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Lists").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add to Reading Path or Tier List")
            }
        }
        .padding(40)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            // A faint wash of this comic's own cover color behind its detail page -- the same
            // "now playing" ambient-tint idea, scoped to just this one column so it never
            // competes with the neutral home-base look everywhere else in the app. Radial rather
            // than flat so it reads as light spilling outward from where the cover sits, not a
            // uniform color cast over the whole column.
            ZStack {
                Design.navBackground.opacity(0.4)
                RadialGradient(
                    colors: [(accentColor ?? Design.warmSpotlightDefault).opacity(0.22),
                             (accentColor ?? Design.warmSpotlightDefault).opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 360
                )
            }
        )
    }

    private func iconAction(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(current.title)
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)
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
                        Picker("", selection: $newTagCategory) {
                            ForEach(TagCategory.allCases, id: \.self) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 110)
                        Button("Add") { addTag() }
                            .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            divider

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

    @ViewBuilder
    private var supplementarySection: some View {
        if !missingIssues.isEmpty || !appearsInRuns.isEmpty || !appearsInTierLists.isEmpty || current.notes != nil {
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

                if !appearsInTierLists.isEmpty {
                    Rectangle().fill(Design.borderColor).frame(width: 1)
                    tierListsSection
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
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Color.orange.opacity(0.2)))
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appears in Reading Paths")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Design.textPrimary)
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

    private var tierListsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appears in Tier Lists")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Design.textPrimary)
            ForEach(appearsInTierLists) { tierList in
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Design.brandGold).font(.subheadline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tierList.title).font(.subheadline)
                        if !tierList.description.isEmpty {
                            Text(tierList.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
            Text("Notes").font(.system(size: 13, weight: .bold)).foregroundStyle(Design.textPrimary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle().fill(Design.borderColor).frame(height: 1)
            .padding(.horizontal, 40)
    }

    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SignageLabel(text: title, size: 11, kerning: 1.2)
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
        // A whisper of the cover's own color in the metadata grid's border -- ties the whole
        // detail page back to the one thing that's actually "this specific comic," instead of
        // every cell reading identically regardless of which issue is open.
        .overlay(RoundedRectangle(cornerRadius: 8).stroke((accentColor ?? Design.borderColor).opacity(accentColor != nil ? 0.35 : 1), lineWidth: 1))
    }

    private func tagChip(_ tag: Tag) -> some View {
        TagChip(name: tag.name, category: tag.category) { removeTag(tag) }
    }

    private var progressLabel: String {
        if current.isFinished   { return "Finished" }
        if current.progress > 0 { return "Page \(current.progress + 1) of \(current.pageCount)" }
        return "Unread"
    }

    private func loadData() {
        let comicId = current.id
        let series  = current.series
        let pub     = current.publisher
        reviewDraft = current.review ?? ""

        ThumbnailCache.shared.thumbnail(for: current) { img in
            guard comicId == self.current.id else { return }
            self.thumbnail = img
        }
        ThumbnailCache.shared.accentColor(for: current) { color in
            guard comicId == self.current.id else { return }
            withAnimation(Design.motion(Design.springGentle, reduce: self.reduceMotion)) { self.accentColor = color }
        }
        Task.detached(priority: .userInitiated) {
            let t   = DatabaseManager.shared.tags(for: comicId)
            let r   = DatabaseManager.shared.runsContaining(comicId: comicId)
            let tl  = DatabaseManager.shared.tierListsContaining(comicId: comicId)
            let mi  = DatabaseManager.shared.missingIssueNumbers(series: series, publisher: pub)
            await MainActor.run {
                // These four feed conditionally-rendered sections (tags row, supplementary
                // gap/runs/tier-lists/notes strip) that otherwise pop into existence the instant
                // this async load resolves, shoving the rest of the page down with no transition.
                withAnimation(Design.motion(Design.easeStandard, reduce: self.reduceMotion)) {
                    tags = t; appearsInRuns = r; appearsInTierLists = tl; missingIssues = mi
                }
            }
        }
    }

    private func addTag() {
        let name = newTagText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.addTag(name: name, to: current, category: newTagCategory)
        newTagText = ""
        let comicId = current.id
        // Await the comic-specific tag refetch before triggering vm.reload() (which separately
        // refreshes the sidebar's library-wide tag list) instead of firing both concurrently --
        // sequencing them removes any ambiguity about which finishes last for no real cost, since
        // neither depends on the other's timing to be correct on its own.
        Task {
            let t = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.tags(for: comicId)
            }.value
            tags = t
            vm.reload()
        }
    }

    private func removeTag(_ tag: Tag) {
        vm.removeTag(tagId: tag.id, from: current)
        let comicId = current.id
        Task {
            let t = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.tags(for: comicId)
            }.value
            tags = t
            vm.reload()
        }
    }

    private func changeCover() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(current.title)",
            prompt: "Set Cover",
            contentTypes: [.image]
        ) { urls in
            guard let url = urls.first else { return }
            guard PlatformImage.fromURL(url) != nil else {
                coverChangeError = "Couldn't read that image file. Try a different image."
                return
            }
            ThumbnailCache.shared.setCustomCover(comicId: self.current.id, imageURL: url)
            self.thumbnail = nil
            ThumbnailCache.shared.thumbnail(for: self.current) { self.thumbnail = $0 }
        }
    }
}
