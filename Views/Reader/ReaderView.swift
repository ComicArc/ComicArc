import SwiftUI

struct ReaderView: View {
    let comic: Comic
    let onClose: () -> Void
    /// Swaps the reader straight into the next issue in the series -- ContentView's ReaderView
    /// is `.id(comic.id)`-keyed, so calling this with a different comic tears down and rebuilds
    /// this whole view (and its `ReaderSession`) fresh for it, the same as opening any other
    /// comic normally.
    let onOpenComic: (Comic) -> Void
    /// Set when this comic was opened from inside a Run's reading path. When present, next/
    /// previous navigation is scoped to that run's ordered items instead of series order.
    let runId: Int64?

    @State private var session: ReaderSession

    @Environment(\.windowService) private var windowService
    @Environment(\.readerNamespace) private var readerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.scenePhase) private var scenePhase
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
    /// broken rather than as ordinary loading time. Pure transient UI/animation state, unrelated
    /// to reading -- `ReaderSession` deliberately doesn't own this.
    @State private var heroCoverImage: PlatformImage?
    @State private var showHeroCover = true
    @State private var isClosing = false

    /// Rating isn't reading state -- it's a library concern that happens to have a control in the
    /// reader's bottom bar, so it stays local rather than living on `ReaderSession`.
    @State private var comicRating: Int

    @State private var showShortcuts = false
    @State private var showFilmstrip = false
    @State private var showBookmarks = false
    @State private var showPageJump = false
    @State private var pageJumpText = ""

    @AppStorage("readerToolbarLocked") private var toolbarLockedPref = false
    @AppStorage("autoplaySpeed") private var autoplayIntervalPref: Double = 6.0

    @GestureState private var pinchScale: CGFloat = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @State private var cursorPosition: CGPoint = .zero

    init(comic: Comic, initialPage: Int? = nil, runId: Int64? = nil, onClose: @escaping () -> Void,
         onOpenComic: @escaping (Comic) -> Void) {
        self.comic       = comic
        self.onClose     = onClose
        self.onOpenComic = onOpenComic
        self.runId       = runId
        _session      = State(initialValue: ReaderSession(comic: comic, runId: runId, initialPage: initialPage))
        _comicRating  = State(initialValue: comic.rating)
    }

    var body: some View {
        @Bindable var session = session
        GeometryReader { geo in
            ZStack(alignment: .top) {
                backdropColor.ignoresSafeArea()

                pageContent
                    .colorEffect(session.colorFilter)

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
                    if session.shouldShowChrome {
                        topBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if showFilmstrip {
                        filmstrip
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if session.shouldShowChrome {
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
                if case .active(let loc) = phase {
                    cursorPosition = loc
                    session.interactionOccurred()
                }
            }
            .onTapGesture(count: 2) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) {
                    if session.isZoomed {
                        session.setZoom(1.0)
                    } else {
                        session.setZoom(2.0, anchorInViewport: cursorPosition)
                    }
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
        .accessibilityLabel("Comic reader — \(comic.title), page \(session.currentPage + 1) of \(comic.pageCount)")
        .accessibilityHint("Double-tap to zoom. Swipe to navigate pages.")
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { session.rtl ? session.advance() : session.retreat(); return .handled }
        .onKeyPress(.rightArrow) { session.rtl ? session.retreat() : session.advance(); return .handled }
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
        .onKeyPress(.end)  { session.jump(to: comic.pageCount - 1); return .handled }
        .onKeyPress(KeyEquivalent("=")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("+")) { zoomIn(); return .handled }
        .onKeyPress(KeyEquivalent("-")) { zoomOut(); return .handled }
        .onKeyPress(KeyEquivalent("0")) { session.setZoom(1.0); return .handled }
        .onChange(of: session.currentPage) { _, _ in comicRating = comic.rating }
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
            session.interactionOccurred()
            windowService.enterImmersiveMode()
            // Cache-only: this exact cover was almost certainly just on screen (a grid card or
            // IssueDetailPage) a moment ago, so this is normally an instant hit, not a fresh
            // decode -- matches the hero layer's own job of bridging that already-loaded image
            // into the reader, not doing new work.
            heroCoverImage = ThumbnailCache.shared.thumbnailFromCache(comicId: comic.id)
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
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
    private var pageContent: some View {
        if session.scrollMode {
            ScrollModeView(session: session)
        } else {
            PagedModeView(session: session)
                .scaleEffect(liveZoom)
                .offset(session.isZoomed ? liveOffset : .zero)
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: {
                    session.updateViewport(size: $0, screenScale: PlatformImage.pdfRenderScale)
                })
                .gesture(
                    MagnifyGesture()
                        .updating($pinchScale) { val, state, _ in state = val.magnification }
                        .onEnded { val in
                            session.setZoom(session.zoomLevel * val.magnification)
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .updating($dragOffset) { val, state, _ in
                            guard session.isZoomed else { return }
                            state = val.translation
                        }
                        .onEnded { val in
                            guard session.isZoomed else { return }
                            session.pan(anchorDelta: val.translation)
                        }
                )
                .onTapGesture { }
                // No `.animation(value:)` on the live zoom/offset here on purpose -- both update
                // every frame during an active pinch/drag, so animating them fought the user's
                // own finger movement with a lagging spring. Discrete, committed changes
                // (zoomIn/zoomOut/setZoom below) already wrap themselves in withAnimation.
        }
    }

    /// Live-gesture preview: the committed `session.zoomLevel`/`panOffsetInPoints` composed with
    /// whatever the in-flight pinch/drag gesture is currently reporting, so panning/pinching
    /// tracks the user's fingers in real time without waiting for the gesture to end and commit.
    /// `pinchScale` resets to 1.0 the instant the gesture ends, in the same update cycle
    /// `.onEnded` commits the new `session.zoomLevel` -- no visible jump at the handoff.
    private var liveZoom: CGFloat { session.zoomLevel * pinchScale }
    private var liveOffset: CGSize {
        let base = session.panOffsetInPoints
        return CGSize(width: base.width + dragOffset.width, height: base.height + dragOffset.height)
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
            Button { session.rtl ? session.advance() : session.retreat() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(session.rtl ? session.currentPage >= comic.pageCount - 1 : session.currentPage == 0)
            .accessibilityLabel(session.rtl ? "Next page" : "Previous page")
            .help(session.rtl ? "Next page (→)" : "Previous page (←)")

            VStack(spacing: 6) {
                if comic.pageCount > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(session.currentPage) },
                            set: { session.jump(to: Int($0.rounded())) }
                        ),
                        in: 0...Double(max(1, comic.pageCount - 1)),
                        step: 1
                    )
                    .frame(maxWidth: .infinity)
                    .tint(Design.brandBlue)
                    .accessibilityLabel("Page scrubber")
                    .accessibilityValue("Page \(session.currentPage + 1) of \(comic.pageCount)")
                    .help("Drag to jump to any page")
                }

                Button {
                    pageJumpText = "\(session.currentPage + 1)"
                    showPageJump = true
                } label: {
                    Text("Page \(session.currentPage + 1) of \(comic.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(session.currentPage + 1) of \(comic.pageCount) — tap to jump")
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
                        Text("of \(comic.pageCount)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                StarRating(rating: comicRating, size: 13, unfilledColor: .white.opacity(0.55)) { star in
                    let newRating = star == comicRating ? 0 : star
                    comicRating = newRating
                    LibraryViewModel.shared.setRating(comic, rating: newRating)
                }
            }
            .padding(.horizontal, 20)

            Button { session.rtl ? session.retreat() : session.advance() } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(session.rtl ? session.currentPage == 0 : session.currentPage >= comic.pageCount - 1)
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
                    ForEach(0..<comic.pageCount, id: \.self) { idx in
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

/// A thin renderer over `session.currentImage`/`secondaryImage` -- no independent loading state
/// of its own, unlike the old `PagedModeView`, since `ReaderSession` already owns page loading
/// (including the double-page/spread pairing) as the one shared implementation every platform uses.
struct PagedModeView: View {
    let session: ReaderSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if session.isLoading {
                    ProgressView().tint(.white)
                        .transition(.opacity)
                } else if session.effectiveDoublePage, let left = session.currentImage {
                    HStack(spacing: 1) {
                        if session.rtl {
                            if let right = session.secondaryImage { pageImage(right, size: geo.size) }
                            pageImage(left, size: geo.size)
                        } else {
                            pageImage(left, size: geo.size)
                            if let right = session.secondaryImage { pageImage(right, size: geo.size) }
                        }
                    }
                    .id(session.currentPage)
                    .transition(.opacity)
                } else if let img = session.currentImage {
                    pageImage(img, size: geo.size)
                        .id(session.currentPage)
                        .transition(.opacity)
                } else if session.loadFailed {
                    // A real dead end before this: no explanation, no way forward except backing
                    // out of the reader entirely -- one bad page (a flaky external drive, a
                    // genuinely corrupt page inside an otherwise-fine archive) shouldn't strand
                    // the whole session.
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("Couldn't load page \(session.currentPage + 1)")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Retry") { session.retryCurrentPage() }
                            .buttonStyle(.bordered)
                    }
                    .transition(.opacity)
                }
            }
            // Keyed on `currentPage`, not the image itself -- `PlatformImage` (NSImage/UIImage)
            // isn't Equatable, and the page index is a perfectly good proxy for "the displayed
            // page just changed" anyway.
            .animation(Design.motion(Design.easeStandard, reduce: reduceMotion), value: session.currentPage)
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { val in
                guard !session.isZoomed else { return }
                let forward  = val.translation.width < -40
                let backward = val.translation.width >  40
                let goForward = session.rtl ? backward : forward
                let goBackward = session.rtl ? forward : backward
                if goForward { session.advance() }
                if goBackward { session.retreat() }
            }
        )
    }

    @ViewBuilder
    private func pageImage(_ img: PlatformImage, size: CGSize) -> some View {
        let imgSize = img.size
        switch session.fitMode {
        case .fitPage:
            Image(platformImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fitWidth:
            let h = imgSize.height > 0 ? (size.width * imgSize.height / imgSize.width) : size.height
            Image(platformImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: h)
        case .fitHeight:
            let w = imgSize.width > 0 ? (size.height * imgSize.width / imgSize.height) : size.width
            Image(platformImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: w, height: size.height)
        case .original:
            ScrollView([.horizontal, .vertical]) {
                Image(platformImage: img).interpolation(.high).frame(width: imgSize.width, height: imgSize.height)
            }
        }
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

struct ScrollModeView: View {
    let session: ReaderSession

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<session.pageCount, id: \.self) { idx in
                    ScrollPageView(session: session, index: idx)
                        .frame(maxWidth: .infinity)
                        .onAppear { session.reportVisiblePage(idx) }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

struct ScrollPageView: View {
    let session: ReaderSession
    let index: Int
    @State private var image: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let img = image {
                Image(platformImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
            } else if loadFailed {
                Color.black.frame(height: 600)
                    .overlay(Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary))
            } else {
                Color.black.frame(height: 600)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .task {
            guard let document = session.document else { return }
            PageStore.shared.request(document: document, comicId: session.comic.id, page: index, maxPixelSize: nil) { img in
                if let img { image = img } else { loadFailed = true }
            }
        }
    }
}
