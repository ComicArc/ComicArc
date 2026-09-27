import SwiftUI

#if os(macOS)
import AppKit
import CoreImage

/// The Mac paged reader surface: a real `NSScrollView`, so a zoomed page moves with ordinary
/// two-finger/mouse-wheel scrolling and scrollbars instead of click-and-drag. Magnification is
/// the zoom level (1 = the chosen fit mode), pinch zooms around the cursor, double-click toggles
/// 2x, and a horizontal two-finger swipe turns the page whenever nothing is scrollable sideways.
struct ZoomablePageView: NSViewRepresentable {
    let images: [PlatformImage]
    let page: Int
    let fitMode: FitMode
    let zoomLevel: CGFloat
    let colorFilter: ColorFilter
    let viewportSize: CGSize
    let onZoomCommitted: (CGFloat) -> Void
    let onSwipe: (_ towardNextPage: Bool) -> Void

    final class Coordinator {
        var parent: ZoomablePageView
        var lastPage: Int?
        var isLiveMagnifying = false
        var observers: [NSObjectProtocol] = []
        init(_ parent: ZoomablePageView) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PageScrollView {
        let scrollView = PageScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 5
        let canvas = PageCanvasView()
        scrollView.documentView = canvas

        let coordinator = context.coordinator
        scrollView.onSwipe = { coordinator.parent.onSwipe($0) }
        canvas.onDoubleClick = { [weak scrollView] point in
            guard let scrollView else { return }
            let target: CGFloat = scrollView.magnification > 1.05 ? 1 : 2
            scrollView.setMagnification(target, centeredAt: point)
            coordinator.parent.onZoomCommitted(target)
        }
        let center = NotificationCenter.default
        coordinator.observers = [
            center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { _ in
                coordinator.isLiveMagnifying = true
            },
            center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak scrollView] _ in
                coordinator.isLiveMagnifying = false
                if let scrollView { coordinator.parent.onZoomCommitted(scrollView.magnification) }
            },
        ]
        return scrollView
    }

    func updateNSView(_ scrollView: PageScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let canvas = scrollView.documentView as? PageCanvasView else { return }
        canvas.setImages(images, filter: colorFilter)

        if !images.isEmpty {
            let size = fittedSize()
            if canvas.frame.size != size { canvas.setFrameSize(size) }
        }
        if !coordinator.isLiveMagnifying, abs(scrollView.magnification - zoomLevel) > 0.01 {
            let visible = scrollView.contentView.bounds
            scrollView.setMagnification(zoomLevel, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        }
        if coordinator.lastPage != page, !images.isEmpty {
            coordinator.lastPage = page
            canvas.scroll(.zero)
        }
    }

    static func dismantleNSView(_ scrollView: PageScrollView, coordinator: Coordinator) {
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The page (or spread) size at magnification 1 for the current fit mode. Only aspect
    /// ratios are used, except for Original Size, since decode resolution changes with zoom.
    private func fittedSize() -> CGSize {
        let aspects = images.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 }
        let unitWidth = aspects.reduce(0, +)
        guard unitWidth > 0, viewportSize.width > 0, viewportSize.height > 0 else { return viewportSize }
        let height: CGFloat
        switch fitMode {
        case .fitPage:   height = min(viewportSize.height, viewportSize.width / unitWidth)
        case .fitWidth:  height = viewportSize.width / unitWidth
        case .fitHeight: height = viewportSize.height
        case .original:  height = images[0].size.height
        }
        return CGSize(width: (height * unitWidth).rounded(), height: height.rounded())
    }
}

final class PageScrollView: NSScrollView {
    var onSwipe: ((Bool) -> Void)?
    private var swipeDistance: CGFloat = 0
    private var trackingSwipe = false

    /// Trackpad horizontal swipes turn the page only when the page has no horizontal room to
    /// scroll; otherwise (zoomed in, Fit Height on a wide spread) they scroll as usual.
    override func scrollWheel(with event: NSEvent) {
        let hasHorizontalRoom = (documentView?.frame.width ?? 0) * magnification > contentSize.width + 1
        guard event.hasPreciseScrollingDeltas, !hasHorizontalRoom, event.momentumPhase.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .began:
            swipeDistance = 0
            trackingSwipe = true
        case .changed where trackingSwipe:
            swipeDistance += event.scrollingDeltaX
        case .ended, .cancelled:
            if trackingSwipe, abs(swipeDistance) > 60 { onSwipe?(swipeDistance < 0) }
            trackingSwipe = false
        default:
            break
        }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { super.scrollWheel(with: event) }
    }
}

/// Keeps a page smaller than the window centered instead of pinned to the top-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}

/// Draws one page, or two side by side for a spread, filling its own bounds at a shared height.
final class PageCanvasView: NSView {
    var onDoubleClick: ((NSPoint) -> Void)?
    private var sourceImages: [NSImage] = []
    private var filter: ColorFilter = .none
    private var displayImages: [NSImage] = []
    private static let ciContext = CIContext()

    override var isFlipped: Bool { true }

    func setImages(_ images: [NSImage], filter: ColorFilter) {
        guard images.count != sourceImages.count
                || zip(images, sourceImages).contains(where: { $0 !== $1 })
                || filter != self.filter else { return }
        sourceImages = images
        self.filter = filter
        displayImages = images.map { Self.apply(filter, to: $0) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        let aspects = displayImages.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 }
        var x: CGFloat = 0
        for (image, aspect) in zip(displayImages, aspects) {
            let width = bounds.height * aspect
            image.draw(in: NSRect(x: x, y: 0, width: width, height: bounds.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += width
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Same looks as the SwiftUI `colorEffect(_:)` modifier, applied to the bitmap since SwiftUI
    /// color modifiers don't reach into an AppKit view.
    private static func apply(_ filter: ColorFilter, to image: NSImage) -> NSImage {
        guard filter != .none,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        func scaled(_ v: CIVector, _ k: CGFloat) -> CIVector { CIVector(x: v.x * k, y: v.y * k, z: v.z * k, w: 0) }
        let matrix: (r: CIVector, g: CIVector, b: CIVector, bias: CIVector)
        switch filter {
        case .none:
            return image
        case .night:
            matrix = (CIVector(x: 1, y: 0, z: 0, w: 0), CIVector(x: 0, y: 0.85, z: 0, w: 0),
                      CIVector(x: 0, y: 0, z: 0.65, w: 0), CIVector(x: -0.05, y: -0.05, z: -0.05, w: 0))
        case .sepia:
            matrix = (scaled(luma, 1.12), scaled(luma, 0.96), scaled(luma, 0.82), CIVector(x: 0, y: 0, z: 0, w: 0))
        case .grayscale:
            matrix = (luma, luma, luma, CIVector(x: 0, y: 0, z: 0, w: 0))
        }
        let output = CIImage(cgImage: cg).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": matrix.r, "inputGVector": matrix.g, "inputBVector": matrix.b,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": matrix.bias,
        ])
        guard let result = ciContext.createCGImage(output, from: output.extent) else { return image }
        return NSImage(cgImage: result, size: image.size)
    }
}
#endif
