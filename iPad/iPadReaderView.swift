#if os(iOS) || os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

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

    @State private var scrollMode: Bool
    @AppStorage("autoplaySpeed") private var autoplaySpeed: Double = 6.0
    @State private var autoplay = false
    @State private var countdownProgress: Double = 0
    @State private var showFilmstrip = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewWidth: CGFloat = 0
    @State private var nextIssue: Comic?
    @State private var dismissedNextIssuePrompt = false

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

    init(comic: Comic, onClose: @escaping () -> Void) {
        self.comic = comic
        self.onClose = onClose
        // Clamp both bounds: page_count can change after progress was saved (metadata refresh,
        // or a revival at the same path with a different file), and a stale out-of-range
        // progress would otherwise land the reader on a blank page with no way to reach it.
        _currentPage = State(initialValue: min(max(0, comic.progress), max(0, comic.pageCount - 1)))
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
            Color.black.ignoresSafeArea()

            if scrollMode {
                scrollReader
            } else {
                pageReader
            }

            overlayControls

            if isOnLastPage, !autoplay, let nextIssue, !dismissedNextIssuePrompt {
                VStack {
                    Spacer()
                    upNextCard(nextIssue)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
        .onAppear { scheduleHide(); loadNextIssue(); loadBookmarks() }
        .onDisappear {
            saveProgress()

            PageCache.shared.evict(comicId: comic.id)
        }

        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .task(id: "\(autoplay)-\(currentPage)") { await runAutoplay() }
        .onChange(of: currentPage) { _, _ in loadBookmarks() }
        .onChange(of: scrollMode) { _, _ in saveSeriesPrefs() }
        .onChange(of: rtl) { _, _ in saveSeriesPrefs() }
        .onChange(of: fitModeRaw) { _, _ in saveSeriesPrefs() }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
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
            withAnimation(.easeOut(duration: 0.15)) { scale = 1; offset = .zero }
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
                withAnimation(.easeOut(duration: 0.25)) { showBars = false }
            }
        }
    }

    private func saveProgress() {
        LibraryViewModel.shared.updateProgress(comic: comic, page: currentPage)
    }

    private var isOnLastPage: Bool { pageCount > 0 && currentPage >= pageCount - 1 }

    /// Looks up the next issue in this series (if any) and warms its cover + first couple pages
    /// in the background, so the "Up Next" card and autoplay's seamless continuation both have
    /// something ready to act on instead of a cold load.
    private func loadNextIssue() {
        let current = comic
        Task.detached(priority: .userInitiated) {
            guard let next = DatabaseManager.shared.nextComic(after: current) else { return }
            ThumbnailCache.shared.thumbnail(for: next) { _ in }
            PageCache.shared.prefetch(comic: next, around: 0, count: 2)
            await MainActor.run { nextIssue = next }
        }
    }

    private func advanceToNextIssue() {
        guard let nextIssue else { return }
        saveProgress()
        vm.openReader(nextIssue)
    }

    private func upNextCard(_ next: Comic) -> some View {
        HStack(spacing: 12) {
            MiniComicCard(comic: next)
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next").font(.caption).foregroundStyle(.white.opacity(0.6))
                Text(next.title).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Continue") { advanceToNextIssue() }
                .buttonStyle(GoldCapsuleStyle())

            Button {
                withAnimation(.easeOut(duration: 0.2)) { dismissedNextIssuePrompt = true }
            } label: {
                Image(systemName: "xmark").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Up next: \(next.title)")
        .accessibilityHint("Double-tap to continue reading")
        .accessibilityAction { advanceToNextIssue() }
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
