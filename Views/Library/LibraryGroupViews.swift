import SwiftUI

/// The accent-color lookup a selected character group's theme detection needs -- shared by
/// `SeriesGroupGridView` (this file) and `LibraryGridView`, which both react to `vm.selectedGroup`
/// changing but previously each hand-rolled an identical `guard`+`groupAccentColor` call.
func loadSelectedGroupMoodColor(_ group: DatabaseManager.CharacterGroup?, into color: Binding<Color?>) {
    guard let group else { color.wrappedValue = nil; return }
    ThumbnailCache.shared.groupAccentColor(key: group.id, coverImagePath: group.coverImagePath,
                                            representativeComicId: group.coverId) { color.wrappedValue = $0 }
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
                if let current = vm.inProgressComics.first {
                    NowReadingHero(comic: current)
                    Divider().overlay(Design.borderColor).padding(.vertical, 6)
                }
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
            title: "Your Shelf Is Empty",
            message: vm.libraryPaths.isEmpty
                ? "Set your library folder(s) in Settings to start stocking it"
                : "Scan your library to bring your comics to the shelf",
            illustration: vm.libraryPaths.isEmpty ? nil : AnyView(LongBoxesIllustration())
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
    @State private var moodColor: Color?

    private let columns = [GridItem(.adaptive(minimum: Design.groupCardWidth,
                                              maximum: Design.groupCardWidth + 20),
                                    spacing: Design.gridSpacing)]
    var body: some View {
        ScrollView {
            if vm.isLoading && vm.seriesGroups.isEmpty {
                // Previously this branched straight to `emptyState` while loading too -- a slow
                // series-grid load would flash "No Series Here" (an error-sounding message) before
                // the real data arrived, instead of a neutral loading state like the other two
                // grids (`CharacterGroupGridView`/`LibraryGridView`) already have.
                skeletonGrid
            } else if vm.seriesGroups.isEmpty {
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
        // A themed backdrop for this character -- name-matched first (generic decoration only,
        // see `Design.ComicTheme`), falling back to a scene derived from the character's own
        // cover-art color for anything unmatched. The same detected theme is also injected into
        // the environment, so every `GroupCard` inside automatically scales its own existing
        // hover spotlight/lift/shadow to match -- no card needs to know which theme it is.
        .background(ThemeBackdrop(name: vm.selectedGroup?.groupName, color: moodColor))
        .environment(\.comicTheme, ComicTheme.detect(name: vm.selectedGroup?.groupName, color: moodColor))
        .onAppear { loadSelectedGroupMoodColor(vm.selectedGroup, into: $moodColor) }
        .onChange(of: vm.selectedGroup?.id) { _, _ in loadSelectedGroupMoodColor(vm.selectedGroup, into: $moodColor) }
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
                  placeholderIcon: "books.vertical.fill", placeholderIconSize: 48,
                  identityKey: "chargroup_\(group.publisher)_\(group.groupName)")
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
                  placeholderIcon: "book.fill", placeholderIconSize: 40,
                  identityKey: "series_\(group.publisher)_\(group.series)")
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
    // Stable identity key ("chargroup_<publisher>_<group>" / "series_<publisher>_<series>",
    // matching `ThumbnailCache`'s existing custom-cover naming) this group's own "identity
    // color" is cached under -- lets the whole card carry a bit of its own color at rest, the
    // "maximal art-driven" browsing treatment `ComicCard` deliberately doesn't get.
    let identityKey: String

    @State private var thumbnail: PlatformImage?
    @State private var identityColor: Color?
    @State private var isHovered = false
    @AppStorage("progressFormat") private var progressFormatRaw = ProgressFormat.fraction.rawValue
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.comicTheme) private var theme

    private var progressFormat: ProgressFormat { ProgressFormat(rawValue: progressFormatRaw) ?? .fraction }
    private var restingTint: Color? {
        Design.atmosphericTint(identityColor,
                                increaseContrast: colorSchemeContrast == .increased,
                                differentiateWithoutColor: differentiateWithoutColor)
    }
    private var scrimColor: Color {
        Design.scrimTint(identityColor,
                          increaseContrast: colorSchemeContrast == .increased,
                          differentiateWithoutColor: differentiateWithoutColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage
                    .frame(width: Design.groupCardWidth, height: Design.groupCardHeight)
                    .comicCardStyle(accentColor: identityColor, isHovered: isHovered, restingTint: restingTint, theme: theme)

                LinearGradient(colors: [.clear, scrimColor.opacity(0.82)],
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
        .hoverLift(scale: theme.interaction.hoverLiftScale, duration: theme.interaction.hoverAnimationDuration, isHovered: $isHovered)
        .animation(Design.motion(Design.easeStandard, reduce: reduceMotion), value: identityColor)
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
        ThumbnailCache.shared.groupAccentColor(key: identityKey, coverImagePath: coverImagePath,
                                                representativeComicId: coverId) { identityColor = $0 }
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
