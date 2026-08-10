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
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isFocused: Bool

    @State private var session: ReaderSession

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
    // `matchedGeometryEffect` to actually connect across the two. Pure transient UI/animation
    // state, unrelated to reading -- stays local, same as the Mac reader.
    @State private var heroCoverImage: PlatformImage?
    @State private var showHeroCover = true
    @State private var isClosing = false

    @State private var showFilmstrip = false
    @State private var showBookmarks = false
    @AppStorage("autoplaySpeed") private var autoplayIntervalPref: Double = 6.0

    @GestureState private var pinchScale: CGFloat = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    init(comic: Comic, runId: Int64? = nil, onClose: @escaping () -> Void) {
        self.comic = comic
        self.runId = runId
        self.onClose = onClose
        _session = State(initialValue: ReaderSession(comic: comic, runId: runId))
    }

    private var pageCount: Int { session.pageCount }

    var body: some View {
        @Bindable var session = session
        ZStack {
            backdropColor.ignoresSafeArea()

            if pageCount == 0 {
                // Previously: `ForEach(0..<pageCount, ...)` over an empty range rendered nothing
                // at all -- a silent black screen with no explanation, unlike the Mac reader's
                // graceful "Couldn't load page 1" fallback. Same underlying cause (a genuinely
                // corrupt or empty archive), same visible treatment now on both platforms.
                unavailablePlaceholder
            } else if session.scrollMode {
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

            if let message = session.boundaryMessage {
                VStack {
                    Spacer()
                    boundaryToast(message).padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportSize = geo.size }
                    .onChange(of: geo.size) { _, size in viewportSize = size }
            }
        )
        .accessibilityLabel("Comic reader — \(comic.title), page \(session.currentPage + 1) of \(pageCount)")
        .accessibilityHint("Double-tap to zoom. Swipe to navigate pages.")
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { session.rtl ? session.advance() : session.retreat(); return .handled }
        .onKeyPress(.rightArrow) { session.rtl ? session.retreat() : session.advance(); return .handled }
        .onKeyPress(.upArrow)    { session.retreat(); return .handled }
        .onKeyPress(.downArrow)  { session.advance(); return .handled }
        .onKeyPress(.home) { session.jump(to: 0); return .handled }
        .onKeyPress(.end)  { session.jump(to: pageCount - 1); return .handled }
        .onKeyPress(.escape) { handleClose(); return .handled }
        .onKeyPress(KeyEquivalent("w")) { handleClose(); return .handled }
        .onKeyPress(KeyEquivalent("a")) { session.toggleAutoplay(); return .handled }
        .onKeyPress(KeyEquivalent("b")) { session.toggleBookmark(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { session.rtl.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("g")) { withAnimation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion)) { showFilmstrip.toggle() }; return .handled }
        // Parity with the Mac reader's zoom keys -- previously iPad had no keyboard zoom at all
        // despite external keyboards being common on this platform.
        .onKeyPress(KeyEquivalent("=")) { session.setZoom(session.zoomLevel * 1.25); return .handled }
        .onKeyPress(KeyEquivalent("+")) { session.setZoom(session.zoomLevel * 1.25); return .handled }
        .onKeyPress(KeyEquivalent("-")) { session.setZoom(session.zoomLevel / 1.25); return .handled }
        .onKeyPress(KeyEquivalent("0")) { session.setZoom(1.0); return .handled }
        .statusBarHidden(!session.shouldShowChrome)
        .persistentSystemOverlays(session.shouldShowChrome ? .visible : .hidden)
        .onAppear {
            isFocused = true
            session.autoplayInterval = autoplayIntervalPref
            session.onRequestIssueTransition = { vm.openReader($0, runId: runId) }
            session.interactionOccurred()
            heroCoverImage = ThumbnailCache.shared.thumbnailFromCache(comicId: comic.id)
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(Design.motion(Design.springGentle, reduce: reduceMotion)) { showHeroCover = false }
            }
            Task { await session.open() }
        }
        .onDisappear { session.teardown() }
        .onChange(of: scenePhase) { _, phase in session.handleScenePhaseChange(isActive: phase == .active) }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
        .sheet(isPresented: $session.showSeriesComplete) {
            SeriesCompleteView(publisher: comic.publisher, series: comic.series)
        }
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

    private var pageReader: some View {
        // `set` fires only for the TabView's own swipe interaction (external, session-driven page
        // changes update `get` without invoking `set`) -- a native swipe is genuine sequential
        // reading, same as `reportVisiblePage` treats continuous-scroll visibility, not a jump.
        TabView(selection: Binding(get: { session.currentPage }, set: { session.reportVisiblePage($0) })) {
            ForEach(0..<pageCount, id: \.self) { idx in
                ReaderPageView(session: session, pageIndex: idx)
                    .tag(idx)
                    .scaleEffect(liveZoom)
                    .offset(liveOffset)
                    .colorEffect(session.colorFilter)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Reverses swipe direction so a right-to-left manga-style series turns pages the way a
        // reader familiar with that format expects, same intent as the Mac reader's own RTL mode.
        .environment(\.layoutDirection, session.rtl ? .rightToLeft : .leftToRight)
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
        .gesture(pinchGesture)
        .gesture(dragGesture)
        .onChange(of: session.currentPage) { _, _ in session.interactionOccurred() }
    }

    private var scrollReader: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    ReaderPageView(session: session, pageIndex: idx)
                        .frame(maxWidth: .infinity)
                        .colorEffect(session.colorFilter)
                        .onAppear { session.reportVisiblePage(idx) }
                }
            }
        }
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
    }

    private var bookmarksSheet: some View {
        NavigationStack {
            List {
                if session.bookmarks.isEmpty {
                    Text("No bookmarks yet. Tap the bookmark icon while reading to save a page.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(session.bookmarks) { mark in
                        Button {
                            session.jump(to: mark.page)
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
                let width = viewportSize.width > 0 ? viewportSize.width : UIScreen.main.bounds.width
                if x < width * 0.25 {
                    session.retreat()
                } else if x > width * 0.75 {
                    session.advance()
                } else {
                    session.shouldShowChrome.toggle()
                    if session.shouldShowChrome { session.interactionOccurred() }
                }
            }
    }

    /// Live-gesture preview, same technique as the Mac reader: the committed
    /// `session.zoomLevel`/`panOffsetInPoints` composed with whatever the in-flight pinch/drag
    /// gesture is currently reporting, so the page tracks the user's fingers in real time without
    /// waiting for the gesture to end and commit (which would also mean re-decoding on every
    /// frame of the gesture, not just once at the end).
    private var liveZoom: CGFloat { session.zoomLevel * pinchScale }
    private var liveOffset: CGSize {
        let base = session.panOffsetInPoints
        return CGSize(width: base.width + dragOffset.width, height: base.height + dragOffset.height)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { val, state, _ in state = val.magnification }
            .onEnded { val in session.setZoom(session.zoomLevel * val.magnification) }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { val, state, _ in
                guard session.isZoomed else { return }
                state = val.translation
            }
            .onEnded { val in
                guard session.isZoomed else { return }
                session.pan(anchorDelta: val.translation)
            }
    }

    private var overlayControls: some View {
        VStack {
            if session.shouldShowChrome {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if session.shouldShowChrome && showFilmstrip {
                filmstrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if session.shouldShowChrome {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion), value: session.shouldShowChrome)
        .animation(Design.motion(.easeInOut(duration: 0.2), reduce: reduceMotion), value: showFilmstrip)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { idx in
                        Button { session.jump(to: idx) } label: {
                            iPadFilmstripThumb(session: session, index: idx, isCurrent: idx == session.currentPage)
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
                Button { if let previous = session.previousIssue { vm.openReader(previous, runId: runId) } } label: {
                    Image(systemName: "chevron.left.circle")
                        .font(.subheadline)
                        .foregroundStyle(session.previousIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(session.previousIssue == nil)
                .accessibilityLabel(session.previousIssue == nil ? "No previous comic" : "Previous comic: \(session.previousIssue?.title ?? "")")

                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Button { if let next = session.nextIssue { vm.openReader(next, runId: runId) } } label: {
                    Image(systemName: "chevron.right.circle")
                        .font(.subheadline)
                        .foregroundStyle(session.nextIssue == nil ? .white.opacity(0.25) : .white.opacity(0.85))
                        .frame(minWidth: 32, minHeight: 32)
                }
                .disabled(session.nextIssue == nil)
                .accessibilityLabel(session.nextIssue == nil ? "No next comic" : "Next comic: \(session.nextIssue?.title ?? "")")
            }
            Spacer()
            Text("\(session.currentPage + 1) / \(pageCount)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()
            Button { session.toggleBookmark() } label: {
                Image(systemName: session.isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(session.isBookmarked ? Design.brandGold : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(session.isBookmarked ? "Remove Bookmark" : "Add Bookmark")

            Menu {
                Button {
                    showBookmarks = true
                } label: {
                    Label("Bookmarks\(session.bookmarks.isEmpty ? "" : " (\(session.bookmarks.count))")", systemImage: "list.bullet")
                }

                Divider()

                Picker("Fit", selection: $session.fitMode) {
                    Label("Fit Page", systemImage: "rectangle.arrowtriangle.2.inward").tag(FitMode.fitPage)
                    Label("Fit Width", systemImage: "arrow.left.and.right").tag(FitMode.fitWidth)
                    Label("Fit Height", systemImage: "arrow.up.and.down").tag(FitMode.fitHeight)
                    Label("Original Size", systemImage: "square.dashed").tag(FitMode.original)
                }

                Picker("Color Filter", selection: $session.colorFilter) {
                    Label("None", systemImage: "circle.slash").tag(ColorFilter.none)
                    Label("Night", systemImage: "moon.fill").tag(ColorFilter.night)
                    Label("Sepia", systemImage: "sun.max.fill").tag(ColorFilter.sepia)
                    Label("Grayscale", systemImage: "circle.lefthalf.filled").tag(ColorFilter.grayscale)
                }

                Toggle(isOn: $session.rtl) {
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
            Button { session.toggleAutoplay() } label: {
                Image(systemName: session.autoplay ? "pause.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(session.autoplay ? Design.brandGold : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(session.scrollMode)
            .opacity(session.scrollMode ? 0.35 : 1)
            .accessibilityLabel(session.autoplay ? "Stop Slideshow" : "Start Slideshow")
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
            if session.autoplay {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Design.brandGold)
                        .frame(width: geo.size.width * session.countdownProgress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 20)
            }
            if pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(session.currentPage) },
                        set: { session.jump(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(pageCount - 1),
                    step: 1
                )
                .tint(.white)
                .padding(.horizontal, 20)
                .accessibilityLabel("Page Scrubber")
                .accessibilityValue("Page \(session.currentPage + 1) of \(pageCount)")
            }
        }
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func boundaryToast(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.75), in: Capsule())
    }
}

/// Each `TabView` page needs to load its own image independently -- unlike the Mac reader's
/// custom-drag-gesture paged mode (which only ever renders the single current page/spread and can
/// read straight from `session.currentImage`), `TabView` keeps swipe-adjacent pages rendered too,
/// so this mirrors `ScrollPageView`'s pattern instead: talk to `PageStore` directly via the
/// session's already-open document.
private struct ReaderPageView: View {
    let session: ReaderSession
    let pageIndex: Int
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var retryToken = UUID()

    @ViewBuilder
    private func fittedImage(_ img: PlatformImage, size: CGSize) -> some View {
        let imgSize = img.size
        switch session.fitMode {
        case .fitPage:
            Image(platformImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
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
            guard let document = session.document else { return }
            PageStore.shared.request(document: document, comicId: session.comic.id, page: pageIndex, maxPixelSize: nil) { img in
                if let img { image = img } else { loadFailed = true }
            }
        }
    }
}

private struct iPadFilmstripThumb: View {
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
        .frame(width: 54, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Design.brandGold : Color.white.opacity(0.15), lineWidth: isCurrent ? 2 : 1)
        )
        .task(id: index) {
            guard let document = session.document else { return }
            ThumbnailStore.shared.thumbnail(document: document, comicId: session.comic.id, page: index) { image = $0 }
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
