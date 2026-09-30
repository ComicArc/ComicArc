#if os(iOS) || os(visionOS)
import SwiftUI

struct iPadRootView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedComic: Comic?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showRenameFilesGlobal = false
    // Shared with every comic cover rendered inside the split view below (`ComicCard`,
    // `IssueDetailPage`, etc. all already read `@Environment(\.readerNamespace)`) so the reader's
    // own hero-cover layer can `matchedGeometryEffect` against whichever cover was on screen.
    // Previously unset on iPad -- the Mac-only reason the grid-to-reader hero morph existed only
    // on one platform wasn't the reader itself, it was this namespace never being injected here.
    @Namespace private var readerNamespace

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                iPadSidebar()
                    .navigationTitle("ComicArc")
            } content: {
                iPadContentColumn(selectedComic: $selectedComic)
                    .id(vm.destination)
            } detail: {
                iPadDetailColumn(comic: selectedComic)
            }
            .navigationSplitViewStyle(.balanced)
            .searchable(text: $vm.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library…")
            .onChange(of: vm.destination) { selectedComic = nil }
            .environment(\.readerNamespace, readerNamespace)

            // A same-hierarchy overlay instead of `.fullScreenCover(item:)` -- a system sheet/cover
            // presentation is a separate view-controller-level transition that can't participate in
            // a `matchedGeometryEffect` with the grid underneath, which is exactly why the hero
            // cover morph (see `iPadReaderView`) could never work on iPad while this used
            // `fullScreenCover`. Mirrors the Mac reader's identical ZStack-overlay presentation in
            // `ContentView.swift`, a pattern already proven there.
            if let comic = vm.readerComic {
                iPadReaderView(comic: comic, runId: vm.readerRunId, onClose: { vm.closeReader() })
                    .environmentObject(vm)
                    // Same fix as the Mac reader: without this, swapping straight from one comic
                    // to another (e.g. advancing to the next issue) reuses this view's existing
                    // @State (currentPage, zoom, autoplay) instead of resetting it for the new comic.
                    .id(comic.id)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let action = vm.pendingUndo {
                VStack {
                    Spacer()
                    iPadUndoToast(action)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(true)
            }

            if let progress = vm.importProgress {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Importing \(progress.done) of \(progress.total)…")
                            .font(.callout).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if vm.showScanReport {
                VStack {
                    iPadScanReportBanner
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if vm.renameCandidateCount > 0, !vm.renameSuggestionDismissed {
                VStack {
                    iPadRenameSuggestionBanner
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.pendingUndo?.message)
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.importProgress)
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.showScanReport)
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.renameCandidateCount)
        .onReceive(NotificationCenter.default.publisher(for: .triggerRenameFiles)) { _ in
            showRenameFilesGlobal = true
        }
        .sheet(isPresented: $showRenameFilesGlobal) {
            RenameFilesView().environmentObject(vm)
        }
        .alert(
            "Import Complete",
            isPresented: Binding(
                get: { vm.lastImportSummary != nil },
                set: { if !$0 { vm.lastImportSummary = nil } }
            ),
            presenting: vm.lastImportSummary
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { summary in
            Text(iPadImportSummaryMessage(summary))
        }
        // See the matching comment on Mac's ContentView -- most of this app's text uses fixed-
        // size fonts rather than semantic text styles, so a full Dynamic Type migration is a
        // larger change than this pass can safely make. Capping the range keeps a moderately
        // larger text preference usable without the most extreme accessibility sizes breaking
        // this app's fixed-width grids.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func iPadImportSummaryMessage(_ summary: LibraryViewModel.ImportSummary) -> String {
        var parts: [String] = []
        if summary.added > 0 { parts.append("\(summary.added) imported") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) already in your library") }
        if !summary.failures.isEmpty {
            let names = summary.failures.prefix(3).map { "\($0.name) (\($0.reason))" }.joined(separator: ", ")
            let more = summary.failures.count > 3 ? ", and \(summary.failures.count - 3) more" : ""
            parts.append("\(summary.failures.count) failed: \(names)\(more)")
        }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: ". ") + "."
    }

    private var iPadScanReportBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Design.brandGold).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Library Updated").font(.caption.bold()).foregroundStyle(.white)
                Text(iPadScanReportLine).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            Button { vm.dismissScanReport() } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    private var iPadRenameSuggestionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "textformat")
                .foregroundStyle(Design.brandBlue).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Filenames Could Be Cleaned Up").font(.caption.bold()).foregroundStyle(.white)
                Text("\(vm.renameCandidateCount) file\(vm.renameCandidateCount == 1 ? "" : "s") don't match the library's naming convention.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            Button("Review") { showRenameFilesGlobal = true }
                .font(.caption.bold())
                .foregroundStyle(Design.brandGold)
                .buttonStyle(.plain)
            Button { vm.dismissRenameSuggestion() } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    private var iPadScanReportLine: String {
        let s = vm.scanState
        var parts: [String] = []
        if s.added > 0     { parts.append("\(s.added) added") }
        if s.removed > 0   { parts.append("\(s.removed) missing") }
        if s.recovered > 0 { parts.append("\(s.recovered) recovered") }
        if s.stillCorrupted > 0 { parts.append("\(s.stillCorrupted) unreadable") }
        return parts.joined(separator: ", ")
    }

    private func iPadUndoToast(_ action: UndoToastController.Action) -> some View {
        HStack(spacing: 14) {
            Text(action.message)
                .font(.callout).foregroundStyle(.white)
                .lineLimit(1)
            if action.undo != nil {
                Button("Undo") { vm.performUndo() }
                    .font(.callout.bold())
                    .foregroundStyle(Design.brandGold)
                    .buttonStyle(.plain)
            }
            Button {
                vm.dismissUndo()
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

private struct iPadSidebar: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @State private var draggedPublisher: String?
    @State private var showAllTags = false

    private var visibleDiscoverItems: [DiscoverItem] {
        SidebarCustomization.visibleItems(orderRaw: discoverOrderRaw, hiddenRaw: discoverHiddenRaw)
    }

    var body: some View {
        List(selection: Binding(
            get: { Optional(vm.destination) },
            set: { if let d = $0 { vm.select(d) } }
        )) {
            Section("Library") {
                ForEach([AppDestination.library, .continueReading, .favorites, .runs], id: \.self) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            if !vm.publishers.isEmpty {
                Section("Publishers") {
                    ForEach(vm.publishers, id: \.self) { pub in
                        Label(pub, systemImage: "building.columns")
                            .foregroundStyle(Design.publisherColor(pub))
                            .tag(AppDestination.publisher(pub))
                            .onDrag {
                                draggedPublisher = pub
                                return NSItemProvider(object: NSString(string: pub))
                            }
                            .onDrop(of: [.plainText], isTargeted: nil) { _, _ in
                                guard let from = draggedPublisher else { return false }
                                vm.movePublisher(from: from, to: pub)
                                draggedPublisher = nil
                                return true
                            }
                            // Keyboard/VoiceOver alternative to the drag reorder above -- onDrag/
                            // onDrop alone has no accessible fallback for a user who can't drag.
                            .accessibilityAction(named: "Move Up") {
                                guard let idx = vm.publishers.firstIndex(of: pub), idx > 0 else { return }
                                vm.movePublisher(from: pub, to: vm.publishers[idx - 1])
                            }
                            .accessibilityAction(named: "Move Down") {
                                guard let idx = vm.publishers.firstIndex(of: pub), idx + 1 < vm.publishers.count else { return }
                                vm.movePublisher(from: pub, to: vm.publishers[idx + 1])
                            }
                    }
                }
            }
            if !vm.allTags.isEmpty {
                Section("Tags") {
                    ForEach(vm.allTags.prefix(15), id: \.tag.id) { t in
                        Label("#\(t.tag.name)", systemImage: "tag")
                            .tag(AppDestination.tag(t.tag.name))
                            .badge(t.count)
                    }
                    Button("See All Tags…") { showAllTags = true }
                }
            }
            Section("Discover") {
                ForEach(visibleDiscoverItems) { item in
                    if item == .libraryHealth {
                        Label(item.title, systemImage: item.icon)
                            .tag(item.destination)
                            .badge(vm.libraryHealthAlertCount)
                    } else {
                        Label(item.title, systemImage: item.icon).tag(item.destination)
                    }
                }
            }
            Section {
                Label(AppDestination.settings.title, systemImage: AppDestination.settings.icon)
                    .tag(AppDestination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !vm.isLibraryAvailable {
                libraryUnavailableBanner
            } else if let err = vm.scanState.error, !vm.isScanning {
                scanErrorBanner(err)
            }
        }
        .sheet(isPresented: $showAllTags) {
            AllTagsView().environmentObject(vm)
        }
    }

    private var libraryUnavailableBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Text("Library folder unavailable")
                    .font(.caption.bold())
                Spacer()
            }
            Button("Retry") { vm.retryAfterVolumeUnavailable() }
                .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func scanErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption)
            Text(message).font(.caption2).lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial)
    }
}

private struct iPadReadNextShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                Text("READ NEXT")
                    .font(.system(size: 13, weight: .black))
                    .kerning(1.5)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.readNextSuggestions) { comic in
                        Button {
                            vm.openReader(comic)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MiniComicCard(comic: comic)
                                    .frame(width: 90, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(comic.title)
                                    .font(.caption2).lineLimit(2)
                                    .frame(width: 90, alignment: .leading)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(comic.title)
                        .accessibilityHint("Double-tap to start reading")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
    }
}

struct iPadContentColumn: View {
    @Binding var selectedComic: Comic?
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Group {
            switch vm.destination {
            case .library, .continueReading, .favorites, .publisher, .tag:
                VStack(spacing: 0) {
                    // Mac shows Read Next as an inline shelf on its home grid; iPad's
                    // library view is a flat grid with no natural "home" section, so it's shown here
                    // only on the plain .library destination rather than every filtered view.
                    if case .library = vm.destination, !vm.readNextSuggestions.isEmpty {
                        iPadReadNextShelf()
                    }
                    iPadComicGrid(comics: vm.comics, selectedComic: $selectedComic)
                }
                .navigationTitle(vm.destination.title)
            case .stats:
                StatsView().environmentObject(vm)
                    .navigationTitle("Stats")
            case .runs:
                RunsView().environmentObject(vm)
                    .navigationTitle("Reading Paths")
            case .favoriteMoments:
                FavoriteMomentsView().environmentObject(vm)
                    .navigationTitle("Highlights")
            case .libraryHealth:
                LibraryHealthView().environmentObject(vm)
                    .navigationTitle("Library Health")
            case .settings:
                SettingsView()
                    .navigationTitle("Settings")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.scan() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isBusy)
                .accessibilityLabel("Rescan Library")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.resyncLibrary() }) {
                    if vm.isResyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(vm.isBusy || vm.libraryPaths.isEmpty)
                .accessibilityLabel("Resync Library")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                iPadImportButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                FilterPicker()
            }
        }
    }
}

#endif
