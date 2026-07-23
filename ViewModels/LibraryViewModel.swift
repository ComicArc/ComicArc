import Foundation
import Combine
import CoreSpotlight
import UserNotifications

enum AppDestination: Hashable, Codable {
    case library
    case continueReading
    case favorites
    case readingList
    case publisher(String)
    case tag(String)
    case runs
    case diary
    case lists
    case stats
    case history
    case duplicates
    case readingOrderManager
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
        case .lists:                return "Lists"
        case .stats:                return "Statistics"
        case .history:              return "History"
        case .duplicates:           return "Possible Duplicates"
        case .readingOrderManager:  return "Reading Order Suggestions"
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
        case .lists:                return "trophy.fill"
        case .stats:                return "chart.bar.xaxis"
        case .history:              return "clock.fill"
        case .duplicates:           return "doc.on.doc"
        case .readingOrderManager:  return "checkmark.seal"
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
    @Published var destination: AppDestination = .library
    @Published var selectedSeries:    String? = nil
    @Published var searchText:        String = ""
    @Published var sortOrder: DatabaseManager.SortOrder =
        DatabaseManager.SortOrder(rawValue: UserDefaults.standard.string(forKey: "comicSortOrder") ?? "") ?? .manual {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "comicSortOrder") }
    }

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
    private var scanReportDismissTask: DispatchWorkItem?

    struct UndoableAction {
        let message: String
        let undo: () -> Void
    }
    @Published var pendingUndo: UndoableAction?
    private var undoDismissTask: DispatchWorkItem?

    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        undoDismissTask?.cancel()
        pendingUndo = UndoableAction(message: message, undo: undo)
        let task = DispatchWorkItem { [weak self] in self?.pendingUndo = nil }
        undoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func performUndo() {
        undoDismissTask?.cancel()
        pendingUndo?.undo()
        pendingUndo = nil
    }

    func dismissUndo() {
        undoDismissTask?.cancel()
        pendingUndo = nil
    }
    @Published var isResyncing:         Bool = false
    @Published var isLoading:           Bool = false
    @Published var isLibraryAvailable:  Bool = true
    @Published var selectedComic:     Comic? = nil
    @Published var selectedRun:       Run? = nil
    @Published var selectedList:      ComicList? = nil
    @Published var readerComic:       Comic? = nil

    @Published var characterGroups:   [DatabaseManager.CharacterGroup] = []
    @Published var seriesGroups:      [DatabaseManager.SeriesGroup] = []
    @Published var selectedGroup:     DatabaseManager.CharacterGroup? = nil
    @Published var useGroupedView:    Bool = true

    @Published var bulkMode:          Bool = false
    @Published var selectedComicIds:  Set<Int64> = []

    @Published var showSeriesManager: Bool = false

    @Published var duplicateGroups:   [[Comic]] = []
    @Published var autoPlacedIssues:  [Comic] = []

    var selectedSection: SidebarSection {
        switch destination {
        case .runs:            return .runs
        case .diary:           return .diary
        case .lists:           return .lists
        case .stats:           return .stats
        case .history:         return .history
        case .duplicates:      return .duplicates
        case .readingOrderManager: return .readingOrderManager
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

    enum SidebarSection: Hashable { case library, continueReading, favorites, readingList, runs, diary, lists, stats, history, duplicates, readingOrderManager, settings }

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

        if let folder = resolveLibraryFolderBookmark() {
            UserDefaults.standard.set(folder.path, forKey: "libraryPath")
        }
        #endif

        useGroupedView = true

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

        scan()
        #endif

        if case .library = destination { restoreLibraryDrillDown() }
    }

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

    func reparseMetaIfNeeded() {

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

    func rehashLibraryIfNeeded() {
        let key = "fileHashRehashV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard !libraryPath.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            LibraryScanner.shared.rehashAll()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

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

    private var reloadWorkItem: DispatchWorkItem?

    private var reloadGeneration = 0

    func reload() {

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

        showSeriesManager = false
        switch item {
        case .tag: useGroupedView = false
        default: useGroupedView = true
        }
        saveNavigationState()
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

        offerUndo("\(ids.count) comic\(ids.count == 1 ? "" : "s") deleted") { [weak self] in
            self?.db.restore(ids)
            self?.reload()
        }
    }

    func scan() {
        let path = libraryPath
        guard !path.isEmpty, !isScanning else { return }
        isScanning = true
        scanState = .init()
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
                    self.refreshLibraryHealth()
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

            let paths = urls.map(\.path)
            let newComics = DatabaseManager.shared.comics(withPaths: paths)
            if !newComics.isEmpty { ThumbnailCache.shared.prewarm(comics: newComics) }
        }
    }

    func refreshDuplicates() {
        Task.detached(priority: .utility) { [db] in
            let groups = db.duplicateGroups()
            let autoPlaced = db.autoPlacedSpecialIssues()
            await MainActor.run {
                self.duplicateGroups = groups
                self.autoPlacedIssues = autoPlaced
            }
        }
    }

    func refreshLibraryHealth() {
        Task.detached(priority: .utility) {
            let report = LibraryHealthAnalyzer.analyze()
            await MainActor.run { self.libraryHealthReport = report.isEmpty ? nil : report }
        }
    }

    func runManualHealthCheck() {
        Task.detached(priority: .utility) {
            let report = LibraryHealthAnalyzer.analyze()
            await MainActor.run {
                self.libraryHealthReport = report
                self.showImportWizard = true
            }
        }
    }

    func openReader(_ comic: Comic) { readerComic = comic }
    func openReader(id: Int64) { if let c = db.comic(id: id) { readerComic = c } }
    func closeReader() { readerComic = nil }

    func clearLibrary(resetPreferences: Bool = false) {

        LibraryScanner.shared.cancel()
        isScanning = false

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

    func startWatcher() {
        let path = libraryPath
        guard !path.isEmpty else { return }
        let w = FileWatcher(
            onAdded: { [weak self] url in
                self?.isLibraryAvailable = true
                // addSingle does file hashing, ComicInfo.xml parsing, and a synchronous DB
                // write on the scanner's serial queue -- run it off the main thread like
                // importFiles does, or a Finder drop into the watched folder freezes the UI
                // for the duration of that work, one file at a time.
                Task.detached(priority: .utility) {
                    LibraryScanner.shared.addSingle(url: url, libraryPath: path)
                    await self?.reload()
                }
            },
            onRemoved: { [weak self] p in
                Task.detached(priority: .utility) {
                    LibraryScanner.shared.removeSingle(path: p)
                    await self?.reload()
                }
            },
            onVolumeUnavailable: { [weak self] in
                self?.isLibraryAvailable = false
            }
        )
        w.start(path: path)
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

        if sortOrder != .manual { sortOrder = .manual }
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

    func moveCharacterGroup(from: DatabaseManager.CharacterGroup, to: DatabaseManager.CharacterGroup) {
        guard from.id != to.id, from.publisher == to.publisher else { return }
        var list = characterGroups
        guard let fromIdx = list.firstIndex(where: { $0.id == from.id }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.id == to.id }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        characterGroups = list
        let sameGroups = list.filter { $0.publisher == from.publisher }.map(\.groupName)
        db.reorderCharacterGroups(publisher: from.publisher, orderedGroupNames: sameGroups)
    }

    func movePublisher(from: String, to: String) {
        guard from != to else { return }
        var list = publishers
        guard let fromIdx = list.firstIndex(of: from) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(of: to) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        publishers = list
        db.reorderPublishers(orderedPublishers: list)
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

    func setCharacterGroupCover(group: DatabaseManager.CharacterGroup, usingCoverOf comic: Comic) {
        let safe = "chargroup_\(group.publisher)_\(group.groupName)"
            .components(separatedBy: .init(charactersIn: "/:")).joined(separator: "_")
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: safe) else { return }
            db.setCharacterGroupCover(groupName: group.groupName, publisher: group.publisher, imagePath: path)
            await MainActor.run { LibraryViewModel.shared.reload() }
        }
    }

    private func patchComicLocally(_ comicId: Int64, removeIfNoLongerVisible: Bool = false, _ mutate: (inout Comic) -> Void) {
        guard let idx = comics.firstIndex(where: { $0.id == comicId }) else { return }
        mutate(&comics[idx])
        if selectedComic?.id == comicId { mutate(&selectedComic!) }
        if removeIfNoLongerVisible { comics.remove(at: idx) }
        // Invalidate any reload that's still in flight: _reload() only applies its result if
        // its captured generation still matches when it lands (see _reload()'s `guard gen ==
        // self.reloadGeneration`). Without bumping it here too, a reload started just before
        // this optimistic patch but landing just after it would silently overwrite this fresher
        // state with the stale pre-patch snapshot it queried.
        reloadGeneration += 1
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

    func addTag(name: String, to comic: Comic, category: TagCategory = .custom) { db.addTag(name: name, to: comic.id, category: category) }
    func removeTag(tagId: Int64, from comic: Comic) { db.removeTag(tagId: tagId, from: comic.id) }


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

    func reorderComics(orderedIds: [Int64]) {
        db.reorderComics(orderedIds: orderedIds)
        if sortOrder != .manual { sortOrder = .manual }
    }

    func rejectAutoPlacement(_ comic: Comic) {
        Task.detached(priority: .userInitiated) { [db] in
            db.setReadingOrderOverride(comicId: comic.id, position: comic.position, reason: "Manually placed")
            db.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }

    func confirmAutoPlacement(_ comic: Comic) {
        Task.detached(priority: .userInitiated) { [db] in
            let pinned = comic.readingOrderPosition ?? comic.position
            db.setReadingOrderOverride(comicId: comic.id, position: pinned, reason: "Confirmed correct")
            db.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }

    @discardableResult
    func createRun(title: String, description: String) -> Int64 { db.createRun(title: title, description: description) }
    func deleteRun(_ runId: Int64) { db.deleteRun(runId) }

    func deleteRunWithUndo(_ run: Run) {
        let items = db.runItems(runId: run.id)
        db.deleteRun(run.id)
        NotificationCenter.default.post(name: .runDeleted, object: nil)
        offerUndo("Reading order \"\(run.title)\" deleted") { [weak self] in
            guard let self else { return }
            let newId = self.db.createRun(title: run.title, description: run.description)
            if let buyLink = run.buyLink, !buyLink.isEmpty {
                self.db.updateRun(id: newId, title: run.title, description: run.description, buyLink: buyLink)
            }
            if let rating = run.rating {
                self.db.setRunRating(newId, rating: rating, review: run.review)
            }
            if let cover = run.coverImagePath {
                self.db.setRunCover(runId: newId, imagePath: cover)
            }
            self.db.addToRun(runId: newId, comicIds: items.map(\.comic.id))

            let newItems = self.db.runItems(runId: newId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setRunItemNotes(match.id, notes: item.notes)
                }
            }
            NotificationCenter.default.post(name: .runDeleted, object: nil)
        }
    }

    func addToRun(runId: Int64, comicIds: [Int64]) { db.addToRun(runId: runId, comicIds: comicIds) }
    func removeFromRun(runId: Int64, comicIds: [Int64]) { db.removeFromRun(runId: runId, comicIds: comicIds) }

    func removeFromRunWithUndo(runId: Int64, items: [RunItem], onRestored: @escaping () -> Void = {}) {
        let ids = items.map(\.comic.id)
        db.removeFromRun(runId: runId, comicIds: ids)
        let label = items.count == 1 ? "\"\(items[0].comic.title)\" removed" : "\(items.count) comics removed"
        offerUndo(label) { [weak self] in
            guard let self else { return }
            self.db.addToRun(runId: runId, comicIds: ids)
            let newItems = self.db.runItems(runId: runId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setRunItemNotes(match.id, notes: item.notes)
                }
            }
            onRestored()
        }
    }
    func reorderRun(runId: Int64, orderedIds: [Int64]) { db.reorderRun(runId: runId, orderedIds: orderedIds) }

    @discardableResult
    func setRunCover(runId: Int64, imageURL: URL) -> String? {
        guard let path = ThumbnailCache.shared.saveCustomRunCover(runId: runId, imageURL: imageURL) else { return nil }
        db.setRunCover(runId: runId, imagePath: path)
        return path
    }
    func clearRunCover(runId: Int64) { db.clearRunCover(runId: runId) }

    func setRunCover(runId: Int64, usingCoverOf comic: Comic, onDone: @escaping () -> Void = {}) {
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: "run_\(runId)") else { return }
            db.setRunCover(runId: runId, imagePath: path)
            await MainActor.run { onDone() }
        }
    }

    func setSeriesCoverImage(series: String, publisher: String, imageURL: URL) {
        guard let path = ThumbnailCache.shared.saveCustomSeriesCover(series: series, publisher: publisher, imageURL: imageURL) else { return }
        db.setSeriesCoverImage(series: series, publisher: publisher, imagePath: path)
        reload()
    }

    func setSeriesCover(series: String, publisher: String, usingCoverOf comic: Comic) {
        db.setSeriesCover(series: series, publisher: publisher, comicId: comic.id)
        reload()
    }
    func clearSeriesCover(_ series: String, publisher: String) {
        db.clearSeriesCover(series: series, publisher: publisher)
        reload()
    }
    func updateRun(id: Int64, title: String, description: String, buyLink: String?) { db.updateRun(id: id, title: title, description: description, buyLink: buyLink) }
    func setRunRating(_ runId: Int64, rating: Int, review: String?) { db.setRunRating(runId, rating: rating, review: review) }
    func setRunItemNotes(_ itemId: Int64, notes: String) { db.setRunItemNotes(itemId, notes: notes) }

    @discardableResult
    func createList(title: String, description: String) -> Int64 { db.createList(title: title, description: description) }
    func deleteList(_ listId: Int64) { db.deleteList(listId) }

    func deleteListWithUndo(_ list: ComicList) {
        let items = db.listItems(listId: list.id)
        db.deleteList(list.id)
        NotificationCenter.default.post(name: .listDeleted, object: nil)
        offerUndo("List \"\(list.title)\" deleted") { [weak self] in
            guard let self else { return }
            let newId = self.db.createList(title: list.title, description: list.description)
            if let rating = list.rating {
                self.db.setListRating(newId, rating: rating, review: list.review)
            }
            if let cover = list.coverImagePath {
                self.db.setListCover(listId: newId, imagePath: cover)
            }
            self.db.addToList(listId: newId, comicIds: items.map(\.comic.id))

            let newItems = self.db.listItems(listId: newId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setListItemNotes(match.id, notes: item.notes)
                }
            }
            NotificationCenter.default.post(name: .listDeleted, object: nil)
        }
    }

    func addToList(listId: Int64, comicIds: [Int64]) { db.addToList(listId: listId, comicIds: comicIds) }
    func removeFromList(listId: Int64, comicIds: [Int64]) { db.removeFromList(listId: listId, comicIds: comicIds) }

    func removeFromListWithUndo(listId: Int64, items: [ListItem], onRestored: @escaping () -> Void = {}) {
        let ids = items.map(\.comic.id)
        db.removeFromList(listId: listId, comicIds: ids)
        let label = items.count == 1 ? "\"\(items[0].comic.title)\" removed" : "\(items.count) comics removed"
        offerUndo(label) { [weak self] in
            guard let self else { return }
            self.db.addToList(listId: listId, comicIds: ids)
            let newItems = self.db.listItems(listId: listId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setListItemNotes(match.id, notes: item.notes)
                }
            }
            onRestored()
        }
    }
    func reorderList(listId: Int64, orderedIds: [Int64]) { db.reorderList(listId: listId, orderedIds: orderedIds) }

    @discardableResult
    func setListCover(listId: Int64, imageURL: URL) -> String? {
        guard let path = ThumbnailCache.shared.saveCustomListCover(listId: listId, imageURL: imageURL) else { return nil }
        db.setListCover(listId: listId, imagePath: path)
        return path
    }
    func clearListCover(listId: Int64) { db.clearListCover(listId: listId) }

    func setListCover(listId: Int64, usingCoverOf comic: Comic, onDone: @escaping () -> Void = {}) {
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: "list_\(listId)") else { return }
            db.setListCover(listId: listId, imagePath: path)
            await MainActor.run { onDone() }
        }
    }

    func updateList(id: Int64, title: String, description: String) { db.updateList(id: id, title: title, description: description) }
    func setListRating(_ listId: Int64, rating: Int, review: String?) { db.setListRating(listId, rating: rating, review: review) }
    func setListItemNotes(_ itemId: Int64, notes: String) { db.setListItemNotes(itemId, notes: notes) }

    func delete(_ toDelete: [Comic]) {
        let ids = toDelete.map(\.id)
        db.softDelete(ids)
        for c in toDelete { ThumbnailCache.shared.evict(c.id) }
        reload()
        refreshDuplicates()
        offerUndo(toDelete.count == 1 ? "\"\(toDelete[0].title)\" deleted" : "\(toDelete.count) comics deleted") { [weak self] in
            self?.db.restore(ids)
            self?.reload()
        }
    }

    func updateProgress(comic: Comic, page: Int) {
        db.updateProgress(comicId: comic.id, page: page)
        patchComicLocally(comic.id) { $0.progress = page }
    }

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
