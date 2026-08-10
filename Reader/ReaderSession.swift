import Foundation
import SwiftUI

/// The one platform-agnostic reader view model, shared verbatim by the Mac, iPad, and iPhone
/// reader shells. Owns navigation, reading-mode, zoom, chrome-visibility, autoplay, and bookmark
/// state for a single open comic. Does NOT own gesture recognizers, view layout, animation
/// curves, or anything AppKit/UIKit-specific -- platform shells translate raw input into calls on
/// this session (`advance()`, `jump(to:)`, `setZoom(...)`), never the other way around.
///
/// One session per open comic, matching the existing `.id(comic.id)`-keyed presentation in
/// `ContentView`/`iPadRootView`: advancing into the next issue tears this session down and a new
/// one is created for the next comic, not reused in place.
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
    /// Set once by the platform view right after creating the session -- the one hook this
    /// session uses to ask the app to open a different comic. Needed because autoplay's page
    /// advance is self-driven by a timer inside this class, not a one-off view-initiated call the
    /// view could intercept the `BoundaryOutcome` of; every boundary-crossing path (manual or
    /// autoplay) funnels through here so the view only has to wire this up once.
    var onRequestIssueTransition: ((Comic) -> Void)?

    private(set) var boundaryMessage: String?
    private(set) var showFinishToast = false
    /// Not `private(set)` -- the platform view's `.sheet(isPresented:)` binding needs to reset
    /// this to `false` itself on dismiss.
    var showSeriesComplete = false
    private var didShowFinishToast = false

    var shouldShowChrome = true
    var toolbarLocked = false

    private var viewportSize: CGSize = .zero
    private var screenScale: CGFloat = 2.0

    private let progressStore = ReadingProgressStore()
    private var sessionStartPage: Int
    private var hideWorkItem: DispatchWorkItem?
    private var autoplayTask: Task<Void, Never>?

    /// What happened when the reader tried to advance/retreat past the current page. `.advanced`
    /// needs no action from the caller; `.atBoundary` hands back the adjacent issue (if any) so
    /// the platform view -- which owns the "open a different comic" routing, not this session --
    /// can carry the transition through. Silent auto-advance into that adjacent issue on reaching
    /// the end is a deliberate product decision (kept from the 2026-08-07 pass, not revisited
    /// here); a `nil` adjacent issue means there's genuinely nowhere to go.
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
        self.rtl = prefs?.rtl ?? UserDefaults.standard.bool(forKey: "readingDirectionRTL")
        self.doublePage = prefs?.doubleSpread ?? false
        self.fitMode = FitMode(rawValue: prefs?.fitMode ?? UserDefaults.standard.string(forKey: "readerFitMode") ?? FitMode.fitPage.rawValue) ?? .fitPage
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
        progressStore.flush(comic: comic, page: currentPage, isSequential: true)
        DatabaseManager.shared.logReadingSession(comicId: comic.id, pageStart: min(sessionStartPage, currentPage), pageEnd: max(sessionStartPage, currentPage))
        PageStore.shared.evict(comicId: comic.id)
        document?.close()
    }

    func handleScenePhaseChange(isActive: Bool) {
        guard !isActive else { return }
        progressStore.flush(comic: comic, page: currentPage, isSequential: true)
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

    private func loadCurrentPage() {
        guard let document else { return }
        isLoading = true
        loadFailed = false
        currentImage = nil
        secondaryImage = nil
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

    /// Non-sequential navigation -- slider, page-jump, filmstrip, bookmark, Home/End. Never earns
    /// completion, however far it lands, and cancels any queued prefetch for the old window since
    /// a far jump means those pages likely aren't needed anymore.
    func jump(to page: Int) {
        let clamped = max(0, min(page, max(0, pageCount - 1)))
        guard clamped != currentPage else { return }
        PageStore.shared.cancelPrefetches(comicId: comic.id)
        setPage(clamped, isSequential: false)
    }

    /// Continuous-scroll mode's own page-visibility tracking -- genuine reading, same as
    /// `advance()`.
    func reportVisiblePage(_ page: Int) {
        guard page != currentPage, page >= 0, page < pageCount else { return }
        setPage(page, isSequential: true)
    }

    private func setPage(_ page: Int, isSequential: Bool) {
        currentPage = page
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

    /// "Complete" is library-relative: every issue currently on disk for this (publisher, series)
    /// has been read, not a claim the real-world series has ended. Requires more than one issue --
    /// finishing a single one-shot isn't a series milestone.
    private func checkSeriesComplete() {
        let pub = comic.publisher, ser = comic.series
        Task.detached(priority: .utility) { [weak self] in
            let siblings = DatabaseManager.shared.allComics(publisher: pub, series: ser)
            guard siblings.count > 1, siblings.allSatisfy(\.isFinished) else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { self?.showSeriesComplete = true }
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
            await MainActor.run {
                self?.nextIssue = result.next
                self?.previousIssue = result.previous
            }
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        bookmarks = DatabaseManager.shared.bookmarks(comicId: comic.id)
        isBookmarked = bookmarks.contains { $0.page == currentPage }
    }

    /// Re-reads the bookmark list from disk without touching any bookmark's state -- for the
    /// bookmarks panel after a favorite toggle or delete made through `DatabaseManager` directly.
    func refreshBookmarks() { loadBookmarks() }

    func toggleBookmark() {
        isBookmarked = DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: currentPage)
        loadBookmarks()
    }

    // MARK: - Zoom

    /// Zoom is two committed values -- level and a normalized (0...1) anchor within the image --
    /// rather than accumulated pixel offsets. A normalized anchor trivially survives a fit-mode
    /// change, window resize, or page change without the pixel-offset clamp math the 2026-08-07
    /// pass had to write (and fix) separately per platform. The valid anchor range shrinks as
    /// zoom drops toward 1 (only `.center` is valid at zoom == 1, where there's no pan room at
    /// all) -- `clampAnchor(_:zoom:)` derives that range from the geometry rather than a flat
    /// 0...1 clamp, which would let the anchor imply an offset larger than the content actually
    /// has room to pan.
    func setZoom(_ level: CGFloat, anchorInViewport point: CGPoint? = nil) {
        let clampedLevel = max(1.0, min(5.0, level))
        if clampedLevel <= 1.05 {
            guard zoomLevel != 1.0 || zoomAnchor != .center else { return }
            zoomLevel = 1.0
            zoomAnchor = .center
            loadCurrentPage()
            return
        }
        if let point, viewportSize.width > 0, viewportSize.height > 0 {
            let raw = UnitPoint(x: point.x / viewportSize.width, y: point.y / viewportSize.height)
            zoomAnchor = clampAnchor(raw, zoom: clampedLevel)
        } else {
            zoomAnchor = clampAnchor(zoomAnchor, zoom: clampedLevel)
        }
        zoomLevel = clampedLevel
        loadCurrentPage()
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

    /// The point-space offset a platform view should apply (after `.scaleEffect(zoomLevel)`) to
    /// bring `zoomAnchor` to the center of the viewport -- centralized here so no platform shell
    /// has to re-derive this geometry itself.
    var panOffsetInPoints: CGSize {
        guard isZoomed, viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        return CGSize(
            width:  (0.5 - zoomAnchor.x) * viewportSize.width  * zoomLevel,
            height: (0.5 - zoomAnchor.y) * viewportSize.height * zoomLevel
        )
    }

    /// State-only reset, no reload -- used internally by `setPage`/`onFitModeChanged`/
    /// `onScrollModeChanged`, which each already call `loadCurrentPage()` separately right after.
    /// View-facing "zoom back out" actions should call `setZoom(1.0)` instead, which resets *and*
    /// reloads at the now-smaller target size.
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
