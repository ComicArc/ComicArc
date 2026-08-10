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
    case readingList
    case publisher(String)
    case tag(String)
    case runs
    case diary
    case tierLists
    case favoriteMoments
    case stats
    case history
    case duplicates
    case readingOrderManager
    case metadataConflicts
    case settings

    var title: String {
        switch self {
        case .library:              return "All Comics"
        case .continueReading:      return "Continue Reading"
        case .favorites:            return "Favorites"
        case .readingList:          return "Reading List"
        case .publisher(let p):     return p
        case .tag(let t):           return "#\(t)"
        case .runs:                 return "Reading Paths"
        case .diary:                return "Diary"
        case .tierLists:            return "Tier Lists"
        case .favoriteMoments:      return "Highlights"
        case .stats:                return "Statistics"
        case .history:              return "History"
        case .duplicates:           return "Possible Duplicates"
        case .readingOrderManager:  return "Reading Order Suggestions"
        case .metadataConflicts:    return "Needs Review"
        case .settings:             return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library:              return "books.vertical.fill"
        case .continueReading:      return "book.open.fill"
        case .favorites:            return "heart.fill"
        case .readingList:          return "bookmark.fill"
        case .publisher:            return "building.columns"
        case .tag:                  return "tag"
        case .runs:                 return "list.bullet.rectangle.portrait.fill"
        case .diary:                return "text.book.closed.fill"
        case .tierLists:            return "square.stack.3d.up.fill"
        case .favoriteMoments:      return "star.circle.fill"
        case .stats:                return "chart.bar.xaxis"
        case .history:              return "clock.fill"
        case .duplicates:           return "doc.on.doc"
        case .readingOrderManager:  return "checkmark.seal"
        case .metadataConflicts:    return "exclamationmark.triangle"
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
    // Series the user actively favorites but has fully caught up on -- distinct from
    // inProgressComics (which only covers books with a page already turned). Previously a
    // finished favorite series just vanished from the home screen with no nudge toward its
    // next unread issue.
    @Published var readNextSuggestions: [Comic] = []
    // "Memories" callback -- diary entries logged on this same calendar day in a previous year.
    // Computed once per launch (see refreshOnThisDay(), called from init()), not on every reload,
    // since the result only ever changes once a day.
    @Published var onThisDayEntries: [DiaryEntry] = []
    @Published var savedViews: [SavedLibraryView] = SavedLibraryViews.read()
    // Cross-series taste-based discovery -- distinct from readNextSuggestions, which only ever
    // continues a series the user already follows. This looks at what's rated highly (tags,
    // publisher, writer overlap) and surfaces unread comics from OTHER series, deliberately
    // excluding any series already represented in the liked set (that's readNextSuggestions'
    // job, not this one's).
    @Published var recommendations: [Comic] = []
    /// Ambient, always-visible-while-browsing streak indicator (sidebar), distinct from the same
    /// number already shown in Stats/Year in Review -- refreshed on its own cadence via
    /// `refreshReadingStreak()` rather than piggybacking on a full `loadStats()` reload.
    @Published var readingStreak: Int = 0
    @Published var destination: AppDestination = .library
    @Published var selectedSeries:    String? = nil
    @Published var searchText:        String = ""
    @Published var sortOrder: DatabaseManager.SortOrder =
        DatabaseManager.SortOrder(rawValue: UserDefaults.standard.string(forKey: "comicSortOrder") ?? "") ?? .manual {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "comicSortOrder") }
    }

    /// `minRatingFilter == 0` means "no minimum" (every rating, including unrated). Both persist
    /// across navigation the same way sortOrder does, rather than silently resetting -- so
    /// "show me only what I haven't read" stays on while browsing from series to series.
    @Published var unreadOnly:      Bool = false { didSet { reload() } }
    @Published var minRatingFilter: Int  = 0     { didSet { reload() } }

    @Published var readingOrderMode: DatabaseManager.ReadingOrderMode = .current {
        didSet {
            guard oldValue != readingOrderMode else { return }
            UserDefaults.standard.set(readingOrderMode.rawValue, forKey: "readingOrderMode")
            Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
                await MainActor.run { self.reload() }
            }
        }
    }
    @Published var scanState:           LibraryScanner.ScanState = .init()
    @Published var isScanning:          Bool = false
    @Published var showScanReport:      Bool = false
    @Published var showImportWizard:    Bool = false
    @Published var libraryHealthReport: LibraryHealthReport? = nil
    @Published var renameCandidateCount: Int = 0

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

    /// See `UndoToastController`. `pendingUndo` is a thin passthrough (kept as the same name/type
    /// existing call sites already use) onto the controller's own `@Published` storage.
    let undoToastController = UndoToastController()
    var pendingUndo: UndoToastController.Action? { undoToastController.pending }

    @Published var isResyncing:         Bool = false

    /// A resync's `reparseAllMeta` pass runs after its underlying scan already reports
    /// `isScanning = false`, so checking `isScanning` alone during that window misses it -- any
    /// UI gating "don't let the user start another library-wide operation" should check this,
    /// not either flag individually.
    var isBusy: Bool { isScanning || isResyncing }

    @Published var isLoading:           Bool = false
    @Published var isLibraryAvailable:  Bool = true
    @Published var selectedComic:     Comic? = nil
    @Published var selectedRun:       Run? = nil
    @Published var selectedTierList:  TierList? = nil
    /// The full list, kept live here rather than fetched ad hoc by whichever view needs it --
    /// `ComicCard`'s "Add to Reading Path"/"Add to Tier List" submenus used to call
    /// `DatabaseManager.shared.allRuns()`/`.allTierLists()` synchronously inside their own
    /// `.contextMenu` closure (blocking the main thread every time a card's menu opened); reading
    /// from here instead means that data is already warm.
    @Published var runs:      [Run] = []
    @Published var tierLists: [TierList] = []
    /// The reader-presentation subsystem, genuinely independent of library data/navigation --
    /// see `ReaderCoordinator`'s doc comment. `readerComic`/`readerInitialPage`/`readerRunId`
    /// below are thin passthroughs so every existing call site keeps working unchanged.
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
    @Published var autoPlacedIssues:  [Comic] = []
    @Published var pendingMetadataConflicts: [MetadataConflictRow] = []

    /// So a collapsed "More" Discover section in the sidebar can't silently hide something that
    /// actually needs attention -- shown as a badge on the disclosure row itself even while
    /// collapsed. Shared by Mac's `SidebarView` and iPad's `iPadSidebar`.
    var moreDiscoverAlertCount: Int {
        duplicateGroups.count + autoPlacedIssues.count + pendingMetadataConflicts.count
    }

    var selectedSection: SidebarSection {
        switch destination {
        case .runs:            return .runs
        case .diary:           return .diary
        case .tierLists:       return .tierLists
        case .favoriteMoments: return .favoriteMoments
        case .stats:           return .stats
        case .history:         return .history
        case .duplicates:      return .duplicates
        case .readingOrderManager: return .readingOrderManager
        case .metadataConflicts: return .metadataConflicts
        case .continueReading: return .continueReading
        case .favorites:       return .favorites
        case .readingList:     return .readingList
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

    enum SidebarSection: Hashable { case library, continueReading, favorites, readingList, runs, diary, tierLists, favoriteMoments, stats, history, duplicates, readingOrderManager, metadataConflicts, settings }

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

    /// The list of configured library folders -- the single source of truth every scan/watch/
    /// import operation threads through. Backed by a real `@Published` var (not a plain computed
    /// UserDefaults getter) so SwiftUI views observing this view model -- the Settings folder
    /// list chief among them -- actually redraw when a folder is added or removed, not just
    /// incidentally alongside some unrelated state change. `LibraryFolders.readMigrating()` seeds
    /// the initial value, transparently upgrading an existing install's old single `libraryPath`
    /// value into a one-element array the first time this runs.
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

    /// Comics currently living under `path` -- callers can show this count in a confirmation
    /// before actually removing the folder, since doing so also removes those comics from the
    /// library (see `removeLibraryFolder`).
    func comicCount(underFolder path: String) -> Int {
        db.comicIds(underFolder: path).count
    }

    func removeLibraryFolder(_ path: String) {
        // Previously left every comic from this folder in the library forever, pointing at a
        // path ComicArc no longer manages at all -- soft-deleting them (reason "folder_removed",
        // distinct from a genuinely missing file) means they land in the same Trash/restore flow
        // as everything else instead of becoming permanent, untouchable ghosts.
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
        // Otherwise the underlying security-scoped bookmark survives in its own array and
        // silently re-adds this path back to `libraryPaths` on the next launch.
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
        // `readerComic`/etc. are passthroughs onto `readerCoordinator`'s own `@Published`
        // storage now, not stored properties here -- without forwarding its `objectWillChange`,
        // views observing `vm` wouldn't re-render when only the coordinator's state changes.
        readerCoordinatorCancellable = readerCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        undoToastCancellable = undoToastController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        reload()
        startWatcher()
        reparseMetaIfNeeded()
        rehashLibraryIfNeeded()
        refreshDuplicates()
        refreshOnThisDay()
        refreshRecommendations()
        refreshReadingStreak()
        refreshRuns()
        refreshTierLists()

        // Scanning at launch (and every time the app is brought back to the foreground) is
        // driven uniformly by `scenePhase == .active` in both app entry points (ComicArcMacApp,
        // ComicArcIPadApp) rather than here -- init() itself only needs to get everything else
        // ready. A cold launch's very first `.active` transition covers the "scan on open" case
        // without this also firing a redundant second scan a moment later.
    }

    func reparseMetaIfNeeded() {
        // V4: backfills folder_group (the folder between Character and Series, e.g. "Batman
        // (Modern)") for every existing comic -- that column didn't exist before this version, so
        // a real one-time reparse is needed for it to ever show up for libraries scanned earlier.
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

    // Independent from `reloadGeneration` -- these guard three unrelated background computations
    // (duplicates, health report, rename candidates) that can each be kicked off from several call
    // sites (post-scan, post-conflict-resolution, a manual re-check) with no fixed ordering. Sharing
    // `reloadGeneration` would mean an unrelated navigation/filter change (which bumps it) discards
    // an in-flight one of these for no reason; each needs to invalidate only its own earlier runs.
    var duplicatesGeneration = 0
    var healthGeneration = 0
    var renameCandidatesGeneration = 0
    var runsGeneration = 0
    var tierListsGeneration = 0

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

        let hasActiveFilter = unreadOnly || minRatingFilter > 0
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
        let minRating = minRatingFilter > 0 ? minRatingFilter : nil

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
                loaded = db.allComics(publisher: pub, search: q, sortOrder: sort, favoritesOnly: true,
                                      unreadOnly: unread, minRating: minRating)
            case .readingList:
                loaded = db.allComics(publisher: pub, search: q, sortOrder: sort, readingListOnly: true,
                                      unreadOnly: unread, minRating: minRating)
            default:
                let character    = group?.character
                let nullCharOnly = group != nil && character == nil
                loaded = db.allComics(publisher: pub, character: character, series: ser,
                                      search: q, sortOrder: sort,
                                      nullCharacterOnly: nullCharOnly, tag: tag,
                                      unreadOnly: unread, minRating: minRating)
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
            let readNext = Self.computeReadNextSuggestions(db: db)
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                self.characterGroups     = groups
                self.publishers          = pubs
                self.allTags             = tags
                self.inProgressComics    = shelf
                self.readNextSuggestions = readNext
                self.comics              = []
                self.isLoading           = false
            }
        }
    }

    /// For each series with at least one favorited comic, if the furthest-along favorited issue
    /// in that series is fully finished, look up the next issue in reading order and suggest it
    /// if it's still unread. Bounded by favorite count (typically small), so this is cheap enough
    /// to run on every reload rather than needing its own cached/invalidated state.
    nonisolated private static func computeReadNextSuggestions(db: DatabaseManager) -> [Comic] {
        let favorites = db.allComics(favoritesOnly: true)
        let bySeries = Dictionary(grouping: favorites) { "\($0.publisher)|\($0.series)" }
        var suggestions: [Comic] = []
        for (_, group) in bySeries {
            guard let lastFinished = group.filter(\.isFinished).max(by: {
                ($0.readingOrderPosition ?? $0.position) < ($1.readingOrderPosition ?? $1.position)
            }) else { continue }
            guard let next = db.nextComic(after: lastFinished), next.progress == 0 else { continue }
            suggestions.append(next)
        }
        return Array(suggestions.prefix(12))
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
        let pub = activePublisher
        reloadGeneration += 1
        let gen = reloadGeneration
        Task.detached(priority: .userInitiated) { [db] in
            let series = db.seriesGroups(groupName: group.groupName, publisher: pub)
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                // springGentle, not springBouncy -- a bouncy overshoot on every drill-down read as
                // the library "shaking" on navigation, same complaint as the hover-lift jitter.
                withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
                    self.selectedGroup = group
                    if series.count == 1 {
                        self.selectedSeries = series[0].series
                    } else {
                        self.seriesGroups = series
                    }
                }
                if series.count == 1 { self.reload() }
            }
        }
    }

    func drillIntoSeries(_ sg: DatabaseManager.SeriesGroup) {
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) { selectedSeries = sg.series }
        reload()
    }

    func navigateBack() {
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
        // A reading session just ended -- today may now be the first day of a new streak, or
        // extended an existing one, and the sidebar's ambient indicator should reflect that
        // without waiting for the next launch.
        refreshReadingStreak()
    }

    func startWatcher() {
        let roots = libraryPaths
        guard !roots.isEmpty else { return }
        let w = FileWatcher(
            onAdded: { [weak self] url in
                self?.isLibraryAvailable = true
                // addSingle does file hashing, ComicInfo.xml parsing, and a synchronous DB
                // write on the scanner's serial queue -- run it off the main thread like
                // importFiles does, or a Finder drop into the watched folder freezes the UI
                // for the duration of that work, one file at a time.
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
        // Invalidate any reload that's still in flight: _reload() only applies its result if
        // its captured generation still matches when it lands (see _reload()'s `guard gen ==
        // self.reloadGeneration`). Without bumping it here too, a reload started just before
        // this optimistic patch but landing just after it would silently overwrite this fresher
        // state with the stale pre-patch snapshot it queried.
        reloadGeneration += 1
    }

    func updateProgress(comic: Comic, page: Int) {
        db.updateProgress(comicId: comic.id, page: page)
        patchComicLocally(comic.id) { $0.progress = page }
    }

    /// Called only when the reader determines a page-turn reached the end via genuine sequential
    /// reading (see `ReaderView.suppressCompletionCheck`) -- sticky, so it's safe to call again on
    /// a later reread without needing to check `comic.isFinished` first.
    func markFinished(comic: Comic) {
        db.markFinished(comicId: comic.id)
        let now = ISO8601DateFormatter().string(from: Date())
        patchComicLocally(comic.id) { $0.finishedAt = now }
    }

}
