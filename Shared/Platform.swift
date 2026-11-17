import SwiftUI
import Foundation
import ImageIO
import CoreImage

// Some scanned pages are huge enough to decode to gigabytes. This caps the decode itself using
// ImageIO's thumbnail path.
let maxDecodedPixelDimension = 8000

/// Decodes at up to `maxPixelSize` on the long edge, without a full decode first.
func safeCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          max(w, h) > maxPixelSize else {
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
}

// Shared: creating a CIContext is the expensive part.
private let averageColorContext = CIContext(options: [.workingColorSpace: NSNull()])

/// Average color of an already-small cover image, via CIAreaAverage.
private func computeAverageColor(from cgImage: CGImage) -> Color? {
    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ciImage,
        kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
    ]), let outputImage = filter.outputImage else { return nil }

    var bitmap = [UInt8](repeating: 0, count: 4)
    averageColorContext.render(outputImage, toBitmap: &bitmap, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

    return Color(red: Double(bitmap[0]) / 255, green: Double(bitmap[1]) / 255, blue: Double(bitmap[2]) / 255)
}

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    static func resized(source: NSImage, to target: CGSize) -> NSImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let src = CGSize(width: cg.width, height: cg.height)
        guard src.width > 0, src.height > 0 else { return nil }
        let ratio = min(target.width / src.width, target.height / src.height)
        let drawSize = CGSize(width: (src.width * ratio).rounded(), height: (src.height * ratio).rounded())
        let result = NSImage(size: drawSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: drawSize))
        result.unlockFocus()
        return result
    }

    static func fromFile(_ path: String) -> NSImage? { NSImage(contentsOfFile: path) }
    static func fromURL(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }
    static func fromCGImage(_ cg: CGImage) -> NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }

    func averageColor() -> Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return computeAverageColor(from: cg)
    }

    func platformJPEGData(compressionFactor: CGFloat = 0.85) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }

    var byteSize: Int {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return cg.width * cg.height * 4
    }

    /// The display's backing scale, clamped, so PDF pages render sharply on Retina.
    static var pdfRenderScale: CGFloat { min(3.0, max(2.0, NSScreen.main?.backingScaleFactor ?? 2.0)) }

    static func renderPDFPage(_ page: CGPDFPage, scale: CGFloat = 1.5) -> NSImage? {
        let bounds = page.getBoxRect(.mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let img = NSImage(size: size)
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        img.unlockFocus()
        return img
    }
}

#else
import UIKit
typealias PlatformImage = UIImage

extension UIImage {
    static func resized(source: UIImage, to target: CGSize) -> UIImage? {
        let src = source.size
        guard src.width > 0, src.height > 0 else { return nil }
        let ratio = min(target.width / src.width, target.height / src.height)
        let drawSize = CGSize(width: (src.width * ratio).rounded(), height: (src.height * ratio).rounded())
        let renderer = UIGraphicsImageRenderer(size: drawSize)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: drawSize)) }
    }

    static func fromCGImage(_ cg: CGImage) -> UIImage { UIImage(cgImage: cg) }

    static func fromFile(_ path: String) -> UIImage? { UIImage(contentsOfFile: path) }
    static func fromURL(_ url: URL) -> UIImage? { guard let data = try? Data(contentsOf: url) else { return nil }; return UIImage(data: data) }

    func averageColor() -> Color? {
        guard let cg = cgImage else { return nil }
        return computeAverageColor(from: cg)
    }

    func platformJPEGData(compressionFactor: CGFloat = 0.85) -> Data? {
        jpegData(compressionQuality: compressionFactor)
    }

    var byteSize: Int { Int(size.width * scale) * Int(size.height * scale) * 4 }

    static var pdfRenderScale: CGFloat {
        #if os(visionOS)
        2.0  // No UIScreen on visionOS; windows render at 2x.
        #else
        min(3.0, max(2.0, UIScreen.main.scale))
        #endif
    }

    static func renderPDFPage(_ page: CGPDFPage, scale: CGFloat = 1.5) -> UIImage? {
        let bounds = page.getBoxRect(.mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: scale, y: -scale)
            cgCtx.drawPDFPage(page)
        }
    }
}
#endif

extension PlatformImage {
    /// Loads and fully decodes an image file on the calling thread. `fromURL` decodes lazily on
    /// first draw, which for grid covers means on the main thread while scrolling.
    static func decodedFromURL(_ url: URL) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return fromCGImage(cg)
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }

}

enum OnboardingGate {
    /// Onboarding is needed when no build has completed it and no library folder is configured.
    static func isNeeded(completedBuild: String) -> Bool {
        completedBuild.isEmpty && LibraryFolders.readMigrating().isEmpty
    }
}
