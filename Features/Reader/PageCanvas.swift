import SwiftUI
import AppKit
import CoreImage

/// The paged reader surface: an `NSScrollView`, so pinch-zoom, scrolling around a zoomed page and
/// momentum all behave like the rest of macOS. Magnification 1 is the chosen fit mode.
/// Clicking the left or right third turns the page (when not zoomed); double-clicking the middle
/// toggles 2×; a horizontal swipe turns the page when there's nothing to scroll sideways.
struct PageCanvas: NSViewRepresentable {
    let images: [CGImage]
    let fitMode: FitMode
    let filter: ColorFilter
    @Binding var zoom: CGFloat
    var forward = true
    let onSwipe: (_ towardNext: Bool) -> Void
    var onSideClick: (_ rightSide: Bool) -> Void = { _ in }
    let onZoomEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PageScrollView {
        let scroll = PageScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 5
        scroll.contentView = CenteringClipView()
        scroll.documentView = context.coordinator.pageView
        scroll.onSwipe = { context.coordinator.parent.onSwipe($0) }
        scroll.onSideClick = { context.coordinator.parent.onSideClick($0) }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didEndMagnify),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: PageScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let changed = c.pageView.setImages(images, filter: filter, forward: forward)
        let target = fittedSize(in: scroll.contentSize)
        if changed || c.pageView.frame.size != target || c.lastFit != fitMode {
            c.lastFit = fitMode
            c.pageView.frame = CGRect(origin: .zero, size: target)
            if changed { scroll.magnification = 1; scrollToStart(scroll) }
        }
        if abs(scroll.magnification - zoom) > 0.01 && !c.magnifying {
            scroll.animator().magnification = zoom
        }
    }

    /// The page (or spread) size at magnification 1.
    private func fittedSize(in viewport: CGSize) -> CGSize {
        guard !images.isEmpty, viewport.width > 0, viewport.height > 0 else { return viewport }
        let height = images.map { CGFloat($0.height) }.max() ?? 1
        let width = images.reduce(0) { $0 + CGFloat($1.width) * (height / CGFloat($1.height)) }
        let aspect = width / height
        switch fitMode {
        case .fitPage:
            return viewport.width / viewport.height > aspect
                ? CGSize(width: viewport.height * aspect, height: viewport.height)
                : CGSize(width: viewport.width, height: viewport.width / aspect)
        case .fitWidth: return CGSize(width: viewport.width, height: viewport.width / aspect)
        case .fitHeight: return CGSize(width: viewport.height * aspect, height: viewport.height)
        case .original:
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return CGSize(width: width / scale, height: height / scale)
        }
    }

    private func scrollToStart(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        let top = doc.isFlipped ? 0 : max(0, doc.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PageCanvas
        let pageView = PageView()
        var lastFit: FitMode?
        var magnifying = false
        init(_ parent: PageCanvas) { self.parent = parent }

        @objc func didEndMagnify(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            parent.zoom = scroll.magnification
            parent.onZoomEnd(scroll.magnification)
        }
    }
}

final class PageScrollView: NSScrollView {
    var onSwipe: ((Bool) -> Void)?
    private var swipeDistance: CGFloat = 0
    private var tracking = false

    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let canScrollSideways = (documentView?.frame.width ?? 0) * magnification > contentSize.width + 1
        guard horizontal, !canScrollSideways, event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        switch event.phase {
        case .began: swipeDistance = 0; tracking = true
        case .changed:
            swipeDistance += event.scrollingDeltaX
            if tracking, abs(swipeDistance) > 70 { tracking = false; onSwipe?(swipeDistance < 0) }
        default: tracking = false
        }
    }

    var onSideClick: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let inView = convert(event.locationInWindow, from: nil)
        let fraction = bounds.width > 0 ? inView.x / bounds.width : 0.5
        // Side thirds turn the page (every click, so quick clicks turn quickly); not while zoomed,
        // where clicks and drags are for moving around the page.
        if magnification <= 1.05, fraction < 0.3 || fraction > 0.7 {
            onSideClick?(fraction > 0.7)
            NSCursor.setHiddenUntilMouseMoves(true)
            return
        }
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if magnification > 1.05 { animator().magnification = 1 } else { animator().setMagnification(2, centeredAt: point) }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
}

/// Keeps a page smaller than the window centered.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Draws one page, or two side by side at a shared height.
final class PageView: NSView {
    private var images: [CGImage] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Returns true if the images changed. A page change slides in from the reading direction.
    func setImages(_ new: [CGImage], filter: ColorFilter, forward: Bool) -> Bool {
        let changed = new.count != images.count || zip(new, images).contains { $0 !== $1 }
        let hadImages = !images.isEmpty
        images = new
        layer?.filters = Self.filters(filter)
        if changed {
            if hadImages, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer {
                let t = CATransition()
                t.type = .push
                t.subtype = forward ? .fromRight : .fromLeft
                t.duration = 0.16
                t.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(t, forKey: "pageTurn")
            }
            needsDisplay = true
        }
        return changed
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !images.isEmpty else { return }
        ctx.interpolationQuality = .high
        let height = bounds.height
        let widths = images.map { CGFloat($0.width) * height / CGFloat($0.height) }
        let total = widths.reduce(0, +)
        let scale = total > 0 ? bounds.width / total : 1
        var x: CGFloat = 0
        for (image, w) in zip(images, widths) {
            let rect = CGRect(x: x, y: 0, width: w * scale, height: height)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: rect)
            ctx.restoreGState()
            x += w * scale
        }
    }

    private static func filters(_ f: ColorFilter) -> [CIFilter] {
        switch f {
        case .none: return []
        case .grayscale:
            let c = CIFilter(name: "CIColorControls")!
            c.setValue(0, forKey: kCIInputSaturationKey)
            return [c]
        case .sepia:
            let s = CIFilter(name: "CISepiaTone")!
            s.setValue(0.75, forKey: kCIInputIntensityKey)
            return [s]
        case .night:
            let m = CIFilter(name: "CIColorMatrix")!
            m.setValue(CIVector(x: 0.62, y: 0, z: 0, w: 0), forKey: "inputRVector")
            m.setValue(CIVector(x: 0, y: 0.5, z: 0, w: 0), forKey: "inputGVector")
            m.setValue(CIVector(x: 0, y: 0, z: 0.36, w: 0), forKey: "inputBVector")
            return [m]
        }
    }
}
