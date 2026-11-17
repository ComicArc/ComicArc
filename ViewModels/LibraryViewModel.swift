import Foundation
import SwiftUI
import Combine
import CoreSpotlight
import UserNotifications
import os

enum AppDestination: Hashable, Codable {
    case library
    case continueReading
    case favorites
    case publisher(String)
    case tag(String)
    case runs
    case favoriteMoments
    case stats
    case libraryHealth
    case settings

    var title: String {
        switch self {
        case .library:              return "All Comics"
        case .continueReading:      return "Continue Reading"
        case .favorites:            return "Favorites"
        case .publisher(let p):     return p
        case .tag(let t):           return "#\(t)"
        case .runs:                 return "Reading Paths"
        case .favoriteMoments:      return "Highlights"
        case .stats:                return "Stats"
        case .libraryHealth:        return "Library Health"
        case .settings:             return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library:              return "books.vertical.fill"
        case .continueReading:      return "book.open.fill"
        case .favorites:            return "heart.fill"
        case .publisher:            return "building.columns"
        case .tag:                  return "tag"
        case .runs:                 return "list.bullet.rectangle.portrait.fill"
        case .favoriteMoments:      return "star.circle.fill"
        case .stats:                return "chart.bar.xaxis"
        case .libraryHealth:        return "stethoscope"
        case .settings:             return "gear"
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
    /// Total in-progress comics for the sidebar badge (`inProgressComics` is capped at the shelf
    /// size).
    @Published var inProgressCount:   Int = 0
    // Next unstarted issue of series you've recently finished an issue of.
    @Published var readNextSuggestions: [Comic] = []
    @Published var destination: AppDestination = .library
    @Published var selectedSeries:    String? = nil
    @Published var searchText:        String = ""
    @Published var sortOrder: DatabaseManager.SortOrder =
        DatabaseManager.SortOrder(rawValue: UserDefaults.standard.string(forKey: "comicSortOrder") ?? "") ?? .manual {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "comicSortOrder") }
    }

    /// Persists across navigation, like sortOrder.
    @Published var unreadOnly: Bool = false { didSet { reload() } }

    @Published var scanState:           LibraryScanner.ScanState = .init()
    @Published var isScanning:          Bool = false
    @Published var showScanReport:      Bool = false
    @Published var libraryHealthReport: LibraryHealthReport? = nil
    @Published var renameCandidateCount: Int = 0
    /// Comics the scanner gave up on (zero pages after 3 retries), shown with a broken-file badge.
    @Published var brokenComicIds: Set<Int64> = []
    /// Sort orders with no data in this library (e.g. Writer when no comic has credits).
    @Published var emptySortOrders: Set<DatabaseManager.SortOrder> = []

    struct ImportProgress: Equatable { var done: Int; var total: Int }
    struct ImportSummary: Equatable {
        var added: Int
        var skipped: Int
        var failures: [(name: String, reason: String)]
        static func == (lhs: ImportSummary, rhs: ImportSummary) -> Bool {
            lhs.added == rhs.added && lhs.skipped == rhs.skipped &&
            lhs.failures.map(\.name) == rhs.failures.map(\.name)
        }
    }
    @Published var importProgress: ImportProgress? = nil
    @Published var lastImportSummary: ImportSummary? = nil
    @Published var renameSuggestionDismissed: Bool = false
    var scanReportDismissTask: DispatchWorkItem?

    let undoToastController = UndoToastController()
    var pendingUndo: UndoToastController.Action? { undoToastController.pending }

    @Published var isResyncing:         Bool = false

    /// True during any library-wide operation, including a resync's metadata pass after its scan
    /// ends.
    var isBusy: Bool { isScanning || isResyncing }

    @Published var isLoading:           Bool = false
    @Published var isLibraryAvailable:  Bool = true
    @Published var selectedComic:     Comic? = nil
    @Published var selectedRun:       Run? = nil
    /// All Reading Paths, kept warm for menus.
    @Published var runs: [Run] = []
    /// Reader presentation state; `readerComic` and friends below forward to it.
    let readerCoordinator = ReaderCoordinator()
    var readerInitialPage: Int? {
        get { readerCoordinator.initialPage }
        set { readerCoordinator.initialPage = newValue }
    }
    var readerRunId: Int64? {
        get { readerCoordinator.runId }
        set { readerCoordinator.runId = newValue }
    }
    var readerComic: Comic? {
        get { readerCoordinator.comic }
        set { readerCoordinator.comic = newValue }
    }

    @Published var characterGroups:   [DatabaseManager.CharacterGroup] = []
    @Published var seriesGroups:      [DatabaseManager.SeriesGroup] = []
    @Published var selectedGroup:     DatabaseManager.CharacterGroup? = nil
    @Published var useGroupedView:    Bool = true

    @Published var bulkMode:          Bool = false
    @Published var selectedComicIds:  Set<Int64> = []

    @Published var showSeriesManager: Bool = false

    @Published var duplicateGroups:   [[Comic]] = []
    @Published var pendingMetadataConflicts: [MetadataConflictRow] = []

    /// Duplicates plus metadata conflicts, shown as a badge on Library Health.
    var libraryHealthAlertCount: Int {
        duplicateGroups.count + pendingMetadataConflicts.count
    }

    var selectedSection: SidebarSection {
        switch destination {
        case .runs:            return .runs
        case .favoriteMoments: return .favoriteMoments
        case .stats:           return .stats
        case .libraryHealth:   return .libraryHealth
        case .continueReading: return .continueReading
        case .favorites:       return .favorites
        case .settings:        return .settings
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

    enum SidebarSection: Hashable { case library, continueReading, favorites, runs, favoriteMoments, stats, libraryHealth, settings }

    enum BrowseLevel { case characters, seriesGroups, issues }
    var browseLevel: BrowseLevel {
        if !useGroupedView || selectedSection != .library || activeTag != nil { return .issues }
        if selectedSeries != nil { return .issues }
        if selectedGroup  != nil { return .seriesGroups }
        return .characters
    }

    var db: DatabaseManager { .shared }
    var watcher: FileWatcher?
    var searchCancellable: AnyCancellable?
    private var readerCoordinatorCancellable: AnyCancellable?
    private var undoToastCancellable: AnyCancellable?

    /// The configured library folders. Published so views redraw when one is added or removed.
    @Published private var libraryPathsStorage: [String] = LibraryFolders.readMigrating()
    var libraryPaths: [String] {
        get { libraryPathsStorage }
        set {
            libraryPathsStorage = newValue
            LibraryFolders.write(newValue)
        }
    }

    func addLibraryFolder(_ path: String) {
        var paths = libraryPaths
        guard !paths.contains(path) else { return }
        paths.append(path)
        libraryPaths = paths
        restartWatcher()
        scan()
    }

    /// How many comics live under `path`, for the remove-folder confirmation.
    func comicCount(underFolder path: String) -> Int {
        db.comicIds(underFolder: path).count
    }

    func removeLibraryFolder(_ path: String) {
        // Removing a folder soft-deletes its comics (reason "folder_removed"), so they can be
        // restored from Trash.
        let orphaned = db.comicIds(underFolder: path)
        if !orphaned.isEmpty {
            db.softDelete(orphaned, reason: "folder_removed")
            orphaned.forEach { ThumbnailCache.shared.evict($0) }
            removeFromSpotlight(orphaned)
        }

        var paths = libraryPaths
        paths.removeAll { $0 == path }
        libraryPaths = paths
        #if os(iOS) || os(visionOS)
        // Also drop its bookmark, or the path comes back on next launch.
        removeLibraryFolderBookmark(path: path)
        #endif
        restartWatcher()
        reload()
    }

    private init() {
        #if os(iOS) || os(visionOS)

        let resolved = resolveLibraryFolderBookmarks()
        if !resolved.isEmpty { libraryPaths = resolved.map(\.path) }
        #endif

        useGroupedView = true

        searchCancellable = $searchText
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
        // Forward the coordinator's changes so views observing `vm` re-render.
        readerCoordinatorCancellable = readerCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        undoToastCancellable = undoToastController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        reload()
        startWatcher()
        reparseMetaIfNeeded()
        rehashLibraryIfNeeded()
        refreshDuplicates()
        refreshRuns()

        // Launch scans are triggered by scenePhase in the app entry points, not here.
    }

    func reparseMetaIfNeeded() {
        // V4: backfills folder_group for libraries scanned before that column existed.
        let key = "folderMetaReparseV4"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let paths = libraryPaths
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            LibraryScanner.shared.reparseAllMeta(libraryRoots: paths)
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func rehashLibraryIfNeeded() {
        let key = "fileHashRehashV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard !libraryPaths.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            LibraryScanner.shared.rehashAll()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    var reloadWorkItem: DispatchWorkItem?

    var reloadGeneration = 0
    /// Separate from `reloadGeneration` so a shelf refresh never cancels a library reload.
    private var homeShelvesGeneration = 0

    // Separate generations for the background health computations, so navigation doesn't discard
    // them.
    var duplicatesGeneration = 0
    var healthGeneration = 0
    var renameCandidatesGeneration = 0
    var runsGeneration = 0

    func reload() {
        reloadWorkItem?.cancel()
        let w = DispatchWorkItem { [weak self] in self?._reload() }
        reloadWorkItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: w)
    }

    func _reload() {
        isLoading = true
        reloadGeneration += 1
        let gen = reloadGeneration
        let section = selectedSection

        let hasActiveFilter = unreadOnly
        if section == .library && useGroupedView && selectedSeries == nil && activeTag == nil
            && searchText.isEmpty && !hasActiveFilter {
            loadCharacterGroups()
            return
        }

        let pub   = activePublisher
        let ser   = selectedSeries
        let tag   = activeTag
        let q     = searchText.isEmpty ? nil : searchText
        let sort  = sortOrder
        let group = selectedGroup
        let unread = unreadOnly

        Task.detached(priority: .userInitiated) { [db] in
            let pubs = db.publishers()
            let tags = db.allTags()

            guard section == .library || section == .continueReading
                || section == .favorites else {
                await MainActor.run {
                    guard gen == self.reloadGeneration else { return }
                    self.publishers = pubs; self.allTags = tags; self.isLoading = false
                }
                return
            }

            let loaded: [Comic]
            switch section {
            case .continueReading:
                loaded = db.inProgress(search: q)
            case .favorites:
                loaded = db.allComics(publisher: pub, search: q, sortOrder: sort, favoritesOnly: true,
                                      unreadOnly: unread)
            default:
                let character    = group?.character
                let nullCharOnly = group != nil && character == nil
                loaded = db.allComics(publisher: pub, character: character, series: ser,
                                      search: q, sortOrder: sort,
                                      nullCharacterOnly: nullCharOnly, tag: tag,
                                      unreadOnly: unread)
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

    func loadCharacterGroups() {
        reloadGeneration += 1
        let gen = reloadGeneration
        let pub = activePublisher
        let q   = searchText.isEmpty ? nil : searchText
        Task.detached(priority: .userInitiated) { [db] in
            let groups = db.characterGroups(publisher: pub, search: q)
            let pubs   = db.publishers()
            let tags   = db.allTags()
            let shelf  = db.inProgress(limit: 8)
            let inProgressCount = db.inProgressCount()
            let readNext = Self.computeReadNextSuggestions(db: db)
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                self.characterGroups     = groups
                self.publishers          = pubs
                self.allTags             = tags
                self.inProgressComics    = shelf
                self.inProgressCount     = inProgressCount
                self.readNextSuggestions = readNext
                self.comics              = []
                self.isLoading           = false
            }
        }
    }

    nonisolated private static func computeReadNextSuggestions(db: DatabaseManager) -> [Comic] {
        var seenSeries = Set<String>()
        var suggestions: [Comic] = []
        for finished in db.recentlyFinished(limit: 60) {
            let key = "\(finished.publisher)|\(finished.series)"
            guard seenSeries.insert(key).inserted else { continue }
            let furthest = db.allComics(publisher: finished.publisher, series: finished.series, sortOrder: .manual)
                .last(where: \.isFinished) ?? finished
            guard let next = db.nextComic(after: furthest), !next.isStarted, !next.isFinished else { continue }
            suggestions.append(next)
            if suggestions.count == 12 { break }
        }
        return suggestions
    }

    func select(_ item: AppDestination) {
        destination       = item
        selectedSeries    = nil
        selectedGroup     = nil
        selectedComic     = nil
        bulkMode          = false
        selectedComicIds.removeAll()

        showSeriesManager = false
        switch item {
        case .tag: useGroupedView = false
        default: useGroupedView = true
        }
        reload()
    }

    func clearAllFilters() {
        searchText     = ""
        selectedSeries = nil
        selectedGroup  = nil
        select(.library)
    }

    func drillIntoGroup(_ group: DatabaseManager.CharacterGroup) {
        // Selection belongs to the grid on screen, so clear it on navigation.
        bulkMode = false
        selectedComicIds.removeAll()
        let pub = activePublisher
        reloadGeneration += 1
        let gen = reloadGeneration
        Task.detached(priority: .userInitiated) { [db] in
            let series = db.seriesGroups(groupName: group.groupName, publisher: pub)
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
                    // Always open the group's series grid, even when it holds one series.
                    self.selectedGroup = group
                    self.seriesGroups = series
                }
            }
        }
    }

    func drillIntoSeries(_ sg: DatabaseManager.SeriesGroup) {
        bulkMode = false
        selectedComicIds.removeAll()
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) { selectedSeries = sg.series }
        reload()
    }

    func navigateBack() {
        bulkMode = false
        selectedComicIds.removeAll()
        if selectedSeries != nil {
            withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) { selectedSeries = nil }
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
            withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) { selectedGroup = nil; selectedSeries = nil }
            comics         = []
            loadCharacterGroups()
        }
    }

    func openReader(_ comic: Comic, atPage page: Int? = nil, runId: Int64? = nil) {
        readerCoordinator.open(comic, atPage: page, runId: runId)
    }
    func openReader(id: Int64, atPage page: Int? = nil, runId: Int64? = nil) {
        guard let c = db.comic(id: id) else { return }
        readerCoordinator.open(c, atPage: page, runId: runId)
    }
    func closeReader() {
        readerCoordinator.close()
        refreshHomeShelves()
    }

    /// Refreshes the home shelves, which progress updates via `patchComicLocally` don't touch.
    func refreshHomeShelves() {
        homeShelvesGeneration += 1
        let gen = homeShelvesGeneration
        Task.detached(priority: .utility) { [db] in
            let shelf = db.inProgress(limit: 8)
            let inProgressCount = db.inProgressCount()
            let readNext = Self.computeReadNextSuggestions(db: db)
            await MainActor.run {
                guard gen == self.homeShelvesGeneration else { return }
                self.inProgressComics    = shelf
                self.inProgressCount     = inProgressCount
                self.readNextSuggestions = readNext
            }
        }
    }

    func startWatcher() {
        let roots = libraryPaths
        guard !roots.isEmpty else { return }
        let w = FileWatcher(
            onAdded: { [weak self] url in
                self?.isLibraryAvailable = true
                // addSingle hashes and parses the file, so keep it off the main thread.
                Task.detached(priority: .utility) {
                    LibraryScanner.shared.addSingle(url: url, libraryRoots: roots)
                    await self?.reload()
                }
            },
            onRemoved: { [weak self] p in
                Task.detached(priority: .utility) {
                    let removedIds = LibraryScanner.shared.removeSingle(path: p)
                    if !removedIds.isEmpty { await self?.removeFromSpotlight(removedIds) }
                    await self?.reload()
                }
            },
            onVolumeUnavailable: { [weak self] in
                self?.isLibraryAvailable = false
            }
        )
        w.start(paths: roots)
        watcher = w
    }

    func restartWatcher() { watcher?.stop(); watcher = nil; startWatcher() }

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

    func patchComicLocally(_ comicId: Int64, removeIfNoLongerVisible: Bool = false, _ mutate: (inout Comic) -> Void) {
        guard let idx = comics.firstIndex(where: { $0.id == comicId }) else { return }
        mutate(&comics[idx])
        if var sc = selectedComic, sc.id == comicId {
            mutate(&sc)
            selectedComic = sc
        }
        if removeIfNoLongerVisible { comics.remove(at: idx) }
        // Invalidate any in-flight reload so it can't overwrite this fresher state.
        reloadGeneration += 1
    }

    func updateProgress(comic: Comic, page: Int) {
        db.updateProgress(comicId: comic.id, page: page)
        patchComicLocally(comic.id) { $0.progress = page }
    }

    /// Called when sequential reading reaches the last page. Sticky, so safe to call on rereads.
    func markFinished(comic: Comic) {
        db.markFinished(comicId: comic.id)
        let now = ISO8601DateFormatter().string(from: Date())
        patchComicLocally(comic.id) { $0.finishedAt = now }
    }

}
