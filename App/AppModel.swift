import Foundation
import Observation
import AppKit
import os

private let log = Logger(subsystem: "com.comicarc", category: "app")

enum SidebarItem: Hashable {
    case home, continueReading, favorites, paths, highlights, stats, health, settings
    case publisher(String), tag(String), era(String)

    var title: String {
        switch self {
        case .home: "Library"
        case .continueReading: "Continue Reading"
        case .favorites: "Favorites"
        case .paths: "Reading Paths"
        case .highlights: "Highlights"
        case .stats: "Stats"
        case .health: "Library Health"
        case .settings: "Settings"
        case .publisher(let p): p
        case .tag(let t): "#\(t)"
        case .era(let e): e
        }
    }
}

enum Route: Hashable {
    case group(CharacterGroup)
    case series(SeriesGroup)
    case comic(Int64)
    case path(Int64)
}

struct ReaderLaunch: Identifiable, Equatable {
    let id = UUID()
    let comic: Comic
    let page: Int?
    let pathID: Int64?
    static func == (a: ReaderLaunch, b: ReaderLaunch) -> Bool { a.id == b.id }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    var isError = false
    var undo: (@MainActor () async -> Void)?
}

struct ScanStatus {
    var running = false
    var done = 0
    var total = 0
    var message: String?
    var warning: String?
}

/// App-wide state and every user action that changes the library. Screens load their own data and
/// reload when `revision` changes.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    private let db = Database.shared

    // Navigation
    var sidebar: SidebarItem = .home {
        didSet {
            guard oldValue != sidebar else { return }
            if !restoringHistory { backSections.append((oldValue, path)); forwardSections.removeAll() }
            restoringHistory = true; path = []; restoringHistory = false
            forward.removeAll()
            endSelection()
        }
    }
    /// Pages pushed inside the current sidebar section. Going somewhere new clears Forward.
    var path: [Route] = [] {
        didSet {
            if !restoringHistory, path.count > oldValue.count, !oldValue.isEmpty || !path.isEmpty,
               Array(path.prefix(oldValue.count)) == oldValue { forward.removeAll() }
        }
    }
    private(set) var forward: [Route] = []
    @ObservationIgnored private var backSections: [(SidebarItem, [Route])] = []
    @ObservationIgnored private var forwardSections: [(SidebarItem, [Route])] = []
    @ObservationIgnored private var restoringHistory = false

    var canGoBack: Bool { reader == nil && (!path.isEmpty || !backSections.isEmpty) }
    var canGoForward: Bool { reader == nil && (!forward.isEmpty || !forwardSections.isEmpty) }

    func goBack() {
        if let last = path.last {
            forward.append(last)
            restoringHistory = true; path.removeLast(); restoringHistory = false
        } else if let (item, route) = backSections.popLast() {
            forwardSections.append((sidebar, path))
            restoringHistory = true; sidebar = item; path = route; restoringHistory = false
        }
    }

    func goForward() {
        if let next = forward.popLast() {
            restoringHistory = true; path.append(next); restoringHistory = false
        } else if let (item, route) = forwardSections.popLast() {
            backSections.append((sidebar, path))
            restoringHistory = true; sidebar = item; path = route; restoringHistory = false
        }
    }

    /// Jumps to a breadcrumb: keeps the first `depth` pages.
    func pop(to depth: Int) {
        guard depth < path.count else { return }
        forward.append(contentsOf: path[depth...].reversed())
        restoringHistory = true; path = Array(path.prefix(depth)); restoringHistory = false
    }
    var searchText = ""
    var reader: ReaderLaunch?
    var quickOpen = false

    // Selection
    var selecting = false
    var selection = Set<Int64>()

    // Library state shown in the sidebar
    private(set) var revision = 0
    private(set) var publishers: [String] = []
    private(set) var tags: [Tag] = []
    private(set) var eras: [Tag] = []
    private(set) var readingPaths: [ReadingPath] = []
    private(set) var inProgressCount = 0
    private(set) var healthAlerts = 0
    private(set) var libraryCount = 0
    private(set) var folders: [String] = LibraryFolders.load()
    var scan = ScanStatus()
    var toast: Toast?

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    /// The welcome flow: shown on first launch (no library yet) or from Help › Welcome Tour.
    var showOnboarding = !UserDefaults.standard.bool(forKey: Prefs.onboardingDone) && LibraryFolders.load().isEmpty
    var needsOnboarding: Bool { showOnboarding }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)
        showOnboarding = false
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        Task {
            await refreshSidebar()
            guard !folders.isEmpty else { return }
            startWatching()
            await runScan()
            if SpotlightIndex.isOutdated { await SpotlightIndex.reindex() }
        }
    }

    func libraryDidChange() {
        revision += 1
        Task { await refreshSidebar() }
    }

    func refreshSidebar() async {
        async let pubs = db.publishers()
        async let tags = db.allTags()
        async let eras = db.eras()
        async let paths = db.readingPaths()
        async let progress = db.inProgressCount()
        async let count = db.libraryCount()
        async let health = healthAlertCount()
        self.publishers = (try? await pubs) ?? []
        self.tags = (try? await tags) ?? []
        self.eras = (try? await eras) ?? []
        self.readingPaths = (try? await paths) ?? []
        self.inProgressCount = (try? await progress) ?? 0
        self.libraryCount = (try? await count) ?? 0
        self.healthAlerts = await health
    }

    private func healthAlertCount() async -> Int {
        (try? await db.read { db in
            try db.scalarInt("SELECT COUNT(*) FROM metadata_conflicts m JOIN comics c ON c.id = m.comic_id AND c.deleted_at IS NULL WHERE m.status = 'pending'")
        }) ?? 0
    }

    // MARK: - Folders and scanning

    func setFolders(_ paths: [String]) {
        LibraryFolders.save(paths)
        folders = LibraryFolders.load()
        startWatching()
    }

    func addFolder(_ url: URL) {
        setFolders(folders + [url.standardizedFileURL.path])
        Task { await runScan() }
    }

    /// Removing a folder moves its comics to Trash (they can be restored).
    func removeFolder(_ path: String) {
        setFolders(folders.filter { $0 != path })
        Task {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let ids = (try? await db.read { db in
                try db.query("SELECT id FROM comics WHERE deleted_at IS NULL AND file_path LIKE ? ESCAPE '\\'",
                             [ComicSQL.likeEscaped(prefix) + "%"]) { $0.int64(0) }
            }) ?? []
            try? await db.softDelete(ids, reason: "folder_removed")
            SpotlightIndex.remove(ids)
            libraryDidChange()
        }
    }

    private func startWatching() {
        watcher = FolderWatcher(paths: folders) { [weak self] in
            Task { await self?.runScan(quiet: true) }
        }
    }

    func rescan() { Task { await runScan() } }

    func runScan(quiet: Bool = false) async {
        guard !scan.running, !folders.isEmpty else { return }
        scan = ScanStatus(running: true, message: quiet ? nil : "Scanning…")
        let summary = await LibraryScanner.shared.scan(roots: folders) { done, total in
            Task { @MainActor in AppModel.shared.scan.done = done; AppModel.shared.scan.total = total }
        }
        finishScan(summary, quiet: quiet)
    }

    func resync() {
        guard !scan.running, !folders.isEmpty else { return }
        scan = ScanStatus(running: true, message: "Resyncing…")
        Task {
            let summary = await LibraryScanner.shared.resync(roots: folders) { done, total in
                Task { @MainActor in AppModel.shared.scan.done = done; AppModel.shared.scan.total = total }
            }
            finishScan(summary, quiet: false)
            await SpotlightIndex.reindex()
        }
    }

    func cancelScan() { Task { await LibraryScanner.shared.cancel() } }

    private func finishScan(_ s: ScanSummary, quiet: Bool) {
        var parts: [String] = []
        if s.added > 0 { parts.append("\(s.added) added") }
        if s.moved > 0 { parts.append("\(s.moved) moved") }
        if s.missing > 0 { parts.append("\(s.missing) missing") }
        if s.recovered > 0 { parts.append("\(s.recovered) repaired") }
        scan = ScanStatus(running: false, message: parts.isEmpty ? nil : parts.joined(separator: ", "), warning: s.warning)
        SpotlightIndex.remove(s.removedIDs)
        if s.changed {
            libraryDidChange()
            Task { await SpotlightIndex.reindex() }
        } else if !quiet {
            Task { await refreshSidebar() }
        }
    }

    func importFiles(_ urls: [URL]) {
        let comics = urls.filter { Documents.libraryExtensions.contains($0.pathExtension.lowercased()) }
        guard !comics.isEmpty else {
            showToast("Those files aren't comics ComicArc can open.", isError: true)
            return
        }
        let roots = folders
        Task {
            var added = 0, existing = 0, failed = 0
            for url in comics {
                switch await LibraryScanner.shared.add(url, roots: roots) {
                case .added, .moved: added += 1
                case .alreadyInLibrary: existing += 1
                case .unsupported, .missing: failed += 1
                }
            }
            libraryDidChange()
            var parts: [String] = []
            if added > 0 { parts.append("Added \(added) comic\(added == 1 ? "" : "s")") }
            if existing > 0 { parts.append("\(existing) already in your library") }
            if failed > 0 { parts.append("\(failed) couldn't be read") }
            showToast(parts.joined(separator: " · "), isError: added == 0 && failed > 0)
        }
    }

    // MARK: - Reading

    func open(_ comic: Comic, page: Int? = nil, pathID: Int64? = nil) {
        guard FileManager.default.fileExists(atPath: comic.filePath) else {
            showToast("“\(comic.title)” isn't where it used to be. Rescan your library to update it.", isError: true)
            return
        }
        endSelection()
        reader = ReaderLaunch(comic: comic, page: page, pathID: pathID)
    }

    func open(comicID: Int64, page: Int? = nil) {
        Task { if let c = try? await db.comic(id: comicID) { open(c, page: page) } }
    }

    func closeReader() {
        reader = nil
        libraryDidChange()
    }

    // MARK: - Library actions

    func setFavorite(_ comics: [Comic], _ on: Bool) {
        perform { try await $0.setFavorite(comics.map(\.id), on) }
    }

    func setReadingList(_ comics: [Comic], _ on: Bool) {
        perform(on ? "Added to Reading List" : "Removed from Reading List") { try await $0.setInReadingList(comics.map(\.id), on) }
    }

    func markRead(_ comics: [Comic]) {
        let pages = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, max(0, $0.pageCount - 1)) })
        perform(comics.count > 1 ? "Marked \(comics.count) comics as read" : nil) { try await $0.markFinished(comics.map(\.id), lastPages: pages) }
    }

    func markUnread(_ comics: [Comic]) {
        perform(comics.count > 1 ? "Marked \(comics.count) comics as unread" : nil) { try await $0.markUnread(comics.map(\.id)) }
    }

    func addToPath(_ comics: [Comic], pathID: Int64, title: String) {
        Task {
            do {
                let added = try await db.addToPath(pathID, comicIDs: comics.map(\.id))
                libraryDidChange()
                if added.isEmpty {
                    showToast(comics.count == 1 ? "Already in “\(title)”" : "All of these are already in “\(title)”")
                } else {
                    showToast("Added \(added.count == 1 ? "1 comic" : "\(added.count) comics") to “\(title)”") {
                        try? await self.db.removeFromPath(pathID, comicIDs: added)
                        self.libraryDidChange()
                    }
                }
            } catch { report(error) }
        }
    }

    func addToNewPath(_ comics: [Comic], title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            guard let id = try? await db.createPath(title: title) else { return }
            addToPath(comics, pathID: id, title: title)
        }
    }

    /// Deletes comics from the library and moves their files to the Trash, with Undo.
    func delete(_ comics: [Comic], moveFilesToTrash: Bool = true) {
        guard !comics.isEmpty else { return }
        Task {
            var trashed: [Int64: String] = [:]
            if moveFilesToTrash {
                for c in comics { if let url = FileOperations.moveToTrash(c.url) { trashed[c.id] = url.path } }
            }
            do {
                try await db.softDelete(comics.map(\.id), trashedPaths: trashed)
                SpotlightIndex.remove(comics.map(\.id))
                endSelection()
                libraryDidChange()
                let label = comics.count == 1 ? "“\(comics[0].title)”" : "\(comics.count) comics"
                showToast("Moved \(label) to the Trash") { await self.restore(comics.map(\.id)) }
            } catch { report(error) }
        }
    }

    /// Restores trashed comics, moving their files back from the system Trash when needed.
    func restore(_ ids: [Int64]) async {
        for id in ids {
            guard let trashed = try? await db.trashedFilePath(id), let comic = try? await db.read({ db in
                try db.first("SELECT file_path FROM comics WHERE id = ?", [id]) { $0.string(0) ?? "" }
            }) else { continue }
            if !FileManager.default.fileExists(atPath: comic) && FileManager.default.fileExists(atPath: trashed) {
                try? FileManager.default.moveItem(atPath: trashed, toPath: comic)
            }
        }
        try? await db.restore(ids)
        libraryDidChange()
    }

    // MARK: - Selection

    func toggleSelection(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func endSelection() {
        selecting = false
        selection.removeAll()
    }

    // MARK: - Feedback

    func showToast(_ message: String, isError: Bool = false, undo: (@MainActor () async -> Void)? = nil) {
        toast = Toast(message: message, isError: isError, undo: undo)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))
            if !Task.isCancelled { toast = nil }
        }
    }

    func undoToast() {
        guard let undo = toast?.undo else { return }
        toast = nil
        Task { await undo() }
    }

    func report(_ error: Error) {
        log.error("\(String(describing: error))")
        showToast("Something went wrong: \(error.localizedDescription)", isError: true)
    }

    /// Runs a database change, refreshes the screens, and optionally confirms it.
    func perform(_ message: String? = nil, _ change: @escaping (Database) async throws -> Void) {
        Task {
            do {
                try await change(db)
                libraryDidChange()
                if let message { showToast(message) }
            } catch { report(error) }
        }
    }
}
