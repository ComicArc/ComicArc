import SwiftUI
import UniformTypeIdentifiers

struct LibraryGridView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    @State private var draggedId:   Int64? = nil
    @State private var dropTargetId: Int64? = nil
    @State private var groupMoodColor: Color?

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
        // Same themed backdrop as the character screen you drilled in from -- only when actually
        // scoped to a character (`vm.selectedGroup`); the plain top-level Library/Favorites/
        // Continue Reading/Reading List sections keep the neutral `libraryAmbientBackground()`
        // their parent `LibraryBrowserView` already provides, nothing layered on top. Also
        // injects the detected theme into the environment so every `ComicCard` inside picks up
        // its hover spotlight/lift/shadow automatically.
        .background {
            if let group = vm.selectedGroup {
                ThemeBackdrop(name: group.groupName, color: groupMoodColor)
            }
        }
        .environment(\.comicTheme, vm.selectedGroup.map {
            ComicTheme.detect(name: $0.groupName, color: groupMoodColor)
        } ?? .library)
        .onAppear { loadSelectedGroupMoodColor(vm.selectedGroup, into: $groupMoodColor) }
        .onChange(of: vm.selectedGroup?.id) { _, _ in loadSelectedGroupMoodColor(vm.selectedGroup, into: $groupMoodColor) }
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
        EmptyStateView(icon: emptyIcon, title: emptyTitle, message: emptyMessage, illustration: emptyIllustration) {
            emptyAction
        }
    }

    private var emptyIllustration: AnyView? {
        switch vm.selectedSection {
        case .continueReading, .favorites, .readingList: return nil
        default:
            if vm.activeTag != nil || vm.activePublisher != nil { return nil }
            if !vm.searchText.isEmpty { return AnyView(SpeechBubbleQuestionIllustration()) }
            if vm.libraryPaths.isEmpty { return nil }
            return AnyView(LongBoxesIllustration())
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
            return "Your Shelf Is Empty"
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
            return "Drop CBZ, CBR, or PDF files here to start stocking your shelves."
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
