import Foundation
import SwiftUI

/// Platform-agnostic reader model shared by the Mac and iPad readers: navigation, reading mode,
/// zoom, chrome, autoplay and bookmarks for one open comic. Platform views translate input into
/// calls on it.
@MainActor
@Observable
final class ReaderSession {
    let comic: Comic
    let runId: Int64?

    private(set) var document: ComicDocument?
    private(set) var pageCount: Int
    private(set) var currentPage: Int
    private(set) var currentImage: PlatformImage?
    private(set) var secondaryImage: PlatformImage?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var currentPageIsSpread = false

    var scrollMode: Bool { didSet { guard scrollMode != oldValue else { return }; onScrollModeChanged() } }
    var doublePage: Bool { didSet { guard doublePage != oldValue else { return }; saveSeriesPrefs() } }
    var rtl: Bool { didSet { guard rtl != oldValue else { return }; saveSeriesPrefs() } }
    var fitMode: FitMode { didSet { guard fitMode != oldValue else { return }; onFitModeChanged() } }
    var colorFilter: ColorFilter { didSet { UserDefaults.standard.set(colorFilter.rawValue, forKey: "readerColorFilter") } }

    private(set) var zoomLevel: CGFloat = 1.0
    private(set) var zoomAnchor: UnitPoint = .center
    var isZoomed: Bool { zoomLevel > 1.05 }

    var autoplay = false { didSet { guard autoplay != oldValue else { return }; if !autoplay { countdownProgress = 0; autoplayTask?.cancel() } } }
    private(set) var countdownProgress: Double = 0
    var autoplayInterval: Double = 6.0

    private(set) var bookmarks: [Bookmark] = []
    private(set) var isBookmarked = false

    private(set) var nextIssue: Comic?
    private(set) var previousIssue: Comic?
    /// Set by the platform view; how the session asks the app to open a different comic (needed
    /// because autoplay advances on its own).
    var onRequestIssueTransition: ((Comic) -> Void)?

    private(set) var boundaryMessage: String?
    private(set) var showFinishToast = false
    /// Settable so the view's sheet binding can reset it.
    var showSeriesComplete = false
    private var didShowFinishToast = false

    /// Controls start hidden and only appear on purpose (a tap on iPad, hovering an edge on Mac).
    var shouldShowChrome = false
    var toolbarLocked = false

    private var viewportSize: CGSize = .zero
    private var screenScale: CGFloat = 2.0

    private let progressStore = ReadingProgressStore()
    private var sessionStartPage: Int
    private var hideWorkItem: DispatchWorkItem?
    private var autoplayTask: Task<Void, Never>?
    /// Whether the last page change was sequential reading or a jump, so teardown flushes with
    /// matching completion rules.
    private var lastPositionWasSequential = true

    /// Result of advancing/retreating past the current page; `.atBoundary` carries the adjacent
    /// issue, if any.
    enum BoundaryOutcome: Equatable {
        case advanced
        case atBoundary(adjacentIssue: Comic?)

        static func == (lhs: BoundaryOutcome, rhs: BoundaryOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.advanced, .advanced): return true
            case let (.atBoundary(a), .atBoundary(b)): return a?.id == b?.id
            default: return false
            }
        }
    }

    init(comic: Comic, runId: Int64? = nil, initialPage: Int? = nil) {
        self.comic = comic
        self.runId = runId
        self.pageCount = comic.pageCount
        let resumed = ReadingProgressStore.resumePage(for: comic)
        let clamped = min(max(0, initialPage ?? resumed), max(0, comic.pageCount - 1))
        self.currentPage = clamped
        self.sessionStartPage = clamped

        let prefs = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
        self.scrollMode = prefs?.scrollMode ?? UserDefaults.standard.bool(forKey: "scrollMode")
        self.rtl = prefs?.rtl ?? false
        self.doublePage = prefs?.doubleSpread ?? false
        self.fitMode = prefs.flatMap { FitMode(rawValue: $0.fitMode) } ?? .fitPage
        self.colorFilter = ColorFilter(rawValue: UserDefaults.standard.string(forKey: "readerColorFilter") ?? ColorFilter.none.rawValue) ?? .none
    }

    // MARK: - Lifecycle

    func open() async {
        do {
            let doc = try await ComicDocumentFactory.open(path: comic.filePath)
            document = doc
            pageCount = doc.pageCount
            currentPage = min(currentPage, max(0, pageCount - 1))
            loadBookmarks()
            resolveAdjacentIssues()
            loadCurrentPage()
        } catch {
            loadFailed = true
        }
    }

    func teardown() {
        hideWorkItem?.cancel()
        autoplayTask?.cancel()
        progressStore.flush(comic: comic, page: currentPage, isSequential: lastPositionWasSequential)
        DatabaseManager.shared.logReadingSession(comicId: comic.id, pageStart: min(sessionStartPage, currentPage), pageEnd: max(sessionStartPage, currentPage))
        PageStore.shared.evict(comicId: comic.id)
        document?.close()
    }

    func handleScenePhaseChange(isActive: Bool) {
        guard !isActive else { return }
        progressStore.flush(comic: comic, page: currentPage, isSequential: lastPositionWasSequential)
    }

    // MARK: - Viewport / target-size decode

    func updateViewport(size: CGSize, screenScale: CGFloat) {
        self.viewportSize = size
        self.screenScale = screenScale
    }

    private var maxPixelSizeForCurrentZoom: Int? {
        guard fitMode != .original else { return nil }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let longEdge = max(viewportSize.width, viewportSize.height)
        return Int(longEdge * screenScale * max(1.0, zoomLevel))
    }

    // MARK: - Page loading

    /// `keepingCurrentImage`: keep showing the current image until the sharper re-decode arrives.
    private func loadCurrentPage(keepingCurrentImage: Bool = false) {
        guard let document else { return }
        loadFailed = false
        if !keepingCurrentImage {
            isLoading = true
            currentImage = nil
            secondaryImage = nil
        }
        let page = currentPage
        let maxPixelSize = maxPixelSizeForCurrentZoom
        PageStore.shared.request(document: document, comicId: comic.id, page: page, maxPixelSize: maxPixelSize) { [weak self] image in
            guard let self, self.currentPage == page else { return }
            self.isLoading = false
            if let image {
                self.currentImage = image
                self.currentPageIsSpread = image.size.width > image.size.height * 1.15
                if self.effectiveDoublePage, page + 1 < self.pageCount {
                    PageStore.shared.request(document: document, comicId: self.comic.id, page: page + 1, maxPixelSize: maxPixelSize) { [weak self] second in
                        guard let self, self.currentPage == page else { return }
                        self.secondaryImage = second
                    }
                }
            } else {
                self.loadFailed = true
            }
            self.prefetch()
        }
    }

    func retryCurrentPage() { loadCurrentPage() }

    var effectiveDoublePage: Bool { doublePage && !currentPageIsSpread && !scrollMode }
    private var pageAdvance: Int { effectiveDoublePage ? 2 : 1 }

    private func prefetch() {
        guard let document else { return }
        let mode: PageStore.PrefetchMode = scrollMode ? .scroll : (effectiveDoublePage ? .spread : .paged)
        PageStore.shared.prefetch(
            document: document, comicId: comic.id, around: currentPage, pageCount: pageCount,
            mode: mode, maxPixelSize: maxPixelSizeForCurrentZoom, isPDF: comic.fileExtension == "pdf"
        )
    }

    // MARK: - Navigation

    @discardableResult
    func advance() -> BoundaryOutcome {
        guard pageCount > 0 else { return .advanced }
        let target = max(0, min(currentPage + pageAdvance, pageCount - 1))
        guard target != currentPage else {
            if let nextIssue { onRequestIssueTransition?(nextIssue) } else { showBoundary("That's the last one") }
            return .atBoundary(adjacentIssue: nextIssue)
        }
        setPage(target, isSequential: true)
        return .advanced
    }

    @discardableResult
    func retreat() -> BoundaryOutcome {
        guard currentPage > 0 else {
            if let previousIssue { onRequestIssueTransition?(previousIssue) } else { showBoundary("That's the first one") }
            return .atBoundary(adjacentIssue: previousIssue)
        }
        setPage(max(0, currentPage - pageAdvance), isSequential: true)
        return .advanced
    }

    /// Jumps (slider, page entry, filmstrip, bookmark, Home/End) never mark a comic finished, and
    /// cancel stale prefetches.
    func jump(to page: Int) {
        let clamped = max(0, min(page, max(0, pageCount - 1)))
        guard clamped != currentPage else { return }
        PageStore.shared.cancelPrefetches(comicId: comic.id)
        setPage(clamped, isSequential: false)
    }

    /// Continuous scroll's page tracking counts as sequential reading.
    func reportVisiblePage(_ page: Int) {
        guard page != currentPage, page >= 0, page < pageCount else { return }
        setPage(page, isSequential: true)
    }

    private func setPage(_ page: Int, isSequential: Bool) {
        currentPage = page
        lastPositionWasSequential = isSequential
        resetZoom()
        loadCurrentPage()
        isBookmarked = bookmarks.contains { $0.page == page }
        progressStore.recordPosition(comic: comic, page: page, isSequential: isSequential) { [weak self] in
            self?.onFinished()
        }
    }

    private func onFinished() {
        guard !didShowFinishToast else { return }
        didShowFinishToast = true
        showFinishToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showFinishToast = false }
        checkSeriesComplete()
    }

    /// "Complete" means every issue of the series in the library is read. Needs more than one
    /// issue.
    private func checkSeriesComplete() {
        let pub = comic.publisher, ser = comic.series
        Task.detached(priority: .utility) { [weak self] in
            let siblings = DatabaseManager.shared.allComics(publisher: pub, series: ser)
            guard siblings.count > 1, siblings.allSatisfy(\.isFinished) else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            await MainActor.run { self.showSeriesComplete = true }
        }
    }

    private func showBoundary(_ text: String) {
        boundaryMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.boundaryMessage == text { self?.boundaryMessage = nil }
        }
    }

    // MARK: - Adjacent issues

    private func resolveAdjacentIssues() {
        let comic = self.comic
        let runId = self.runId
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = NextIssueResolver.resolve(for: comic, runId: runId)
            NextIssueResolver.prefetchCover(for: result.next)
            guard let self else { return }
            await MainActor.run {
                self.nextIssue = result.next
                self.previousIssue = result.previous
            }
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        bookmarks = DatabaseManager.shared.bookmarks(comicId: comic.id)
        isBookmarked = bookmarks.contains { $0.page == currentPage }
    }

    func refreshBookmarks() { loadBookmarks() }

    func toggleBookmark() {
        isBookmarked = DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: currentPage)
        loadBookmarks()
    }

    // MARK: - Zoom

    /// Zoom is a level plus a normalized (0...1) anchor in the image, which survives fit-mode
    /// changes, resizes and page changes.
    func setZoom(_ level: CGFloat, anchorInViewport point: CGPoint? = nil) {
        let clampedLevel = max(1.0, min(5.0, level))
        if clampedLevel <= 1.05 {
            guard zoomLevel != 1.0 || zoomAnchor != .center else { return }
            zoomLevel = 1.0
            zoomAnchor = .center
            loadCurrentPage(keepingCurrentImage: true)
            return
        }
        if let point, viewportSize.width > 0, viewportSize.height > 0 {
            let raw = UnitPoint(x: point.x / viewportSize.width, y: point.y / viewportSize.height)
            zoomAnchor = clampAnchor(raw, zoom: clampedLevel)
        } else {
            zoomAnchor = clampAnchor(zoomAnchor, zoom: clampedLevel)
        }
        zoomLevel = clampedLevel
        loadCurrentPage(keepingCurrentImage: true)
    }

    func pan(anchorDelta delta: CGSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let dx = delta.width / viewportSize.width
        let dy = delta.height / viewportSize.height
        zoomAnchor = clampAnchor(UnitPoint(x: zoomAnchor.x - dx, y: zoomAnchor.y - dy), zoom: zoomLevel)
    }

    private func clampAnchor(_ anchor: UnitPoint, zoom: CGFloat) -> UnitPoint {
        guard zoom > 1 else { return .center }
        let maxDelta = (zoom - 1) / (2 * zoom)
        let minC = 0.5 - maxDelta, maxC = 0.5 + maxDelta
        return UnitPoint(x: min(maxC, max(minC, anchor.x)), y: min(maxC, max(minC, anchor.y)))
    }

    /// Offset to apply after `.scaleEffect(zoomLevel)` to center `zoomAnchor` in the viewport.
    var panOffsetInPoints: CGSize {
        guard isZoomed, viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        return CGSize(
            width:  (0.5 - zoomAnchor.x) * viewportSize.width  * zoomLevel,
            height: (0.5 - zoomAnchor.y) * viewportSize.height * zoomLevel
        )
    }

    /// Resets zoom state without reloading; views should call `setZoom(1.0)` instead.
    func resetZoom() {
        zoomLevel = 1.0
        zoomAnchor = .center
    }

    // MARK: - Autoplay

    func toggleAutoplay() {
        guard !scrollMode else { return }
        autoplay.toggle()
        if autoplay { startAutoplay() }
    }

    private func startAutoplay() {
        autoplayTask?.cancel()
        autoplayTask = Task { [weak self] in
            while let self, self.autoplay, !Task.isCancelled {
                let steps = 60
                for i in 0..<steps {
                    guard self.autoplay, !Task.isCancelled else { return }
                    self.countdownProgress = Double(i) / Double(steps)
                    try? await Task.sleep(nanoseconds: UInt64(self.autoplayInterval / Double(steps) * 1_000_000_000))
                }
                guard self.autoplay, !Task.isCancelled else { return }
                self.countdownProgress = 0
                if case .atBoundary(let next) = self.advance(), next == nil {
                    self.autoplay = false
                    return
                }
            }
        }
    }

    // MARK: - Chrome

    func interactionOccurred() {
        shouldShowChrome = true
        guard !toolbarLocked else { return }
        scheduleHideChrome()
    }

    private func scheduleHideChrome() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shouldShowChrome = false }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: - Prefs

    private func saveSeriesPrefs() {
        DatabaseManager.shared.setSeriesReaderPrefs(
            series: comic.series, publisher: comic.publisher,
            fitMode: fitMode.rawValue, rtl: rtl, doubleSpread: doublePage, scrollMode: scrollMode
        )
    }

    private func onFitModeChanged() {
        saveSeriesPrefs()
        resetZoom()
        loadCurrentPage()
    }

    private func onScrollModeChanged() {
        saveSeriesPrefs()
        resetZoom()
        if scrollMode, autoplay { autoplay = false }
    }
}

enum FitMode: String, CaseIterable {
    case fitPage    = "fitPage"
    case fitWidth   = "fitWidth"
    case fitHeight  = "fitHeight"
    case original   = "original"

    var label: String {
        switch self {
        case .fitPage:   return "Fit Page"
        case .fitWidth:  return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .original:  return "Original Size"
        }
    }
    var icon: String {
        switch self {
        case .fitPage:   return "arrow.up.left.and.arrow.down.right"
        case .fitWidth:  return "arrow.left.and.right"
        case .fitHeight: return "arrow.up.and.down"
        case .original:  return "1.circle"
        }
    }
}

enum ColorFilter: String, CaseIterable {
    case none, night, sepia, grayscale
    var label: String {
        switch self {
        case .none:      return "Normal"
        case .night:     return "Night"
        case .sepia:     return "Sepia"
        case .grayscale: return "Grayscale"
        }
    }
    var icon: String {
        switch self {
        case .none:      return "circle.lefthalf.filled"
        case .night:     return "moon.fill"
        case .sepia:     return "photo.artframe"
        case .grayscale: return "circle.fill"
        }
    }
}

/// Rules for saving the reading position and deciding when a page counts as finished reading rather
/// than a jump.
@MainActor
final class ReadingProgressStore {
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.25

    /// Resume page, clamped in case the page count shrank since it was saved.
    nonisolated static func resumePage(for comic: Comic) -> Int {
        min(max(0, comic.progress), max(0, comic.pageCount - 1))
    }

    /// Called on every page change. Only sequential reading can mark a comic finished; the resume
    /// position always updates.
    func recordPosition(comic: Comic, page: Int, isSequential: Bool, onFinished: (() -> Void)? = nil) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem {
            LibraryViewModel.shared.updateProgress(comic: comic, page: page)
            if isSequential, comic.pageCount > 1, page >= comic.pageCount - 1 {
                LibraryViewModel.shared.markFinished(comic: comic)
                onFinished?()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Synchronous flush on teardown, so the last position survives a quit.
    func flush(comic: Comic, page: Int, isSequential: Bool) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        LibraryViewModel.shared.updateProgress(comic: comic, page: page)
        if isSequential, comic.pageCount > 1, page >= comic.pageCount - 1 {
            LibraryViewModel.shared.markFinished(comic: comic)
        }
    }
}

/// Previous/next issue for a comic: within its Reading Path when opened from one, otherwise in
/// series order.
enum NextIssueResolver {
    struct Result { let next: Comic?; let previous: Comic? }

    static func resolve(for comic: Comic, runId: Int64?) -> Result {
        if let runId {
            let items = DatabaseManager.shared.runItems(runId: runId)
            guard let idx = items.firstIndex(where: { $0.comic.id == comic.id }) else {
                return Result(next: nil, previous: nil)
            }
            let next = idx + 1 < items.count ? items[idx + 1].comic : nil
            let previous = idx > 0 ? items[idx - 1].comic : nil
            return Result(next: next, previous: previous)
        }
        return Result(
            next: DatabaseManager.shared.nextComic(after: comic),
            previous: DatabaseManager.shared.previousComic(before: comic)
        )
    }

    /// Warms just the next issue's cover; prefetching its pages is `ReaderSession`'s decision.
    static func prefetchCover(for comic: Comic?) {
        guard let comic else { return }
        ThumbnailCache.shared.thumbnail(for: comic) { _ in }
    }
}

/// Which comic is open in the reader overlay, and the context it was opened with.
@MainActor
final class ReaderCoordinator: ObservableObject {
    /// Starting page override (e.g. a favorite moment), instead of the saved resume position.
    @Published var initialPage: Int? = nil
    /// The Reading Path the reader was opened from, for path-scoped next/previous.
    @Published var runId: Int64? = nil
    @Published var comic: Comic? = nil {
        didSet {
            // Posted on close so views showing progress (e.g. a Reading Path) can refresh.
            if oldValue != nil, comic == nil {
                NotificationCenter.default.post(name: .readerDidClose, object: nil)
            }
        }
    }

    func open(_ comic: Comic, atPage page: Int? = nil, runId: Int64? = nil) {
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
            self.initialPage = page; self.runId = runId; self.comic = comic
        }
    }

    func close() {
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
            comic = nil; initialPage = nil; runId = nil
        }
    }
}
