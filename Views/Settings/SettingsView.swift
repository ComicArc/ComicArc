import SwiftUI

// `SettingsView` is shared verbatim by all three platforms (Mac, iPad, visionOS) -- section-level
// search (the toolbar's search field is shared app-wide) is coarser than filtering every
// individual control,
// but matches how most macOS/iOS settings search actually behaves: it finds the relevant *pane*,
// not every label inside it. Each section gets a handful of terms a user would plausibly type to
// find it, beyond its own visible title.
enum SettingsSearch {
    static let keywords: [String: [String]] = [
        "Appearance": ["theme", "accent", "color", "colour", "dark", "light", "sepia"],
        "Library": ["folder", "path", "scan", "cache", "comics imported"],
        "Reader": ["scroll", "slideshow", "autoplay", "speed"],
        "Import": ["cbr", "unar", "rar"],
        "Sidebar": ["discover", "reorder", "hide"],
        "ComicInfo Write-Back": ["comicinfo", "write back", "metadata", "xml", "portable"],
        "Data": ["backup", "export", "trash", "resync", "clear", "cache"],
        "Sync": ["nearby", "multipeer", "ipad", "mac", "progress", "wifi", "network", "peer"],
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

    @State private var folderToRemove: String?
    @State private var folderToRemoveComicCount = 0

    private var progressFormat: Binding<ProgressFormat> {
        Binding(get: { ProgressFormat(rawValue: progressFormatRaw) ?? .fraction },
                set: { progressFormatRaw = $0.rawValue })
    }

    // Kept platform-conditional so a search matching only a Mac-only section (e.g. "cbr") doesn't
    // leave `noSectionsMatch` false while nothing actually renders on iPad/visionOS.
    private static let sectionTitles: [String] = {
        var titles = ["Appearance", "Library",
                      "Reader", "Sidebar", "Data", "Sync", "Help", "About"]
        #if os(macOS)
        titles.append("Import")
        #endif
        return titles
    }()

    private func sectionMatches(_ title: String) -> Bool {
        SettingsSearch.matches(title, query: vm.searchText)
    }

    private var noSectionsMatch: Bool {
        SettingsSearch.noneMatch(Self.sectionTitles, query: vm.searchText)
    }

    @State private var unarAvailable         = false
    @State private var showTrash             = false
    @State private var showPeerSync          = false
    #if os(macOS)
    @AppStorage("comicInfoWriteBackEnabled") private var comicInfoWriteBackEnabled = false
    #endif
    @State private var showClearConfirm      = false
    @State private var showOnboardingConfirm = false
    @State private var backupErrorMessage: String?
    @State private var comicCount            = 0

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            if noSectionsMatch {
                EmptyStateView(icon: "magnifyingglass", title: "No Matching Settings")
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .padding(.top, 60)
            }

            Form {
                if sectionMatches("Appearance") { appearanceSection }
                if sectionMatches("Library") { librarySection }
                if sectionMatches("Reader") { readerSection }
                #if os(macOS)
                if sectionMatches("Import") { importSection }
                #endif
                if sectionMatches("Sidebar") { sidebarSection }
                #if os(macOS)
                if sectionMatches("ComicInfo Write-Back") { comicInfoWriteBackSection }
                #endif
                if sectionMatches("Data") { dataSection }
                if sectionMatches("Sync") { syncSection }
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
        .task {
            comicCount = await Task.detached(priority: .utility) {
                DatabaseManager.shared.allComics().count
            }.value
        }
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(vm) }
        .sheet(isPresented: $showPeerSync) { PeerSyncView() }
        .confirmationDialog("Clear Library?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Library", role: .destructive) { vm.clearLibrary() }
        } message: {
            Text("This will permanently remove all comics, reading progress, reading paths, tags, bookmarks, and cached thumbnails. Your actual comic files will not be deleted.")
        }
        .confirmationDialog("Run Setup Again?", isPresented: $showOnboardingConfirm, titleVisibility: .visible) {
            Button("Erase & Run Setup", role: .destructive) {
                vm.clearLibrary(resetPreferences: true)
                completedBuild = ""
            }
        } message: {
            Text("This will erase your entire library database, all reading progress, reading paths, tags, bookmarks, and cached thumbnails, then restart the setup wizard. Your actual comic files will not be deleted.")
        }
        .errorAlert("Backup Error", message: $backupErrorMessage)
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
        Section {
            if vm.libraryPaths.isEmpty {
                #if os(macOS)
                Text("No folders configured yet.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("No library folder set. Comics can still be imported one at a time with the + button, or choose a folder here to scan its whole contents (including subfolders) and pick up new files automatically whenever you return to the app.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            } else {
                ForEach(vm.libraryPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            folderToRemoveComicCount = vm.comicCount(underFolder: path)
                            folderToRemove = path
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(path)")
                    }
                }
            }

            Button("Add Folder…") { pickFolder() }

            Button("Scan Now") { vm.scan() }
                .disabled(vm.libraryPaths.isEmpty || vm.isBusy)

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
        } header: {
            Text("Library")
        } footer: {
            #if !os(macOS)
            Text("CBZ, PDF, JPG, and PNG are supported. CBR isn't readable here — extraction needs a command-line tool that doesn't exist in the iOS sandbox. If reading order or metadata looks wrong, use Resync Library — it rescans and re-derives metadata for every comic.")
            #endif
        }
        .confirmationDialog(
            folderToRemoveComicCount > 0
                ? "Remove this folder and its \(folderToRemoveComicCount) comic\(folderToRemoveComicCount == 1 ? "" : "s")?"
                : "Remove this folder?",
            isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let path = folderToRemove { vm.removeLibraryFolder(path) }
                folderToRemove = nil
            }
            Button("Cancel", role: .cancel) { folderToRemove = nil }
        } message: {
            Text(folderToRemoveComicCount > 0
                 ? "The files themselves are untouched on disk. Their entries move to Trash and can be restored from there."
                 : "ComicArc will stop scanning this folder.")
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

    #if os(macOS)
    // CBR extraction shells out to a command-line tool (`unar`) that doesn't exist in the iOS/
    // iPadOS sandbox -- there's nothing this section could do there, so it's Mac-only rather than
    // showing a toggle that can never actually turn anything on.
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
    #endif

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

    #if os(macOS)
    @ViewBuilder private var comicInfoWriteBackSection: some View {
        Section("ComicInfo Write-Back") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow Writing Metadata Back to Files", isOn: $comicInfoWriteBackEnabled)
                Text("Off by default. When on, the Metadata Inspector shows a button to write a comic's Series, Title, Issue Number, Publisher, Writer, Penciller, Volume, and Year directly into that file's own ComicInfo.xml (CBZ only) — so the metadata travels with the file if it's opened in another app. This modifies the file itself; nothing is ever written automatically, only when you tap the button for a specific comic.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }
    #endif

    @ViewBuilder private var syncSection: some View {
        Section("Sync") {
            VStack(alignment: .leading, spacing: 6) {
                #if os(macOS)
                Text("Sync your reading progress with another device (like an iPad) over your local network -- no account, no cloud.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("Sync your reading progress with another device (like your Mac) over your local network -- no account, no cloud.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .padding(.vertical, 2)
            Button("Sync with Nearby Device…") { showPeerSync = true }
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            HStack {
                Text("Comics Imported")
                Spacer()
                Text("\(comicCount)").foregroundStyle(.secondary)
            }
            Button("Export Backup…") { exportBackup() }
            Button("Import Backup…") { importBackup() }
            Button("View Trash…") { showTrash = true }
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
            .disabled(vm.isBusy)
            .help("Rescans your folders and re-derives publisher, character, series, and issue number for every comic. Use this if reading order or metadata looks wrong.")
            Button("Clear Thumbnail Cache") { clearCache() }
                .help("Remove cached thumbnails — they regenerate on demand")
            Button("Clear Library…", role: .destructive) { confirmClear() }
                .help("Remove all comics, progress, and reading paths from the database")
        } header: {
            Text("Data")
        } footer: {
            Text("Backup includes reading progress, favorites, tags, bookmarks, manual issue orders, and lists. Comics themselves stay wherever they already are.")
        }
    }

    @ViewBuilder private var helpSection: some View {
        Section("Help") {

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
            let found = ExternalTool.shared.which("unar") != nil
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
    @State private var stillMissingAlert: Comic?
    @State private var purgeTarget: Comic?
    @State private var confirmEmptyTrash = false

    /// "missing" (file vanished from disk) and "folder_removed" (its library folder was removed
    /// from Settings, file likely untouched) are both distinct from an explicit user delete (or
    /// nil, for anything soft-deleted before this distinction existed) -- restoring either only
    /// really makes sense once the file is confirmed to still be reachable, checked before acting.
    private func badge(for comic: Comic) -> (label: String, systemImage: String)? {
        switch comic.deletedReason {
        case "missing":        return ("Missing", "questionmark.folder")
        case "folder_removed": return ("Folder Removed", "folder.badge.minus")
        default:                return nil
        }
    }
    private func needsFileCheckBeforeRestore(_ comic: Comic) -> Bool {
        comic.deletedReason == "missing" || comic.deletedReason == "folder_removed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trash").font(.title2.bold())
                Spacer()
                if !trashed.isEmpty {
                    Button("Empty Trash…", role: .destructive) { confirmEmptyTrash = true }
                        .controlSize(.small)
                }
                Button("Done") { dismiss() }
            }
            .padding(20)

            if trashed.isEmpty {
                EmptyStateView(icon: "trash", title: "Trash is empty")
            } else {
                List(trashed) { comic in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(comic.title).font(.subheadline)
                                if let badge = badge(for: comic) {
                                    Label(badge.label, systemImage: badge.systemImage)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .labelStyle(.titleAndIcon)
                                        .help("Not something you deleted yourself")
                                }
                            }
                            Text(comic.publisher + " · " + comic.series)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            if needsFileCheckBeforeRestore(comic), !FileManager.default.fileExists(atPath: comic.filePath) {
                                stillMissingAlert = comic
                            } else {
                                vm.restoreFromTrash(id: comic.id)
                                trashed.removeAll { $0.id == comic.id }
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Button("Delete Permanently", role: .destructive) { purgeTarget = comic }
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
        .alert("File Still Missing", isPresented: Binding(
            get: { stillMissingAlert != nil },
            set: { if !$0 { stillMissingAlert = nil } }
        )) {
            Button("Restore Anyway") {
                if let comic = stillMissingAlert {
                    vm.restoreFromTrash(id: comic.id)
                    trashed.removeAll { $0.id == comic.id }
                }
                stillMissingAlert = nil
            }
            Button("Cancel", role: .cancel) { stillMissingAlert = nil }
        } message: {
            Text("This file still isn't at its original location. Restoring brings the entry back to your library, but ComicArc won't be able to open it until the file is back in place.")
        }
        .alert("Delete Permanently?", isPresented: Binding(
            get: { purgeTarget != nil },
            set: { if !$0 { purgeTarget = nil } }
        )) {
            Button("Delete Permanently", role: .destructive) {
                if let comic = purgeTarget {
                    vm.purgeFromTrash(id: comic.id)
                    trashed.removeAll { $0.id == comic.id }
                }
                purgeTarget = nil
            }
            Button("Cancel", role: .cancel) { purgeTarget = nil }
        } message: {
            Text("This removes \"\(purgeTarget?.title ?? "")\" from ComicArc for good, including its progress and tags. This can't be undone. The file itself is untouched (already in Finder's Trash if you deleted it from here).")
        }
        .alert("Empty Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) {
                vm.emptyTrash(trashed.map(\.id))
                trashed.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes all \(trashed.count) comic\(trashed.count == 1 ? "" : "s") in Trash from ComicArc, including their progress and tags. This can't be undone. Files themselves are untouched.")
        }
    }
}
