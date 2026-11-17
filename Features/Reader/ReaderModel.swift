import SwiftUI
import Observation

/// State and navigation for one open comic. Pages come from a `PageRenderer`; the next pages are
/// decoded before they're needed so turning a page shows it immediately.
@MainActor @Observable
final class ReaderModel {
    private(set) var comic: Comic
    let pathID: Int64?
    private(set) var renderer: PageRenderer?
    private(set) var pageCount = 0
    private(set) var page = 0
    private(set) var images: [CGImage] = []      // the current page, or two for a spread
    private(set) var loading = true
    private(set) var failed = false
    private(set) var bookmarks: [Bookmark] = []
    private(set) var nextIssue: Comic?
    private(set) var previousIssue: Comic?
    private(set) var notice: String?
    private(set) var justFinished = false
    /// Direction of the last page change, for the page-turn animation.
    private(set) var movedForward = true

    var fitMode: FitMode { didSet { if fitMode != oldValue { savePrefs(); reload() } } }
    var rightToLeft: Bool { didSet { if rightToLeft != oldValue { savePrefs() } } }
    var doublePage: Bool { didSet { if doublePage != oldValue { savePrefs(); reload() } } }
    var scrollMode: Bool {
        didSet {
            guard scrollMode != oldValue else { return }
            autoplay = false
            savePrefs()
            if !scrollMode { images = []; reload() }
        }
    }
    var colorFilter: ColorFilter { didSet { UserDefaults.standard.set(colorFilter.rawValue, forKey: Prefs.colorFilter) } }
    var zoom: CGFloat = 1
    var autoplay = false { didSet { autoplay ? startAutoplay() : autoplayTask?.cancel() } }
    var autoplaySeconds: Double {
        didSet { UserDefaults.standard.set(autoplaySeconds, forKey: Prefs.autoplaySeconds); if autoplay { startAutoplay() } }
    }
    private(set) var autoplayProgress: Double = 0

    @ObservationIgnored var onOpenComic: ((Comic) -> Void)?
    @ObservationIgnored private var viewportPixels = 2400
    @ObservationIgnored private var sessionStart = 0
    @ObservationIgnored private var lastMoveWasReading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var autoplayTask: Task<Void, Never>?
    @ObservationIgnored private var spreadFlags: [Int: Bool] = [:]
    @ObservationIgnored private var closed = false

    init(launch: ReaderLaunch) {
        // The caller's copy may be stale; resume from the saved position.
        let fresh = Database.shared.comicSync(id: launch.comic.id) ?? launch.comic
        comic = fresh
        pathID = launch.pathID
        let prefs = Database.shared.readerPrefs(series: fresh.series, publisher: fresh.publisher)
        fitMode = prefs?.fitMode ?? .fitPage
        rightToLeft = prefs?.rightToLeft ?? false
        doublePage = prefs?.doublePage ?? false
        scrollMode = prefs?.scrollMode ?? UserDefaults.standard.bool(forKey: Prefs.defaultScrollMode)
        colorFilter = ColorFilter(rawValue: UserDefaults.standard.string(forKey: Prefs.colorFilter) ?? "") ?? .none
        let seconds = UserDefaults.standard.double(forKey: Prefs.autoplaySeconds)
        autoplaySeconds = seconds > 0 ? seconds : 6
        let resume = fresh.isFinished && fresh.currentPage >= max(0, fresh.pageCount - 1) ? 0 : fresh.currentPage
        page = launch.page ?? resume
        sessionStart = page
    }

    // MARK: - Lifecycle

    func open() async {
        let path = comic.filePath
        do {
            let doc = try await Task.detached(priority: .userInitiated) { try Documents.open(path) }.value
            let r = PageRenderer(document: doc)
            renderer = r
            pageCount = r.pageCount
            guard pageCount > 0 else { failed = true; loading = false; return }
            page = min(max(0, page), pageCount - 1)
            if comic.pageCount != pageCount {
                let id = comic.id, count = pageCount
                _ = try? await Database.shared.write { db in try db.run("UPDATE comics SET page_count = ? WHERE id = ?", [count, id]) }
            }
            reload()
            await loadBookmarks()
            resolveNeighbors()
        } catch {
            failed = true
            loading = false
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        autoplay = false
        saveTask?.cancel()
        await persist()
        try? await Database.shared.logReadingSession(comicID: comic.id, from: sessionStart, to: page)
        await renderer?.close()
    }

    /// Called when the window size changes: pages are decoded to match the screen.
    func setViewport(_ size: CGSize, scale: CGFloat) {
        let pixels = PageRenderer.bucket(Int(max(size.width, size.height) * scale))
        guard pixels != viewportPixels, pixels > 0 else { return }
        viewportPixels = pixels
        reload()
    }

    private var decodePixels: Int? {
        if fitMode == .original { return nil }
        return min(ImageDecoder.maxDimension, Int(Double(viewportPixels) * Double(max(1, zoom))))
    }

    /// Re-decodes at higher resolution after zooming in.
    func zoomChanged(_ z: CGFloat) {
        let old = zoom
        zoom = z
        if z > 1.3 && z > old * 1.2 { reload(keepImages: true) }
    }

    // MARK: - Navigation

    /// Pages shown together at `p`: a spread pairs it with the next page unless either is a wide
    /// (two-page) image or it's the cover.
    private func spreadPages(at p: Int) async -> [Int] {
        guard doublePage, !scrollMode, p > 0, p + 1 < pageCount, let r = renderer else { return [p] }
        if await isWide(p, r) { return [p] }
        if await isWide(p + 1, r) { return [p] }
        return [p, p + 1]
    }

    private func isWide(_ p: Int, _ r: PageRenderer) async -> Bool {
        if let known = spreadFlags[p] { return known }
        let wide = (await r.aspectRatio(p) ?? 0.66) > 1.0
        spreadFlags[p] = wide
        return wide
    }

    func next() {
        Task {
            let shown = await spreadPages(at: page)
            let target = (shown.last ?? page) + 1
            if target < pageCount { go(to: target, reading: true) } else { reachedEnd() }
        }
    }

    func previous() {
        Task {
            guard page > 0 else {
                if let previousIssue { switchTo(previousIssue) } else { flash("This is the first page") }
                return
            }
            var target = page - 1
            if doublePage && target > 1 {
                let pair = await spreadPages(at: target - 1)
                if pair.count == 2 { target -= 1 }
            }
            go(to: target, reading: true)
        }
    }

    /// Jumps (slider, filmstrip, bookmark, Home/End) never mark a comic as finished.
    func jump(to p: Int) { go(to: min(max(0, p), max(0, pageCount - 1)), reading: false) }

    /// Continuous scroll reports the page in view; scrolling counts as reading.
    func scrolledTo(_ p: Int) {
        guard p != page, p >= 0, p < pageCount else { return }
        page = p
        lastMoveWasReading = true
        scheduleSave()
        if p == pageCount - 1 { finishIfNeeded() }
    }

    private func go(to p: Int, reading: Bool) {
        guard p != page else { return }
        movedForward = p > page
        page = p
        lastMoveWasReading = reading
        zoom = 1
        reload()
        scheduleSave()
        if reading && p == pageCount - 1 { finishIfNeeded() }
        else if reading, doublePage, p == pageCount - 2 {
            Task { if await spreadPages(at: p).count == 2 { finishIfNeeded() } }
        }
    }

    private func reachedEnd() {
        finishIfNeeded()
        if let nextIssue { switchTo(nextIssue) } else { flash(pathID != nil ? "End of this Reading Path" : "That's the last issue") }
    }

    private func switchTo(_ comic: Comic) {
        Task {
            await close()
            onOpenComic?(comic)
        }
    }

    private func finishIfNeeded() {
        guard !comic.isFinished, pageCount > 1 else { return }
        comic.finishedAt = "now"
        justFinished = true
        let id = comic.id, last = pageCount - 1
        Task {
            try? await Database.shared.markFinished([id], lastPages: [id: last])
            try? await Task.sleep(for: .seconds(3))
            justFinished = false
        }
    }

    private func reload(keepImages: Bool = false) {
        guard let renderer, !scrollMode || images.isEmpty else { return }
        loadTask?.cancel()
        if !keepImages { loading = images.isEmpty }
        let p = page, pixels = decodePixels
        loadTask = Task {
            let shown = await spreadPages(at: p)
            var result: [CGImage] = []
            for index in shown {
                if let image = await renderer.image(index, maxPixel: pixels) { result.append(image) }
            }
            guard !Task.isCancelled, p == page else { return }
            if result.isEmpty { failed = true } else { failed = false; images = result }
            loading = false
            // Prefetch the next two views and the previous one.
            let ahead = (shown.last ?? p) + 1
            await renderer.prefetch([ahead, ahead + 1, ahead + 2, ahead + 3, p - 1, p - 2], maxPixel: pixels)
        }
    }

    func retry() { failed = false; reload() }

    var pagesLeft: Int { max(0, pageCount - page - 1) }

    // MARK: - Bookmarks

    var isBookmarked: Bool { bookmarks.contains { $0.page == page } }
    var isHighlighted: Bool { bookmarks.contains { $0.page == page && $0.isHighlight } }

    func toggleBookmark() {
        let id = comic.id, p = page
        Task {
            let on = (try? await Database.shared.toggleBookmark(comicID: id, page: p)) ?? false
            flash(on ? "Bookmarked page \(p + 1)" : "Bookmark removed")
            await loadBookmarks()
        }
    }

    func toggleHighlight() {
        let id = comic.id, p = page, on = !isHighlighted
        Task {
            try? await Database.shared.setHighlight(comicID: id, page: p, on: on)
            flash(on ? "Added page \(p + 1) to Highlights" : "Removed from Highlights")
            await loadBookmarks()
        }
    }

    func deleteBookmark(_ b: Bookmark) {
        Task { try? await Database.shared.deleteBookmark(b.id); await loadBookmarks() }
    }

    private func loadBookmarks() async { bookmarks = (try? await Database.shared.bookmarks(comicID: comic.id)) ?? [] }

    // MARK: - Autoplay

    func toggleAutoplay() { if !scrollMode { autoplay.toggle() } }

    private func startAutoplay() {
        autoplayTask?.cancel()
        autoplayTask = Task {
            while !Task.isCancelled && autoplay {
                let steps = 40
                for i in 0...steps {
                    guard !Task.isCancelled, autoplay else { return }
                    autoplayProgress = Double(i) / Double(steps)
                    try? await Task.sleep(for: .seconds(autoplaySeconds / Double(steps)))
                }
                autoplayProgress = 0
                if page >= pageCount - 1 { autoplay = false; reachedEnd(); return }
                next()
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await persist()
        }
    }

    private func persist() async {
        try? await Database.shared.saveProgress(comicID: comic.id, page: page)
    }

    private func savePrefs() {
        let prefs = SeriesReaderPrefs(fitMode: fitMode, rightToLeft: rightToLeft, doublePage: doublePage, scrollMode: scrollMode)
        let s = comic.series, p = comic.publisher
        Task { try? await Database.shared.setReaderPrefs(prefs, series: s, publisher: p) }
    }

    private func resolveNeighbors() {
        let c = comic, path = pathID
        Task {
            if let path, let items = try? await Database.shared.pathItems(path), let i = items.firstIndex(where: { $0.comic.id == c.id }) {
                nextIssue = i + 1 < items.count ? items[i + 1].comic : nil
                previousIssue = i > 0 ? items[i - 1].comic : nil
            } else {
                nextIssue = Database.shared.adjacentComic(to: c, forward: true)
                previousIssue = Database.shared.adjacentComic(to: c, forward: false)
            }
            if let next = nextIssue { _ = await CoverStore.shared.cover(id: next.id, path: next.filePath) }
        }
    }

    func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { notice = nil }
        }
    }
}
