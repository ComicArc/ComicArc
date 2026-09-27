import SwiftUI

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
    @State private var viewportWidth: CGFloat = 0

    /// Scroll mode always fits to width (height flows with aspect ratio), unlike Mac paged mode
    /// (fitPage) or iPad's TabView (fitWidth/fitHeight/fitPage), where the long edge in either
    /// direction can be the binding constraint -- width is the one fixed, known dimension here,
    /// so it's the right basis for a target-size-aware decode. Previously always requested
    /// `maxPixelSize: nil` (full/native resolution) for every page, unconditionally -- the one
    /// reading surface most exposed to that cost, since `LazyVStack` can have several of these
    /// alive near the viewport at once during a fast scroll.
    private var targetMaxPixelSize: Int? {
        guard viewportWidth > 0 else { return nil }
        return Int(viewportWidth * PlatformImage.pdfRenderScale)
    }

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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { viewportWidth = $0 })
        .task {
            guard let document = session.document else { return }
            PageStore.shared.request(document: document, comicId: session.comic.id, page: index, maxPixelSize: targetMaxPixelSize) { img in
                if let img { image = img } else { loadFailed = true }
            }
        }
    }
}
