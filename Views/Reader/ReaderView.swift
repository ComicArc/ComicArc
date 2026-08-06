import SwiftUI

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

struct ReaderView: View {
    let comic: Comic
    let onClose: () -> Void
    /// Swaps the reader straight into the next issue in the series -- ContentView's ReaderView
    /// is `.id(comic.id)`-keyed, so calling this with a different comic tears down and rebuilds
    /// this whole view fresh for it (currentPage, zoom, etc. all reset), the same as opening any
    /// other comic normally.
    let onOpenComic: (Comic) -> Void
    /// Set when this comic was opened from inside a Run's reading path. When present, next/
    /// previous navigation is scoped to that run's ordered items instead of series order.
    let runId: Int64?

    @State private var nextIssue: Comic?
    @State private var previousIssue: Comic?
    @State private var showBoundaryToast = false
    @State private var boundaryToastText = ""

    @Environment(\.windowService) private var windowService
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @FocusState private var isFocused: Bool

    @State private var accentColor: Color?
    private var backdropColor: Color {
        Design.deepBackdropTint(accentColor,
                                 increaseContrast: colorSchemeContrast == .increased,
                                 differentiateWithoutColor: differentiateWithoutColor)
    }

    /// A brief hero layer that grows from wherever this comic's cover was on screen (a grid card
    /// or IssueDetailPage) into the reader, then fades to reveal the real paginated content
    /// underneath -- and the reverse on close. Not tied to whether the first page has actually
    /// finished decoding: that page is loading in parallel regardless, and gating this on it
    /// would mean a slow page turns "cover morph" into "cover hangs there," which reads as
    /// broken rather than as ordinary loading time.
    @State private var heroCoverImage: PlatformImage?
    @State private var showHeroCover = true
    @State private var isClosing = false

    @State private var showFinishToast = false
    @State private var didShowFinishToast = false
    @State private var showSeriesComplete = false

    @State private var currentPage:      Int
    @State private var sessionStartPage: Int

    @AppStorage("readerColorFilter")    private var colorFilterRaw = ColorFilter.none.rawValue

    @State private var scrollMode: Bool
    @State private var rtl:        Bool
    @State private var fitModeRaw: String

    private var fitMode: FitMode         { FitMode(rawValue: fitModeRaw) ?? .fitPage }
    private var colorFilter: ColorFilter { ColorFilter(rawValue: colorFilterRaw) ?? .none }

    @State private var doublePage: Bool
    @State private var currentPageIsSpread = false
    @State private var saveProgressWorkItem: DispatchWorkItem?
    @State private var autoplay          = false
    @State private var countdownProgress = 0.0
    @AppStorage("autoplaySpeed") private var autoplayInterval: Double = 6.0

    @State private var bookmarks:   [Bookmark] = []
    @State private var isBookmarked = false
    @State private var showBookmarks = false

    @State private var showShortcuts = false
    @State private var showFilmstrip = false
    @State private var comicRating:  Int

    @State private var showTopBar    = true
    @State private var showBottomBar = true
    @State private var hideTask:     DispatchWorkItem? = nil
    @AppStorage("readerToolbarLocked") private var toolbarLocked = false

    @GestureState private var pinchScale: CGFloat = 1.0
    @State private var steadyZoom: CGFloat = 1.0
    @State private var panOffset:  CGSize  = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var cursorPosition: CGPoint = .zero

    private var currentZoom: CGFloat { min(5, max(0.5, steadyZoom * pinchScale)) }
    private var isZoomed:    Bool    { currentZoom > 1.05 }
    private var totalOffset: CGSize {
        CGSize(width: panOffset.width + dragOffset.width,
               height: panOffset.height + dragOffset.height)
    }

    init(comic: Comic, initialPage: Int? = nil, runId: Int64? = nil, onClose: @escaping () -> Void,
         onOpenComic: @escaping (Comic) -> Void) {
        self.comic        = comic
        self.onClose      = onClose
        self.onOpenComic  = onOpenComic
        self.runId        = runId
        // Clamp both bounds: page_count can change after progress was saved (a metadata refresh
        // correcting a bad initial page count, or a revival at the same path with a different
        // file) and a stale out-of-range progress would otherwise land the reader on a blank
        // page with "Next" already disabled and the page slider out of its own bounds.
        let clampedPage = min(max(0, initialPage ?? comic.progress), max(0, comic.pageCount - 1))
        _currentPage      = State(initialValue: clampedPage)
        _sessionStartPage = State(initialValue: clampedPage)
        _comicRating      = State(initialValue: comic.rating)

        let defaults = UserDefaults.standard
        let prefs = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
        _fitModeRaw = State(initialValue: prefs?.fitMode ?? defaults.string(forKey: "readerFitMode") ?? FitMode.fitPage.rawValue)
        _rtl        = State(initialValue: prefs?.rtl ?? defaults.bool(forKey: "readingDirectionRTL"))
        _doublePage = State(initialValue: prefs?.doubleSpread ?? false)
        _scrollMode = State(initialValue: prefs?.scrollMode ?? defaults.bool(forKey: "scrollMode"))
    }

    private func saveSeriesPrefs() {
        DatabaseManager.shared.setSeriesReaderPrefs(
            series: comic.series, publisher: comic.publisher,
            fitMode: fitModeRaw, rtl: rtl, doubleSpread: doublePage, scrollMode: scrollMode
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                backdropColor.ignoresSafeArea()

                pageContent
                    .colorEffect(colorFilter)

                if showHeroCover, let heroCoverImage {
                    Image(platformImage: heroCoverImage)
                        .comicCoverStyle()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .heroGeometry(id: comic.id, in: readerNamespace, isSource: false)
                        .transition(.opacity)
                        .zIndex(5)
                }

                VStack(spacing: 0) {
                    if showTopBar {
                        topBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if showFilmstrip {
                        filmstrip
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if showBottomBar {
                        bottomBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if autoplay {
                    autoplayBar
                }

                if showFinishToast {
                    VStack {
                        Spacer()
                        finishToast
                            .padding(.bottom, 100)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

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
            .onContinuousHover { phase in
                if case .active(let loc) = phase {
                    cursorPosition = loc
                    let nearTop    = loc.y < 100
                    let nearBottom = loc.y > geo.size.height - 120
                    withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) {
                        if nearTop || toolbarLocked { showTopBar = true }
                        if nearBottom || toolbarLocked { showBottomBar = true }
                    }
                    scheduleHide()
                }
            }

            .onTapGesture(count: 2) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) {
                    if isZoomed {
                        steadyZoom = 1; panOffset = .zero
                    } else {
                        let cx = geo.size.width / 2
                        let cy = geo.size.height / 2
                        steadyZoom  = 2.0
                        panOffset   = CGSize(width:  cx - cursorPosition.x,
                                            height: cy - cursorPosition.y)
                    }
                }
            }

            .onChange(of: geo.size) { _, _ in resetZoom() }
        }
        .accessibilityLabel("Comic reader — \(comic.title), page \(currentPage + 1) of \(comic.pageCount)")
        .accessibilityHint("Double-tap to zoom. Swipe to navigate pages.")
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { rtl ? nextPage() : prevPage(); return .handled }
        .onKeyPress(.rightArrow) { rtl ? prevPage() : nextPage(); return .handled }
        .onKeyPress(.upArrow)    { prevPage(); return .handled }
        .onKeyPress(.downArrow)  { nextPage(); return .handled }
        .onKeyPress(.escape) {
            if autoplay { autoplay = false; return .handled }
            handleClose(); return .handled
        }
        .onKeyPress(KeyEquivalent("a")) { toggleAutoplay(); return .handled }
        .onKeyPress(KeyEquivalent("d")) { doublePage.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("b")) { toggleBookmark(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { rtl.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("?")) { showShortcuts.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("g")) { withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showFilmstrip.toggle() }; return .handled }
        .onKeyPress(.home) { currentPage = 0; saveProgress(); return .handled }
        .onKeyPress(.end)  { currentPage = max(0, comic.pageCount - 1); saveProgress(); return .handled }
        .onKeyPress(KeyEquivalent("=")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("+")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("-")) { zoomOut(); return .handled }
        .onKeyPress(KeyEquivalent("0")) { resetZoom(); return .handled }
        .onChange(of: currentPage)     { _, _ in
            resetZoom()
            // Recompute locally instead of re-querying the DB on every single page turn --
            // the bookmarks list itself only changes via toggleBookmark()/loadBookmarks(),
            // never as a side effect of simply turning pages.
            isBookmarked = bookmarks.contains { $0.page == currentPage }
            showFinishToastIfNeeded()
        }
        .onChange(of: fitModeRaw)      { _, _ in saveSeriesPrefs() }
        .onChange(of: rtl)             { _, _ in saveSeriesPrefs() }
        .onChange(of: doublePage)      { _, _ in saveSeriesPrefs() }
        .onChange(of: scrollMode)      { _, newValue in
            saveSeriesPrefs()
            // Autoplay's page-by-page advance is meaningless once scrolling continuously;
            // stop it rather than leaving a stuck "playing" icon with a frozen countdown.
            if newValue, autoplay { autoplay = false; countdownProgress = 0 }
        }
        .onKeyPress(KeyEquivalent("w"), action: { handleClose(); return .handled })
        .onKeyPress(KeyEquivalent("f")) {
            windowService.toggleFullScreen()
            return .handled
        }
        .background(
            Button("") { handleClose() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        )
        .onAppear {
            isFocused = true
            loadBookmarks()
            scheduleHide()
            windowService.enterImmersiveMode()
            loadNextIssue()
            // Cache-only: this exact cover was almost certainly just on screen (a grid card or
            // IssueDetailPage) a moment ago, so this is normally an instant hit, not a fresh
            // decode -- matches the hero layer's own job of bridging that already-loaded image
            // into the reader, not doing new work.
            heroCoverImage = ThumbnailCache.shared.thumbnailFromCache(comicId: comic.id)
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = false }
            }
        }
        .onDisappear {
            saveProgress(); logSession(); hideTask?.cancel()
            windowService.showCursor()
            windowService.exitImmersiveMode()

            PageCache.shared.evict(comicId: comic.id)
        }
        .task(id: "\(autoplay)-\(currentPage)") { await runAutoplay() }
        .onReceive(NotificationCenter.default.publisher(for: .triggerPrint)) { _ in printCurrentPage() }
        .sheet(isPresented: $showShortcuts) { shortcutsSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksPanel }
        .sheet(isPresented: $showSeriesComplete) {
            SeriesCompleteView(publisher: comic.publisher, series: comic.series)
        }
        // Always dark, regardless of the user's app theme: the reader chrome (topBar/bottomBar)
        // uses hardcoded white icons/text over .ultraThinMaterial. Materials pick up a lighter
        // tint under a .light color scheme, which ContentView applies app-wide for the Sepia
        // theme -- that would wash the toolbar toward white-on-white right where the fixed
        // white controls need the darkest, highest-contrast variant of the material.
        .preferredColorScheme(.dark)
    }

    /// Every internal trigger that ends a reading session (Escape, ⌘W, the close button) calls
    /// this instead of `onClose()` directly -- brings the hero-cover layer back first so there's
    /// something for the matched-geometry shrink to actually animate, then tears the view down
    /// once that's had a moment to play out. Calling `onClose()` immediately instead would remove
    /// this view before any of that could be seen.
    private func handleClose() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onClose() }
    }

    /// Fires once per reader session (not once ever -- reopening an already-finished comic and
    /// reaching the last page again is a legitimate reread, not a bug to suppress) the moment a
    /// page turn lands on the comic's actual last page. Checks `currentPage` directly rather than
    /// `comic.isFinished`, since `comic` is this session's original snapshot and never reflects
    /// the progress this same session is making.
    private func showFinishToastIfNeeded() {
        guard !didShowFinishToast, comic.pageCount > 1, currentPage >= comic.pageCount - 1 else { return }
        didShowFinishToast = true
        withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showFinishToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showFinishToast = false }
        }
        // Must save first: checkSeriesComplete() queries every comic's live progress straight
        // from the DB, and this comic's own row won't reflect the page just reached until this
        // writes it -- without it, a series' very last issue would always look one issue short
        // of complete on the read that actually finishes it.
        saveProgress()
        checkSeriesComplete()
    }

    /// "Complete" is library-relative: every issue currently on disk for this (publisher, series)
    /// has been read, not a claim the real-world series has ended (nothing in the schema tracks
    /// that, and most series a user reads are ongoing anyway). Requires more than one issue --
    /// finishing a single one-shot isn't a series milestone.
    private func checkSeriesComplete() {
        let pub = comic.publisher, ser = comic.series
        Task.detached(priority: .utility) {
            let siblings = DatabaseManager.shared.allComics(publisher: pub, series: ser)
            guard siblings.count > 1, siblings.allSatisfy(\.isFinished) else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { showSeriesComplete = true }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !toolbarLocked else {
            withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showTopBar = true; showBottomBar = true }
            return
        }
        let w = DispatchWorkItem { [self] in
            withAnimation(Design.motion(.easeOut(duration: 0.25), reduce: reduceMotion)) {
                showTopBar    = false
                showBottomBar = false
            }
            if !scrollMode { windowService.hideCursorUntilMouseMoves() }
        }
        hideTask = w

        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    @ViewBuilder
    private var pageContent: some View {
        if scrollMode {
            ScrollModeView(comic: comic, currentPage: $currentPage)
        } else {
            PagedModeView(
                comic: comic,
                currentPage: $currentPage,
                isSpread: $currentPageIsSpread,
                doublePage: doublePage,
                fitMode: fitMode,
                rtl: rtl,
                isZoomed: isZoomed
            )
            .scaleEffect(currentZoom)
            .offset(isZoomed ? totalOffset : .zero)

            .gesture(
                MagnifyGesture()
                    .updating($pinchScale) { val, state, _ in state = val.magnification }
                    .onEnded { val in
                        steadyZoom = min(5, max(0.5, steadyZoom * val.magnification))
                        if steadyZoom <= 1.05 {
                            withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { steadyZoom = 1; panOffset = .zero }
                        }
                    }
            )

            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .updating($dragOffset) { val, state, _ in
                        guard currentZoom > 1.05 else { return }
                        state = val.translation
                    }
                    .onEnded { val in
                        guard currentZoom > 1.05 else { return }
                        panOffset = CGSize(
                            width:  panOffset.width  + val.translation.width,
                            height: panOffset.height + val.translation.height
                        )
                    }
            )
            .onTapGesture { }
            .animation(Design.motion(Design.springSnappy, reduce: reduceMotion), value: currentZoom)
        }
    }

    private func zoomIn()  { withAnimation(Design.motion(.default, reduce: reduceMotion)) { steadyZoom = min(5, steadyZoom * 1.25) } }
    private func zoomOut() {
        withAnimation(Design.motion(.default, reduce: reduceMotion)) {
            steadyZoom = max(0.5, steadyZoom / 1.25)
            if steadyZoom <= 1.05 { steadyZoom = 1; panOffset = .zero }
        }
    }
    private func resetZoom() { withAnimation(Design.motion(.default, reduce: reduceMotion)) { steadyZoom = 1; panOffset = .zero } }

    private var autoplayBar: some View {
        VStack {
            Spacer()
            GeometryReader { geo in
                Rectangle()
                    .fill(Design.brandBlue)
                    .frame(width: geo.size.width * countdownProgress, height: 3)
                    .animation(.linear(duration: 0.1), value: countdownProgress)
            }
            .frame(height: 3)
        }
        .ignoresSafeArea()
    }

    private var finishToast: some View {
        HStack(spacing: 10) {
            // The one deliberately bouncy flourish near the reader itself -- transient chrome
            // celebrating a real moment, not the page content, which stays undistracted. Owns its
            // own @State since this view only exists while showFinishToast is already true --
            // animating `.scaleEffect(showFinishToast ? ... )` here would never see a change fire.
            FinishToastIcon()
            Text("Finished!")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.75), in: Capsule())
    }

    private struct FinishToastIcon: View {
        @State private var scale: CGFloat = 0.01
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .scaleEffect(scale)
                .onAppear { withAnimation(Design.motion(Design.springBouncy, reduce: reduceMotion)) { scale = 1 } }
        }
    }

    /// Fires when a page-turn tries to cross a comic boundary with nowhere to go (no next/
    /// previous comic available) -- a brief, non-interactive bump acknowledging the edge of the
    /// library instead of stopping dead with no feedback at all.
    private func showBoundaryToast(_ text: String) {
        boundaryToastText = text
        withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showBoundaryToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showBoundaryToast = false }
        }
    }

    private var boundaryToast: some View {
        Text(boundaryToastText)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.75), in: Capsule())
    }

    private var topBar: some View {
        HStack {
            Button { handleClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain).padding()
            .accessibilityLabel("Close reader")
            .help("Close reader (W)")

            Spacer()

            HStack(spacing: 10) {
                Button { goToPreviousIssue() } label: {
                    Image(systemName: "chevron.left.circle")
                        .font(.title3)
                        .foregroundStyle(previousIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(previousIssue == nil)
                .accessibilityLabel(previousIssue == nil ? "No previous comic" : "Previous comic: \(previousIssue?.title ?? "")")
                .help(previousIssue == nil ? "No previous comic" : "Previous: \(previousIssue?.title ?? "")")

                Text(comic.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(1).padding(.horizontal)
                    .accessibilityLabel("Reading: \(comic.title)")

                Button { advanceToNextIssue() } label: {
                    Image(systemName: "chevron.right.circle")
                        .font(.title3)
                        .foregroundStyle(nextIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(nextIssue == nil)
                .accessibilityLabel(nextIssue == nil ? "No next comic" : "Next comic: \(nextIssue?.title ?? "")")
                .help(nextIssue == nil ? "No next comic" : "Next: \(nextIssue?.title ?? "")")
            }

            Spacer()

            HStack(spacing: 10) {
                Button { toggleBookmark() } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.title2)
                        .foregroundStyle(isBookmarked ? Design.brandGold : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isBookmarked ? "Remove bookmark from page \(currentPage + 1)" : "Bookmark page \(currentPage + 1)")
                .help("Bookmark this page (B)")

                Button { showBookmarks.toggle() } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2).foregroundStyle(bookmarks.isEmpty ? .white.opacity(0.4) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All bookmarks\(bookmarks.isEmpty ? "" : ", \(bookmarks.count) total")")
                .help("All bookmarks")
                .overlay(alignment: .topTrailing) {
                    if !bookmarks.isEmpty {
                        Text("\(bookmarks.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .background(Design.brandGold)
                            .clipShape(Capsule())
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }

                Divider().frame(height: 16).background(.white.opacity(0.3)).accessibilityHidden(true)

                Menu {
                    ForEach(FitMode.allCases, id: \.self) { mode in
                        Button { fitModeRaw = mode.rawValue } label: {
                            Label(mode.label, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image(systemName: fitMode.icon)
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Fit mode: \(fitMode.label)")
                .help("Fit mode: \(fitMode.label)")

                Menu {
                    Toggle(isOn: $rtl) {
                        Label(rtl ? "Right-to-Left" : "Left-to-Right", systemImage: "text.justify.right")
                    }
                    if !scrollMode {
                        Toggle(isOn: $doublePage) {
                            Label("Double-Page Spread", systemImage: "rectangle.split.2x1")
                        }
                    }
                    Toggle(isOn: $scrollMode) {
                        Label("Scroll Mode", systemImage: "scroll")
                    }
                    Divider()
                    Menu {
                        ForEach(ColorFilter.allCases, id: \.self) { f in
                            Button { colorFilterRaw = f.rawValue } label: {
                                Label(f.label, systemImage: f.icon)
                            }
                        }
                    } label: {
                        Label("Color Filter: \(colorFilter.label)", systemImage: colorFilter.icon)
                    }
                    Divider()
                    Toggle(isOn: $toolbarLocked) {
                        Label("Pin Toolbar", systemImage: "pin")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Reader settings")
                .help("Reader settings")

                Button { toggleAutoplay() } label: {
                    Image(systemName: autoplay ? "pause.circle.fill" : "play.circle")
                        .font(.title2).foregroundStyle(autoplay ? Design.brandGold : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                // runAutoplay() no-ops entirely in scroll mode (page-by-page advancing doesn't
                // apply to a continuous scroll), so without this the button/key shortcut can
                // flip autoplay to visually "on" (gold icon, static countdown bar) with nothing
                // actually advancing -- disable it here to match iPadReaderView's guard.
                .disabled(scrollMode)
                .opacity(scrollMode ? 0.35 : 1)
                .accessibilityLabel(autoplay ? "Stop slideshow" : "Start slideshow")
                .help(autoplay ? "Stop Autoplay (A)" : "Start Autoplay (A)")

                Button { showShortcuts.toggle() } label: {
                    Image(systemName: "keyboard")
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keyboard shortcuts")
                .help("Keyboard Shortcuts (?)")

                Button { withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showFilmstrip.toggle() } } label: {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.title2)
                        .foregroundStyle(showFilmstrip ? Design.brandGold : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showFilmstrip ? "Hide page filmstrip" : "Show page filmstrip")
                .help(showFilmstrip ? "Hide page filmstrip (G)" : "Show page filmstrip (G)")
            }
            .padding()
        }
        .background(.ultraThinMaterial.opacity(0.9))
    }

    @State private var showPageJump = false
    @State private var pageJumpText = ""

    private var bottomBar: some View {
        HStack {
            Button { rtl ? nextPage() : prevPage() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(rtl ? currentPage >= comic.pageCount - 1 : currentPage == 0)
            .accessibilityLabel(rtl ? "Next page" : "Previous page")
            .help(rtl ? "Next page (→)" : "Previous page (←)")

            VStack(spacing: 6) {
                if comic.pageCount > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(currentPage) },
                            set: { currentPage = Int($0.rounded()); saveProgressDebounced() }
                        ),
                        in: 0...Double(max(1, comic.pageCount - 1)),
                        step: 1
                    )
                    .frame(maxWidth: .infinity)
                    .tint(Design.brandBlue)
                    .accessibilityLabel("Page scrubber")
                    .accessibilityValue("Page \(currentPage + 1) of \(comic.pageCount)")
                    .help("Drag to jump to any page")
                }

                Button {
                    pageJumpText = "\(currentPage + 1)"
                    showPageJump = true
                } label: {
                    Text("Page \(currentPage + 1) of \(comic.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(currentPage + 1) of \(comic.pageCount) — tap to jump")
                .help("Click to jump to page")
                .popover(isPresented: $showPageJump) {
                    HStack(spacing: 8) {
                        Text("Go to page:")
                            .foregroundStyle(.primary)
                        TextField("", text: $pageJumpText)
                            .frame(width: 48)
                            .onSubmit {
                                if let n = Int(pageJumpText) {
                                    currentPage = max(0, min(comic.pageCount - 1, n - 1))
                                }
                                showPageJump = false
                            }
                        Text("of \(comic.pageCount)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            let newRating = star == comicRating ? 0 : star
                            comicRating = newRating
                            LibraryViewModel.shared.setRating(comic, rating: newRating)
                        } label: {
                            Image(systemName: star <= comicRating ? "star.fill" : "star")
                                .font(.system(size: 13))
                                .foregroundStyle(star <= comicRating ? Design.brandGold : .white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(star == comicRating ? "Remove \(star)-star rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                        .help(star == comicRating ? "Tap to clear rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                    }
                }
            }
            .padding(.horizontal, 20)

            Button { rtl ? prevPage() : nextPage() } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(rtl ? currentPage == 0 : currentPage >= comic.pageCount - 1)
            .accessibilityLabel(rtl ? "Previous page" : "Next page")
            .help(rtl ? "Previous page (←)" : "Next page (→)")
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<comic.pageCount, id: \.self) { idx in
                        Button {
                            currentPage = idx
                            saveProgress()
                        } label: {
                            FilmstripThumb(comic: comic, index: idx, isCurrent: idx == currentPage)
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
        .frame(height: 108)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private var bookmarksPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bookmarks — \(comic.title)")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { showBookmarks = false }.keyboardShortcut(.return)
            }
            .padding()

            Divider()

            if bookmarks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No bookmarks yet").foregroundStyle(.secondary)
                    Text("Press B while reading to bookmark a page.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(bookmarks) { bm in
                        HStack {
                            Image(systemName: "bookmark.fill").foregroundStyle(Design.brandGold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Page \(bm.page + 1)")
                                    .font(.headline)
                                if !bm.label.isEmpty {
                                    Text(bm.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                DatabaseManager.shared.setBookmarkFavorite(
                                    comicId: comic.id, page: bm.page, isFavorite: !bm.isFavorite)
                                loadBookmarks()
                            } label: {
                                Image(systemName: bm.isFavorite ? "star.fill" : "star")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(bm.isFavorite ? Design.brandGold : .secondary)
                            .help(bm.isFavorite ? "Remove from Highlights" : "Add to Highlights")
                            .accessibilityLabel(bm.isFavorite ? "Remove from highlights" : "Add to highlights")
                            Button("Go") {
                                currentPage = bm.page
                                showBookmarks = false
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .onDelete { idx in
                        idx.forEach { i in
                            DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: bookmarks[i].page)
                        }
                        loadBookmarks()
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }

    private var shortcutsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())
                .padding(24)
            Divider()

            let shortcuts: [(String, String)] = [
                ("→ / ←",        "Next / Previous page (respects RTL)"),
                ("↑ / ↓",        "Previous / Next page"),
                ("Home",         "First page"),
                ("End",          "Last page"),
                ("A",            "Toggle Autoplay"),
                ("B",            "Bookmark current page"),
                ("D",            "Toggle Double-Page Spread"),
                ("R",            "Toggle RTL reading direction"),
                ("+ / -",        "Zoom in / out"),
                ("0",            "Reset zoom"),
                ("F",            "Toggle fullscreen"),
                ("G",            "Toggle page filmstrip"),
                ("Escape / W",   "Close reader"),
                ("?",            "Show / hide this panel"),
            ]
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                ForEach(shortcuts, id: \.0) { key, desc in
                    GridRow {
                        Text(key).font(.system(.body, design: .monospaced).bold()).foregroundStyle(Design.brandBlue)
                        Text(desc).foregroundStyle(.primary)
                    }
                }
            }
            .padding(24)
            Divider()
            HStack {
                Spacer()
                Button("Done") { showShortcuts = false }.keyboardShortcut(.return).padding(16)
            }
        }
        .frame(width: 420)
    }

    private func nextPage() {
        guard comic.pageCount > 0 else { return }
        let advance = (doublePage && !currentPageIsSpread && !scrollMode) ? 2 : 1
        let target  = max(0, min(currentPage + advance, comic.pageCount - 1))
        guard target != currentPage else {
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
        currentPage = target
        saveProgress()
    }

    private func prevPage() {
        let step = (doublePage && !currentPageIsSpread && !scrollMode) ? 2 : 1
        guard currentPage > 0 else {
            if let previousIssue {
                goToPreviousIssue()
            } else {
                showBoundaryToast("That's the first one")
            }
            return
        }
        currentPage = max(0, currentPage - step)
        saveProgress()
    }

    private func toggleAutoplay() {
        guard !scrollMode else { return }
        autoplay.toggle()
        if !autoplay { countdownProgress = 0 }
    }

    private func toggleBookmark() {
        isBookmarked = DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: currentPage)
        loadBookmarks()
    }

    private func printCurrentPage() {
        PageCache.shared.load(comic: comic, page: currentPage) { img in
            guard let img else { return }
            windowService.printImage(img)
        }
    }

    private func loadBookmarks() {
        bookmarks    = DatabaseManager.shared.bookmarks(comicId: comic.id)
        isBookmarked = bookmarks.contains { $0.page == currentPage }
    }

    private func saveProgress() {
        LibraryViewModel.shared.updateProgress(comic: comic, page: currentPage)
    }

    private func saveProgressDebounced() {
        saveProgressWorkItem?.cancel()
        let work = DispatchWorkItem { saveProgress() }
        saveProgressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func logSession() {
        DatabaseManager.shared.logReadingSession(comicId: comic.id, pageStart: min(sessionStartPage, currentPage), pageEnd: max(sessionStartPage, currentPage))
    }

    /// Looks up the adjacent issues (if any) so a page-turn past either end of this comic has
    /// something to carry straight into -- also warms the next one's cover and first couple pages
    /// in the background so that transition, whenever it happens, is instant instead of a cold
    /// load. Inside a run, "next"/"previous" are scoped to that run's ordered items; otherwise
    /// they fall back to series order.
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
        onOpenComic(nextIssue)
    }

    private func goToPreviousIssue() {
        guard let previousIssue else { return }
        saveProgress()
        logSession()
        onOpenComic(previousIssue)
    }

    private func runAutoplay() async {
        guard autoplay, !scrollMode else { return }
        let steps = 60
        for i in 0..<steps {
            guard autoplay, !Task.isCancelled else { await MainActor.run { countdownProgress = 0 }; return }
            await MainActor.run { countdownProgress = Double(i) / Double(steps) }
            do {
                try await Task.sleep(for: .milliseconds(Int(autoplayInterval * 1000) / steps))
            } catch {
                await MainActor.run { countdownProgress = 0 }
                return
            }
        }
        guard autoplay, !Task.isCancelled else { await MainActor.run { countdownProgress = 0 }; return }
        await MainActor.run {
            countdownProgress = 0
            if currentPage < comic.pageCount - 1 {
                nextPage()
            } else if nextIssue != nil {
                // Autoplay is a hands-off "just keep reading" mode -- carrying it across the
                // seam into the next issue (instead of silently stopping) is what makes it match
                // that intent instead of quietly giving up at the one moment it'd matter most.
                advanceToNextIssue()
            } else {
                autoplay = false
                showBoundaryToast("That's the last one")
            }
        }
    }
}

extension View {
    @ViewBuilder
    func colorEffect(_ filter: ColorFilter) -> some View {
        switch filter {
        case .none:
            self
        case .night:
            self.colorMultiply(Color(red: 1.0, green: 0.85, blue: 0.65))
                .brightness(-0.05)
        case .sepia:
            self.saturation(0)
                .colorMultiply(Color(red: 1.12, green: 0.96, blue: 0.82))
        case .grayscale:
            self.grayscale(1.0)
        }
    }
}

struct PagedModeView: View {
    let comic:      Comic
    @Binding var currentPage: Int
    @Binding var isSpread:    Bool
    let doublePage: Bool
    let fitMode:    FitMode
    let rtl:        Bool
    let isZoomed:   Bool

    @State private var imageLeft:  PlatformImage?
    @State private var imageRight: PlatformImage?
    @State private var isLoading  = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSpreadPage: Bool {
        guard let img = imageLeft else { return false }
        return img.size.width > img.size.height * 1.15
    }
    private var effectiveDoublePage: Bool { doublePage && !isSpreadPage }
    private var pageAdvance: Int { effectiveDoublePage ? 2 : 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if isLoading {
                    ProgressView().tint(.white)
                        .transition(.opacity)
                } else if effectiveDoublePage, let left = imageLeft {
                    HStack(spacing: 1) {
                        if rtl {
                            if let right = imageRight { pageImage(right, size: geo.size) }
                            pageImage(left, size: geo.size)
                        } else {
                            pageImage(left, size: geo.size)
                            if let right = imageRight { pageImage(right, size: geo.size) }
                        }
                    }
                    .id(currentPage)
                    .transition(.opacity)
                } else if let img = imageLeft {
                    pageImage(img, size: geo.size)
                        .id(currentPage)
                        .transition(.opacity)
                } else {
                    // A real dead end before this: no explanation, no way forward except backing
                    // out of the reader entirely -- one bad page (a flaky external drive, a
                    // genuinely corrupt page inside an otherwise-fine archive) shouldn't strand
                    // the whole session.
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("Couldn't load page \(currentPage + 1)")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Retry") { loadPage(currentPage) }
                            .buttonStyle(.bordered)
                    }
                    .transition(.opacity)
                }
            }
        }

        .gesture(
            DragGesture(minimumDistance: 40).onEnded { val in
                guard !isZoomed, comic.pageCount > 0 else { return }
                let forward  = val.translation.width < -40
                let backward = val.translation.width >  40
                // Clamp with max/min rather than a plain `currentPage > 0`/`< pageCount - 1` guard --
                // with pageAdvance == 2 (double-page mode), landing on an odd page index (reachable
                // via the filmstrip, slider, page-jump popover, or a bookmark, none of which are
                // restricted to even pages) let a backward drag compute currentPage - 2 = -1, a
                // negative index that traps as a fatal array-out-of-range error once it reaches the
                // raw `images[index]` subscript in cbzPage/cbrPage.
                if rtl {
                    if forward  { currentPage = max(0, currentPage - pageAdvance) }
                    if backward { currentPage = min(comic.pageCount - 1, currentPage + pageAdvance) }
                } else {
                    if forward  { currentPage = min(comic.pageCount - 1, currentPage + pageAdvance) }
                    if backward { currentPage = max(0, currentPage - pageAdvance) }
                }
            }
        )
        .onChange(of: currentPage) { _, page in loadPage(page) }
        .onChange(of: doublePage)  { _, _    in loadPage(currentPage) }
        .onAppear { loadPage(currentPage) }
    }

    @ViewBuilder
    private func pageImage(_ img: PlatformImage, size: CGSize) -> some View {
        let imgSize = img.size
        switch fitMode {
        case .fitPage:
            Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }

    private func loadPage(_ page: Int) {
        isLoading = true
        imageLeft = nil; imageRight = nil
        PageCache.shared.load(comic: comic, page: page) { img in
            guard page == self.currentPage else { return }
            // A real page-turn transition -- previously an instant/jarring image swap with no
            // `.transition`/`withAnimation` at all, the one place Mac's paged mode read as less
            // finished than iPad's free native TabView swipe. Wrapping the mutation itself
            // (rather than an `.animation(value:)` keyed off `currentPage`) is what actually
            // catches this, since the real content change lands here, one async hop later than
            // the `currentPage` assignment that triggered it.
            withAnimation(Design.motion(Design.easeStandard, reduce: self.reduceMotion)) {
                self.imageLeft  = img
                self.isLoading  = false
            }
            self.isSpread = self.isSpreadPage
            if self.effectiveDoublePage && page + 1 < self.comic.pageCount {
                PageCache.shared.load(comic: self.comic, page: page + 1) { img2 in
                    guard page == self.currentPage else { return }
                    withAnimation(Design.motion(Design.easeStandard, reduce: self.reduceMotion)) {
                        self.imageRight = img2
                    }
                }
            }
        }
        PageCache.shared.prefetch(comic: comic, around: page, count: 4)
    }
}

private struct FilmstripThumb: View {
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
        .frame(width: 60, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Design.brandGold : Color.white.opacity(0.15), lineWidth: isCurrent ? 2 : 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(2)
        }
        .task(id: index) {
            PageThumbnailCache.shared.thumbnail(comic: comic, page: index) { image = $0 }
        }
    }
}

struct ScrollModeView: View {
    let comic: Comic
    @Binding var currentPage: Int

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<comic.pageCount, id: \.self) { idx in
                    ScrollPageView(comic: comic, index: idx)
                        .frame(maxWidth: .infinity)
                        .onAppear { currentPage = idx }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

struct ScrollPageView: View {
    let comic: Comic
    let index: Int
    @State private var image: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let img = image {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
            } else if loadFailed {
                Color.black.frame(height: 600)
                    .overlay(Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary))
            } else {
                Color.black.frame(height: 600)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .task {
            PageCache.shared.load(comic: comic, page: index) { img in
                if let img { image = img } else { loadFailed = true }
            }
        }
    }
}
