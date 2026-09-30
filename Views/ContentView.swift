import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let showReaderShortcuts = Notification.Name("showReaderShortcuts")
    static let triggerImport       = Notification.Name("triggerImport")
    static let triggerRenameFiles  = Notification.Name("triggerRenameFiles")
    static let readerDidClose      = Notification.Name("readerDidClose")
    static let triggerPrint        = Notification.Name("triggerPrint")
    static let triggerBulkDelete   = Notification.Name("triggerBulkDelete")
}

struct ContentView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.windowService) private var windowService
    @Environment(\.fileService)   private var fileService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showRenameFiles = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Namespace private var readerNamespace

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
                ReaderView(comic: comic, initialPage: vm.readerInitialPage, runId: vm.readerRunId) {
                    vm.closeReader()
                } onOpenComic: { next in
                    vm.openReader(next, runId: vm.readerRunId)
                }
                // Ties this view's identity to the comic itself rather than just to the `if`
                // branch -- without it, a future reassignment of readerComic straight from one
                // comic to another (skipping the nil in between) would carry over ReaderView's
                // @State (currentPage, zoom, bookmarks) into the new comic instead of resetting.
                .id(comic.id)
                .transition(.opacity)
                .zIndex(10)
            }


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

            if let progress = vm.importProgress {
                VStack {
                    Spacer()
                    importProgressToast(progress)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(30)
                .allowsHitTesting(false)
            }
        }
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.pendingUndo?.message)
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.importProgress)
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
            Text(importSummaryMessage(summary))
        }

        .preferredColorScheme(AppTheme.current.isLight ? .light : .dark)
        // Most of the app's text uses fixed-size fonts, not semantic text styles, so it doesn't
        // scale with Dynamic Type -- a real gap, but fully migrating every font in the app to
        // scale correctly is a much larger change than this pass can safely make. Capping the
        // range (rather than leaving it fully unbounded) means a user with a moderately larger
        // text size preference still gets what DOES scale (native controls, semantic-styled
        // text already used in several screens) without the most extreme accessibility sizes
        // visually breaking this app's fixed-width card grids and toolbars.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(minWidth: 960, minHeight: 640)
        .environment(\.readerNamespace, readerNamespace)
        .animation(Design.motion(Design.springGentle, reduce: reduceMotion), value: vm.readerComic?.id)
        .onChange(of: vm.readerComic?.id) { _, newId in
            withAnimation(Design.motion(.easeInOut(duration: 0.25), reduce: reduceMotion)) {
                columnVisibility = newId != nil ? .detailOnly : .all
            }
        }
        .onAppear { windowService.configureMainWindow() }
        .onReceive(NotificationCenter.default.publisher(for: .triggerImport)) { _ in
            importFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerRenameFiles)) { _ in
            showRenameFiles = true
        }
        .sheet(isPresented: $vm.showSeriesManager) {
            if let series = vm.selectedSeries {
                SeriesManagerView(series: series, publisher: vm.activePublisher)
                    .environmentObject(vm)
            }
        }
        .sheet(isPresented: $showRenameFiles) {
            RenameFilesView().environmentObject(vm)
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            Task { await handleWindowDrop(providers) }
            return true
        }
    }

    private func undoToast(_ action: UndoToastController.Action) -> some View {
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

    private func importProgressToast(_ progress: LibraryViewModel.ImportProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(.white)
            Text("Importing \(progress.done) of \(progress.total)…")
                .font(.callout).foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func importSummaryMessage(_ summary: LibraryViewModel.ImportSummary) -> String {
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

    @ViewBuilder
    private var detailContent: some View {
        switch vm.selectedSection {
        case .library, .continueReading, .favorites:
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
        case .favoriteMoments:
            FavoriteMomentsView()
        case .stats:
            StatsView()
        case .libraryHealth:
            LibraryHealthView()
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
                    .ambientBackground()
            } else {
                runsPlaceholder
            }
        }
    }

    private var runsPlaceholder: some View {
        EmptyStateView(
            icon: "list.bullet.rectangle",
            title: "Select a Reading Path",
            message: "Group comics into reading paths to track multi-series arcs."
        )
        .ambientBackground()
    }

    @ToolbarContentBuilder
    private var mainToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "scan", placement: .primaryAction) {
            scanToolbarItem
        }

        ToolbarItem(id: "import", placement: .primaryAction) {
            Button { importFiles() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import comic files (⌘O)")
        }

        ToolbarItem(id: "density", placement: .primaryAction) {
            DensityPicker()
                .opacity(isLibrarySection ? 1 : 0)
                .disabled(!isLibrarySection)
                .allowsHitTesting(isLibrarySection)
        }

        ToolbarItem(id: "sort", placement: .primaryAction) {
            SortPicker()
                .opacity(isLibrarySection ? 1 : 0)
                .disabled(!isLibrarySection)
                .allowsHitTesting(isLibrarySection)
        }

        ToolbarItem(id: "filter", placement: .primaryAction) {
            FilterPicker()
                .opacity(isLibrarySection ? 1 : 0)
                .disabled(!isLibrarySection)
                .allowsHitTesting(isLibrarySection)
        }

        ToolbarItem(id: "bulk", placement: .primaryAction) {
            let show = vm.browseLevel == .issues && isLibrarySection && vm.selectedComic == nil
            Button { vm.toggleBulkMode() } label: {
                Label(vm.bulkMode ? "Exit Selection" : "Select Multiple",
                      systemImage: vm.bulkMode ? "checklist.checked" : "checklist")
            }
            .foregroundStyle(vm.bulkMode ? Design.brandBlue : .primary)
            .help(vm.bulkMode ? "Exit selection mode" : "Select multiple comics (⌘E)")
            .opacity(show ? 1 : 0)
            .disabled(!show)
            .allowsHitTesting(show)
        }
    }

    @ViewBuilder
    private var scanToolbarItem: some View {
        if vm.isResyncing {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65).tint(Design.brandGold)
                Text("Resyncing…").font(.caption2).foregroundStyle(.secondary)
            }
        } else if vm.isScanning {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65).tint(Design.brandGold)
                Text("\(vm.scanState.done)/\(vm.scanState.total)")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Cancel") { LibraryScanner.shared.cancel() }
                    .controlSize(.mini)
            }
        } else {
            Button { vm.scan() } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Scan library folders for new comics (⇧⌘R)")
            .disabled(vm.libraryPaths.isEmpty)
        }
    }

    private var isLibrarySection: Bool {
        let s = vm.selectedSection
        return s == .library || s == .continueReading || s == .favorites
    }

    private func importFiles() {
        let types: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .zip,
            UTType(filenameExtension: "cbr") ?? .archive,
            .pdf, .image
        ]
        fileService.pickFiles(
            allowsMultiple: true,
            message: "Select comic files to import into your library",
            prompt: "Import",
            contentTypes: types
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
        let comics = urls.filter { LibraryScanner.importableExtensions.contains($0.pathExtension.lowercased()) }
        if !comics.isEmpty { vm.importFiles(comics) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @State private var draggedPublisher: String?
    @State private var dropTargetPublisher: String?
    @State private var showAllTags = false

    private var visibleDiscoverItems: [DiscoverItem] {
        SidebarCustomization.visibleItems(orderRaw: discoverOrderRaw, hiddenRaw: discoverHiddenRaw)
    }

    var body: some View {
        List {
            Section("Library") {
                navRow("Library",          icon: "books.vertical.fill", item: .library)
                navRow("Continue Reading", icon: "book.open.fill",       item: .continueReading)
                navRow("Favorites",        icon: "heart.fill",           item: .favorites)
                navRow("Reading Paths",    icon: "list.bullet.rectangle.portrait.fill", item: .runs)
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

                            .overlay(alignment: .bottom) {
                                if isTarget {
                                    Rectangle().fill(Design.brandGold).frame(height: 2)
                                }
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
                        navRow("#\(t.tag.name)", icon: "tag", item: .tag(t.tag.name), trailingText: "\(t.count)")
                    }
                    Button("See All Tags…") { showAllTags = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Design.brandGold)
                        .font(.caption)
                }
            }

            Section("Discover") {
                ForEach(visibleDiscoverItems) { discoverItem in
                    navRow(discoverItem.title, icon: discoverItem.icon, item: discoverItem.destination,
                           trailingText: discoverItem == .libraryHealth && vm.libraryHealthAlertCount > 0
                               ? "\(vm.libraryHealthAlertCount)" : nil)
                }
            }

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
                } else if vm.renameCandidateCount > 0, !vm.renameSuggestionDismissed {
                    renameSuggestionBanner
                }
            }
        }
        .sheet(isPresented: $showAllTags) {
            AllTagsView().environmentObject(vm)
        }
    }

    private func navRow(_ label: String,
                        icon: String? = nil,
                        publisherColor: Color? = nil,
                        item: AppDestination,
                        trailingText: String? = nil) -> some View {
        Button {
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
                if case .continueReading = item, vm.inProgressCount > 0 {
                    Text("\(vm.inProgressCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.25)))
                        .foregroundStyle(.secondary)
                } else if let t = trailingText {
                    Text(t).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.destination == item
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Design.brandGold.opacity(0.16))
                    .padding(.horizontal, 4)
                : nil
        )
        .foregroundStyle(vm.destination == item ? Design.brandGold : Color.primary)
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
                if let report = vm.libraryHealthReport, !report.isEmpty {
                    Button("Review \(report.totalCount) issue\(report.totalCount == 1 ? "" : "s")") {
                        vm.select(.libraryHealth)
                        vm.dismissScanReport()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Button { vm.dismissScanReport() } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Design.navBackground)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var renameSuggestionBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "textformat")
                    .foregroundStyle(Design.brandBlue).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filenames Could Be Cleaned Up").font(.caption.bold()).foregroundStyle(.primary)
                    Text("\(vm.renameCandidateCount) file\(vm.renameCandidateCount == 1 ? "" : "s") don't match the library's naming convention.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review") {
                    NotificationCenter.default.post(name: .triggerRenameFiles, object: nil)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button { vm.dismissRenameSuggestion() } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .accessibilityLabel("Dismiss")
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
