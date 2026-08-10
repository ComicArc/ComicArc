import Foundation
import CoreGraphics

/// Turns a document's raw page source into a displayable, resolution-appropriate image. Owns the
/// target-size-aware decode: decoding at approximately the actual viewport size, instead of
/// always decoding to the safety-cap ceiling and letting the view scale down after the fact, is
/// the single biggest lever on both decode latency and peak memory for oversized pages -- most
/// reading happens at a fit mode, where the displayed size is a small fraction of a large
/// scanned page's native resolution.
enum PageDecoder {
    /// `maxPixelSize` is the caller's desired long-edge pixel size (already screen-scale-
    /// adjusted), or `nil` for "decode at full/native resolution" (actual-size zoom). Always
    /// clamped to the same safety ceiling `PlatformImage.fromData` uses regardless of what's
    /// requested, so a pathological source can't be forced to decode unbounded.
    static func decode(_ source: PageSource, maxPixelSize: Int?) -> PlatformImage? {
        let cappedSize = min(maxPixelSize ?? maxDecodedPixelDimension, maxDecodedPixelDimension)
        switch source {
        case .imageData(let data):
            guard let cg = safeCGImage(from: data, maxPixelSize: cappedSize) else { return nil }
            return PlatformImage.fromCGImage(cg)
        case .pdfPage(let page):
            let box = page.getBoxRect(.mediaBox)
            let longEdge = max(box.width, box.height, 1)
            let scale: CGFloat
            if maxPixelSize != nil {
                scale = max(1.0, CGFloat(cappedSize) / longEdge)
            } else {
                scale = PlatformImage.pdfRenderScale
            }
            return PlatformImage.renderPDFPage(page, scale: scale)
        }
    }
}
