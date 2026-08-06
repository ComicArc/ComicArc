#if os(iOS) || os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

struct iPadReaderView: View {
    let comic: Comic
    let runId: Int64?
    let onClose: () -> Void

    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @FocusState private var isFocused: Bool
    @State private var currentPage: Int
    @State private var sessionStartPage: Int
    @State private var showBars = true
    @State private var hideTask: Task<Void, Never>?

    @State private var accentColor: Color?
    private var backdropColor: Color {
        Design.deepBackdropTint(accentColor,
                                 increaseContrast: colorSchemeContrast == .increased,
                                 differentiateWithoutColor: differentiateWithoutColor)
    }

    // Same hero cover-morph the Mac reader uses (`ReaderView.swift`) -- grows from wherever this
    // comic's cover was on screen into the reader, then fades to reveal the real page underneath,
    // and reverses on close. Needs `iPadRootView` to present this view in the same view hierarchy
    // as the library (not a `.fullScreenCover`) and inject a real `readerNamespace` for the
    // `matchedGeometryEffect` to actually connect across the two.
    @State private var heroCoverImage: PlatformImage?
    @State private var showHeroCover = true
    @State private var isClosing = false

    @State private var didShowFinishToast = false
    @State private var showSeriesComplete = false

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var scrollMode: Bool
    @AppStorage("autoplaySpeed") private var autoplaySpeed: Double = 6.0
    @State private var autoplay = false
    @State private var countdownProgress: Double = 0
    @State private var showFilmstrip = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewWidth: CGFloat = 0
    @State private var nextIssue: Comic?
    @State private var previousIssue: Comic?
    @State private var showBoundaryToast = false
    @State private var boundaryToastText = ""

    // Parity with the Mac reader -- these previously existed only there, leaving the platform
    // most people actually read on with a noticeably thinner reader.
    @State private var rtl: Bool
    @State private var fitModeRaw: String
    @AppStorage("readerColorFilter") private var colorFilterRaw = ColorFilter.none.rawValue
    @State private var bookmarks: [Bookmark] = []
    @State private var isBookmarked = false
    @State private var showBookmarks = false

    private var fitMode: FitMode { FitMode(rawValue: fitModeRaw) ?? .fitPage }
    private var colorFilter: ColorFilter { ColorFilter(rawValue: colorFilterRaw) ?? .none }

    init(comic: Comic, runId: Int64? = nil, onClose: @escaping () -> Void) {
        self.comic = comic
        self.runId = runId
        self.onClose = onClose
        // Clamp both bounds: page_count can change after progress was saved (metadata refresh,
        // or a revival at the same path with a different file), and a stale out-of-range
        // progress would otherwise land the reader on a blank page with no way to reach it.
        let clampedPage = min(max(0, comic.progress), max(0, comic.pageCount - 1))
        _currentPage = State(initialValue: clampedPage)
        _sessionStartPage = State(initialValue: clampedPage)
        let prefs = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
        _scrollMode = State(initialValue: prefs?.scrollMode ?? UserDefaults.standard.bool(forKey: "scrollMode"))
        _rtl = State(initialValue: prefs?.rtl ?? UserDefaults.standard.bool(forKey: "readingDirectionRTL"))
        _fitModeRaw = State(initialValue: prefs?.fitMode ?? UserDefaults.standard.string(forKey: "readerFitMode") ?? FitMode.fitPage.rawValue)
    }

    private var pageCount: Int { comic.pageCount }

    private func saveSeriesPrefs() {
        DatabaseManager.shared.setSeriesReaderPrefs(
            series: comic.series, publisher: comic.publisher,
            fitMode: fitModeRaw, rtl: rtl, doubleSpread: false, scrollMode: scrollMode
        )
    }

    private func loadBookmarks() {
        bookmarks = DatabaseManager.shared.bookmarks(comicId: comic.id)
        isBookmarked = bookmarks.contains { $0.page == currentPage }
    }

    private func toggleBookmark() {
        isBookmarked = DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: currentPage)
        loadBookmarks()
    }

    var body: some View {
        ZStack {
            backdropColor.ignoresSafeArea()

            if pageCount == 0 {
                // Previously: `ForEach(0..<pageCount, ...)` over an empty range rendered nothing
                // at all -- a silent black screen with no explanation, unlike the Mac reader's
                // graceful "Couldn't load page 1" fallback. Same underlying cause (a genuinely
                // corrupt or empty archive), same visible treatment now on both platforms.
                unavailablePlaceholder
            } else if scrollMode {
                scrollReader
            } else {
                pageReader
            }

            if showHeroCover, let heroCoverImage {
                Image(platformImage: heroCoverImage)
                    .comicCoverStyle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .heroGeometry(id: comic.id, in: readerNamespace, isSource: false)
                    .transition(.opacity)
                    .zIndex(5)
            }

            overlayControls

            if showBoundaryToast {
                VStack {
                    Spacer()
                    boundaryToast
                        .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewWidth = w }
            }
        )
        .accessibilityLabel("Comic reader — \(comic.title), page \(currentPage + 1) of \(pageCount)")
        .accessibilityHint("Double-tap to zoom. Swipe to navigate pages.")
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { rtl ? nextPage() : prevPage(); return .handled }
        .onKeyPress(.rightArrow) { rtl ? prevPage() : nextPage(); return .handled }
        .onKeyPress(.upArrow)    { prevPage(); return .handled }
        .onKeyPress(.downArrow)  { nextPage(); return .handled }
        .onKeyPress(.home) { currentPage = 0; saveProgress(); return .handled }
        .onKeyPress(.end)  { currentPage = max(0, pageCount - 1); saveProgress(); return .handled }
        .onKeyPress(.escape) { handleClose(); return .handled }
        .onKeyPress(KeyEquivalent("w")) { handleClose(); return .handled }
        .onKeyPress(KeyEquivalent("a")) { guard !scrollMode else { return .ignored }; autoplay.toggle(); if !autoplay { countdownProgress = 0 }; return .handled }
        .onKeyPress(KeyEquivalent("b")) { toggleBookmark(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { rtl.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("g")) { withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { showFilmstrip.toggle() }; return .handled }
        .statusBarHidden(!showBars)
        .persistentSystemOverlays(showBars ? .visible : .hidden)
        .onAppear {
            isFocused = true
            scheduleHide(); loadNextIssue(); loadBookmarks()
            heroCoverImage = ThumbnailCache.shared.thumbnailFromCache(comicId: comic.id)
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = false }
            }
        }
        .onDisappear {
            saveProgress(); logSession()

            PageCache.shared.evict(comicId: comic.id)
        }

        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .task(id: "\(autoplay)-\(currentPage)") { await runAutoplay() }
        .onChange(of: currentPage) { _, _ in
            loadBookmarks()
            showFinishToastIfNeeded()
        }
        .onChange(of: scrollMode) { _, _ in saveSeriesPrefs() }
        .onChange(of: rtl) { _, _ in saveSeriesPrefs() }
        .onChange(of: fitModeRaw) { _, _ in saveSeriesPrefs() }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
        .sheet(isPresented: $showSeriesComplete) {
            SeriesCompleteView(publisher: comic.publisher, series: comic.series)
        }
    }

    private func nextPage() {
        guard currentPage < pageCount - 1 else {
            // Already on the last page -- turning the page again carries straight into the next
            // comic, like flipping past the final page of a bound anthology, instead of stopping
            // dead or waiting on a "Continue" tap.
            if let nextIssue {
                advanceToNextIssue()
            } else {
                showBoundaryToast("That's the last one")
            }
            return
        }
        currentPage += 1
    }

    private func prevPage() {
        guard currentPage > 0 else {
            if let previousIssue {
                goToPreviousIssue()
            } else {
                showBoundaryToast("That's the first one")
            }
            return
        }
        currentPage -= 1
    }

    /// Same hero-reverse-then-close sequence as the Mac reader (`ReaderView.handleClose()`):
    /// brings the hero-cover layer back so there's something for the matched-geometry shrink to
    /// animate, then tears the view down once that's had a moment to play out.
    private func handleClose() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onClose() }
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("This Comic Couldn't Be Read")
                .font(.headline).foregroundStyle(.white)
            Text("It may be corrupted or empty. Try rescanning your library from Settings.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Close") { handleClose() }
                .buttonStyle(.bordered)
        }
    }

    /// Mirrors `ReaderView.showFinishToastIfNeeded()`'s series-complete trigger (minus the Mac-only
    /// finish toast itself, which isn't part of this pass's scope) -- fires once per session, the
    /// moment a page turn lands on the comic's actual last page.
    private func showFinishToastIfNeeded() {
        guard !didShowFinishToast, pageCount > 1, currentPage >= pageCount - 1 else { return }
        didShowFinishToast = true
        saveProgress()
        checkSeriesComplete()
    }

    private func checkSeriesComplete() {
        let pub = comic.publisher, ser = comic.series
        Task.detached(priority: .utility) {
            let siblings = DatabaseManager.shared.allComics(publisher: pub, series: ser)
            guard siblings.count > 1, siblings.allSatisfy(\.isFinished) else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { showSeriesComplete = true }
        }
    }

    private func logSession() {
        DatabaseManager.shared.logReadingSession(comicId: comic.id, pageStart: min(sessionStartPage, currentPage), pageEnd: max(sessionStartPage, currentPage))
    }

    private var pageReader: some View {
        TabView(selection: $currentPage) {
            ForEach(0..<pageCount, id: \.self) { idx in
                ReaderPageView(comic: comic, pageIndex: idx, fitMode: fitMode)
                    .tag(idx)
                    .scaleEffect(scale)
                    .offset(offset)
                    .colorEffect(colorFilter)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Reverses swipe direction so a right-to-left manga-style series turns pages the way a
        // reader familiar with that format expects, same intent as the Mac reader's own RTL mode.
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
        .gesture(pinchGesture)
        .gesture(dragGesture)
        .onChange(of: currentPage) { _, _ in
            withAnimation(Design.motion(.easeOut(duration: 0.15), reduce: reduceMotion)) { scale = 1; offset = .zero }
            // Reset the gesture baselines too, not just the animated scale/offset -- otherwise
            // zooming on this page, then swiping to the next page without zooming back out,
            // leaves the next pinch/drag starting from the *previous* page's zoomed baseline.
            lastScale = 1; lastOffset = .zero
            scheduleHide()
            // Previously only saved on backgrounding/disappear -- a crash or force-quit mid-
            // session could silently roll progress back to wherever the reader was last opened.
            saveProgress()
        }
    }

    private var scrollReader: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    ReaderPageView(comic: comic, pageIndex: idx, fitMode: fitMode)
                        .frame(maxWidth: .infinity)
                        .colorEffect(colorFilter)
                        // Previously only `pageReader`'s `TabView` selection tracked `currentPage`
                        // -- scroll mode never updated it, so progress silently stopped saving the
                        // moment a user switched to continuous scroll. Matches the Mac reader's
                        // identical `ScrollPageView.onAppear` pattern.
                        .onAppear { currentPage = idx; saveProgress() }
                }
            }
        }
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
    }

    private var bookmarksSheet: some View {
        NavigationStack {
            List {
                if bookmarks.isEmpty {
                    Text("No bookmarks yet. Tap the bookmark icon while reading to save a page.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarks) { mark in
                        Button {
                            currentPage = mark.page
                            showBookmarks = false
                        } label: {
                            HStack {
                                Text(mark.label.isEmpty ? "Page \(mark.page + 1)" : mark.label)
                                Spacer()
                                Text("Page \(mark.page + 1)").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showBookmarks = false }
                }
            }
        }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let x = value.location.x
                let width = viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width
                if x < width * 0.25 {
                    prevPage()
                } else if x > width * 0.75 {
                    nextPage()
                } else {
                    withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { showBars.toggle() }
                    if showBars { scheduleHide() } else { hideTask?.cancel() }
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1.0, min(5.0, lastScale * value.magnification))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.05 {
                    // Matches the Mac reader's identical zoom-reset snap (ReaderView.swift),
                    // rather than a bare, uncalibrated `.spring()`.
                    withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { scale = 1; offset = .zero }
                    lastScale = 1
                    lastOffset = .zero
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width:  lastOffset.width  + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var overlayControls: some View {
        VStack {
            if showBars {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if showBars && showFilmstrip {
                filmstrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showBars {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion), value: showBars)
        .animation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion), value: showFilmstrip)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { idx in
                        Button {
                            currentPage = idx
                            saveProgress()
                        } label: {
                            iPadFilmstripThumb(comic: comic, index: idx, isCurrent: idx == currentPage)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(idx + 1)")
                        .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
            .onChange(of: currentPage) { _, page in
                withAnimation(Design.motion(.default, reduce: reduceMotion)) { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .frame(height: 100)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var topBar: some View {
        HStack {
            Button(action: handleClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Close Reader")
            Spacer()
            HStack(spacing: 8) {
                Button(action: goToPreviousIssue) {
                    Image(systemName: "chevron.left.circle")
                        .font(.subheadline)
                        .foregroundStyle(previousIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(previousIssue == nil)
                .accessibilityLabel(previousIssue == nil ? "No previous comic" : "Previous comic: \(previousIssue?.title ?? "")")

                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Button(action: advanceToNextIssue) {
                    Image(systemName: "chevron.right.circle")
                        .font(.subheadline)
                        .foregroundStyle(nextIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(nextIssue == nil)
                .accessibilityLabel(nextIssue == nil ? "No next comic" : "Next comic: \(nextIssue?.title ?? "")")
            }
            Spacer()
            Text("\(currentPage + 1) / \(pageCount)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()
            Button(action: toggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(isBookmarked ? Design.brandGold : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Add Bookmark")

            Menu {
                Button {
                    showBookmarks = true
                } label: {
                    Label("Bookmarks\(bookmarks.isEmpty ? "" : " (\(bookmarks.count))")", systemImage: "list.bullet")
                }

                Divider()

                Picker("Fit", selection: $fitModeRaw) {
                    Label("Fit Page", systemImage: "rectangle.arrowtriangle.2.inward").tag(FitMode.fitPage.rawValue)
                    Label("Fit Width", systemImage: "arrow.left.and.right").tag(FitMode.fitWidth.rawValue)
                    Label("Fit Height", systemImage: "arrow.up.and.down").tag(FitMode.fitHeight.rawValue)
                    Label("Original Size", systemImage: "square.dashed").tag(FitMode.original.rawValue)
                }

                Picker("Color Filter", selection: $colorFilterRaw) {
                    Label("None", systemImage: "circle.slash").tag(ColorFilter.none.rawValue)
                    Label("Night", systemImage: "moon.fill").tag(ColorFilter.night.rawValue)
                    Label("Sepia", systemImage: "sun.max.fill").tag(ColorFilter.sepia.rawValue)
                    Label("Grayscale", systemImage: "circle.lefthalf.filled").tag(ColorFilter.grayscale.rawValue)
                }

                Toggle(isOn: $rtl) {
                    Label("Right to Left", systemImage: "arrow.left.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Reader Settings")

            Button(action: { withAnimation(Design.motion(.default, reduce: reduceMotion)) { showFilmstrip.toggle() } }) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.title3)
                    .foregroundStyle(showFilmstrip ? Design.brandGold : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(showFilmstrip ? "Hide Page Filmstrip" : "Show Page Filmstrip")
            Button(action: { autoplay.toggle(); if !autoplay { countdownProgress = 0 } }) {
                Image(systemName: autoplay ? "pause.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(autoplay ? Design.brandGold : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(scrollMode)
            .opacity(scrollMode ? 0.35 : 1)
            .accessibilityLabel(autoplay ? "Stop Slideshow" : "Start Slideshow")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if autoplay {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Design.brandGold)
                        .frame(width: geo.size.width * countdownProgress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 20)
            }
            if pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { currentPage = Int($0.rounded()) }
                    ),
                    in: 0...Double(pageCount - 1),
                    step: 1
                )
                .tint(.white)
                .padding(.horizontal, 20)
                .accessibilityLabel("Page Scrubber")
                .accessibilityValue("Page \(currentPage + 1) of \(pageCount)")
            }
        }
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(Design.motion(.easeOut(duration: 0.25), reduce: reduceMotion)) { showBars = false }
            }
        }
    }

    private func saveProgress() {
        LibraryViewModel.shared.updateProgress(comic: comic, page: currentPage)
    }

    /// Looks up the adjacent issues (if any) and warms the next one's cover + first couple pages
    /// in the background, so a page-turn past either end of this comic has something ready to
    /// carry straight into instead of a cold load. Inside a run, "next"/"previous" are scoped to
    /// that run's ordered items; otherwise they fall back to series order.
    private func loadNextIssue() {
        let current = comic
        let rid = runId
        Task.detached(priority: .userInitiated) {
            if let rid {
                let items = DatabaseManager.shared.runItems(runId: rid)
                guard let idx = items.firstIndex(where: { $0.comic.id == current.id }) else { return }
                let next = idx + 1 < items.count ? items[idx + 1].comic : nil
                let prev = idx > 0 ? items[idx - 1].comic : nil
                if let next {
                    ThumbnailCache.shared.thumbnail(for: next) { _ in }
                    PageCache.shared.prefetch(comic: next, around: 0, count: 2)
                }
                await MainActor.run { nextIssue = next; previousIssue = prev }
            } else {
                let next = DatabaseManager.shared.nextComic(after: current)
                let prev = DatabaseManager.shared.previousComic(before: current)
                if let next {
                    ThumbnailCache.shared.thumbnail(for: next) { _ in }
                    PageCache.shared.prefetch(comic: next, around: 0, count: 2)
                }
                await MainActor.run { nextIssue = next; previousIssue = prev }
            }
        }
    }

    private func advanceToNextIssue() {
        guard let nextIssue else { return }
        saveProgress()
        logSession()
        vm.openReader(nextIssue, runId: runId)
    }

    private func goToPreviousIssue() {
        guard let previousIssue else { return }
        saveProgress()
        logSession()
        vm.openReader(previousIssue, runId: runId)
    }

    /// Fires when a page-turn tries to cross a comic boundary with nowhere to go -- a brief,
    /// non-interactive bump acknowledging the edge of the library instead of stopping dead with
    /// no feedback at all. Mirrors the Mac reader's identical `boundaryToast`.
    private func showBoundaryToast(_ text: String) {
        boundaryToastText = text
        withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { showBoundaryToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { showBoundaryToast = false }
        }
    }

    private var boundaryToast: some View {
        Text(boundaryToastText)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.75), in: Capsule())
    }

    private func runAutoplay() async {
        guard autoplay, !scrollMode else { return }
        let steps = 60
        for i in 0..<steps {
            guard autoplay, !Task.isCancelled else { await MainActor.run { countdownProgress = 0 }; return }
            await MainActor.run { countdownProgress = Double(i) / Double(steps) }
            do {
                try await Task.sleep(for: .milliseconds(Int(autoplaySpeed * 1000) / steps))
            } catch {
                await MainActor.run { countdownProgress = 0 }
                return
            }
        }
        guard autoplay, !Task.isCancelled else { await MainActor.run { countdownProgress = 0 }; return }
        await MainActor.run {
            countdownProgress = 0
            if currentPage < pageCount - 1 {
                currentPage += 1
            } else if nextIssue != nil {
                advanceToNextIssue()
            } else {
                autoplay = false
                showBoundaryToast("That's the last one")
            }
        }
    }
}

private struct ReaderPageView: View {
    let comic: Comic
    let pageIndex: Int
    var fitMode: FitMode = .fitPage
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var retryToken = UUID()

    @ViewBuilder
    private func fittedImage(_ img: PlatformImage, size: CGSize) -> some View {
        let imgSize = img.size
        switch fitMode {
        case .fitPage:
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .fitWidth:
            let h = imgSize.height > 0 ? (size.width * imgSize.height / imgSize.width) : size.height
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: h)
        case .fitHeight:
            let w = imgSize.width > 0 ? (size.height * imgSize.width / imgSize.height) : size.width
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: w, height: size.height)
        case .original:
            ScrollView([.horizontal, .vertical]) {
                Image(platformImage: img).frame(width: imgSize.width, height: imgSize.height)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = image {
                    fittedImage(img, size: geo.size)
                } else if loadFailed {
                    // A real dead end before this: no explanation, no way forward except
                    // backing out of the reader entirely for one bad page.
                    Color.black
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle).foregroundStyle(.secondary)
                                Text("Couldn't load page \(pageIndex + 1)")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Retry") {
                                    loadFailed = false
                                    retryToken = UUID()
                                }
                                .buttonStyle(.bordered)
                            }
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color.black
                        .overlay(ProgressView().tint(.white))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: retryToken) {
            PageCache.shared.load(comic: comic, page: pageIndex) { img in
                if let img { image = img } else { loadFailed = true }
            }
        }
    }
}

private struct iPadFilmstripThumb: View {
    let comic:     Comic
    let index:     Int
    let isCurrent: Bool
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 54, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Design.brandGold : Color.white.opacity(0.15), lineWidth: isCurrent ? 2 : 1)
        )
        .task(id: index) {
            PageThumbnailCache.shared.thumbnail(comic: comic, page: index) { image = $0 }
        }
    }
}

struct iPadDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .zip,
            .pdf
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
#endif
