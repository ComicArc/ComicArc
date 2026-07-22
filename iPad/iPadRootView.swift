#if os(iOS)
import SwiftUI

struct iPadRootView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var selectedComic: Comic?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showRenameFilesGlobal = false

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

            .fullScreenCover(item: $vm.readerComic) { comic in
                iPadReaderView(comic: comic, onClose: { vm.closeReader() })
                    .environmentObject(vm)
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

            if vm.showScanReport {
                VStack {
                    iPadScanReportBanner
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Design.springGentle, value: vm.pendingUndo?.message)
        .animation(Design.springGentle, value: vm.showScanReport)
        .onReceive(NotificationCenter.default.publisher(for: .triggerRenameFiles)) { _ in
            showRenameFilesGlobal = true
        }
        .sheet(isPresented: $showRenameFilesGlobal) {
            RenameFilesView().environmentObject(vm)
        }
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

    private func iPadUndoToast(_ action: LibraryViewModel.UndoableAction) -> some View {
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
}

private struct iPadSidebar: View {
    @EnvironmentObject var vm: LibraryViewModel
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @State private var draggedPublisher: String?

    private var visibleDiscoverItems: [DiscoverItem] {
        let hidden = SidebarCustomization.decodeHidden(discoverHiddenRaw)
        return SidebarCustomization.decodeOrder(discoverOrderRaw).filter { !hidden.contains($0) }
    }

    var body: some View {
        List(selection: Binding(
            get: { Optional(vm.destination) },
            set: { if let d = $0 { vm.select(d) } }
        )) {
            Section("Library") {
                ForEach([AppDestination.library, .continueReading, .favorites, .readingList], id: \.self) { s in
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
                }
            }
            Section("Discover") {
                ForEach(visibleDiscoverItems) { item in
                    if item == .duplicates {
                        if !vm.duplicateGroups.isEmpty {
                            Label(item.title, systemImage: item.icon)
                                .tag(item.destination)
                                .badge(vm.duplicateGroups.count)
                        }
                    } else if item == .readingOrderManager {
                        if !vm.autoPlacedIssues.isEmpty {
                            Label(item.title, systemImage: item.icon)
                                .tag(item.destination)
                                .badge(vm.autoPlacedIssues.count)
                        }
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

private struct iPadContentColumn: View {
    @Binding var selectedComic: Comic?
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Group {
            switch vm.destination {
            case .library, .continueReading, .favorites, .readingList, .publisher, .tag:
                iPadComicGrid(comics: vm.comics, selectedComic: $selectedComic)
                    .navigationTitle(vm.destination.title)
            case .stats:
                StatsView().environmentObject(vm)
                    .navigationTitle("Statistics")
            case .runs:
                RunsView().environmentObject(vm)
                    .navigationTitle("Reading Paths")
            case .history:
                ReadingHistoryView().environmentObject(vm)
                    .navigationTitle("History")
            case .duplicates:
                DuplicatesView().environmentObject(vm)
                    .navigationTitle("Possible Duplicates")
            case .readingOrderManager:
                ReadingOrderManagerView().environmentObject(vm)
                    .navigationTitle("Reading Order Suggestions")
            case .settings:
                iPadSettingsView()
                    .navigationTitle("Settings")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.scan() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isScanning || vm.isResyncing)
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
                .disabled(vm.isScanning || vm.isResyncing || vm.libraryPath.isEmpty)
                .accessibilityLabel("Resync Library")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                iPadImportButton()
            }
        }
    }
}

private struct iPadDetailColumn: View {
    let comic: Comic?
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Group {
            if let comic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        iPadComicHero(comic: comic)

                        HStack(spacing: 12) {
                            Button(action: { vm.openReader(comic) }) {
                                Label(comic.isStarted ? "Continue" : "Read", systemImage: "book.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isStarted ? "Continue reading \(comic.title)" : "Read \(comic.title)")

                            Button {
                                if comic.isFinished { vm.markUnread(comic) } else { vm.markRead(comic) }
                            } label: {
                                Image(systemName: comic.isFinished ? "arrow.counterclockwise" : "checkmark")
                                    .font(.title3)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isFinished ? "Mark as unread" : "Mark as read")

                            Button(action: { vm.toggleFavorite(comic) }) {
                                Image(systemName: comic.isFavorite ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(comic.isFavorite ? .red : .primary)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.isFavorite ? "Remove from favorites" : "Add to favorites")

                            Button(action: { vm.toggleReadingList(comic) }) {
                                Image(systemName: comic.inReadingList ? "bookmark.fill" : "bookmark")
                                    .font(.title3)
                                    .foregroundStyle(comic.inReadingList ? Color.accentColor : .primary)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityLabel(comic.inReadingList ? "Remove from reading list" : "Add to reading list")
                        }
                        .padding(.horizontal)

                        iPadComicMeta(comic: comic)
                    }
                }
                .navigationTitle(comic.title)
                .navigationBarTitleDisplayMode(.large)
            } else {
                ContentUnavailableView("Select a Comic",
                                       systemImage: "book.closed",
                                       description: Text("Choose a comic from the library."))
            }
        }
    }
}

private struct iPadComicGrid: View {
    let comics: [Comic]
    @Binding var selectedComic: Comic?
    @EnvironmentObject var vm: LibraryViewModel

    @State private var draggedId: Int64?
    @State private var dropTargetId: Int64?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            if comics.isEmpty && vm.isLoading {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<20, id: \.self) { _ in ShimmerCard() }
                }
                .padding()
            } else if comics.isEmpty {
                ContentUnavailableView("No Comics",
                                       systemImage: "books.vertical",
                                       description: Text("Import comics to get started."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(comics) { comic in
                        let isTarget = dropTargetId == comic.id && draggedId != comic.id
                        iPadComicTile(comic: comic)
                            .onTapGesture { selectedComic = comic }
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner)
                                    .stroke(Design.brandBlue, lineWidth: selectedComic?.id == comic.id ? 2 : 0)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.cardCorner)
                                    .stroke(Design.brandGold, lineWidth: isTarget ? 3 : 0)
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
                    }
                }
                .padding()
            }
        }
    }
}

private struct iPadComicTile: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Design.cardBg
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 140, height: 200)
            .comicCardStyle()

            Text(comic.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if comic.progress > 0 {
                ProgressView(value: Double(comic.progress), total: max(1, Double(comic.pageCount)))
                    .tint(Design.brandBlue)
            }
        }
        .frame(width: 140)
        .task { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
        .contextMenu {
            Button("Open") { vm.readerComic = comic }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
            Button(comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                vm.toggleFavorite(comic)
            }
            Button("Add to Reading List") { vm.toggleReadingList(comic) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue(comic.progress > 0
            ? "Page \(comic.progress + 1) of \(comic.pageCount)"
            : "Unread")
        .accessibilityHint("Double-tap to open")
        .accessibilityAddTraits(.isButton)
    }
}

private struct iPadComicHero: View {
    let comic: Comic
    @State private var thumbnail: PlatformImage?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let img = thumbnail {
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: Design.cardCorner)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .frame(width: 140, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .shadow(radius: 4)
            .padding(.leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(comic.title).font(.title2.bold()).lineLimit(3)
                if !comic.series.isEmpty {
                    Text(comic.series).font(.subheadline).foregroundStyle(.secondary)
                }
                if !comic.publisher.isEmpty {
                    Text(comic.publisher).font(.caption).foregroundStyle(.tertiary)
                }
                if comic.pageCount > 0 {
                    Text("\(comic.pageCount) pages").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        }
        .task { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
    }
}

private struct iPadComicMeta: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var tags: [Tag] = []
    @State private var newTagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal)
            HStack {
                Label("Rating", systemImage: "star").foregroundStyle(.secondary)
                Spacer()
                StarRatingLarge(rating: comic.rating) { star in
                    vm.setRating(comic, rating: star == comic.rating ? 0 : star)
                }
            }
            .padding()

            if comic.progress > 0 {
                metaRow("Progress",
                        value: "Page \(comic.progress) of \(comic.pageCount)",
                        icon: "book")
                ProgressView(value: Double(comic.progress), total: max(1, Double(comic.pageCount)))
                    .tint(.accentColor)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            if let issue = comic.issueNumber  { metaRow("Issue",    value: "#\(issue)",       icon: "number") }
            if let year  = comic.year          { metaRow("Year",     value: "\(year)",         icon: "calendar") }
            if let writer = comic.writer,  !writer.isEmpty  { metaRow("Writer",   value: writer,    icon: "pencil") }
            if let pencil = comic.penciller, !pencil.isEmpty { metaRow("Penciller", value: pencil,  icon: "paintbrush") }
            if let arc    = comic.storyArc, !arc.isEmpty     { metaRow("Story Arc", value: arc,     icon: "books.vertical") }

            Divider().padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) {
                Label("Tags", systemImage: "tag").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags) { tag in
                                TagChip(name: tag.name) { removeTag(tag) }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Add tag…", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 10)
        }
        .task(id: comic.id) { loadTags() }
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: String, icon: String) -> some View {
        Divider().padding(.horizontal)
        HStack {
            Label(label, systemImage: icon).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .padding()
    }

    private func loadTags() {
        let comicId = comic.id
        Task.detached(priority: .userInitiated) {
            let t = DatabaseManager.shared.tags(for: comicId)
            await MainActor.run { tags = t }
        }
    }

    private func addTag() {
        let name = newTagText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.addTag(name: name, to: comic)
        newTagText = ""
        loadTags()
        vm.reload()
    }

    private func removeTag(_ tag: Tag) {
        vm.removeTag(tagId: tag.id, from: comic)
        loadTags()
        vm.reload()
    }
}

private struct iPadImportButton: View {
    @State private var showPicker = false
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Button(action: { showPicker = true }) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Import Comics")
        .sheet(isPresented: $showPicker) {
            iPadDocumentPicker { urls in
                vm.importFiles(urls)
            }
        }
    }
}

struct iPadSettingsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService
    @AppStorage("scrollMode")    private var scrollMode    = false
    @AppStorage("autoplaySpeed") private var autoplaySpeed: Double = 6.0
    @AppStorage("libraryPath")   private var libraryPath   = ""
    @State private var showClearConfirm = false
    @State private var showRenameFiles  = false
    @State private var cacheCleared     = false
    @State private var comicCount       = 0
    @State private var backupErrorMessage: String?
    @State private var isFixingOrder    = false
    @State private var gcdDownloadState: GCDDatabaseDownloader.State = .idle
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.dark.rawValue
    @AppStorage("customAccentColorHex") private var customAccentHex: String = ""

    private var smartReadingOrderIsOn: Binding<Bool> {
        Binding(get: { vm.readingOrderMode == .intelligent },
                set: { vm.readingOrderMode = $0 ? .intelligent : .filename })
    }

    private var gcdSizeLabel: String? {
        guard let bytes = OfflineMetadataStore.shared.fileSizeOnDisk else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var readingOrderModeExplainer: String {
        switch vm.readingOrderMode {
        case .filename:        return "Issues sort by their original position, unaffected by any of the modes below."
        case .legacyNumber:    return "Issues sort strictly by parsed issue number within each series."
        case .publicationDate: return "Issues sort by cover date within each series."
        case .comicInfoOrder:  return "Issues sort by the issue number embedded in ComicInfo.xml, where present."
        case .intelligent:     return "Annuals and specials are placed using publication date, story arc, and other signals — not just issue number. Manual corrections in Manage Series always take priority."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(
                    get: { AppTheme(rawValue: appThemeRaw) ?? .dark },
                    set: { appThemeRaw = $0.rawValue }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        HStack {
                            Circle().fill(theme.palette.appBackground).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Design.borderColor, lineWidth: 1))
                            Text(theme.title)
                        }
                        .tag(theme)
                    }
                }

                ColorPicker("Accent Color", selection: Binding(
                    get: { Color(hex: customAccentHex) ?? AppTheme(rawValue: appThemeRaw)?.palette.brandBlue ?? Design.brandBlue },
                    set: { customAccentHex = $0.toHexString() ?? "" }
                ))
                if !customAccentHex.isEmpty {
                    Button("Reset to Theme's Accent") { customAccentHex = "" }
                        .font(.caption).foregroundStyle(Design.brandBlue)
                }

                Text("Takes effect the next time you launch ComicArc.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }

            Section("Sidebar") {
                Text("Reorder or hide the Discover section. Library, Publishers, and Tags always show.")
                    .font(.caption).foregroundStyle(.secondary)
                let order = SidebarCustomization.decodeOrder(discoverOrderRaw)
                ForEach(Array(order.enumerated()), id: \.element) { idx, item in
                    HStack {
                        Label(item.title, systemImage: item.icon)
                        Spacer()
                        Button {
                            var o = order; o.swapAt(idx, idx - 1)
                            discoverOrderRaw = SidebarCustomization.encode(o)
                        } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(idx == 0)
                        .accessibilityLabel("Move \(item.title) up")

                        Button {
                            var o = order; o.swapAt(idx, idx + 1)
                            discoverOrderRaw = SidebarCustomization.encode(o)
                        } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(idx == order.count - 1)
                        .accessibilityLabel("Move \(item.title) down")

                        Toggle("", isOn: Binding(
                            get: { !SidebarCustomization.decodeHidden(discoverHiddenRaw).contains(item) },
                            set: { visible in
                                var hidden = SidebarCustomization.decodeHidden(discoverHiddenRaw)
                                if visible { hidden.remove(item) } else { hidden.insert(item) }
                                discoverHiddenRaw = SidebarCustomization.encode(Array(hidden))
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Show \(item.title) in sidebar")
                    }
                }
            }

            Section("Reader") {
                Toggle("Scroll Mode", isOn: $scrollMode)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Slideshow Speed")
                        Spacer()
                        Text(String(format: "%.1fs", autoplaySpeed)).foregroundStyle(.secondary)
                    }
                    Slider(value: $autoplaySpeed, in: 1.0...15.0, step: 0.5)
                }
            }

            Section {
                if libraryPath.isEmpty {
                    Text("No library folder set. Comics can still be imported one at a time with the + button, or choose a folder here to scan its whole contents (including subfolders) and pick up new files automatically whenever you return to the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Label("Library Folder", systemImage: "folder")
                        Spacer()
                        Text(URL(fileURLWithPath: libraryPath).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button {
                    fileService.pickFolder { url in
                        guard let url else { return }
                        libraryPath = url.path
                        vm.scan()
                    }
                } label: {
                    Label(libraryPath.isEmpty ? "Choose Library Folder…" : "Change Library Folder…", systemImage: "folder.badge.plus")
                }
                if !libraryPath.isEmpty {
                    Button { vm.scan() } label: {
                        Label("Scan Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isScanning || vm.isResyncing)
                    Button {
                        vm.resyncLibrary()
                    } label: {
                        if vm.isResyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Resyncing…")
                            }
                        } else {
                            Label("Resync Library", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(vm.isScanning || vm.isResyncing)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("CBZ, PDF, JPG, and PNG are supported. CBR isn't readable on iPad — extraction needs a command-line tool that doesn't exist in the iOS sandbox. If reading order or metadata looks wrong, use Resync Library — it rescans and re-derives metadata for every comic.")
            }

            Section("Reading Order") {
                Toggle("Smart Reading Order", isOn: smartReadingOrderIsOn)
                Text("Automatically places annuals and specials in their correct spot in a series instead of dumping them at the end. Turn this off to go back to the original order.")
                    .font(.caption).foregroundStyle(.secondary)

                Button(isFixingOrder ? "Working…" : "Recheck My Library") { recheckReadingOrder() }
                    .disabled(isFixingOrder)
                Button(isFixingOrder ? "Working…" : "Undo My Manual Fixes") { undoManualOrderFixes() }
                    .foregroundStyle(.red)
                    .disabled(isFixingOrder)

                DisclosureGroup("Advanced") {
                    Picker("Order Basis", selection: $vm.readingOrderMode) {
                        ForEach(DatabaseManager.ReadingOrderMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text(readingOrderModeExplainer)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Comics Database") {
                if OfflineMetadataStore.shared.isAvailable {
                    Label("Downloaded" + (gcdSizeLabel.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Annuals and specials with a real match are placed using their actual publication date, entirely offline.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(gcdDownloadState.isDownloading ? "Working…" : "Check for Database Update") {
                        GCDDatabaseDownloader.download { gcdDownloadState = $0 }
                    }.disabled(gcdDownloadState.isDownloading)
                    Button("Delete", role: .destructive) {
                        OfflineMetadataStore.shared.deleteDownloadedDatabase()
                        gcdDownloadState = .idle
                    }
                } else {
                    Text("A free, one-time download that lets annuals and specials be placed using their real publication date instead of a guess. Works offline forever after — no account, no ongoing internet, no cost.")
                        .font(.caption).foregroundStyle(.secondary)
                    switch gcdDownloadState {
                    case .idle, .success:
                        Button("Download Comics Database") {
                            GCDDatabaseDownloader.download { gcdDownloadState = $0 }
                        }
                    case .downloading(let progress):
                        ProgressView(value: progress)
                        Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                    case .failure(let message):
                        Text(message).font(.caption).foregroundStyle(.red)
                        Button("Try Again") { GCDDatabaseDownloader.download { gcdDownloadState = $0 } }
                    }
                }
            }

            Section {
                Text("ComicArc reads folders as Publisher / Character / Series, and file names as \"Series #Issue\" (e.g. \"Batman #427.cbz\"). Files that don't match this can still import, but their series or issue number may come out wrong.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    showRenameFiles = true
                } label: {
                    Label("Rename Files to Match Library…", systemImage: "textformat")
                }
            } header: {
                Text("Fix Filenames")
            }

            Section {
                HStack {
                    Label("Comics imported", systemImage: "books.vertical")
                    Spacer()
                    Text("\(comicCount)").foregroundStyle(.secondary)
                }
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear Thumbnail Cache", systemImage: "trash")
                }
            }

            Section {
                Button {
                    BackupService.export(fileService: fileService) { backupErrorMessage = $0 }
                } label: {
                    Label("Export Backup…", systemImage: "square.and.arrow.up")
                }
                Button {
                    BackupService.import(fileService: fileService, vm: vm) { backupErrorMessage = $0 }
                } label: {
                    Label("Import Backup…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Backs up ratings, reviews, tags, bookmarks, and reading orders. Comics themselves stay wherever they already are.")
            }

            Section("About") {
                HStack {
                    Text("ComicArc")
                    Spacer()
                    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    Text(v).foregroundStyle(.secondary)
                }
                if OfflineMetadataStore.shared.isAvailable {
                    Text("Comics database data from the Grand Comics Database™ (GCD), licensed under CC BY-SA 4.0.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the thumbnail cache? Thumbnails will be regenerated on next view.",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task.detached(priority: .utility) { ThumbnailCache.shared.clearAll() }
                cacheCleared = true
            }
        }
        .alert("Cache cleared", isPresented: $cacheCleared) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showRenameFiles) { RenameFilesView().environmentObject(vm) }
        .alert("Backup Error", isPresented: Binding(get: { backupErrorMessage != nil }, set: { if !$0 { backupErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupErrorMessage ?? "")
        }
        .onChange(of: gcdDownloadState) { _, newValue in
            guard newValue == .success else { return }
            isFixingOrder = true
            Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.recomputeGCDMatches()
                DatabaseManager.shared.autoPopulateSeriesLinksFromGCD()
                DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
                await MainActor.run {
                    isFixingOrder = false
                    vm.reload()
                }
            }
        }
        .task {
            let count = await Task.detached(priority: .utility) {
                DatabaseManager.shared.allComics().count
            }.value
            comicCount = count
        }
    }

    private func recheckReadingOrder() {
        isFixingOrder = true
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.recomputeGCDMatches()
            DatabaseManager.shared.autoPopulateSeriesLinksFromGCD()
            DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run {
                isFixingOrder = false
                vm.reload()
            }
        }
    }

    private func undoManualOrderFixes() {
        isFixingOrder = true
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.clearAllReadingOrderOverrides()
            DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run {
                isFixingOrder = false
                vm.reload()
            }
        }
    }
}
#endif
