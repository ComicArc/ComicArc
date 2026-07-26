import SwiftUI

// Shared between Mac's SettingsView and iPad's iPadSettingsView -- section-level search (the
// toolbar's search field is shared app-wide) is coarser than filtering every individual control,
// but matches how most macOS/iOS settings search actually behaves: it finds the relevant *pane*,
// not every label inside it. Each section gets a handful of terms a user would plausibly type to
// find it, beyond its own visible title.
enum SettingsSearch {
    static let keywords: [String: [String]] = [
        "Appearance": ["theme", "accent", "color", "colour", "dark", "light", "sepia"],
        "Library": ["folder", "path", "scan", "cache", "comics imported"],
        "Reading Order": ["smart", "annual", "special", "manual fixes", "order basis", "sort"],
        "Comics Database": ["gcd", "download", "offline", "publication date", "grand comics database"],
        "Reader": ["scroll", "slideshow", "autoplay", "speed"],
        "Import": ["cbr", "unar", "rar"],
        "Sidebar": ["discover", "reorder", "hide"],
        "Fix Filenames": ["rename", "filename"],
        "Data": ["backup", "export", "trash", "resync", "clear", "cache", "health check"],
        "Backup": ["export", "import", "restore"],
        "Help": ["tutorial", "onboarding"],
        "About": ["version"],
    ]

    static func matches(_ title: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if title.lowercased().contains(q) { return true }
        return (keywords[title] ?? []).contains { $0.contains(q) }
    }

    static func noneMatch(_ titles: [String], query: String) -> Bool {
        !query.isEmpty && titles.allSatisfy { !matches($0, query: query) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService

    @AppStorage("scrollMode")       private var scrollMode       = false

    @AppStorage("cbrEnabled")       private var cbrEnabled       = true
    @AppStorage("autoplaySpeed")    private var autoplaySpeed: Double = 6.0
    @AppStorage("progressFormat")   private var progressFormatRaw = ProgressFormat.fraction.rawValue
    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""
    @AppStorage(SidebarCustomization.orderKey)  private var discoverOrderRaw  = ""
    @AppStorage(SidebarCustomization.hiddenKey) private var discoverHiddenRaw = ""
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.dark.rawValue
    @AppStorage("customAccentColorHex") private var customAccentHex: String = ""

    private var progressFormat: Binding<ProgressFormat> {
        Binding(get: { ProgressFormat(rawValue: progressFormatRaw) ?? .fraction },
                set: { progressFormatRaw = $0.rawValue })
    }

    private var smartReadingOrderIsOn: Binding<Bool> {
        Binding(get: { vm.readingOrderMode == .intelligent },
                set: { vm.readingOrderMode = $0 ? .intelligent : .filename })
    }

    private var gcdSizeLabel: String? {
        guard let bytes = OfflineMetadataStore.shared.fileSizeOnDisk else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let sectionTitles = ["Appearance", "Library", "Reading Order", "Comics Database",
                                        "Reader", "Import", "Sidebar", "Fix Filenames", "Data", "Help", "About"]

    private func sectionMatches(_ title: String) -> Bool {
        SettingsSearch.matches(title, query: vm.searchText)
    }

    private var noSectionsMatch: Bool {
        SettingsSearch.noneMatch(Self.sectionTitles, query: vm.searchText)
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

    @State private var unarAvailable         = false
    @State private var isFixingOrder         = false
    @State private var gcdDownloadState: GCDDatabaseDownloader.State = .idle
    @State private var showTrash             = false
    @State private var showRenameFiles       = false
    @State private var showClearConfirm      = false
    @State private var showOnboardingConfirm = false
    @State private var backupErrorMessage: String?

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            if noSectionsMatch {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").font(.system(size: 42)).foregroundStyle(.quaternary)
                    Text("No Matching Settings").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .padding(.top, 60)
            }

            Form {
                if sectionMatches("Appearance") { appearanceSection }
                if sectionMatches("Library") { librarySection }
                if sectionMatches("Reading Order") { readingOrderSection }
                if sectionMatches("Comics Database") { comicsDatabaseSection }
                if sectionMatches("Reader") { readerSection }
                if sectionMatches("Import") { importSection }
                if sectionMatches("Sidebar") { sidebarSection }
                if sectionMatches("Fix Filenames") { fixFilenamesSection }
                if sectionMatches("Data") { dataSection }
                if sectionMatches("Help") { helpSection }
                if sectionMatches("About") { aboutSection }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 640)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Design.appBackground)
        .navigationTitle("Settings")
        .onAppear { if cbrEnabled { checkUnarAsync() } }
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
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(vm) }
        .sheet(isPresented: $showRenameFiles) { RenameFilesView().environmentObject(vm) }
        .confirmationDialog("Clear Library?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Library", role: .destructive) { vm.clearLibrary() }
        } message: {
            Text("This will permanently remove all comics, reading progress, ratings, reviews, runs, lists, tier lists, tags, bookmarks, and cached thumbnails. Your actual comic files will not be deleted.")
        }
        .confirmationDialog("Run Setup Again?", isPresented: $showOnboardingConfirm, titleVisibility: .visible) {
            Button("Erase & Run Setup", role: .destructive) {
                vm.clearLibrary(resetPreferences: true)
                completedBuild = ""
            }
        } message: {
            Text("This will erase your entire library database, all reading progress, ratings, reviews, runs, lists, tier lists, tags, bookmarks, and cached thumbnails, then restart the setup wizard. Your actual comic files will not be deleted.")
        }
        .alert("Backup Error", isPresented: Binding(
            get: { backupErrorMessage != nil },
            set: { if !$0 { backupErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupErrorMessage ?? "")
        }
    }

    @ViewBuilder private var appearanceSection: some View {
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
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Design.brandBlue)
            }

            Text("Takes effect the next time you launch ComicArc.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Appearance")
        }
    }

    @ViewBuilder private var librarySection: some View {
        Section("Library") {
            if vm.libraryPaths.isEmpty {
                Text("No folders configured yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(vm.libraryPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { vm.removeLibraryFolder(path) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(path)")
                    }
                }
            }

            Button("Add Folder…") { pickFolder() }

            Button("Scan Now") { vm.scan() }
                .disabled(vm.libraryPaths.isEmpty || vm.isScanning)

            Picker("Progress Display", selection: progressFormat) {
                ForEach(ProgressFormat.allCases, id: \.self) { fmt in
                    Text(fmt.label).tag(fmt)
                }
            }
            .pickerStyle(.menu)

            if vm.isScanning {
                ProgressView(value: Double(vm.scanState.done),
                             total: max(1, Double(vm.scanState.total)))
                Text("\(vm.scanState.done) / \(vm.scanState.total) — \(vm.scanState.added) added")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var readingOrderSection: some View {
        Section("Reading Order") {
            Toggle("Smart Reading Order", isOn: smartReadingOrderIsOn)
            Text("Automatically places annuals and specials in their correct spot in a series instead of dumping them at the end. Turn this off to go back to the original order.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(isFixingOrder ? "Working…" : "Recheck My Library") { recheckReadingOrder() }
                    .disabled(isFixingOrder)
                    .help("Re-run automatic placement for every series, without touching anything you've manually fixed")
                Button(isFixingOrder ? "Working…" : "Undo My Manual Fixes") { undoManualOrderFixes() }
                    .foregroundStyle(.red)
                    .disabled(isFixingOrder)
                    .help("Forget every manual reading-order correction you've made and let automatic placement decide again")
            }

            DisclosureGroup("Advanced") {
                Picker("Order Basis", selection: $vm.readingOrderMode) {
                    ForEach(DatabaseManager.ReadingOrderMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text(readingOrderModeExplainer)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var comicsDatabaseSection: some View {
        Section("Comics Database") {
            if OfflineMetadataStore.shared.isAvailable {
                Label("Downloaded" + (gcdSizeLabel.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Annuals and specials with a real match are placed using their actual publication date, entirely offline.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(gcdDownloadState.isDownloading ? "Working…" : "Check for Database Update") {
                        GCDDatabaseDownloader.download { gcdDownloadState = $0 }
                    }.disabled(gcdDownloadState.isDownloading)
                    Button("Delete", role: .destructive) {
                        OfflineMetadataStore.shared.deleteDownloadedDatabase()
                        gcdDownloadState = .idle
                    }
                }
            } else {
                Text("A free, one-time download that lets annuals and specials be placed using their real publication date instead of a guess. Works offline forever after — no account, no ongoing internet, no cost.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    @ViewBuilder private var readerSection: some View {
        Section("Reader") {
            Toggle("Scroll Mode (continuous scroll)", isOn: $scrollMode)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Slideshow Speed")
                    Spacer()
                    Text(String(format: "%.1fs per page", autoplaySpeed))
                        .foregroundStyle(.secondary).font(.caption)
                }
                Slider(value: $autoplaySpeed, in: 1.0...15.0, step: 0.5)
            }
        }
    }

    @ViewBuilder private var importSection: some View {
        Section("Import") {
            Toggle("CBR Support (requires unar)", isOn: $cbrEnabled)
                .onChange(of: cbrEnabled) { _, enabled in if enabled { checkUnarAsync() } }
            if cbrEnabled {
                HStack {
                    Image(systemName: unarAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(unarAvailable ? .green : .red)
                    Text(unarAvailable ? "unar found" : "unar not found — install with: brew install unar")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var sidebarSection: some View {
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
    }

    @ViewBuilder private var fixFilenamesSection: some View {
        Section("Fix Filenames") {
            VStack(alignment: .leading, spacing: 6) {
                Text("ComicArc reads folders as Publisher / Character / Series. It's flexible about the exact filename on import, but reads most reliably — and renames to — ComicArc's canonical format: \"Series (Edition) #Issue\" (e.g. \"Batman (2016) #001.cbz\"). Files that don't match this can still import, but their series or issue number may come out wrong.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            Button("Rename Files to Match Library…") { showRenameFiles = true }
                .help("Preview and apply a batch rename of files whose names don't match their series/issue number")
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section("Data") {
            Button("Export Backup…") { exportBackup() }
            Button("Import Backup…") { importBackup() }
            Button("View Trash…") { showTrash = true }
            Divider()
            Button("Run Library Health Check…") { vm.runManualHealthCheck() }
                .help("Scan for duplicates, missing issues, multiple volumes, missing metadata, corrupt archives, and broken reading-order links")
            Divider()
            Button {
                vm.resyncLibrary()
            } label: {
                if vm.isResyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Resyncing…")
                    }
                } else {
                    Text("Resync Library")
                }
            }
            .disabled(vm.isResyncing || vm.isScanning)
            .help("Rescans your folders and re-derives publisher, character, series, and issue number for every comic. Use this if reading order or metadata looks wrong.")
            Button("Clear Thumbnail Cache") { clearCache() }
                .help("Remove cached thumbnails — they regenerate on demand")
            Button("Clear Library…", role: .destructive) { confirmClear() }
                .help("Remove all comics, progress, ratings, and runs from the database")
        }
    }

    @ViewBuilder private var helpSection: some View {
        Section("Help") {
            Button("Show Tutorial Again") {
                NotificationCenter.default.post(name: .showTutorial, object: nil)
            }
            .help("Re-run the interactive feature tour")

            Button("Run Setup Again…") { confirmRerunOnboarding() }
                .help("Re-run the initial library setup wizard")
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("ComicArc")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
            Text("A native macOS comic reader and library.")
                .font(.caption).foregroundStyle(.secondary)
            if OfflineMetadataStore.shared.isAvailable {
                Text("Comics database data from the Grand Comics Database™ (GCD), licensed under CC BY-SA 4.0.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func pickFolder() {
        fileService.pickFolder { url in
            if let url { vm.addLibraryFolder(url.path) }
        }
    }

    private func checkUnarAsync() {
#if os(macOS)
        Task.detached(priority: .utility) {
            let found = LibraryScanner.shared.which("unar") != nil
            await MainActor.run { unarAvailable = found }
        }
#endif
    }

    private func clearCache() {
        Task.detached(priority: .utility) {
            ThumbnailCache.shared.clearAll()
        }
    }

    private func confirmRerunOnboarding() { showOnboardingConfirm = true }

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
    private func confirmClear()           { showClearConfirm = true }

    private func exportBackup() {
        BackupService.export(fileService: fileService) { backupErrorMessage = $0 }
    }

    private func importBackup() {
        BackupService.import(fileService: fileService, vm: vm) { backupErrorMessage = $0 }
    }
}

struct TrashView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var trashed: [Comic] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trash").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)

            if trashed.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("Trash is empty").foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(trashed) { comic in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comic.title).font(.subheadline)
                            Text(comic.publisher + " · " + comic.series)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            vm.restoreComic(id: comic.id)
                            trashed.removeAll { $0.id == comic.id }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .frame(width: 480, height: 400)
        .task {
            trashed = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.trashedComics()
            }.value
        }
    }
}
