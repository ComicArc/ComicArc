import SwiftUI

// MARK: - Reader settings enums

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

// MARK: - ReaderView

struct ReaderView: View {
    let comic: Comic
    let onClose: () -> Void

    @Environment(\.windowService) private var windowService
    @FocusState private var isFocused: Bool

    // Reading state
    @State private var currentPage:      Int
    @State private var sessionStartPage: Int

    // Mode toggles — seeded per-series in init() (falling back to these global defaults for
    // a series that's never been read before), then persisted per-series as the user changes
    // them, so switching between e.g. a manga (RTL) and a Western comic doesn't require
    // re-toggling reading direction every time.
    @AppStorage("readerColorFilter")    private var colorFilterRaw = ColorFilter.none.rawValue

    @State private var scrollMode: Bool
    @State private var rtl:        Bool
    @State private var fitModeRaw: String

    // Derived
    private var fitMode: FitMode         { FitMode(rawValue: fitModeRaw) ?? .fitPage }
    private var colorFilter: ColorFilter { ColorFilter(rawValue: colorFilterRaw) ?? .none }

    // Reader features
    @State private var doublePage: Bool
    @State private var currentPageIsSpread = false  // updated by PagedModeView after each load
    @State private var saveProgressWorkItem: DispatchWorkItem?
    @State private var autoplay          = false
    @State private var countdownProgress = 0.0
    @AppStorage("autoplaySpeed") private var autoplayInterval: Double = 6.0

    // Bookmarks
    @State private var bookmarks:   [Bookmark] = []
    @State private var isBookmarked = false
    @State private var showBookmarks = false

    // Overlays
    @State private var showShortcuts = false
    @State private var showFilmstrip = false
    @State private var comicRating:  Int

    // Auto-hide bar state
    @State private var showTopBar    = true
    @State private var showBottomBar = true
    @State private var hideTask:     DispatchWorkItem? = nil
    @AppStorage("readerToolbarLocked") private var toolbarLocked = false

    // Zoom & pan — single source of truth (PagedModeView owns no zoom state)
    @GestureState private var pinchScale: CGFloat = 1.0
    @State private var steadyZoom: CGFloat = 1.0
    @State private var panOffset:  CGSize  = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var cursorPosition: CGPoint = .zero   // tracked for cursor-anchored zoom

    private var currentZoom: CGFloat { min(5, max(0.5, steadyZoom * pinchScale)) }
    private var isZoomed:    Bool    { currentZoom > 1.05 }
    private var totalOffset: CGSize {
        CGSize(width: panOffset.width + dragOffset.width,
               height: panOffset.height + dragOffset.height)
    }

    init(comic: Comic, onClose: @escaping () -> Void) {
        self.comic        = comic
        self.onClose      = onClose
        _currentPage      = State(initialValue: max(0, comic.progress))
        _sessionStartPage = State(initialValue: max(0, comic.progress))
        _comicRating      = State(initialValue: comic.rating)

        let defaults = UserDefaults.standard
        let prefs = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
        _fitModeRaw = State(initialValue: prefs?.fitMode ?? defaults.string(forKey: "readerFitMode") ?? FitMode.fitPage.rawValue)
        _rtl        = State(initialValue: prefs?.rtl ?? defaults.bool(forKey: "readingDirectionRTL"))
        _doublePage = State(initialValue: prefs?.doubleSpread ?? false)
        _scrollMode = State(initialValue: prefs?.scrollMode ?? defaults.bool(forKey: "scrollMode"))
    }

    // Called whenever fit mode / RTL / double-page / scroll mode changes, so the next comic
    // opened from this same series picks up where this one left off.
    private func saveSeriesPrefs() {
        DatabaseManager.shared.setSeriesReaderPrefs(
            series: comic.series, publisher: comic.publisher,
            fitMode: fitModeRaw, rtl: rtl, doubleSpread: doublePage, scrollMode: scrollMode
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                pageContent
                    .colorEffect(colorFilter)

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
            }
            .onContinuousHover { phase in
                if case .active(let loc) = phase {
                    cursorPosition = loc
                    let nearTop    = loc.y < 100
                    let nearBottom = loc.y > geo.size.height - 120
                    withAnimation(Design.easeFast) {
                        if nearTop || toolbarLocked { showTopBar = true }
                        if nearBottom || toolbarLocked { showBottomBar = true }
                    }
                    scheduleHide()
                }
            }
            // Cursor-anchored double-click zoom (needs geo.size, so lives here not in pageContent)
            .onTapGesture(count: 2) {
                withAnimation(Design.springGentle) {
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
            // steadyZoom/panOffset are absolute points computed against geo.size at the
            // moment of the gesture; resizing the window (or toggling fullscreen) reapplies
            // that same stale offset/scale to the new size via .scaleEffect/.offset below,
            // so the pan no longer matches where the user actually zoomed. Resetting on
            // resize is simpler and safer than trying to rescale a pan offset proportionally,
            // and matches the existing page-change behavior on the line below.
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
            onClose(); return .handled
        }
        .onKeyPress(KeyEquivalent("a")) { toggleAutoplay(); return .handled }
        .onKeyPress(KeyEquivalent("d")) { doublePage.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("b")) { toggleBookmark(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { rtl.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("?")) { showShortcuts.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("g")) { withAnimation(Design.easeFast) { showFilmstrip.toggle() }; return .handled }
        .onKeyPress(.home) { currentPage = 0; saveProgress(); return .handled }
        .onKeyPress(.end)  { currentPage = max(0, comic.pageCount - 1); saveProgress(); return .handled }
        .onKeyPress(KeyEquivalent("=")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("+")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("-")) { zoomOut(); return .handled }
        .onKeyPress(KeyEquivalent("0")) { resetZoom(); return .handled }
        .onChange(of: currentPage)     { _, _ in resetZoom(); loadBookmarks() }
        .onChange(of: fitModeRaw)      { _, _ in saveSeriesPrefs() }
        .onChange(of: rtl)             { _, _ in saveSeriesPrefs() }
        .onChange(of: doublePage)      { _, _ in saveSeriesPrefs() }
        .onChange(of: scrollMode)      { _, _ in saveSeriesPrefs() }
        .onKeyPress(KeyEquivalent("w"), action: { onClose(); return .handled })
        .onKeyPress(KeyEquivalent("f")) {
            windowService.toggleFullScreen()
            return .handled
        }
        .background(
            Button("") { onClose() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        )
        .onAppear {
            isFocused = true
            loadBookmarks()
            scheduleHide()
            windowService.enterImmersiveMode()
        }
        .onDisappear {
            saveProgress(); logSession(); hideTask?.cancel()
            windowService.showCursor()
            windowService.exitImmersiveMode()
            // Otherwise up to 30 full-resolution decoded pages from this comic stay
            // resident in PageCache until unrelated LRU pressure from other comics
            // eventually pushes them out.
            PageCache.shared.evict(comicId: comic.id)
        }
        .task(id: "\(autoplay)-\(currentPage)") { await runAutoplay() }
        .sheet(isPresented: $showShortcuts) { shortcutsSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksPanel }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !toolbarLocked else {
            withAnimation(Design.easeFast) { showTopBar = true; showBottomBar = true }
            return
        }
        let w = DispatchWorkItem { [self] in
            withAnimation(.easeOut(duration: 0.25)) {
                showTopBar    = false
                showBottomBar = false
            }
            if !scrollMode { windowService.hideCursorUntilMouseMoves() }
        }
        hideTask = w
        // 8s delay before auto-hiding controls, long enough not to vanish mid-glance at the page counter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    // MARK: - Page content

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
            // Pinch-to-zoom — live scale via @GestureState pinchScale, committed on end
            .gesture(
                MagnifyGesture()
                    .updating($pinchScale) { val, state, _ in state = val.magnification }
                    .onEnded { val in
                        steadyZoom = min(5, max(0.5, steadyZoom * val.magnification))
                        if steadyZoom <= 1.05 {
                            withAnimation(Design.springGentle) { steadyZoom = 1; panOffset = .zero }
                        }
                    }
            )
            // Drag-to-pan — always attached, only responds when zoomed
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
            .onTapGesture { }   // absorbs single taps so they don't fall through
            .animation(Design.springSnappy, value: currentZoom)
        }
    }

    private func zoomIn()  { withAnimation { steadyZoom = min(5, steadyZoom * 1.25) } }
    private func zoomOut() {
        withAnimation {
            steadyZoom = max(0.5, steadyZoom / 1.25)
            if steadyZoom <= 1.05 { steadyZoom = 1; panOffset = .zero }
        }
    }
    private func resetZoom() { withAnimation { steadyZoom = 1; panOffset = .zero } }

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

    // MARK: - Overlay

    private var topBar: some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain).padding()
            .accessibilityLabel("Close reader")
            .help("Close reader (W)")

            Spacer()

            Text(comic.title)
                .font(.headline).foregroundStyle(.white).lineLimit(1).padding(.horizontal)
                .accessibilityLabel("Reading: \(comic.title)")

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

                // Reading direction, double-page, scroll mode, color filter, and pin toolbar
                // are set once per series and rarely touched again, so they live in one menu
                // rather than as always-visible icons alongside bookmark/fit/autoplay/filmstrip.
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
                .accessibilityLabel(autoplay ? "Stop slideshow" : "Start slideshow")
                .help(autoplay ? "Stop Autoplay (A)" : "Start Autoplay (A)")

                Button { showShortcuts.toggle() } label: {
                    Image(systemName: "keyboard")
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keyboard shortcuts")
                .help("Keyboard Shortcuts (?)")

                Button { withAnimation(Design.easeFast) { showFilmstrip.toggle() } } label: {
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

    // MARK: - Filmstrip

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
                        .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
            .onChange(of: currentPage) { _, page in
                withAnimation { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .frame(height: 108)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    // MARK: - Bookmarks panel

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
                            Button("Go") {
                                currentPage = bm.page
                                showBookmarks = false
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .onDelete { idx in
                        idx.forEach { i in
                            ReadingSessionService.shared.toggleBookmark(comicId: comic.id, page: bookmarks[i].page)
                        }
                        loadBookmarks()
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }

    // MARK: - Shortcuts sheet

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

    // MARK: - Helpers

    private func nextPage() {
        let advance = (doublePage && !currentPageIsSpread && !scrollMode) ? 2 : 1
        let target  = min(currentPage + advance, comic.pageCount - 1)
        guard target != currentPage else { return }
        currentPage = target
        saveProgress()
    }

    private func prevPage() {
        let step    = (doublePage && !currentPageIsSpread && !scrollMode) ? 2 : 1
        currentPage = max(0, currentPage - step)
        saveProgress()
    }

    private func toggleAutoplay() {
        autoplay.toggle()
        if !autoplay { countdownProgress = 0 }
    }

    private func toggleBookmark() {
        isBookmarked = ReadingSessionService.shared.toggleBookmark(comicId: comic.id, page: currentPage)
        loadBookmarks()
    }

    private func loadBookmarks() {
        bookmarks    = ReadingSessionService.shared.bookmarks(for: comic.id)
        isBookmarked = bookmarks.contains { $0.page == currentPage }
    }

    private func saveProgress() {
        ReadingSessionService.shared.updateProgress(comic: comic, page: currentPage)
    }

    // Dragging the page scrubber fires a set() on every intermediate value — saving on each
    // one is a synchronous SQLite write per tick across potentially hundreds of pages in one
    // gesture. Debounced so only the value the drag actually settles on gets written.
    private func saveProgressDebounced() {
        saveProgressWorkItem?.cancel()
        let work = DispatchWorkItem { saveProgress() }
        saveProgressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func logSession() {
        ReadingSessionService.shared.logSession(comicId: comic.id, from: sessionStartPage, to: currentPage)
    }

    private func runAutoplay() async {
        guard autoplay, !scrollMode else { return }
        let steps = 60
        for i in 0..<steps {
            guard autoplay, !Task.isCancelled else { countdownProgress = 0; return }
            await MainActor.run { countdownProgress = Double(i) / Double(steps) }
            do {
                try await Task.sleep(for: .milliseconds(Int(autoplayInterval * 1000) / steps))
            } catch {
                // Cancelled — e.g. the user manually turned the page. `try?` here would
                // swallow the CancellationError and let the loop spin through its remaining
                // iterations instantly, still calling nextPage() at the end and silently
                // skipping an extra page on top of the manual turn.
                countdownProgress = 0
                return
            }
        }
        guard autoplay, !Task.isCancelled else { countdownProgress = 0; return }
        await MainActor.run {
            countdownProgress = 0
            if currentPage < comic.pageCount - 1 { nextPage() }
            else { autoplay = false }
        }
    }
}

// MARK: - Color filter view extension

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

// MARK: - Paged mode

struct PagedModeView: View {
    let comic:      Comic
    @Binding var currentPage: Int
    @Binding var isSpread:    Bool
    let doublePage: Bool
    let fitMode:    FitMode
    let rtl:        Bool
    let isZoomed:   Bool   // owned by ReaderView; used to block page-swipe while zoomed

    @State private var imageLeft:  PlatformImage?
    @State private var imageRight: PlatformImage?
    @State private var isLoading  = false

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
                } else if effectiveDoublePage, let left = imageLeft {
                    // imageLeft is always the earlier page (currentPage) and imageRight the
                    // later one (currentPage + 1). In RTL/manga reading order the eye should
                    // encounter the later page first, so the physical left/right placement
                    // needs to mirror — otherwise a spread always renders in LTR order even
                    // with RTL enabled, breaking artwork that's meant to be read right-to-left.
                    HStack(spacing: 1) {
                        if rtl {
                            if let right = imageRight { pageImage(right, size: geo.size) }
                            pageImage(left, size: geo.size)
                        } else {
                            pageImage(left, size: geo.size)
                            if let right = imageRight { pageImage(right, size: geo.size) }
                        }
                    }
                } else if let img = imageLeft {
                    pageImage(img, size: geo.size)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }
        // Page-swipe: only when not zoomed (zoom/pan is handled entirely by ReaderView)
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { val in
                guard !isZoomed else { return }
                let forward  = val.translation.width < -40
                let backward = val.translation.width >  40
                if rtl {
                    if forward  && currentPage > 0                   { currentPage -= pageAdvance }
                    if backward && currentPage < comic.pageCount - 1 { currentPage += pageAdvance }
                } else {
                    if forward  && currentPage < comic.pageCount - 1 { currentPage += pageAdvance }
                    if backward && currentPage > 0                   { currentPage -= pageAdvance }
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
            // PageCache dispatches decodes onto a concurrent queue, so completion order
            // across overlapping requests isn't guaranteed — a fast scrub through many
            // pages can start several loads before any complete. Without this check, a
            // slow, now-abandoned page's decode finishing after a newer one would silently
            // overwrite what the scrubber says is the current page.
            guard page == self.currentPage else { return }
            self.imageLeft  = img
            self.isLoading  = false
            self.isSpread   = self.isSpreadPage
            if self.effectiveDoublePage && page + 1 < self.comic.pageCount {
                PageCache.shared.load(comic: self.comic, page: page + 1) { img2 in
                    guard page == self.currentPage else { return }
                    self.imageRight = img2
                }
            }
        }
        PageCache.shared.prefetch(comic: comic, around: page, count: 4)
    }
}

// MARK: - Filmstrip thumbnail

// Reuses PageCache rather than a separate thumbnail cache — LazyHStack only instantiates
// visible cells, so at most a screenful of thumbnails (~10-12) actually decode, well within
// PageCache's 30-entry LRU budget alongside the reader's own current-page/prefetch entries.
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
            PageCache.shared.load(comic: comic, page: index) { image = $0 }
        }
    }
}

// MARK: - Scroll mode

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

    var body: some View {
        Group {
            if let img = image {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
            } else {
                Color.black.frame(height: 600)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .task { PageCache.shared.load(comic: comic, page: index) { image = $0 } }
    }
}
