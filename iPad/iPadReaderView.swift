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

    // Zoom state
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @AppStorage("scrollMode") private var scrollMode = false

    init(comic: Comic, onClose: @escaping () -> Void) {
        self.comic = comic
        self.onClose = onClose
        _currentPage = State(initialValue: max(0, comic.progress))
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
        .statusBarHidden(!showBars)
        .persistentSystemOverlays(showBars ? .visible : .hidden)
        .onAppear { scheduleHide() }
        .onDisappear { saveProgress() }
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
                let width = UIScreen.main.bounds.width
                if x < width * 0.25 {
                    // Left tap zone: previous page
                    if currentPage > 0 { currentPage -= 1 }
                } else if x > width * 0.75 {
                    // Right tap zone: next page
                    if currentPage < pageCount - 1 { currentPage += 1 }
                } else {
                    // Center: toggle bars
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
            if showBars {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showBars)
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
                .padding(.trailing, 8)
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
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { showBars = false }
            }
        }
    }

    private func saveProgress() {
        ReadingSessionService.shared.updateProgress(comic: comic, page: currentPage)
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

// MARK: - UIDocumentPicker wrapper

struct iPadDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .zip,
            UTType(filenameExtension: "cbr") ?? .data,
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
