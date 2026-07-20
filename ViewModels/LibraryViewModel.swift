import Foundation
import Combine
import CoreSpotlight
import UserNotifications

// MARK: - Navigation

enum AppDestination: Hashable, Codable {
    case library
    case continueReading
    case favorites
    case readingList
    case publisher(String)
    case tag(String)
    case runs
    case stats
    case history
    case duplicates
    case settings

    var title: String {
        switch self {
        case .library:          return "All Comics"
        case .continueReading:  return "Continue Reading"
        case .favorites:        return "Favorites"
        case .readingList:      return "Reading List"
        case .publisher(let p): return p
        case .tag(let t):       return "#\(t)"
        case .runs:             return "Reading Orders"
        case .stats:            return "Statistics"
        case .history:          return "History"
        case .duplicates:       return "Possible Duplicates"
        case .settings:         return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library:         return "books.vertical.fill"
        case .continueReading: return "book.open.fill"
        case .favorites:       return "heart.fill"
        case .readingList:     return "bookmark.fill"
        case .publisher:       return "building.columns"
        case .tag:             return "tag"
        case .runs:            return "list.bullet.rectangle.portrait.fill"
        case .stats:           return "chart.bar.xaxis"
        case .history:         return "clock.fill"
        case .duplicates:      return "doc.on.doc"
        case .settings:        return "gear"
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    static let shared = LibraryViewModel()

    @Published var comics:            [Comic] = []
    @Published var publishers:        [String] = []
    @Published var allTags:           [(tag: Tag, count: Int)] = []
    @Published var inProgressComics:  [Comic] = []
    @Published var destination: AppDestination = .library
    @Published var selectedSeries:    String? = nil
    @Published var searchText:        String = ""
    @Published var sortOrder: DatabaseManager.SortOrder =
        DatabaseManager.SortOrder(rawValue: UserDefaults.standard.string(forKey: "comicSortOrder") ?? "") ?? .manual {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "comicSortOrder") }
    }
    @Published var scanState:           LibraryScanner.ScanState = .init()
    @Published var isScanning:          Bool = false
    @Published var showScanReport:      Bool = false
    private var scanReportDismissTask: DispatchWorkItem?
    @Published var isResyncing:         Bool = false
    @Published var isLoading:           Bool = false
    @Published var isLibraryAvailable:  Bool = true
    @Published var selectedComic:     Comic? = nil
    @Published var selectedRun:       Run? = nil
    @Published var readerComic:       Comic? = nil

    // Browse hierarchy state
    @Published var characterGroups:   [DatabaseManager.CharacterGroup] = []
    @Published var seriesGroups:      [DatabaseManager.SeriesGroup] = []
    @Published var selectedGroup:     DatabaseManager.CharacterGroup? = nil
    @Published var useGroupedView:    Bool = true

    // Bulk selection
    @Published var bulkMode:          Bool = false
    @Published var selectedComicIds:  Set<Int64> = []

    // Series manager sheet trigger
    @Published var showSeriesManager: Bool = false

    // Possible duplicates (same publisher+series+issue# imported under different filenames)
    @Published var duplicateGroups:   [[Comic]] = []

    var selectedSection: SidebarSection {
        switch destination {
        case .runs:            return .runs
        case .stats:           return .stats
        case .history:         return .history
        case .duplicates:      return .duplicates
        case .continueReading: return .continueReading
        case .favorites:       return .favorites
        case .readingList:     return .readingList
        default:               return .library
        }
    }

    var activePublisher: String? {
        if case .publisher(let p) = destination { return p }
        return nil
    }

    var activeTag: String? {
        if case .tag(let t) = destination { return t }
        return nil
    }

    enum SidebarSection: Hashable { case library, continueReading, favorites, readingList, runs, stats, history, duplicates }

    enum BrowseLevel { case characters, seriesGroups, issues }
    var browseLevel: BrowseLevel {
        if !useGroupedView || selectedSection != .library || activeTag != nil { return .issues }
        if selectedSeries != nil { return .issues }
        if selectedGroup  != nil { return .seriesGroups }
        return .characters
    }

    private var db: DatabaseManager { .shared }
    private var watcher: FileWatcher?
    private var searchCancellable: AnyCancellable?
    var libraryPath: String { UserDefaults.standard.string(forKey: "libraryPath") ?? "" }

    private init() {
        #if os(iOS)
        // Security-scope access to a bookmarked library folder must be re-started every
        // process launch — iOS revokes it on relaunch even though the bookmark stays valid.
        // Must happen before startWatcher()/reload() below touch the library path.
        if let folder = resolveLibraryFolderBookmark() {
            UserDefaults.standard.set(folder.path, forKey: "libraryPath")
        }
        #endif

        useGroupedView = true  // grouped hierarchy is the only browse mode

        // Restore last destination before initial reload so the right data loads
        if let data = UserDefaults.standard.data(forKey: "session.destination"),
           let dest = try? JSONDecoder().decode(AppDestination.self, from: data) {
            destination = dest
            if case .tag = dest { useGroupedView = false }
        }

        searchCancellable = $searchText
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
        reload()
        startWatcher()
        reparseMetaIfNeeded()
        rehashLibraryIfNeeded()
        refreshDuplicates()

        #if os(macOS)
        // FSEvents only reports changes from the moment the watcher starts (kFSEventStreamEventIdSinceNow)
        // — it has no memory of what happened while the app wasn't running, so anything added
        // or removed between quit and relaunch was invisible until the user remembered to hit
        // Scan. The scan itself is already incremental (only touches paths it doesn't already
        // know about), so this stays fast on the common case of nothing new having changed.
        scan()
        #endif

        // Restore library drill-down state (group/series) after initial data load
        if case .library = destination { restoreLibraryDrillDown() }
    }

    // MARK: - Session persistence

    func saveNavigationState() {
        if let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: "session.destination")
        }
        UserDefaults.standard.set(selectedGroup?.groupName ?? "", forKey: "session.groupName")
        UserDefaults.standard.set(selectedGroup?.publisher ?? "", forKey: "session.groupPublisher")
        UserDefaults.standard.set(selectedSeries ?? "", forKey: "session.series")
    }

    private func restoreLibraryDrillDown() {
        let groupName = UserDefaults.standard.string(forKey: "session.groupName") ?? ""
        let groupPub  = UserDefaults.standard.string(forKey: "session.groupPublisher") ?? ""
        let series    = UserDefaults.standard.string(forKey: "session.series") ?? ""
        guard !groupName.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [db] in
            let groups = db.characterGroups(publisher: nil, search: nil)
            guard let group = groups.first(where: { $0.groupName == groupName && $0.publisher == groupPub })
            else { return }
            let seriesList = db.seriesGroups(groupName: groupName, publisher: groupPub.isEmpty ? nil : groupPub)
            await MainActor.run {
                self.selectedGroup = group
                if !series.isEmpty, seriesList.contains(where: { $0.series == series }) {
                    self.selectedSeries = series
                    self.reload()
                } else {
                    self.seriesGroups = seriesList
                }
            }
        }
    }

    // One-time migration: re-derive publisher/character/series from folder structure.
    // Runs in the background; resets the flag so a manual trigger (Settings) can force it again.
    func reparseMetaIfNeeded() {
        // Bump version key when the reparse logic changes so all users get the updated fix.
        let key = "folderMetaReparseV3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = libraryPath
        guard !path.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            LibraryScanner.shared.reparseAllMeta(libraryPath: path)
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.async { self?.reload() }
        }
    }

    // One-time migration: recompute every comic's file_hash with the current algorithm.
    // See LibraryScanner.rehashAll() — bump the version key if fileHash()'s formula changes.
    func rehashLibraryIfNeeded() {
        let key = "fileHashRehashV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard !libraryPath.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            LibraryScanner.shared.rehashAll()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// One button that actually fixes things: rescans for file changes, then re-derives
    /// metadata (publisher/character/series/issue number) for every comic from its folder
    /// path and filename, respecting any manual edits (meta_edited=1 rows are skipped).
    /// Previously a user had to know that "Scan Library" only catches new/removed files and
    /// separately find "Re-parse Library Metadata" buried in Settings to fix drifted
    /// ordering or metadata — this does both in one visible, one-button action.
    func resyncLibrary() {
        let path = libraryPath
        guard !path.isEmpty, !isScanning, !isResyncing else { return }
        isResyncing = true
        LibraryScanner.shared.scan(libraryPath: path) { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanState  = state
                self.isScanning = state.running
                guard !state.running else { return }
                DispatchQueue.global(qos: .utility).async {
                    LibraryScanner.shared.reparseAllMeta(libraryPath: path)
                    DispatchQueue.main.async {
                        self.reload()
                        self.indexSpotlight()
                        self.refreshDuplicates()
                        self.isResyncing = false
                    }
                }
            }
        }
    }

    // MARK: - Load

    private var reloadWorkItem: DispatchWorkItem?
    // Guards against an older, slower reload overwriting a newer one's results
    // when rapid successive reload() calls each spawn their own detached query.
    private var reloadGeneration = 0

    func reload() {
        // Debounce: coalesce rapid consecutive calls into one (16ms window)
        reloadWorkItem?.cancel()
        let w = DispatchWorkItem { [weak self] in self?._reload() }
        reloadWorkItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: w)
    }

    private func _reload() {
        isLoading = true
        reloadGeneration += 1
        let gen = reloadGeneration
        let section = selectedSection

        if section == .library && useGroupedView && selectedSeries == nil && activeTag == nil && searchText.isEmpty {
            loadCharacterGroups()
            return
        }

        let pub   = activePublisher
        let ser   = selectedSeries
        let tag   = activeTag
        let q     = searchText.isEmpty ? nil : searchText
        let sort  = sortOrder
        let group = selectedGroup

        Task.detached(priority: .userInitiated) { [db] in
            let pubs = db.publishers()
            let tags = db.allTags()

            guard section == .library || section == .continueReading
                || section == .favorites || section == .readingList else {
                await MainActor.run {
                    guard gen == self.reloadGeneration else { return }
                    self.publishers = pubs; self.allTags = tags; self.isLoading = false
                }
                return
            }

            let loaded: [Comic]
            switch section {
            case .continueReading:
                loaded = db.inProgress()
            case .favorites:
                loaded = db.allComics(publisher: pub, search: q, sortOrder: sort, favoritesOnly: true)
            case .readingList:
                loaded = db.allComics(publisher: pub, search: q, sortOrder: sort, readingListOnly: true)
            default:
                let character    = group?.character
                let nullCharOnly = group != nil && character == nil
                loaded = db.allComics(publisher: pub, character: character, series: ser,
                                      search: q, sortOrder: sort,
                                      nullCharacterOnly: nullCharOnly, tag: tag)
            }
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                self.comics     = loaded
                self.publishers = pubs
                self.allTags    = tags
                self.isLoading  = false
            }
        }
    }

    private func loadCharacterGroups() {
        reloadGeneration += 1
        let gen = reloadGeneration
        let pub = activePublisher
        let q   = searchText.isEmpty ? nil : searchText
        Task.detached(priority: .userInitiated) { [db] in
            let groups = db.characterGroups(publisher: pub, search: q)
            let pubs   = db.publishers()
            let tags   = db.allTags()
            let shelf  = db.inProgress(limit: 8)
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                self.characterGroups   = groups
                self.publishers        = pubs
                self.allTags           = tags
                self.inProgressComics  = shelf
                self.comics            = []
                self.isLoading         = false
            }
        }
    }

    func select(_ item: AppDestination) {
        destination       = item
        selectedSeries    = nil
        selectedGroup     = nil
        selectedComic     = nil
        bulkMode          = false
        selectedComicIds.removeAll()
        // A macOS main-menu shortcut (Cmd+1…8) still fires even while the Series Manager
        // sheet is open. Since it's bound to selectedSeries, leaving it presented after that
        // becomes nil shows a permanently blank sheet the user can only escape via Cancel.
        showSeriesManager = false
        if case .tag = item { useGroupedView = false } else { useGroupedView = true }
        saveNavigationState()
        reload()
    }

    func clearAllFilters() {
        searchText     = ""
        selectedSeries = nil
        selectedGroup  = nil
        select(.library)
    }

    func selectSeries(_ series: String?) {
        selectedSeries = series
        reload()
    }

    // MARK: - Hierarchical browsing

    func drillIntoGroup(_ group: DatabaseManager.CharacterGroup) {
        let pub = activePublisher
        reloadGeneration += 1
        let gen = reloadGeneration
        Task.detached(priority: .userInitiated) { [db] in
            let series = db.seriesGroups(groupName: group.groupName, publisher: pub)
            await MainActor.run {
                // A newer navigation (drilled elsewhere, or backed out) happened while this
                // query was in flight — applying it now would resurrect an abandoned screen.
                guard gen == self.reloadGeneration else { return }
                self.selectedGroup = group
                if series.count == 1 {
                    self.selectedSeries = series[0].series
                    self.saveNavigationState()
                    self.reload()
                } else {
                    self.seriesGroups = series
                    self.saveNavigationState()
                }
            }
        }
    }

    func drillIntoSeries(_ sg: DatabaseManager.SeriesGroup) {
        selectedSeries = sg.series
        saveNavigationState()
        reload()
    }

    func navigateBack() {
        if selectedSeries != nil {
            selectedSeries = nil
            comics = []
            if let group = selectedGroup {
                let pub = activePublisher
                reloadGeneration += 1
                let gen = reloadGeneration
                Task.detached(priority: .userInitiated) { [db] in
                    let series = db.seriesGroups(groupName: group.groupName, publisher: pub)
                    await MainActor.run {
                        guard gen == self.reloadGeneration else { return }
                        self.seriesGroups = series
                    }
                }
            } else {
                loadCharacterGroups()
            }
        } else if selectedGroup != nil {
            selectedGroup  = nil
            selectedSeries = nil
            comics         = []
            loadCharacterGroups()
        }
        saveNavigationState()
    }

    // MARK: - Bulk operations

    func toggleBulkMode() {
        bulkMode.toggle()
        if !bulkMode { selectedComicIds.removeAll() }
    }

    func toggleSelection(_ id: Int64) {
        if selectedComicIds.contains(id) { selectedComicIds.remove(id) }
        else { selectedComicIds.insert(id) }
    }

    func selectAll() { selectedComicIds = Set(comics.map(\.id)) }

    func bulkMarkRead() {
        let updates = comics
            .filter { selectedComicIds.contains($0.id) }
            .map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) }
        db.updateProgress(updates)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkMarkUnread() {
        db.updateProgress(selectedComicIds.map { (comicId: $0, page: 0) })
        selectedComicIds.removeAll()
        reload()
    }

    func bulkAddToReadingList() {
        db.setInReadingList(Array(selectedComicIds), true)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkRemoveFromReadingList() {
        db.setInReadingList(Array(selectedComicIds), false)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkReassign(series: String?, publisher: String?) {
        db.bulkReassign(ids: Array(selectedComicIds), series: series, publisher: publisher)
        selectedComicIds.removeAll()
        reload()
        refreshDuplicates()
    }

    func bulkDelete() {
        let ids = Array(selectedComicIds)
        db.softDelete(ids)
        ids.forEach { ThumbnailCache.shared.evict($0) }
        selectedComicIds.removeAll()
        bulkMode = false
        reload()
        refreshDuplicates()
    }

    // MARK: - Scan / import

    func scan() {
        let path = libraryPath
        guard !path.isEmpty, !isScanning else { return }
        isScanning = true
        scanState = .init()   // Clear previous error before starting a fresh scan
        LibraryScanner.shared.scan(libraryPath: path) { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanState  = state
                self.isScanning = state.running
                if !state.running {
                    self.reload()
                    self.indexSpotlight()
                    self.notifyScanComplete(added: state.added)
                    self.refreshDuplicates()
                    self.presentScanReport(state)
                }
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        let path = libraryPath
        Task.detached(priority: .utility) { [weak self] in
            for url in urls { LibraryScanner.shared.addSingle(url: url, libraryPath: path) }
            await self?.reload()
            await self?.refreshDuplicates()
            // Prewarm only the newly imported comics — not the entire library
            let paths = urls.map(\.path)
            let newComics = DatabaseManager.shared.comics(withPaths: paths)
            if !newComics.isEmpty { ThumbnailCache.shared.prewarm(comics: newComics) }
        }
    }

    func refreshDuplicates() {
        Task.detached(priority: .utility) { [db] in
            let groups = db.duplicateGroups()
            await MainActor.run { self.duplicateGroups = groups }
        }
    }

    func openReader(_ comic: Comic) { readerComic = comic }
    func openReader(id: Int64) { if let c = db.comic(id: id) { readerComic = c } }
    func closeReader() { readerComic = nil }

    func clearLibrary(resetPreferences: Bool = false) {
        // cancel() only flips a flag checked between files in the scan loop — it does not
        // wait for the scan thread to stop, so a cancelled scan's final flushPending() can
        // still be sitting on (or about to join) the scanner's serial queue. Clearing the DB
        // here directly could race that tail write and have a few comics reappear right
        // after "Clear Library" finishes. Routing the actual clear through the same queue
        // guarantees it runs after any in-flight scan work, not concurrently with it.
        LibraryScanner.shared.cancel()
        isScanning = false

        // UI resets immediately — none of this depends on the DB clear having happened yet.
        selectedComic = nil; selectedRun = nil; readerComic = nil
        selectedGroup = nil; selectedSeries = nil
        bulkMode = false; selectedComicIds.removeAll()
        comics = []; characterGroups = []; seriesGroups = []

        if resetPreferences {
            let keep: Set<String> = ["onboardingCompletedForBuild"]
            let all = UserDefaults.standard.dictionaryRepresentation().keys
            for key in all where !keep.contains(key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        LibraryScanner.shared.runAfterCurrentWork { [db] in
            db.clearAll()
            ThumbnailCache.shared.clearAll()
            CSSearchableIndex.default().deleteAllSearchableItems { _ in }
            DispatchQueue.main.async { self.reload() }
        }
    }

    // MARK: - File watcher

    func startWatcher() {
        let path = libraryPath
        guard !path.isEmpty else { return }
        let w = FileWatcher(
            onAdded: { [weak self] url in
                self?.isLibraryAvailable = true
                LibraryScanner.shared.addSingle(url: url, libraryPath: path)
                self?.reload()
            },
            onRemoved: { [weak self] p in
                LibraryScanner.shared.removeSingle(path: p)
                self?.reload()
            },
            onVolumeUnavailable: { [weak self] in
                self?.isLibraryAvailable = false
            }
        )
        w.start(path: path)
        watcher = w
    }

    func restartWatcher() { watcher?.stop(); watcher = nil; startWatcher() }

    // MARK: - App termination

    /// Synchronous, best-effort cleanup run on app quit: stop watching the filesystem,
    /// cancel any in-flight scan (and the `unar` subprocess it may be blocked on), and
    /// checkpoint+close the database connection so nothing is left running or holding
    /// a file handle once the process actually exits.
    func shutdown() {
        watcher?.stop()
        watcher = nil
        LibraryScanner.shared.cancel()
        #if os(macOS)
        LibraryScanner.shared.terminateActiveProcess()
        #endif
        db.checkpointAndClose()
    }

    func retryAfterVolumeUnavailable() {
        isLibraryAvailable = true
        restartWatcher()
        scan()
    }

    // MARK: - Mutations

    func markAllRead() {
        db.updateProgress(comics.map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) })
        reload()
    }

    func setSeriesCover(_ comic: Comic) {
        db.setSeriesCover(series: comic.series, publisher: comic.publisher, comicId: comic.id)
        reload()
    }

    func moveComic(id: Int64, before targetId: Int64) {
        guard id != targetId else { return }
        var list = comics
        guard let fromIdx = list.firstIndex(where: { $0.id == id }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.id == targetId }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        comics = list
        db.reorderComics(orderedIds: list.map(\.id))
    }

    func moveSeriesGroup(fromSeries: String, toSeries: String) {
        guard fromSeries != toSeries,
              let group = selectedGroup else { return }
        var list = seriesGroups
        guard let fromIdx = list.firstIndex(where: { $0.series == fromSeries }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.series == toSeries }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        seriesGroups = list
        db.reorderSeriesGroups(groupName: group.groupName, publisher: group.publisher,
                               orderedSeries: list.map(\.series))
    }

    func setCharacterGroupCover(group: DatabaseManager.CharacterGroup, imageURL: URL) {
        guard let path = ThumbnailCache.shared.saveCustomGroupCover(
            groupName: group.groupName,
            publisher: group.publisher,
            imageURL: imageURL
        ) else { return }
        db.setCharacterGroupCover(groupName: group.groupName, publisher: group.publisher, imagePath: path)
        reload()
    }

    func clearCharacterGroupCover(group: DatabaseManager.CharacterGroup) {
        db.clearCharacterGroupCover(groupName: group.groupName, publisher: group.publisher)
        reload()
    }

    // Patches the comic in place (same approach as updateProgress below) instead of
    // reload()'s full debounced SQL requery + resort of the whole filtered library — these
    // four are the most frequently-tapped actions in the app (grid context menus, star
    // ratings, detail pages), and with a large library reload() on every single tap was a
    // visible stutter. When the current section's membership actually depends on the field
    // being changed (Favorites/Reading List/Continue Reading), the comic is additionally
    // removed from the in-memory list so it doesn't linger somewhere it should have
    // disappeared from — every other section (Library, a publisher, a tag, a series) never
    // filters on these fields, so a plain in-place update is already fully correct there.
    private func patchComicLocally(_ comicId: Int64, removeIfNoLongerVisible: Bool = false, _ mutate: (inout Comic) -> Void) {
        guard let idx = comics.firstIndex(where: { $0.id == comicId }) else { return }
        mutate(&comics[idx])
        if selectedComic?.id == comicId { mutate(&selectedComic!) }
        if removeIfNoLongerVisible { comics.remove(at: idx) }
    }

    func toggleFavorite(_ comic: Comic) {
        let newValue = !comic.isFavorite
        db.setFavorite(comic.id, newValue)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .favorites && !newValue) {
            $0.isFavorite = newValue
        }
    }

    func toggleReadingList(_ comic: Comic) {
        let newValue = !comic.inReadingList
        db.setInReadingList(comic.id, newValue)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .readingList && !newValue) {
            $0.inReadingList = newValue
        }
    }

    func setRating(_ comic: Comic, rating: Int) {
        db.setRating(comic.id, rating: rating)
        patchComicLocally(comic.id) { $0.rating = rating }
    }

    func markRead(_ comic: Comic) {
        let page = max(0, comic.pageCount - 1)
        db.updateProgress(comicId: comic.id, page: page)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .continueReading) {
            $0.progress = page
        }
    }

    func markUnread(_ comic: Comic) {
        db.updateProgress(comicId: comic.id, page: 0)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .continueReading) {
            $0.progress = 0
        }
    }
    func markRead(_ comics: [Comic]) {
        db.updateProgress(comics.map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) })
        reload()
    }

    func setReview(_ comic: Comic, review: String?) { db.setComicReview(comic.id, review: review?.isEmpty == false ? review : nil) }
    func updateMeta(comicId: Int64, fields: [(String, Any?)]) { db.updateMeta(comicId: comicId, fields: fields) }

    func addTag(name: String, to comic: Comic) { db.addTag(name: name, to: comic.id) }
    func removeTag(tagId: Int64, from comic: Comic) { db.removeTag(tagId: tagId, from: comic.id) }

    func addToShelf(comicId: Int64, shelfId: Int64) { db.addToShelf(comicId: comicId, shelfId: shelfId) }
    func removeFromShelf(comicId: Int64, shelfId: Int64) { db.removeFromShelf(comicId: comicId, shelfId: shelfId) }

    func restoreComic(id: Int64) { db.restoreComic(id: id); reload() }

    func setReadingGoal(year: Int, count: Int) { db.setReadingGoal(year: year, count: count) }

    func setSeriesCoverById(series: String, publisher: String, comicId: Int64) {
        db.setSeriesCover(series: series, publisher: publisher, comicId: comicId)
        ThumbnailCache.shared.evict(comicId)
        reload()
    }
    func clearSeriesCoverByName(series: String, publisher: String) {
        db.clearSeriesCover(series: series, publisher: publisher)
        reload()
    }
    func renameSeries(oldName: String, publisher: String?, newName: String) {
        db.renameSeries(oldName: oldName, publisher: publisher, newName: newName)
        reload()
        refreshDuplicates()
    }
    func seriesNameCollides(oldName: String, publisher: String?, newName: String) -> Bool {
        db.seriesNameCollides(oldName: oldName, publisher: publisher, newName: newName)
    }
    func reorderComics(orderedIds: [Int64]) { db.reorderComics(orderedIds: orderedIds) }

    @discardableResult
    func createRun(title: String, description: String) -> Int64 { db.createRun(title: title, description: description) }
    func deleteRun(_ runId: Int64) { db.deleteRun(runId) }

    func addToRun(runId: Int64, comicIds: [Int64]) { db.addToRun(runId: runId, comicIds: comicIds) }
    func removeFromRun(runId: Int64, comicIds: [Int64]) { db.removeFromRun(runId: runId, comicIds: comicIds) }
    func reorderRun(runId: Int64, orderedIds: [Int64]) { db.reorderRun(runId: runId, orderedIds: orderedIds) }
    func updateRun(id: Int64, title: String, description: String, buyLink: String?) { db.updateRun(id: id, title: title, description: description, buyLink: buyLink) }
    func setRunRating(_ runId: Int64, rating: Int, review: String?) { db.setRunRating(runId, rating: rating, review: review) }
    func setRunItemNotes(_ itemId: Int64, notes: String) { db.setRunItemNotes(itemId, notes: notes) }

    func delete(_ toDelete: [Comic]) {
        db.softDelete(toDelete.map(\.id))
        for c in toDelete { ThumbnailCache.shared.evict(c.id) }
        reload()
        refreshDuplicates()
    }

    func updateProgress(comic: Comic, page: Int) {
        db.updateProgress(comicId: comic.id, page: page)
        if let idx = comics.firstIndex(where: { $0.id == comic.id }) { comics[idx].progress = page }
        if selectedComic?.id == comic.id { selectedComic?.progress = page }
    }

    // MARK: - Spotlight

    func indexSpotlight() {
        Task.detached(priority: .background) {
            let all = DatabaseManager.shared.allComics()
            let items: [CSSearchableItem] = all.map { comic in
                let attrs = CSSearchableItemAttributeSet(contentType: .data)
                attrs.title            = comic.title
                attrs.contentDescription = "\(comic.series) · \(comic.publisher)"
                attrs.keywords         = [comic.series, comic.publisher, comic.title]
                return CSSearchableItem(
                    uniqueIdentifier: "comicarc-\(comic.id)",
                    domainIdentifier: "com.comicarc.library",
                    attributeSet: attrs
                )
            }
            try? await CSSearchableIndex.default().indexSearchableItems(items)
        }
    }

    // A scan runs silently on every launch now (not just when the user hits the Scan button),
    // so without some in-app feedback a real reorganization — files renamed, moved, or gone
    // missing since last launch — would be invisible unless the user happened to notice the
    // comic count changed. Only surfaced when there's something worth reporting; a no-op scan
    // (the common case) stays silent rather than showing "0 added, 0 removed" every launch.
    private func presentScanReport(_ state: LibraryScanner.ScanState) {
        guard state.error == nil, !state.cancelled else { return }
        guard state.added > 0 || state.removed > 0 || state.recovered > 0 || state.stillCorrupted > 0 else { return }
        scanReportDismissTask?.cancel()
        showScanReport = true
        let task = DispatchWorkItem { [weak self] in self?.showScanReport = false }
        scanReportDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func dismissScanReport() {
        scanReportDismissTask?.cancel()
        showScanReport = false
    }

    // MARK: - Scan notifications

    func notifyScanComplete(added: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted, added > 0 else { return }
            let content          = UNMutableNotificationContent()
            content.title        = "Library Updated"
            content.body         = "Added \(added) new comic\(added == 1 ? "" : "s") to your library."
            content.sound        = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}
