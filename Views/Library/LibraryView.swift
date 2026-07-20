import SwiftUI

// MARK: - Top-level browser (routes correct level)

struct LibraryBrowserView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar()
            Rectangle().fill(Design.borderColor).frame(height: 1)

            switch vm.browseLevel {
            case .characters:   CharacterGroupGridView()
            case .seriesGroups: SeriesGroupGridView()
            case .issues:       LibraryGridView()
            }
        }
        .background(Design.appBackground)
        .focusable()
        .focused($focused)
        .onKeyPress(.return) {
            if let comic = vm.selectedComic { vm.openReader(comic); return .handled }
            return .ignored
        }
        .onKeyPress(.escape) {
            if vm.bulkMode { vm.toggleBulkMode(); return .handled }
            if vm.browseLevel != .characters && vm.browseLevel != .seriesGroups {
                if vm.selectedGroup != nil { vm.navigateBack(); return .handled }
            }
            return .ignored
        }
        .onKeyPress(.leftArrow)  { navigateGrid(forward: false) }
        .onKeyPress(.upArrow)    { navigateGrid(forward: false) }
        .onKeyPress(.rightArrow) { navigateGrid(forward: true) }
        .onKeyPress(.downArrow)  { navigateGrid(forward: true) }
        .onAppear { focused = true }
    }

    @discardableResult
    private func navigateGrid(forward: Bool) -> KeyPress.Result {
        guard vm.browseLevel == .issues, !vm.bulkMode, !vm.comics.isEmpty else { return .ignored }
        let comics = vm.comics
        let idx = vm.selectedComic.flatMap { c in comics.firstIndex(where: { $0.id == c.id }) } ?? (forward ? -1 : 0)
        let next = forward ? min(comics.count - 1, idx + 1) : max(0, idx - 1)
        vm.selectedComic = comics[next]
        return .handled
    }
}

// MARK: - Filter bar (heading + sort + bulk bar)

struct LibraryFilterBar: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var confirmBulkDelete = false
    @State private var showBulkReassign = false

    private var displayCount: Int {
        switch vm.browseLevel {
        case .characters:   return vm.characterGroups.count
        case .seriesGroups: return vm.seriesGroups.count
        case .issues:       return vm.comics.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // Breadcrumb back button (when drilled into a group)
                if vm.selectedGroup != nil && vm.useGroupedView {
                    Button { vm.navigateBack() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text(vm.selectedSeries != nil
                                 ? (vm.selectedGroup?.groupName ?? "Back")
                                 : "Library")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Design.brandBlue)
                    }
                    .buttonStyle(.plain)
                    .help("Go back (⌘[)")
                }

                // Section title + count
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headingTitle)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(.white)
                        .kerning(0.5)
                        .lineLimit(1)

                    Text("\(displayCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Design.surfaceBg)
                        .clipShape(Capsule())
                }

                Spacer()

                // Manage Series button — only visible when browsing a specific series
                if vm.selectedSeries != nil && vm.browseLevel == .issues && vm.selectedComic == nil {
                    Button {
                        vm.showSeriesManager = true
                    } label: {
                        Label("Manage Series", systemImage: "pencil.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rename series and reorder issues")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            // Bulk action bar
            if vm.bulkMode && vm.browseLevel == .issues {
                Divider().overlay(Design.borderColor)
                bulkBar
            }
        }
        .background(Design.navBackground)
    }

    // MARK: - Heading

    private var headingTitle: String {
        if let tag = vm.activeTag { return "#\(tag)" }
        switch vm.selectedSection {
        case .continueReading: return "Continue Reading"
        case .favorites:       return "Favorites"
        case .readingList:     return "Reading List"
        default:
            if let ser = vm.selectedSeries { return ser }
            if let pub = vm.activePublisher { return pub }
            return "Library"
        }
    }

    // MARK: - Bulk bar

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Text(vm.selectedComicIds.isEmpty
                 ? "Select comics…"
                 : "\(vm.selectedComicIds.count) selected")
                .font(.subheadline.bold())
                .foregroundStyle(vm.selectedComicIds.isEmpty ? .secondary : .primary)

            Spacer()

            Button("All") { vm.selectAll() }.controlSize(.small)

            Divider().frame(height: 16)

            Button { vm.bulkMarkRead() } label: {
                Label("Read", systemImage: "checkmark")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)

            Button { vm.bulkMarkUnread() } label: {
                Label("Unread", systemImage: "arrow.counterclockwise")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)

            Button { vm.bulkAddToReadingList() } label: {
                Label("Add to List", systemImage: "bookmark.badge.plus")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)

            Button { vm.bulkRemoveFromReadingList() } label: {
                Label("Remove from List", systemImage: "bookmark.slash")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)

            Button { showBulkReassign = true } label: {
                Label("Reassign…", systemImage: "folder.badge.gearshape")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)
            .sheet(isPresented: $showBulkReassign) {
                BulkReassignView(count: vm.selectedComicIds.count) { series, publisher in
                    vm.bulkReassign(series: series, publisher: publisher)
                }
            }

            Divider().frame(height: 16)

            Button(role: .destructive) { confirmBulkDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(vm.selectedComicIds.isEmpty).controlSize(.small)
            .confirmationDialog(
                "Delete \(vm.selectedComicIds.count) comic\(vm.selectedComicIds.count == 1 ? "" : "s")?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { vm.bulkDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deleted comics move to Trash and can be restored from Settings.")
            }

            Button("Done") { vm.toggleBulkMode() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Design.navBackground)
    }
}

// MARK: - Continue Reading shelf

struct ContinueReadingShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTINUE READING")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .kerning(1.5)
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.inProgressComics) { comic in
                        ShelfCard(comic: comic)
                            .onTapGesture { vm.openReader(comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct ShelfCard: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: PlatformImage?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Design.cardBg
                    if let img = thumbnail {
                        Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 130)
                .comicCardStyle()

                if !comic.isFinished {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 3)
                        Rectangle().fill(Design.brandBlue)
                            .frame(width: 90 * comic.progressPercent, height: 3)
                    }
                    .frame(width: 90)
                    .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
                }
            }

            Text(comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text("p. \(comic.progress + 1)/\(comic.pageCount)")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1.0)
        .animation(Design.motion(Design.springSnappy, reduce: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
        .contextMenu {
            Button("Continue Reading") { vm.readerComic = comic }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue("Page \(comic.progress + 1) of \(comic.pageCount), \(Int(comic.progressPercent * 100))% complete")
        .accessibilityHint("Double-tap to continue reading")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Character group grid

struct CharacterGroupGridView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var draggedGroup: DatabaseManager.CharacterGroup?
    @State private var dropTargetGroupId: String?

    private let columns = [GridItem(.adaptive(minimum: Design.groupCardWidth,
                                              maximum: Design.groupCardWidth + 20),
                                    spacing: Design.gridSpacing)]
    var body: some View {
        ScrollView {
            if vm.isLoading && vm.characterGroups.isEmpty {
                skeletonGrid
            } else if vm.characterGroups.isEmpty {
                emptyState
            } else {
                if !vm.inProgressComics.isEmpty {
                    ContinueReadingShelf()
                    Divider().overlay(Design.borderColor).padding(.vertical, 6)
                }
                LazyVGrid(columns: columns, spacing: Design.gridSpacing) {
                    ForEach(vm.characterGroups) { group in
                        let isTarget = dropTargetGroupId == group.id && draggedGroup?.id != group.id
                        CharacterGroupCard(group: group)
                            .onTapGesture { vm.drillIntoGroup(group) }
                            .onDrag {
                                draggedGroup = group
                                return NSItemProvider(object: NSString(string: group.id))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetGroupId = active ? group.id : nil }
                                    )) { _, _ in
                                guard let from = draggedGroup else { return false }
                                vm.moveCharacterGroup(from: from, to: group)
                                draggedGroup = nil; dropTargetGroupId = nil
                                return true
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner + 2)
                                    .stroke(Design.brandGold, lineWidth: 2.5)
                                    .opacity(isTarget ? 1 : 0)
                                    .allowsHitTesting(false)
                            )
                    }
                }
                .padding(Design.gridSpacing)
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, spacing: Design.gridSpacing) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    ShimmerCard(width: Design.groupCardWidth, height: Design.groupCardHeight)
                    ShimmerCard(width: Design.groupCardWidth * 0.7, height: 10)
                }
            }
        }
        .padding(Design.gridSpacing)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64)).foregroundStyle(.secondary)
            Text("No Comics").font(.title2.bold())
            Text(vm.libraryPath.isEmpty
                 ? "Set your library path in Settings"
                 : "Scan your library to get started")
                .foregroundStyle(.secondary)
            if !vm.libraryPath.isEmpty {
                Button("Scan Library") { vm.scan() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Series group grid

struct SeriesGroupGridView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var draggedSeries: String?
    @State private var dropTargetSeries: String?

    private let columns = [GridItem(.adaptive(minimum: Design.groupCardWidth,
                                              maximum: Design.groupCardWidth + 20),
                                    spacing: Design.gridSpacing)]
    var body: some View {
        ScrollView {
            if vm.seriesGroups.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: Design.gridSpacing) {
                    ForEach(vm.seriesGroups) { sg in
                        let isTarget = dropTargetSeries == sg.series && draggedSeries != sg.series
                        SeriesGroupCard(group: sg)
                            .onTapGesture { vm.drillIntoSeries(sg) }
                            .onDrag {
                                draggedSeries = sg.series
                                return NSItemProvider(object: NSString(string: sg.series))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetSeries = active ? sg.series : nil }
                                    )) { _, _ in
                                guard let from = draggedSeries else { return false }
                                vm.moveSeriesGroup(fromSeries: from, toSeries: sg.series)
                                draggedSeries = nil; dropTargetSeries = nil
                                return true
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner + 2)
                                    .stroke(Design.brandGold, lineWidth: 2.5)
                                    .opacity(isTarget ? 1 : 0)
                                    .allowsHitTesting(false)
                            )
                    }
                }
                .padding(Design.gridSpacing)
            }
        }
    }

    // Reachable when every series that used to live under this character/collection group
    // has had its last comic removed, renamed away, or moved elsewhere — the group card
    // itself still exists one screen up, but drilling into it now finds nothing. Without
    // this, the screen was just a blank scroll area with no explanation of what happened.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text("No Series Here").font(.title2.bold())
            Text("The comics that were here have been moved, renamed, or removed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back") { vm.navigateBack() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Character / series group cards

struct CharacterGroupCard: View {
    let group: DatabaseManager.CharacterGroup
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService

    var body: some View {
        GroupCard(title: group.groupName, subtitle: group.publisher,
                  count: group.count, finished: group.finished, started: group.started,
                  coverId: group.coverId, coverImagePath: group.coverImagePath,
                  placeholderIcon: "books.vertical.fill", placeholderIconSize: 48)
        .contextMenu {
            Button("Set Custom Cover…") { pickCoverImage() }
            if group.coverImagePath != nil {
                Button("Remove Custom Cover") { vm.clearCharacterGroupCover(group: group) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.groupName), \(group.count) issue\(group.count == 1 ? "" : "s")")
        .accessibilityHint("Double-tap to open collection")
        .accessibilityAddTraits(.isButton)
    }

    private func pickCoverImage() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(group.groupName)",
            prompt: "Set Cover"
        ) { urls in
            if let url = urls.first { vm.setCharacterGroupCover(group: group, imageURL: url) }
        }
    }
}

struct SeriesGroupCard: View {
    let group: DatabaseManager.SeriesGroup
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        GroupCard(title: group.series, subtitle: nil,
                  count: group.count, finished: group.finished, started: group.started,
                  coverId: group.coverId, placeholderIcon: "book.fill", placeholderIconSize: 40)
        .contextMenu {
            Button("Open Series") { vm.drillIntoSeries(group) }
            Button("Manage Series…") {
                vm.drillIntoSeries(group)
                vm.showSeriesManager = true
            }
            Divider()
            Button("Mark All as Read") {
                let pub    = vm.activePublisher
                let series = group.series
                Task.detached(priority: .userInitiated) {
                    let comics = DatabaseManager.shared.allComics(publisher: pub, series: series)
                    await MainActor.run { vm.markRead(comics) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.series), \(group.count) issue\(group.count == 1 ? "" : "s")")
        .accessibilityValue(progressText)
        .accessibilityHint("Double-tap to open series")
        .accessibilityAddTraits(.isButton)
    }

    private var progressText: String {
        if group.finished == group.count { return "Complete" }
        if group.finished > 0 || group.started > 0 { return "\(group.finished) read" }
        return "Unread"
    }
}

private struct GroupCard: View {
    let title: String
    let subtitle: String?
    let count: Int
    let finished: Int
    let started: Int
    let coverId: Int64
    var coverImagePath: String? = nil
    let placeholderIcon: String
    let placeholderIconSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: PlatformImage?
    @State private var isHovered = false
    @AppStorage("progressFormat") private var progressFormatRaw = ProgressFormat.fraction.rawValue

    private var progressFormat: ProgressFormat { ProgressFormat(rawValue: progressFormatRaw) ?? .fraction }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage
                    .frame(width: Design.groupCardWidth, height: Design.groupCardHeight)
                    .comicCardStyle()

                LinearGradient(colors: [.clear, .black.opacity(0.82)],
                               startPoint: .center, endPoint: .bottom)
                    .frame(width: Design.groupCardWidth, height: Design.groupCardHeight)
                    .clipShape(Rectangle())
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white).lineLimit(2)
                    if let prog = progressFormat.text(finished: finished, started: started, total: count) {
                        Text(prog).font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(10)
                .frame(width: Design.groupCardWidth, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                Text("\(count)")
                    .font(.caption.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Design.brandGold).clipShape(Capsule())
                    .padding(8)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: Design.groupCardWidth, alignment: .leading)
            }
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1.0)
        .animation(Design.motion(Design.springSnappy, reduce: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear { loadThumbnail() }
    }

    @ViewBuilder
    private var coverImage: some View {
        ZStack {
            Design.cardBg
            if let img = thumbnail {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                LinearGradient(colors: [Design.brandBlue, Design.brandBlue.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: placeholderIcon)
                    .font(.system(size: placeholderIconSize)).foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func loadThumbnail() {
        // Custom image path takes priority over derived comic cover
        if let path = coverImagePath, let img = PlatformImage.fromFile(path) {
            thumbnail = img
            return
        }
        Task.detached(priority: .utility) {
            if let img = ThumbnailCache.shared.thumbnailFromCache(comicId: coverId) {
                await MainActor.run { thumbnail = img }; return
            }
            if let comic = DatabaseManager.shared.comic(id: coverId) {
                ThumbnailCache.shared.thumbnail(for: comic) { img in
                    DispatchQueue.main.async { thumbnail = img }
                }
            }
        }
    }
}

// MARK: - Issue grid (leaf level)

struct LibraryGridView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    @State private var draggedId:   Int64? = nil
    @State private var dropTargetId: Int64? = nil

    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .regular }
    private var isManualSort: Bool { vm.sortOrder == .manual }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: density.cardWidth, maximum: density.cardWidth + 8),
                  spacing: density.spacing)]
    }
    var body: some View {
        ScrollView {
            if vm.isLoading && vm.comics.isEmpty {
                skeletonGrid(density: density)
            } else if vm.comics.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: density.spacing) {
                    ForEach(vm.comics) { comic in
                        let isTarget = dropTargetId == comic.id && draggedId != comic.id
                        ComicCard(
                            comic: comic,
                            isSelected: vm.selectedComic?.id == comic.id,
                            onOpen: { vm.openReader(comic) },
                            cardWidth: density.cardWidth,
                            cardHeight: density.cardHeight
                        )
                        .onTapGesture {
                            if vm.bulkMode { vm.toggleSelection(comic.id) }
                            else           { vm.selectedComic = comic }
                        }
                        .onDrag {
                            guard isManualSort else { return NSItemProvider() }
                            draggedId = comic.id
                            return NSItemProvider(object: NSString(string: String(comic.id)))
                        }
                        .onDrop(of: [.plainText],
                                isTargeted: Binding(
                                    get: { isTarget },
                                    set: { active in dropTargetId = active ? comic.id : nil }
                                )) { _, _ in
                            guard isManualSort, let from = draggedId else { return false }
                            vm.moveComic(id: from, before: comic.id)
                            draggedId = nil; dropTargetId = nil
                            return true
                        }
                        .overlay(
                            Rectangle()
                                .stroke(Design.brandGold, lineWidth: 2.5)
                                .opacity(isTarget ? 1 : 0)
                                .allowsHitTesting(false)
                        )
                    }
                }
                .padding(Design.gridSpacing)
            }
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func skeletonGrid(density: GridDensity) -> some View {
        let cols = [GridItem(.adaptive(minimum: density.cardWidth, maximum: density.cardWidth + 8),
                             spacing: density.spacing)]
        return LazyVGrid(columns: cols, spacing: density.spacing) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    ShimmerCard(width: density.cardWidth, height: density.cardHeight)
                    ShimmerCard(width: density.cardWidth * 0.8, height: 9)
                    ShimmerCard(width: density.cardWidth * 0.5, height: 9)
                }
            }
        }
        .padding(Design.gridSpacing)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: emptyIcon)
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.title3.bold())
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            emptyAction
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyIcon: String {
        switch vm.selectedSection {
        case .continueReading: return "book.open"
        case .favorites:       return "heart"
        case .readingList:     return "bookmark"
        default:
            if vm.activeTag != nil        { return "tag" }
            if vm.activePublisher != nil  { return "building.2" }
            if !vm.searchText.isEmpty     { return "magnifyingglass" }
            return "books.vertical"
        }
    }

    private var emptyTitle: String {
        switch vm.selectedSection {
        case .continueReading: return "Nothing In Progress"
        case .favorites:       return "No Favorites"
        case .readingList:     return "Reading List Is Empty"
        default:
            if let tag = vm.activeTag        { return "No \"\(tag)\" Comics" }
            if let pub = vm.activePublisher  { return "No \(pub) Comics" }
            if !vm.searchText.isEmpty        { return "No Results" }
            if vm.libraryPath.isEmpty        { return "Library Not Set Up" }
            return "No Comics"
        }
    }

    private var emptyMessage: String {
        switch vm.selectedSection {
        case .continueReading:
            return "Start reading any comic and it will appear here."
        case .favorites:
            return "Open any comic's detail page and tap the heart to add it here."
        case .readingList:
            return "Right-click any comic and choose Add to Reading List to queue it up."
        default:
            if let tag = vm.activeTag        { return "No comics are tagged \"\(tag)\"." }
            if let pub = vm.activePublisher  { return "No \(pub) comics found in your library." }
            if !vm.searchText.isEmpty        { return "Try a different search term or clear the search field." }
            if vm.libraryPath.isEmpty        { return "Go to Settings to choose your comics folder." }
            return "Drop CBZ, CBR, or PDF files here, or scan your library folder."
        }
    }

    @ViewBuilder
    private var emptyAction: some View {
        switch vm.selectedSection {
        case .continueReading, .favorites, .readingList:
            Button("Browse Library") { vm.select(.library) }
                .buttonStyle(.borderedProminent)
        default:
            if vm.activeTag != nil || vm.activePublisher != nil || !vm.searchText.isEmpty {
                Button("Clear Filter") { vm.clearAllFilters() }
                    .buttonStyle(.bordered)
            } else if !vm.libraryPath.isEmpty {
                Button("Scan Library") { vm.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            let url = await withCheckedContinuation { cont in
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                        cont.resume(returning: u as URL?)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            if let url { urls.append(url) }
        }
        if !urls.isEmpty { vm.importFiles(urls) }
    }
}

// MARK: - Density picker

struct DensityPicker: View {
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .regular }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GridDensity.allCases, id: \.rawValue) { d in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { densityRaw = d.rawValue }
                } label: {
                    Image(systemName: d.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(density == d ? Design.brandGold : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(d.rawValue.capitalized + " grid")
            }
        }
        .padding(3)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
