import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.fileService) private var fileService

    @AppStorage("libraryPath")      private var libraryPath      = ""
    @AppStorage("scrollMode")       private var scrollMode       = false
    @AppStorage("cbrEnabled")       private var cbrEnabled       = false
    @AppStorage("autoplaySpeed")    private var autoplaySpeed: Double = 6.0
    @AppStorage("progressFormat")   private var progressFormatRaw = ProgressFormat.fraction.rawValue
    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""
    @AppStorage("quitOnLastWindowClose") private var quitOnLastWindowClose = false

    private var progressFormat: Binding<ProgressFormat> {
        Binding(get: { ProgressFormat(rawValue: progressFormatRaw) ?? .fraction },
                set: { progressFormatRaw = $0.rawValue })
    }

    @State private var unarAvailable         = false
    @State private var showTrash             = false
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
            Form {
                Section("Library") {
                    HStack {
                        TextField("Library Path", text: $libraryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { pickFolder() }
                    }
                    .onChange(of: libraryPath) { _, newPath in
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: newPath, isDirectory: &isDir),
                              isDir.boolValue else { return }
                        vm.restartWatcher()
                    }

                    Button("Scan Now") { vm.scan() }
                        .disabled(libraryPath.isEmpty || vm.isScanning)

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

                Section("Behavior") {
                    Toggle("Quit when last window closes", isOn: $quitOnLastWindowClose)
                        .help("Quit ComicArc when you close the main window")
                }

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

                Section("Data") {
                    Button("Export Backup…") { exportBackup() }
                    Button("Import Backup…") { importBackup() }
                    Button("View Trash…") { showTrash = true }
                    Divider()
                    Button("Re-parse Library Metadata") { vm.forceReparseAllMeta() }
                        .help("Re-derive publisher, character, and series from your folder structure")
                    Button("Clear Thumbnail Cache") { clearCache() }
                        .help("Remove cached thumbnails — they regenerate on demand")
                    Button("Clear Library…", role: .destructive) { confirmClear() }
                        .help("Remove all comics, progress, ratings, and runs from the database")
                }

                Section("Help") {
                    Button("Show Tutorial Again") {
                        NotificationCenter.default.post(name: .showTutorial, object: nil)
                    }
                    .help("Re-run the interactive feature tour")

                    Button("Run Setup Again…") { confirmRerunOnboarding() }
                        .help("Re-run the initial library setup wizard")
                }

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
            .formStyle(.grouped)
        }
        .frame(width: 520)
        .padding()
        .onAppear { if cbrEnabled { checkUnarAsync() } }
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(vm) }
        .confirmationDialog("Clear Library?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Library", role: .destructive) { vm.clearLibrary() }
        } message: {
            Text("This will permanently remove all comics, reading progress, ratings, runs, tags, and cached thumbnails. Your actual comic files will not be deleted.")
        }
        .confirmationDialog("Run Setup Again?", isPresented: $showOnboardingConfirm, titleVisibility: .visible) {
            Button("Erase & Run Setup", role: .destructive) {
                vm.clearLibrary(resetPreferences: true)
                completedBuild = ""
            }
        } message: {
            Text("This will erase your entire library database, all reading progress, ratings, runs, and cached thumbnails, then restart the setup wizard. Your actual comic files will not be deleted.")
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

    private func pickFolder() {
        fileService.pickFolder { url in
            if let url { libraryPath = url.path }
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
    private func confirmClear()           { showClearConfirm = true }

    private func exportBackup() {
        fileService.pickSaveDestination(filename: "ComicArc-backup.json") { savedURL in
            guard let url = savedURL else { return }
            Task {
                let comics = await Task.detached(priority: .utility) {
                    DatabaseManager.shared.allComics()
                }.value
                let backup: [[String: Any]] = comics.map { c in
                    var d: [String: Any] = ["id": c.id, "title": c.title, "file_path": c.filePath,
                                            "publisher": c.publisher, "series": c.series,
                                            "progress": c.progress, "rating": c.rating,
                                            "is_favorite": c.isFavorite, "in_reading_list": c.inReadingList]
                    if let i = c.issueNumber { d["issue_number"] = i }
                    return d
                }
                guard let data = try? JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted) else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    await MainActor.run { backupErrorMessage = "Export failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func importBackup() {
        fileService.pickFiles(allowsMultiple: false, message: "", prompt: "Import") { urls in
            guard let url = urls.first else { return }
            Task {
                let result = await Task.detached(priority: .utility) { () -> String? in
                    guard let data = try? Data(contentsOf: url),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        return "Could not read backup file."
                    }
                    let db = DatabaseManager.shared
                    let knownPaths = db.knownPaths()
                    for item in arr {
                        guard let path = item["file_path"] as? String, knownPaths.contains(path) else { continue }
                        let id = (item["id"] as? Int64) ?? (item["id"] as? Int).map(Int64.init)
                               ?? (item["id"] as? Double).map(Int64.init) ?? nil
                        guard let comicId = id, comicId > 0 else { continue }
                        if let r = item["rating"] as? Int, r > 0 { db.setRating(comicId, rating: r) }
                        if let f = item["is_favorite"] as? Bool   { db.setFavorite(comicId, f) }
                        if let rl = item["in_reading_list"] as? Bool { db.setInReadingList(comicId, rl) }
                        if let p = item["progress"] as? Int, p > 0 { db.updateProgress(comicId: comicId, page: p) }
                    }
                    return nil
                }.value
                await MainActor.run {
                    if let errorMsg = result { backupErrorMessage = "Import failed: \(errorMsg)" }
                    vm.reload()
                }
            }
        }
    }
}

// MARK: - Trash view

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
        .task { trashed = DatabaseManager.shared.trashedComics() }
    }
}
