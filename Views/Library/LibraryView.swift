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

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar()
            Rectangle().fill(Design.borderColor).frame(height: 1)

            // Previously slid in/out directionally (trailing on drill-in, leading on
            // navigateBack()) -- that read as an unwanted "sliding" motion, so this now just
            // relies on the plain crossfade SwiftUI defaults to under the existing
            // `withAnimation(Design.springGentle)` wrapping each browseLevel change.
            switch vm.browseLevel {
            case .characters:   CharacterGroupGridView()
            case .seriesGroups: SeriesGroupGridView()
            case .issues:       LibraryGridView()
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { gridWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in gridWidth = w }
            }
        )
        .libraryAmbientBackground(tint: vm.activePublisher.map { Design.publisherColor($0) } ?? Design.warmSpotlightDefault)
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
    // The heading a user sees at the top of every browsing screen -- worth scaling with Dynamic
    // Type even though most of this bar's smaller chrome text stays fixed-size.
    @ScaledMetric(relativeTo: .title2) private var headingSize: CGFloat = 22

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

                    // The Continue Reading/Read Next/On This Day/Recommended shelves only ever
                    // render at the top-level character grid -- previously the only way back to
                    // them from several levels deep was clicking "Go back" repeatedly. One tap
                    // back to the top of Library, not a duplicate copy of the shelves themselves.
                    if vm.selectedSection == .library {
                        Button { vm.select(.library) } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Design.brandGold)
                        }
                        .buttonStyle(.plain)
                        .help("Back to Library home (Continue Reading, Recommended, and more)")
                        .accessibilityLabel("Back to Library home")
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headingTitle)
                        .font(.system(size: headingSize, weight: .black))
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
