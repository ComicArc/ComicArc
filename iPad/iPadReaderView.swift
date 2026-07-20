#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - iPad immersive reader

struct iPadReaderView: View {
    let comic: Comic
    let onClose: () -> Void

    @EnvironmentObject var vm: LibraryViewModel
    @State private var currentPage: Int
    @State private var showBars = true
    @State private var hideTask: Task<Void, Never>?

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Seeded per-series in init() (falling back to this global default for a series that's
    // never been read before), then persisted per-series as it changes — matches the macOS
    // reader's per-series preference behavior.
    @State private var scrollMode: Bool
    @AppStorage("autoplaySpeed") private var autoplaySpeed: Double = 6.0
    @State private var autoplay = false
    @State private var countdownProgress: Double = 0
    @State private var showFilmstrip = false
    @Environment(\.scenePhase) private var scenePhase
    // The reader's own width, not the device screen's — UIScreen.main.bounds.width is wrong
    // in Split View/Slide Over, where the app's window is narrower than the full screen,
    // making the tap zones for prev/next page misaligned with what's actually on screen.
    @State private var viewWidth: CGFloat = 0

    init(comic: Comic, onClose: @escaping () -> Void) {
        self.comic = comic
        self.onClose = onClose
        _currentPage = State(initialValue: max(0, comic.progress))
        let prefs = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
        _scrollMode = State(initialValue: prefs?.scrollMode ?? UserDefaults.standard.bool(forKey: "scrollMode"))
    }

    private var pageCount: Int { comic.pageCount }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if scrollMode {
                scrollReader
            } else {
                pageReader
            }

            overlayControls
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewWidth = w }
            }
        )
        .statusBarHidden(!showBars)
        .persistentSystemOverlays(showBars ? .visible : .hidden)
        .onAppear { scheduleHide() }
        .onDisappear {
            saveProgress()
            // Otherwise up to 30 full-resolution decoded pages from this comic stay
            // resident until unrelated LRU pressure evicts them — worth freeing eagerly
            // on iOS, where a backgrounded app can be jetsam-killed for memory pressure.
            PageCache.shared.evict(comicId: comic.id)
        }
        // iOS can suspend or kill the app without ever calling onDisappear (a phone call,
        // the app switcher, a low-memory kill while backgrounded) — flush progress the
        // moment the scene stops being active rather than only when the view tears down.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .task(id: "\(autoplay)-\(currentPage)") { await runAutoplay() }
        .onChange(of: scrollMode) { _, newValue in
            // Preserve fit mode / RTL / double-page if the Mac reader already set them for
            // this series — the iPad reader doesn't expose those toggles, so it should only
            // ever change the one preference it actually controls.
            let existing = DatabaseManager.shared.seriesReaderPrefs(series: comic.series, publisher: comic.publisher)
            DatabaseManager.shared.setSeriesReaderPrefs(
                series: comic.series, publisher: comic.publisher,
                fitMode: existing?.fitMode ?? FitMode.fitPage.rawValue,
                rtl: existing?.rtl ?? false,
                doubleSpread: existing?.doubleSpread ?? false,
                scrollMode: newValue
            )
        }
    }

    // MARK: - Page reader (swipe between pages)

    private var pageReader: some View {
        TabView(selection: $currentPage) {
            ForEach(0..<pageCount, id: \.self) { idx in
                ReaderPageView(comic: comic, pageIndex: idx)
                    .tag(idx)
                    .scaleEffect(scale)
                    .offset(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
        .gesture(pinchGesture)
        .gesture(dragGesture)
        .onChange(of: currentPage) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { scale = 1; offset = .zero }
            scheduleHide()
        }
    }

    // MARK: - Scroll reader (continuous vertical scroll)

    private var scrollReader: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    ReaderPageView(comic: comic, pageIndex: idx)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .simultaneousGesture(tapGesture)
    }

    // MARK: - Gestures

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let x = value.location.x
                let width = viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width
                if x < width * 0.25 {
                    if currentPage > 0 { currentPage -= 1 }
                } else if x > width * 0.75 {
                    if currentPage < pageCount - 1 { currentPage += 1 }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
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
                    withAnimation(.spring()) { scale = 1; offset = .zero }
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

    // MARK: - Overlay UI (top bar + bottom scrubber)

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
        .animation(.easeInOut(duration: 0.2), value: showBars)
        .animation(.easeInOut(duration: 0.2), value: showFilmstrip)
    }

    // Reuses PageCache rather than a separate thumbnail cache — LazyHStack only instantiates
    // visible cells, so at most a screenful of thumbnails actually decode, well within
    // PageCache's 30-entry LRU budget alongside the reader's own current-page/prefetch entries.
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
        .frame(height: 100)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Close Reader")
            Spacer()
            Text(comic.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text("\(currentPage + 1) / \(pageCount)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()
            Button(action: { withAnimation { showFilmstrip.toggle() } }) {
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
            Slider(
                value: Binding(
                    get: { Double(currentPage) },
                    set: { currentPage = Int($0) }
                ),
                in: 0...max(1, Double(pageCount - 1)),
                step: 1
            )
            .tint(.white)
            .padding(.horizontal, 20)
            .accessibilityLabel("Page Scrubber")
            .accessibilityValue("Page \(currentPage + 1) of \(pageCount)")
        }
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - Helpers

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            // Matches the macOS reader's 8-second auto-hide delay so both platforms feel the same.
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { showBars = false }
            }
        }
    }

    private func saveProgress() {
        ReadingSessionService.shared.updateProgress(comic: comic, page: currentPage)
    }

    private func runAutoplay() async {
        guard autoplay, !scrollMode else { return }
        let steps = 60
        for i in 0..<steps {
            guard autoplay, !Task.isCancelled else { countdownProgress = 0; return }
            await MainActor.run { countdownProgress = Double(i) / Double(steps) }
            do {
                try await Task.sleep(for: .milliseconds(Int(autoplaySpeed * 1000) / steps))
            } catch {
                // Cancelled — e.g. the user manually swiped to another page. `try?` here
                // would swallow the CancellationError and let the loop spin through its
                // remaining iterations instantly, still advancing the page at the end and
                // silently skipping an extra page on top of the manual swipe.
                countdownProgress = 0
                return
            }
        }
        guard autoplay, !Task.isCancelled else { countdownProgress = 0; return }
        await MainActor.run {
            countdownProgress = 0
            if currentPage < pageCount - 1 { currentPage += 1 }
            else { autoplay = false }
        }
    }
}

// MARK: - Single page image loader

private struct ReaderPageView: View {
    let comic: Comic
    let pageIndex: Int
    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = image {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color.black
                        .overlay(ProgressView().tint(.white))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task {
            PageCache.shared.load(comic: comic, page: pageIndex) { img in image = img }
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
            PageCache.shared.load(comic: comic, page: index) { image = $0 }
        }
    }
}

// MARK: - UIDocumentPicker wrapper

struct iPadDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // CBR is intentionally excluded: it's extracted via the `unar` command-line
        // tool on macOS (Scanner/LibraryScanner.swift), which isn't available in the
        // iOS sandbox, so a CBR imported here would show 0 pages and never open.
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
