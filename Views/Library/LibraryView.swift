import SwiftUI
import UniformTypeIdentifiers

struct LibraryBrowserView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @FocusState private var focused: Bool
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    @State private var gridWidth: CGFloat = 0

    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .regular }
    // Approximates LibraryGridView's `.adaptive(minimum: density.cardWidth, ...)` column count so
    // Up/Down can jump by a row's worth of columns instead of behaving identically to Left/Right.
    private var columnsPerRow: Int {
        guard gridWidth > 0 else { return 1 }
        let itemStride = density.cardWidth + density.spacing
        return max(1, Int((gridWidth + density.spacing) / itemStride))
    }

    /// Drilling in slides new content in from the trailing edge; `navigateBack()` reverses it --
    /// mirrors `vm.browseNavigationDirection`, which the view model sets right before it changes
    /// `browseLevel`.
    private var browseTransition: AnyTransition {
        let forward = vm.browseNavigationDirection == .forward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar()
            Rectangle().fill(Design.borderColor).frame(height: 1)

            switch vm.browseLevel {
            case .characters:   CharacterGroupGridView().transition(browseTransition)
            case .seriesGroups: SeriesGroupGridView().transition(browseTransition)
            case .issues:       LibraryGridView().transition(browseTransition)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { gridWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in gridWidth = w }
            }
        )
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
        .onKeyPress(.leftArrow)  { navigateGrid(by: -1) }
        .onKeyPress(.upArrow)    { navigateGrid(by: -columnsPerRow) }
        .onKeyPress(.rightArrow) { navigateGrid(by: 1) }
        .onKeyPress(.downArrow)  { navigateGrid(by: columnsPerRow) }
        .onAppear { focused = true }
    }

    @discardableResult
    private func navigateGrid(by delta: Int) -> KeyPress.Result {
        guard vm.browseLevel == .issues, !vm.bulkMode, !vm.comics.isEmpty else { return .ignored }
        let comics = vm.comics
        let idx = vm.selectedComic.flatMap { c in comics.firstIndex(where: { $0.id == c.id }) } ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(comics.count - 1, idx + delta))
        vm.selectedComic = comics[next]
        return .handled
    }
}

struct LibraryFilterBar: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
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

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headingTitle)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Design.textPrimary)
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

            if vm.bulkMode && vm.browseLevel == .issues {
                Divider().overlay(Design.borderColor)
                bulkBar
            }
        }
        .background(Design.navBackground)
    }

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
                Button("Delete", role: .destructive) { vm.bulkDelete(fileService: fileService) }
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

struct ContinueReadingShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "book.open.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                Text("CONTINUE READING")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(1.5)
            }
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

struct ReadNextShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                Text("READ NEXT")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(1.5)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.readNextSuggestions) { comic in
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

struct OnThisDayShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                Text("ON THIS DAY")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(1.5)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.onThisDayEntries) { entry in
                        OnThisDayCard(entry: entry)
                            .onTapGesture { vm.openReader(entry.comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct OnThisDayCard: View {
    let entry: DiaryEntry
    @State private var thumbnail: PlatformImage?

    private var yearsAgo: Int {
        let loggedYear = Int(entry.loggedAt.prefix(4)) ?? Calendar.current.component(.year, from: Date())
        return max(1, Calendar.current.component(.year, from: Date()) - loggedYear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Design.cardBg
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                        .frame(width: 90, height: 130)
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 130)
            .comicCardStyle()

            Text(entry.comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(yearsAgo == 1 ? "1 YEAR AGO" : "\(yearsAgo) YEARS AGO")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Design.brandGold)
        }
        .hoverLift(scale: 1.04)
        .onAppear { ThumbnailCache.shared.thumbnail(for: entry.comic) { thumbnail = $0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.comic.title)
        .accessibilityValue(yearsAgo == 1 ? "Read 1 year ago today" : "Read \(yearsAgo) years ago today")
        .accessibilityHint("Double-tap to open in reader")
        .accessibilityAddTraits(.isButton)
    }
}

struct RecommendedShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                Text("RECOMMENDED FOR YOU")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(1.5)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.recommendations) { comic in
                        RecommendedCard(comic: comic)
                            .onTapGesture { vm.openReader(comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct RecommendedCard: View {
    let comic: Comic
    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Design.cardBg
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                        .frame(width: 90, height: 130)
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 130)
            .comicCardStyle()

            Text(comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(comic.series)
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
        .hoverLift(scale: 1.04)
        .onAppear { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue("From \(comic.series), recommended based on your ratings")
        .accessibilityHint("Double-tap to open in reader")
        .accessibilityAddTraits(.isButton)
    }
}

struct ShelfCard: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?
    @State private var showMetadataInspector = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Design.cardBg
                    if let img = thumbnail {
                        Image(platformImage: img).comicCoverStyle()
                            .frame(width: 90, height: 130)
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
        .hoverLift(scale: 1.04)
        .onAppear { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
        .contextMenu {
            Button("Continue Reading") { vm.readerComic = comic }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
            Button("Metadata Inspector…") { showMetadataInspector = true }
        }
        .sheet(isPresented: $showMetadataInspector) { MetadataInspectorView(comicId: comic.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue("Page \(comic.progress + 1) of \(comic.pageCount), \(Int(comic.progressPercent * 100))% complete")
        .accessibilityHint("Double-tap to continue reading")
        .accessibilityAddTraits(.isButton)
    }
}

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
                if !vm.readNextSuggestions.isEmpty {
                    ReadNextShelf()
                    Divider().overlay(Design.borderColor).padding(.vertical, 6)
                }
                if !vm.onThisDayEntries.isEmpty {
                    OnThisDayShelf()
                    Divider().overlay(Design.borderColor).padding(.vertical, 6)
                }
                if !vm.recommendations.isEmpty {
                    RecommendedShelf()
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
                                    .animation(Design.easeFast, value: isTarget)
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
        EmptyStateView(
            icon: "books.vertical.fill",
            title: "No Comics",
            message: vm.libraryPaths.isEmpty
                ? "Set your library folder(s) in Settings"
                : "Scan your library to get started"
        ) {
            if !vm.libraryPaths.isEmpty {
                Button("Scan Library") { vm.scan() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

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
            } else if folderGroupBuckets.count <= 1 {
                // The common case (1-3 level folder layout, no in-between grouping folder) --
                // render exactly as before, no header.
                LazyVGrid(columns: columns, spacing: Design.gridSpacing) {
                    ForEach(vm.seriesGroups) { sg in seriesCard(sg) }
                }
                .padding(Design.gridSpacing)
            } else {
                // A real on-disk folder sits between this Character and some of its series (e.g.
                // "Batman (Modern)") -- surface it as a section header instead of silently
                // discarding it, so that grouping the user built on disk actually shows up here.
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(folderGroupBuckets, id: \.label) { bucket in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(bucket.label)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Design.gridSpacing)
                            LazyVGrid(columns: columns, spacing: Design.gridSpacing) {
                                ForEach(bucket.groups) { sg in seriesCard(sg) }
                            }
                            .padding(.horizontal, Design.gridSpacing)
                        }
                    }
                }
                .padding(.vertical, Design.gridSpacing)
            }
        }
    }

    @ViewBuilder
    private func seriesCard(_ sg: DatabaseManager.SeriesGroup) -> some View {
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
                    .animation(Design.easeFast, value: isTarget)
            )
    }

    /// Buckets `vm.seriesGroups` by their on-disk folder group, preserving each series' existing
    /// relative order (manual reorder / series_order) both within and across buckets. A single
    /// bucket means no meaningful in-between folder exists anywhere in this character -- callers
    /// should render flat with no header in that case, matching every library that's just 1-3
    /// folder levels deep.
    private var folderGroupBuckets: [(label: String, groups: [DatabaseManager.SeriesGroup])] {
        var buckets: [String: [DatabaseManager.SeriesGroup]] = [:]
        for sg in vm.seriesGroups {
            let label = (sg.folderGroup?.isEmpty == false) ? sg.folderGroup! : "Other"
            buckets[label, default: []].append(sg)
        }
        // Previously ordered by whichever label's first series happened to sort earliest
        // overall (e.g. "Batman (Modern)" could land before "Batman (Classic)" just because
        // some 2016-dated issue alphabetized ahead of an annual) -- sort the labels themselves
        // instead, so folder-group headers read in a predictable order. "Other" (comics with no
        // real on-disk group) always trails, regardless of where it'd fall alphabetically.
        let realLabels = buckets.keys.filter { $0 != "Other" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let labels = buckets["Other"] != nil ? realLabels + ["Other"] : realLabels
        return labels.map { (label: $0, groups: buckets[$0] ?? []) }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "square.stack.3d.up.slash",
            title: "No Series Here",
            message: "The comics that were here have been moved, renamed, or removed."
        ) {
            Button("Back") { vm.navigateBack() }.buttonStyle(.borderedProminent)
        }
    }
}

struct CharacterGroupCard: View {
    let group: DatabaseManager.CharacterGroup
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
    @State private var showCoverPicker = false

    var body: some View {
        GroupCard(title: group.groupName, subtitle: group.publisher,
                  count: group.count, finished: group.finished, started: group.started,
                  coverId: group.coverId, coverImagePath: group.coverImagePath,
                  placeholderIcon: "books.vertical.fill", placeholderIconSize: 48)
        .contextMenu {
            Button("Choose Existing Cover…") { showCoverPicker = true }
            Button("Custom Image…") { pickCoverImage() }
            if group.coverImagePath != nil {
                Button("Remove Custom Cover") { vm.clearCharacterGroupCover(group: group) }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(title: "Choose Cover for \(group.groupName)") { comic in
                vm.setCharacterGroupCover(group: group, usingCoverOf: comic)
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
            prompt: "Set Cover",
            contentTypes: [.image]
        ) { urls in
            if let url = urls.first { vm.setCharacterGroupCover(group: group, imageURL: url) }
        }
    }
}

struct SeriesGroupCard: View {
    let group: DatabaseManager.SeriesGroup
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
    @State private var showCoverPicker = false

    var body: some View {
        GroupCard(title: group.series, subtitle: nil,
                  count: group.count, finished: group.finished, started: group.started,
                  coverId: group.coverId, coverImagePath: group.coverImagePath,
                  placeholderIcon: "book.fill", placeholderIconSize: 40)
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
            Divider()

            Button("Choose Existing Cover…") { showCoverPicker = true }
            Button("Custom Image…") { pickCoverImage() }
            if group.coverImagePath != nil {
                Button("Remove Custom Cover") { vm.clearSeriesCover(group.series, publisher: group.publisher) }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(title: "Choose Cover for \(group.series)") { comic in
                vm.setSeriesCover(series: group.series, publisher: group.publisher, usingCoverOf: comic)
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

    private func pickCoverImage() {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(group.series)",
            prompt: "Set Cover",
            contentTypes: [.image]
        ) { urls in
            if let url = urls.first {
                vm.setSeriesCoverImage(series: group.series, publisher: group.publisher, imageURL: url)
            }
        }
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

    @State private var thumbnail: PlatformImage?
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
        .hoverLift()
        .onAppear { loadThumbnail() }
    }

    @ViewBuilder
    private var coverImage: some View {
        ZStack {
            Design.cardBg
            if let img = thumbnail {
                Image(platformImage: img).comicCoverStyle()
                    .frame(width: Design.groupCardWidth, height: Design.groupCardHeight)
            } else {
                LinearGradient(colors: [Design.brandBlue, Design.brandBlue.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: placeholderIcon)
                    .font(.system(size: placeholderIconSize)).foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func loadThumbnail() {
        if let path = coverImagePath, let img = PlatformImage.fromFile(path) {
            thumbnail = img
            return
        }
        Task.detached(priority: .utility) {
            if let img = ThumbnailCache.shared.thumbnailFromCache(comicId: coverId) {
                await MainActor.run { thumbnail = img }; return
            }
            if let path = DatabaseManager.shared.filePath(forComicId: coverId) {
                ThumbnailCache.shared.thumbnail(id: coverId, filePath: path) { img in
                    DispatchQueue.main.async { thumbnail = img }
                }
            }
        }
    }
}

struct LibraryGridView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    @State private var draggedId:   Int64? = nil
    @State private var dropTargetId: Int64? = nil

    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .regular }

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
                            onSelect: {
                                if vm.bulkMode { vm.toggleSelection(comic.id) }
                                else           { vm.selectedComic = comic }
                            },
                            cardWidth: density.cardWidth,
                            cardHeight: density.cardHeight
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
                        .overlay(
                            Rectangle()
                                .stroke(Design.brandGold, lineWidth: 2.5)
                                .opacity(isTarget ? 1 : 0)
                                .allowsHitTesting(false)
                                .animation(Design.easeFast, value: isTarget)
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

    private var emptyState: some View {
        EmptyStateView(icon: emptyIcon, title: emptyTitle, message: emptyMessage) {
            emptyAction
        }
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
            if vm.libraryPaths.isEmpty        { return "Library Not Set Up" }
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
            if vm.libraryPaths.isEmpty        { return "Go to Settings to choose your comics folder(s)." }
            return "Drop CBZ, CBR, or PDF files here, or scan your library folders."
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
            } else if !vm.libraryPaths.isEmpty {
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

struct SortPicker: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Menu {
            ForEach(DatabaseManager.SortOrder.allCases) { order in
                Button {
                    vm.sortOrder = order
                    vm.reload()
                } label: {
                    if vm.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12))
        }
        .help("Sort: \(vm.sortOrder.rawValue)")
        .accessibilityLabel("Sort by \(vm.sortOrder.rawValue)")
    }
}

struct FilterPicker: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showSaveViewPrompt = false
    @State private var saveViewNameDraft = ""

    private var isActive: Bool { vm.unreadOnly || vm.minRatingFilter > 0 }

    var body: some View {
        Menu {
            Button {
                vm.unreadOnly.toggle()
            } label: {
                if vm.unreadOnly {
                    Label("Unread Only", systemImage: "checkmark")
                } else {
                    Text("Unread Only")
                }
            }

            Divider()

            ForEach([0, 1, 2, 3, 4, 5], id: \.self) { threshold in
                Button {
                    vm.minRatingFilter = threshold
                } label: {
                    let label = threshold == 0 ? "Any Rating" : "★\(threshold) & Up"
                    if vm.minRatingFilter == threshold {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }

            Divider()

            Button {
                saveViewNameDraft = ""
                showSaveViewPrompt = true
            } label: {
                Label("Save Current View…", systemImage: "pin")
            }
        } label: {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
        }
        .help(isActive ? "Filters active" : "Filter by read status or rating")
        .accessibilityLabel(isActive ? "Filters active" : "Filter comics")
        .alert("Save Current View", isPresented: $showSaveViewPrompt) {
            TextField("Name", text: $saveViewNameDraft)
            Button("Save") {
                let trimmed = saveViewNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                vm.saveCurrentAsView(name: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remembers the current sort, filter, and search so you can jump straight back to it from the sidebar.")
        }
    }
}

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
                .accessibilityLabel("\(d.rawValue.capitalized) grid")
                .accessibilityAddTraits(density == d ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
