import SwiftUI

extension Notification.Name {
    static let showTutorial        = Notification.Name("showTutorial")
    static let showReaderShortcuts = Notification.Name("showReaderShortcuts")
    static let triggerImport       = Notification.Name("triggerImport")
}

// MARK: - Content view (root)

struct ContentView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.windowService) private var windowService
    @Environment(\.fileService)   private var fileService

    @AppStorage("tutorialSeen") private var tutorialSeen = false
    @State private var showTutorial = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all


    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 300)
            } detail: {
                detailContent
                    .id(vm.selectedSection)
                    .toolbar(id: "main") { mainToolbar }
            }
            .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search library…")
            .navigationSplitViewStyle(.balanced)

            if let comic = vm.readerComic {
                ReaderView(comic: comic) {
                    withAnimation(.easeInOut(duration: 0.25)) { vm.readerComic = nil }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            if showTutorial {
                TutorialView {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showTutorial = false
                        tutorialSeen = true
                    }
                }
                .transition(.opacity)
                .zIndex(20)
            }

            // Undo toast — floats above whatever's on screen (Library, Runs, Duplicates all
            // trigger it) rather than living in the sidebar like the scan-report banner, since
            // deletions happen throughout the app, not just from sidebar-adjacent actions.
            if let action = vm.pendingUndo {
                VStack {
                    Spacer()
                    undoToast(action)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(30)
                .allowsHitTesting(true)
            }
        }
        .animation(Design.springGentle, value: vm.pendingUndo?.message)
        // Every theme but Sepia is dark; forcing .dark unconditionally made Sepia render its
        // light card/background colors underneath dark-scheme system chrome (text fields,
        // scrollbars, etc.), which looks broken rather than like a real light theme.
        .preferredColorScheme(AppTheme.current.isLight ? .light : .dark)
        .frame(minWidth: 960, minHeight: 640)
        .animation(.easeInOut(duration: 0.2), value: vm.readerComic?.id)
        .onChange(of: vm.readerComic?.id) { _, newId in
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = newId != nil ? .detailOnly : .all
            }
        }
        .onAppear {
            windowService.configureMainWindow()
            if !tutorialSeen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation { showTutorial = true }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            withAnimation { showTutorial = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerImport)) { _ in
            importFiles()
        }
        .sheet(isPresented: $vm.showSeriesManager) {
            if let series = vm.selectedSeries {
                SeriesManagerView(series: series, publisher: vm.activePublisher)
                    .environmentObject(vm)
            }
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            Task { await handleWindowDrop(providers) }
            return true
        }
    }

    private func undoToast(_ action: LibraryViewModel.UndoableAction) -> some View {
        HStack(spacing: 14) {
            Text(action.message)
                .font(.callout).foregroundStyle(.white)
                .lineLimit(1)
            Button("Undo") { vm.performUndo() }
                .font(.callout.bold())
                .foregroundStyle(Design.brandGold)
                .buttonStyle(.plain)
            Button {
                vm.dismissUndo()
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    // MARK: - Detail content router

    @ViewBuilder
    private var detailContent: some View {
        switch vm.selectedSection {
        case .library, .continueReading, .favorites, .readingList:
            if let comic = vm.selectedComic {
                IssueDetailPage(comic: comic, onBack: { vm.selectedComic = nil })
                    .id(comic.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.2), value: vm.selectedComic?.id)
            } else {
                LibraryBrowserView()
            }
        case .runs:
            runsContent
        case .stats:
            StatsView()
        case .history:
            ReadingHistoryView()
        case .duplicates:
            DuplicatesView()
        case .settings:
            SettingsView()
        }
    }

    private var runsContent: some View {
        HStack(spacing: 0) {
            RunsListView(selectedRun: $vm.selectedRun)
                .frame(width: 320)
                .background(Design.navBackground)
            Rectangle().fill(Design.borderColor).frame(width: 1)
            if let run = vm.selectedRun {
                RunDetailView(run: run, onDelete: { vm.selectedRun = nil })
                    .frame(maxWidth: .infinity)
                    .background(Design.appBackground)
            } else {
                runsPlaceholder
            }
        }
    }

    private var runsPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 52)).foregroundStyle(.quaternary)
            Text("Select a Reading Order")
                .font(.title3.bold()).foregroundStyle(.secondary)
            Text("Group comics into reading orders to track multi-series arcs.")
                .font(.subheadline).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.appBackground)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "scan", placement: .primaryAction) {
            scanToolbarItem
        }

        // Resync library (rescan + re-derive metadata) — the fix for "ordering/metadata
        // looks wrong" was previously only reachable by opening Settings and finding a
        // buried button, or knowing a menu-bar shortcut existed. Now it's one click from
        // the main window at all times.
        ToolbarItem(id: "resync", placement: .primaryAction) {
            resyncToolbarItem
        }

        ToolbarItem(id: "import", placement: .primaryAction) {
            Button { importFiles() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import comic files (⌘O)")
        }

        // Grid density (library only). Hidden via opacity/disabled rather than omitted
        // outright — a conditionally-omitted ToolbarItem collapses to zero width, which
        // visibly shifts every item after it (Bulk select, Settings) left or right every
        // time you navigate in or out of the library section.
        ToolbarItem(id: "density", placement: .primaryAction) {
            DensityPicker()
                .opacity(isLibrarySection ? 1 : 0)
                .disabled(!isLibrarySection)
                .allowsHitTesting(isLibrarySection)
        }

        // Bulk select (issue level only) — same fixed-width treatment as density above.
        ToolbarItem(id: "bulk", placement: .primaryAction) {
            let show = vm.browseLevel == .issues && isLibrarySection && vm.selectedComic == nil
            Button { vm.toggleBulkMode() } label: {
                Image(systemName: vm.bulkMode ? "checklist.checked" : "checklist")
            }
            .foregroundStyle(vm.bulkMode ? Design.brandBlue : .primary)
            .help(vm.bulkMode ? "Exit selection mode" : "Select multiple comics (⌘E)")
            .opacity(show ? 1 : 0)
            .disabled(!show)
            .allowsHitTesting(show)
        }

        // Settings is a real in-app page (see detailContent), not the macOS Settings{}
        // scene — consistent with Stats/History/Runs.
        #if os(macOS)
        ToolbarItem(id: "settings", placement: .primaryAction) {
            Button { vm.select(.settings) } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
        }
        #endif
    }

    @ViewBuilder
    private var scanToolbarItem: some View {
        if vm.isScanning {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65).tint(Design.brandGold)
                Text("\(vm.scanState.done)/\(vm.scanState.total)")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Cancel") { LibraryScanner.shared.cancel() }
                    .controlSize(.mini)
            }
        } else {
            Button { vm.scan() } label: {
                // "folder.badge.magnifyingglass" isn't a real SF Symbol — it silently
                // rendered as a blank circle with no glyph at all, making Scan look broken
                // and indistinguishable from Resync right next to it.
                Label("Scan", systemImage: "magnifyingglass")
            }
            .help("Scan library folder for new comics (⇧⌘R)")
            .disabled(vm.libraryPath.isEmpty)
        }
    }

    @ViewBuilder
    private var resyncToolbarItem: some View {
        if vm.isResyncing {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65).tint(Design.brandGold)
                Text("Resyncing…").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Button { vm.resyncLibrary() } label: {
                Label("Resync", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Rescan and re-derive metadata for every comic — fixes wrong reading order or metadata (⌥⇧⌘R)")
            .disabled(vm.libraryPath.isEmpty || vm.isScanning)
        }
    }

    private var isLibrarySection: Bool {
        let s = vm.selectedSection
        return s == .library || s == .continueReading || s == .favorites || s == .readingList
    }

    // MARK: - Import

    private func importFiles() {
        fileService.pickFiles(
            allowsMultiple: true,
            message: "Select comic files to import into your library",
            prompt: "Import"
        ) { urls in if !urls.isEmpty { vm.importFiles(urls) } }
    }

    private func handleWindowDrop(_ providers: [NSItemProvider]) async {
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
        let supported: Set<String> = ["cbz", "cbr", "pdf"]
        let comics = urls.filter { supported.contains($0.pathExtension.lowercased()) }
        if !comics.isEmpty { vm.importFiles(comics) }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @State private var draggedPublisher: String?
    @State private var dropTargetPublisher: String?

    private var visibleDiscoverItems: [DiscoverItem] {
        let hidden = SidebarCustomization.decodeHidden(discoverHiddenRaw)
        return SidebarCustomization.decodeOrder(discoverOrderRaw).filter { !hidden.contains($0) }
    }

    var body: some View {
        List {
            Section {
                navRow("Library",          icon: "books.vertical.fill", item: .library)
                navRow("Continue Reading", icon: "book.open.fill",       item: .continueReading)
                navRow("Favorites",        icon: "heart.fill",           item: .favorites)
                navRow("Reading List",     icon: "bookmark.fill",        item: .readingList)
            }

            if !vm.publishers.isEmpty {
                Section("Publishers") {
                    ForEach(vm.publishers, id: \.self) { pub in
                        let isTarget = dropTargetPublisher == pub && draggedPublisher != pub
                        navRow(pub, publisherColor: Design.publisherColor(pub), item: .publisher(pub))
                            .onDrag {
                                draggedPublisher = pub
                                return NSItemProvider(object: NSString(string: pub))
                            }
                            .onDrop(of: [.plainText],
                                    isTargeted: Binding(
                                        get: { isTarget },
                                        set: { active in dropTargetPublisher = active ? pub : nil }
                                    )) { _, _ in
                                guard let from = draggedPublisher else { return false }
                                vm.movePublisher(from: from, to: pub)
                                draggedPublisher = nil; dropTargetPublisher = nil
                                return true
                            }
                            // An overlay rather than a second .listRowBackground call — navRow
                            // already sets one for selection highlighting, and a later
                            // .listRowBackground on the same row would replace it outright
                            // (List reads only the outermost one), silently breaking the
                            // selected-row highlight whenever it isn't also a drop target.
                            .overlay(alignment: .bottom) {
                                if isTarget {
                                    Rectangle().fill(Design.brandGold).frame(height: 2)
                                }
                            }
                    }
                }
            }

            if !vm.allTags.isEmpty {
                Section("Tags") {
                    ForEach(vm.allTags.prefix(15), id: \.tag.id) { t in
                        navRow("#\(t.tag.name)", icon: "tag", item: .tag(t.tag.name), trailingText: "\(t.count)")
                    }
                }
            }

            Section {
                ForEach(visibleDiscoverItems) { discoverItem in
                    if discoverItem == .duplicates {
                        if !vm.duplicateGroups.isEmpty {
                            navRow(discoverItem.title, icon: discoverItem.icon, item: discoverItem.destination,
                                   trailingText: "\(vm.duplicateGroups.count)")
                        }
                    } else {
                        navRow(discoverItem.title, icon: discoverItem.icon, item: discoverItem.destination)
                    }
                }
            }

            // Settings row behaves like every other sidebar destination, not a separate window.
            #if os(macOS)
            Section {
                navRow("Settings", icon: "gearshape", item: .settings)
            }
            #endif
        }
        .listStyle(.sidebar)
        .navigationTitle("ComicArc")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !vm.isLibraryAvailable {
                    libraryUnavailableBanner
                } else if let err = vm.scanState.error, !vm.isScanning {
                    scanErrorBanner(err)
                } else if vm.isScanning {
                    sidebarScanProgress
                } else if vm.showScanReport {
                    scanReportBanner
                }
            }
        }
    }

    // Single row builder used by every sidebar item — Button-based so taps always fire
    @ViewBuilder
    private func navRow(_ label: String,
                        icon: String? = nil,
                        publisherColor: Color? = nil,
                        item: AppDestination,
                        trailingText: String? = nil) -> some View {
        Button {
            // Publisher tap: second tap deselects → all comics
            if case .publisher(let p) = item, case .publisher(let cur) = vm.destination, p == cur {
                vm.select(.library)
            } else {
                vm.select(item)
            }
        } label: {
            HStack(spacing: 8) {
                if let color = publisherColor {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: 14, height: 14)
                } else if let icon {
                    Image(systemName: icon).frame(width: 16)
                }
                Text(label)
                Spacer()
                if case .continueReading = item, vm.inProgressComics.count > 0 {
                    Text("\(vm.inProgressComics.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.25)))
                        .foregroundStyle(.secondary)
                } else if let t = trailingText {
                    Text(t).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // Extra vertical padding so the tap target matches native Mac sidebar row height (~28pt).
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.destination == item
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor).padding(.horizontal, 4)
                : nil
        )
        .foregroundStyle(vm.destination == item ? Color.white : Color.primary)
        .accessibilityAddTraits(vm.destination == item ? [.isButton, .isSelected] : .isButton)
    }

    private var sidebarScanProgress: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                ProgressView(value: Double(vm.scanState.done),
                             total: max(1, Double(vm.scanState.total)))
                    .tint(Design.brandGold)
                Text("\(vm.scanState.done) of \(vm.scanState.total)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Design.navBackground)
    }

    private var libraryUnavailableBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Library unavailable")
                        .font(.caption.bold()).foregroundStyle(.primary)
                    Text("Drive may be disconnected")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    vm.retryAfterVolumeUnavailable()
                } label: {
                    Text("Retry").font(.caption2)
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Design.navBackground)
    }

    // Auto-dismissed a few seconds after appearing; only shown when the scan changed something.
    private var scanReportBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Design.brandGold).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library Updated").font(.caption.bold()).foregroundStyle(.primary)
                    Text(scanReportLine).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { vm.dismissScanReport() } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Design.navBackground)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var scanReportLine: String {
        let s = vm.scanState
        var parts: [String] = []
        if s.added > 0     { parts.append("\(s.added) added") }
        if s.removed > 0   { parts.append("\(s.removed) missing") }
        if s.recovered > 0 { parts.append("\(s.recovered) recovered") }
        if s.stillCorrupted > 0 { parts.append("\(s.stillCorrupted) unreadable") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func scanErrorBanner(_ message: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
                Text(message)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Design.navBackground)
    }
}
