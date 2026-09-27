import SwiftUI

struct ReaderView: View {
    let comic: Comic
    let onClose: () -> Void
    /// Swaps the reader straight into the next issue in the series -- ContentView's ReaderView
    /// is `.id(comic.id)`-keyed, so calling this with a different comic tears down and rebuilds
    /// this whole view (and its `ReaderSession`) fresh for it, the same as opening any other
    /// comic normally.
    let onOpenComic: (Comic) -> Void

    @State private var session: ReaderSession

    @Environment(\.windowService) private var windowService
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isFocused: Bool

    /// A brief hero layer that grows from wherever this comic's cover was on screen (a grid card
    /// or IssueDetailPage) into the reader, then fades to reveal the real paginated content
    /// underneath -- and the reverse on close. Not tied to whether the first page has actually
    /// finished decoding: that page is loading in parallel regardless, and gating this on it
    /// would mean a slow page turns "cover morph" into "cover hangs there," which reads as
    /// broken rather than as ordinary loading time. Pure transient UI/animation state, unrelated
    /// to reading -- `ReaderSession` deliberately doesn't own this.
    @State private var heroCoverImage: PlatformImage?
    @State private var showHeroCover = true
    @State private var isClosing = false

    @State private var showShortcuts = false
    @State private var showFilmstrip = false
    @State private var showBookmarks = false
    @State private var showPageJump = false
    @State private var pageJumpText = ""

    @AppStorage("readerToolbarLocked") private var toolbarLockedPref = false
    @AppStorage("autoplaySpeed") private var autoplayIntervalPref: Double = 6.0

    /// Reader chrome is hover-driven only: the top bar shows while the pointer is near the top
    /// edge, the bottom bar while it's near the bottom edge. Page turns never reveal either.
    @State private var hoveringTop = false
    @State private var hoveringBottom = false
    private static let topHoverZone: CGFloat = 72
    private static let bottomHoverZone: CGFloat = 130

    private var showTopBar: Bool { session.toolbarLocked || hoveringTop }
    private var showBottomBar: Bool { session.toolbarLocked || hoveringBottom || showPageJump }

    init(comic: Comic, initialPage: Int? = nil, runId: Int64? = nil, onClose: @escaping () -> Void,
         onOpenComic: @escaping (Comic) -> Void) {
        self.comic       = comic
        self.onClose     = onClose
        self.onOpenComic = onOpenComic
        _session      = State(initialValue: ReaderSession(comic: comic, runId: runId, initialPage: initialPage))
    }

    var body: some View {
        @Bindable var session = session
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                pageContent(viewportSize: geo.size)

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

                if session.autoplay {
                    autoplayBar
                }

                if session.showFinishToast {
                    VStack {
                        Spacer()
                        finishToast.padding(.bottom, 100)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                if let message = session.boundaryMessage {
                    VStack {
                        Spacer()
                        boundaryToast(message).padding(.bottom, 100)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                var top = false, bottom = false
                if case .active(let location) = phase {
                    top = location.y < Self.topHoverZone
                    bottom = location.y > geo.size.height - Self.bottomHoverZone
                }
                guard top != hoveringTop || bottom != hoveringBottom else { return }
                withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) {
                    hoveringTop = top
                    hoveringBottom = bottom
                }
            }
            .onChange(of: geo.size) { _, size in
                // `PlatformImage.pdfRenderScale`, not raw `NSScreen`/`UIScreen` -- this file is
                // compiled into the iPad/Vision targets too (even though those platforms use their
                // own reader views), so it needs a cross-platform scale source. Already the right
                // shape: real display scale, clamped to a sane [2, 3] decode-target range.
                session.updateViewport(size: size, screenScale: PlatformImage.pdfRenderScale)
                session.resetZoom()
            }
        }
        .accessibilityLabel("Comic reader — \(comic.title), page \(session.currentPage + 1) of \(session.pageCount)")
        .accessibilityHint("Double-click to zoom. Use the arrow keys to turn pages.")
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { if session.rtl { session.advance() } else { session.retreat() }; return .handled }
        .onKeyPress(.rightArrow) { if session.rtl { session.retreat() } else { session.advance() }; return .handled }
        .onKeyPress(.upArrow)    { session.retreat(); return .handled }
        .onKeyPress(.downArrow)  { session.advance(); return .handled }
        .onKeyPress(.escape) {
            if session.autoplay { session.autoplay = false; return .handled }
            handleClose(); return .handled
        }
        .onKeyPress(KeyEquivalent("a")) { session.toggleAutoplay(); return .handled }
        .onKeyPress(KeyEquivalent("d")) { session.doublePage.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("b")) { session.toggleBookmark(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { session.rtl.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("?")) { showShortcuts.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("g")) { withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { showFilmstrip.toggle() }; return .handled }
        .onKeyPress(.home) { session.jump(to: 0); return .handled }
        .onKeyPress(.end)  { session.jump(to: session.pageCount - 1); return .handled }
        .onKeyPress(KeyEquivalent("=")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("+")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("-")) { zoomOut(); return .handled }
        .onKeyPress(KeyEquivalent("0")) { session.setZoom(1.0); return .handled }
        .onChange(of: scenePhase) { _, phase in session.handleScenePhaseChange(isActive: phase == .active) }
        .onKeyPress(KeyEquivalent("w"), action: { handleClose(); return .handled })
        .onKeyPress(KeyEquivalent("f")) { windowService.toggleFullScreen(); return .handled }
        .background(
            Button("") { handleClose() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        )
        .onAppear {
            isFocused = true
            session.toolbarLocked = toolbarLockedPref
            session.autoplayInterval = autoplayIntervalPref
            session.onRequestIssueTransition = { onOpenComic($0) }
            windowService.enterImmersiveMode()
            // Cache-only: this exact cover was almost certainly just on screen (a grid card or
            // IssueDetailPage) a moment ago, so this is normally an instant hit, not a fresh
            // decode -- matches the hero layer's own job of bridging that already-loaded image
            // into the reader, not doing new work.
            heroCoverImage = ThumbnailCache.shared.thumbnailFromCache(comicId: comic.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = false }
            }
            Task { await session.open() }
        }
        .onDisappear {
            session.teardown()
            windowService.showCursor()
            windowService.exitImmersiveMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerPrint)) { _ in
            if let image = session.currentImage { windowService.printImage(image) }
        }
        .sheet(isPresented: $showShortcuts) { shortcutsSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksPanel }
        .sheet(isPresented: $session.showSeriesComplete) {
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

    @ViewBuilder
    private func pageContent(viewportSize: CGSize) -> some View {
        if session.scrollMode {
            ScrollModeView(session: session)
                .colorEffect(session.colorFilter)
        } else {
            #if os(macOS)
            ZoomablePageView(
                images: pagedImages, page: session.currentPage, fitMode: session.fitMode,
                zoomLevel: session.zoomLevel, colorFilter: session.colorFilter, viewportSize: viewportSize,
                onZoomCommitted: { session.setZoom($0) },
                onSwipe: { towardNext in
                    if towardNext != session.rtl { session.advance() } else { session.retreat() }
                }
            )
            .overlay { pageStatusOverlay }
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: {
                session.updateViewport(size: $0, screenScale: PlatformImage.pdfRenderScale)
            })
            #else
            EmptyView()  // This reader is macOS-only; iPad and visionOS use iPadReaderView.
            #endif
        }
    }

    /// The current page, or both pages of a spread in on-screen (left-to-right) order.
    private var pagedImages: [PlatformImage] {
        guard let first = session.currentImage else { return [] }
        guard session.effectiveDoublePage, let second = session.secondaryImage else { return [first] }
        return session.rtl ? [second, first] : [first, second]
    }

    @ViewBuilder
    private var pageStatusOverlay: some View {
        if session.isLoading && session.currentImage == nil {
            ProgressView().tint(.white)
        } else if session.loadFailed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("Couldn't load page \(session.currentPage + 1)")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Retry") { session.retryCurrentPage() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func zoomIn() { session.setZoom(session.zoomLevel * 1.25) }
    private func zoomOut() { session.setZoom(session.zoomLevel / 1.25) }

    private var autoplayBar: some View {
        VStack {
            Spacer()
            GeometryReader { geo in
                Rectangle()
                    .fill(Design.brandBlue)
                    .frame(width: geo.size.width * session.countdownProgress, height: 3)
                    .animation(.linear(duration: 0.1), value: session.countdownProgress)
            }
            .frame(height: 3)
        }
        .ignoresSafeArea()
    }

    private var finishToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text("Finished!")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.75), in: Capsule())
    }

    private func boundaryToast(_ text: String) -> some View {
        Text(text)
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
                Button { if let previous = session.previousIssue { onOpenComic(previous) } } label: {
                    Image(systemName: "chevron.left.circle")
                        .font(.title3)
                        .foregroundStyle(session.previousIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(session.previousIssue == nil)
                .accessibilityLabel(session.previousIssue == nil ? "No previous comic" : "Previous comic: \(session.previousIssue?.title ?? "")")
                .help(session.previousIssue == nil ? "No previous comic" : "Previous: \(session.previousIssue?.title ?? "")")

                Text(comic.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(1).padding(.horizontal)
                    .accessibilityLabel("Reading: \(comic.title)")

                Button { if let next = session.nextIssue { onOpenComic(next) } } label: {
                    Image(systemName: "chevron.right.circle")
                        .font(.title3)
                        .foregroundStyle(session.nextIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(session.nextIssue == nil)
                .accessibilityLabel(session.nextIssue == nil ? "No next comic" : "Next comic: \(session.nextIssue?.title ?? "")")
                .help(session.nextIssue == nil ? "No next comic" : "Next: \(session.nextIssue?.title ?? "")")
            }

            Spacer()

            HStack(spacing: 10) {
                Button { session.toggleBookmark() } label: {
                    Image(systemName: session.isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.title2)
                        .foregroundStyle(session.isBookmarked ? Design.brandGold : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isBookmarked ? "Remove bookmark from page \(session.currentPage + 1)" : "Bookmark page \(session.currentPage + 1)")
                .help("Bookmark this page (B)")

                Button { showBookmarks.toggle() } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2).foregroundStyle(session.bookmarks.isEmpty ? .white.opacity(0.4) : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All bookmarks\(session.bookmarks.isEmpty ? "" : ", \(session.bookmarks.count) total")")
                .help("All bookmarks")
                .overlay(alignment: .topTrailing) {
                    if !session.bookmarks.isEmpty {
                        Text("\(session.bookmarks.count)")
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
                        Button { session.fitMode = mode } label: {
                            Label(mode.label, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image(systemName: session.fitMode.icon)
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Fit mode: \(session.fitMode.label)")
                .help("Fit mode: \(session.fitMode.label)")

                Menu {
                    Toggle(isOn: $session.rtl) {
                        Label(session.rtl ? "Right-to-Left" : "Left-to-Right", systemImage: "text.justify.right")
                    }
                    if !session.scrollMode {
                        Toggle(isOn: $session.doublePage) {
                            Label("Double-Page Spread", systemImage: "rectangle.split.2x1")
                        }
                    }
                    Toggle(isOn: $session.scrollMode) {
                        Label("Scroll Mode", systemImage: "scroll")
                    }
                    Divider()
                    Menu {
                        ForEach(ColorFilter.allCases, id: \.self) { f in
                            Button { session.colorFilter = f } label: {
                                Label(f.label, systemImage: f.icon)
                            }
                        }
                    } label: {
                        Label("Color Filter: \(session.colorFilter.label)", systemImage: session.colorFilter.icon)
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { session.toolbarLocked }, set: { session.toolbarLocked = $0; toolbarLockedPref = $0 })) {
                        Label("Pin Toolbar", systemImage: "pin")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Reader settings")
                .help("Reader settings")

                Button { session.toggleAutoplay() } label: {
                    Image(systemName: session.autoplay ? "pause.circle.fill" : "play.circle")
                        .font(.title2).foregroundStyle(session.autoplay ? Design.brandGold : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(session.scrollMode)
                .opacity(session.scrollMode ? 0.35 : 1)
                .accessibilityLabel(session.autoplay ? "Stop slideshow" : "Start slideshow")
                .help(session.autoplay ? "Stop Autoplay (A)" : "Start Autoplay (A)")

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

    private var bottomBar: some View {
        HStack {
            Button { if session.rtl { session.advance() } else { session.retreat() } } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(session.rtl ? session.currentPage >= session.pageCount - 1 : session.currentPage == 0)
            .accessibilityLabel(session.rtl ? "Next page" : "Previous page")
            .help(session.rtl ? "Next page (→)" : "Previous page (←)")

            VStack(spacing: 6) {
                if session.pageCount > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(session.currentPage) },
                            set: { session.jump(to: Int($0.rounded())) }
                        ),
                        in: 0...Double(max(1, session.pageCount - 1)),
                        step: 1
                    )
                    .frame(maxWidth: .infinity)
                    .tint(Design.brandBlue)
                    .accessibilityLabel("Page scrubber")
                    .accessibilityValue("Page \(session.currentPage + 1) of \(session.pageCount)")
                    .help("Drag to jump to any page")
                }

                Button {
                    pageJumpText = "\(session.currentPage + 1)"
                    showPageJump = true
                } label: {
                    Text("Page \(session.currentPage + 1) of \(session.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(session.currentPage + 1) of \(session.pageCount) — tap to jump")
                .help("Click to jump to page")
                .popover(isPresented: $showPageJump) {
                    HStack(spacing: 8) {
                        Text("Go to page:")
                            .foregroundStyle(.primary)
                        TextField("", text: $pageJumpText)
                            .frame(width: 48)
                            .onSubmit {
                                if let n = Int(pageJumpText) { session.jump(to: n - 1) }
                                showPageJump = false
                            }
                        Text("of \(session.pageCount)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

            }
            .padding(.horizontal, 20)

            Button { if session.rtl { session.retreat() } else { session.advance() } } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(session.rtl ? session.currentPage == 0 : session.currentPage >= session.pageCount - 1)
            .accessibilityLabel(session.rtl ? "Previous page" : "Next page")
            .help(session.rtl ? "Previous page (←)" : "Next page (→)")
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<session.pageCount, id: \.self) { idx in
                        Button { session.jump(to: idx) } label: {
                            FilmstripThumb(session: session, index: idx, isCurrent: idx == session.currentPage)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(idx + 1)")
                        .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(session.currentPage, anchor: .center) }
            .onChange(of: session.currentPage) { _, page in
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

            if session.bookmarks.isEmpty {
                EmptyStateView(icon: "bookmark", title: "No bookmarks yet",
                                message: "Press B while reading to bookmark a page.")
            } else {
                List {
                    ForEach(session.bookmarks) { bm in
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
                                session.refreshBookmarks()
                            } label: {
                                Image(systemName: bm.isFavorite ? "star.fill" : "star")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(bm.isFavorite ? Design.brandGold : .secondary)
                            .help(bm.isFavorite ? "Remove from Highlights" : "Add to Highlights")
                            .accessibilityLabel(bm.isFavorite ? "Remove from highlights" : "Add to highlights")
                            Button("Go") {
                                session.jump(to: bm.page)
                                showBookmarks = false
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .onDelete { idx in
                        idx.forEach { i in
                            DatabaseManager.shared.toggleBookmark(comicId: comic.id, page: session.bookmarks[i].page)
                        }
                        session.refreshBookmarks()
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
                ("Double-click", "Zoom in / back to fit"),
                ("Scroll",       "Move around a zoomed page"),
                ("Swipe",        "Two-finger swipe to turn pages"),
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
}

private struct FilmstripThumb: View {
    let session: ReaderSession
    let index: Int
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
            guard let document = session.document else { return }
            ThumbnailStore.shared.thumbnail(document: document, comicId: session.comic.id, page: index) { image = $0 }
        }
    }
}
