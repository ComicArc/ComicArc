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

            // Full-screen reader — covers the entire content area
            if let comic = vm.readerComic {
                ReaderView(comic: comic) {
                    withAnimation(.easeInOut(duration: 0.25)) { vm.readerComic = nil }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            // Tutorial overlay
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
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 640)
        .animation(.easeInOut(duration: 0.2), value: vm.readerComic?.id)
        // Sidebar hides only when reading; restores when the reader closes
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
        // Drag files onto window to import
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            Task { await handleWindowDrop(providers) }
            return true
        }
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
        case .creators:
            CreatorBrowseView()
        case .duplicates:
            DuplicatesView()
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
        // Scan library
        ToolbarItem(id: "scan", placement: .primaryAction) {
            scanToolbarItem
        }

        // Import files
        ToolbarItem(id: "import", placement: .primaryAction) {
            Button { importFiles() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import comic files (⌘O)")
        }

        // Separator
        ToolbarItem(id: "sep1", placement: .primaryAction) {
            Divider().frame(height: 16)
        }

        // Grid density (library only)
        ToolbarItem(id: "density", placement: .primaryAction) {
            if isLibrarySection { DensityPicker() }
        }

        // Bulk select (issue level only)
        ToolbarItem(id: "bulk", placement: .primaryAction) {
            if vm.browseLevel == .issues && isLibrarySection && vm.selectedComic == nil {
                Button { vm.toggleBulkMode() } label: {
                    Image(systemName: vm.bulkMode ? "checklist.checked" : "checklist")
                }
                .foregroundStyle(vm.bulkMode ? Design.brandBlue : .primary)
                .help(vm.bulkMode ? "Exit selection mode" : "Select multiple comics (⌘E)")
            }
        }
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
                Label("Scan", systemImage: "folder.badge.magnifyingglass")
            }
            .help("Scan library folder for new comics (⇧⌘R)")
            .disabled(vm.libraryPath.isEmpty)
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
                        navRow(pub, publisherColor: Design.publisherColor(pub), item: .publisher(pub))
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
                navRow("Reading Orders", icon: "list.bullet.rectangle.portrait.fill", item: .runs)
                navRow("Statistics",     icon: "chart.bar.xaxis",                     item: .stats)
                navRow("History",        icon: "clock.fill",                          item: .history)
                navRow("Creators",       icon: "person.2.fill",                       item: .creators)
                if !vm.duplicateGroups.isEmpty {
                    navRow("Possible Duplicates", icon: "square.stack.3d.up.badge.a", item: .duplicates,
                           trailingText: "\(vm.duplicateGroups.count)")
                }
            }
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
