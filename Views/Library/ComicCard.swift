import SwiftUI

struct ComicCard: View {
    let comic:      Comic
    let isSelected: Bool
    let onOpen:     () -> Void
    var onSelect:   () -> Void = {}
    var cardWidth:  CGFloat = Design.cardWidth
    var cardHeight: CGFloat = Design.cardHeight

    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fileService) private var fileService
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.comicTheme) private var theme
    @State private var thumbnail: PlatformImage?
    @State private var accentColor: Color?
    @State private var isHovered = false
    @State private var showMetadataInspector = false
    // Backs the context menu's "Add to Reading Path…"/"Add to Tier List…" new-item prompts --
    // previously the only way to get a comic into either was opening that feature's own
    // management screen first; this gives all six "remember this comic" features (Favorites,
    // Highlights, Reading List, Reading Paths, Tier Lists, Diary) the same "flag from anywhere"
    // pattern Favorites/Reading List's heart/bookmark icons already have.
    @State private var showNewRunPrompt = false
    @State private var newRunTitle = ""
    @State private var showNewTierListPrompt = false
    @State private var newTierListTitle = ""

    private var isBulkSelected: Bool { vm.selectedComicIds.contains(comic.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                cover
                    .frame(width: cardWidth, height: cardHeight)
                    .comicCardStyle(accentColor: accentColor, isHovered: isHovered,
                                     fallbackTint: Design.publisherColor(comic.publisher), theme: theme)

                if comic.isStarted && !comic.isFinished {
                    progressStrip
                }
            }
            .overlay(alignment: .topTrailing) {
                if comic.isFavorite && !vm.bulkMode {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red).font(.caption)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if vm.bulkMode {
                    Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isBulkSelected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if comic.isFinished && !vm.bulkMode { finishedBadge }
            }

            Text(comic.title)
                .font(.caption).lineLimit(2)
                .frame(width: cardWidth, alignment: .leading)

            PublisherBadge(publisher: comic.publisher)

            if comic.rating > 0 && !vm.bulkMode {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= comic.rating ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundStyle(i <= comic.rating ? Design.brandGold : Design.secondaryLabel)
                    }
                }
            }
        }
        // isHovered: binds this to the shared HoverLiftModifier (same scale/ease/reduce-motion
        // behavior every other card uses) while still exposing the boolean here, since the cover
        // glow above (`comicCardStyle(accentColor:isHovered:)`) needs it too.
        // `theme.interaction.hoverLiftScale` is how this same lift becomes theme-aware (e.g. a
        // snappier pop inside `webbed`) without this view ever knowing which theme it is.
        .hoverLift(scale: theme.interaction.hoverLiftScale, duration: theme.interaction.hoverAnimationDuration, isHovered: $isHovered)
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardCorner + 2)
                .stroke(
                    isBulkSelected ? Color.accentColor
                    : isSelected   ? Color.accentColor
                    : Color.clear,
                    lineWidth: 2.5
                )
                .frame(width: cardWidth + 5, height: cardHeight + 5)
                // Entering/leaving bulk-select mode (or selecting/deselecting) previously cut this
                // ring in and out instantly -- same "no spring, just ease" rule as the hover fix.
                .animation(Design.motion(Design.easeFast, reduce: reduceMotion), value: isBulkSelected)
                .animation(Design.motion(Design.easeFast, reduce: reduceMotion), value: isSelected)
        )
        // Both tap counts attached at the same view level via `.exclusively(before:)` instead of
        // splitting single-tap (attached by the caller, outside this view) from double-tap
        // (attached in here) across two different nodes in the hierarchy -- two independently
        // attached recognizers at different levels is fragile in SwiftUI's gesture arbitration
        // and can swallow the double-tap before it ever resolves.
        .gesture(
            TapGesture(count: 2).onEnded {
                if !vm.bulkMode { onOpen() }
            }
            .exclusively(before: TapGesture(count: 1).onEnded { onSelect() })
        )
        .contextMenu { contextMenu }
        .sheet(isPresented: $showMetadataInspector) { MetadataInspectorView(comicId: comic.id) }
        .alert("New Reading Path", isPresented: $showNewRunPrompt) {
            TextField("Name", text: $newRunTitle)
            Button("Create") {
                let trimmed = newRunTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let runId = vm.createRun(title: trimmed, description: "")
                vm.addToRun(runId: runId, comicIds: [comic.id])
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Tier List", isPresented: $showNewTierListPrompt) {
            TextField("Name", text: $newTierListTitle)
            Button("Create") {
                let trimmed = newTierListTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let listId = vm.createTierList(title: trimmed, description: "")
                vm.addToTierList(tierListId: listId, comicIds: [comic.id])
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { loadThumbnail() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(vm.bulkMode ? "Double-tap to toggle selection" : "Double-tap to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { if !vm.bulkMode { onOpen() } }
        .accessibilityAction(named: comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            vm.toggleFavorite(comic)
        }
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            Design.cardBg
            if let img = thumbnail {
                Image(platformImage: img).comicCoverStyle()
                    .frame(width: cardWidth, height: cardHeight)
                    .heroGeometry(id: comic.id, in: readerNamespace)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                    Text(comic.series).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 4)
                }
            }
        }
    }

    private var progressStrip: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.35)).frame(height: 4)
                Rectangle().fill(Color.accentColor)
                    .frame(width: cardWidth * comic.progressPercent, height: 4)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .allowsHitTesting(false)
    }

    private var finishedBadge: some View {
        ZStack {
            Circle().fill(Color.green).frame(width: 22, height: 22)
            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
        }
        .padding(6)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if vm.bulkMode {
            Button(isBulkSelected ? "Deselect" : "Select") { vm.toggleSelection(comic.id) }
            Button("Select All") { vm.selectAll() }
            Divider()
            Button("Exit Selection Mode") { vm.toggleBulkMode() }
        } else {
            Button("Read") { onOpen() }
            Button("View Details") { vm.selectedComic = comic }

            Divider()

            Button(comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                vm.toggleFavorite(comic)
            }
            Button(comic.inReadingList ? "Remove from Reading List" : "Add to Reading List") {
                vm.toggleReadingList(comic)
            }

            Menu("Add to Reading Path") {
                ForEach(vm.runs) { run in
                    Button(run.title) { vm.addToRun(runId: run.id, comicIds: [comic.id]) }
                }
                if !vm.runs.isEmpty { Divider() }
                Button("New Reading Path…") { newRunTitle = ""; showNewRunPrompt = true }
            }
            Menu("Add to Tier List") {
                ForEach(vm.tierLists) { list in
                    Button(list.title) { vm.addToTierList(tierListId: list.id, comicIds: [comic.id]) }
                }
                if !vm.tierLists.isEmpty { Divider() }
                Button("New Tier List…") { newTierListTitle = ""; showNewTierListPrompt = true }
            }

            Divider()

            if comic.isFinished {
                Button("Mark as Unread") { vm.markUnread(comic) }
            } else {
                Button("Mark as Read")   { vm.markRead(comic) }
            }

            Divider()

            Button("Set as Series Cover") { vm.setSeriesCover(comic) }
            Button("Select Multiple")     { vm.toggleBulkMode() }
            Button("Metadata Inspector…") { showMetadataInspector = true }

            Divider()

            #if os(macOS)
            Button("Show in Finder") {
                fileService.revealInFinder(URL(fileURLWithPath: comic.filePath))
            }
            #endif
            ShareLink("Share", item: URL(fileURLWithPath: comic.filePath))

            Divider()

            Button("Delete", role: .destructive) { vm.delete([comic], fileService: fileService) }
        }
    }

    private var accessibilityDescription: String {
        var parts = [comic.title, comic.series, comic.publisher]
        if comic.rating > 0 { parts.append("\(comic.rating) stars") }
        if comic.isFinished { parts.append("Finished") }
        else if comic.isStarted { parts.append("Page \(comic.progress + 1) of \(comic.pageCount)") }
        else { parts.append("Unread") }
        if comic.isFavorite { parts.append("Favorited") }
        if vm.bulkMode { parts.append(isBulkSelected ? "Selected" : "Not selected") }
        return parts.joined(separator: ", ")
    }

    private func loadThumbnail() {
        ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
        ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
    }
}
