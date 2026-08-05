import SwiftUI
import Foundation
import ImageIO
import CoreImage

// A handful of real-world scanned/uncompressed comic pages come through at absurd pixel
// dimensions (raw scanner output dropped into a CBZ with no resave) that would otherwise decode
// to gigabytes of raw bitmap and can crash the reader outright. This caps the *decode* itself
// (not just display) via ImageIO's thumbnail-from-source path, which is cheap to check (reads
// only the header) and only kicks in when a page is genuinely pathological -- ordinary comic
// pages (a few thousand pixels on a side) are decoded exactly as before.
private let maxDecodedPixelDimension = 8000

private func safeCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
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

// Reused across every averageColor() call rather than allocated fresh each time -- CIContext
// construction is the expensive part of this pipeline, and this one carries no per-image state.
private let averageColorContext = CIContext(options: [.workingColorSpace: NSNull()])

/// Shared by both platforms' `averageColor()` -- a comic's cover-driven accent color, sampled
/// once via CIAreaAverage (collapses the whole image to a single pixel) rather than manually
/// walking raw bitmap bytes. Runs against an already-decoded, already-thumbnail-sized `CGImage`
/// (see `ThumbnailCache`), never a full-resolution page.
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
public typealias PlatformImage = NSImage

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

    static func fromData(_ data: Data) -> NSImage? {
        if let cg = safeCGImage(from: data, maxPixelSize: maxDecodedPixelDimension) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: data)
    }
    static func fromFile(_ path: String) -> NSImage? { NSImage(contentsOfFile: path) }
    static func fromURL(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }

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
public typealias PlatformImage = UIImage

extension UIImage {
    static func resized(source: UIImage, to target: CGSize) -> UIImage? {
        let src = source.size
        guard src.width > 0, src.height > 0 else { return nil }
        let ratio = min(target.width / src.width, target.height / src.height)
        let drawSize = CGSize(width: (src.width * ratio).rounded(), height: (src.height * ratio).rounded())
        let renderer = UIGraphicsImageRenderer(size: drawSize)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: drawSize)) }
    }

    static func fromData(_ data: Data) -> UIImage? {
        if let cg = safeCGImage(from: data, maxPixelSize: maxDecodedPixelDimension) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
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
    /// Shared between the Mac and iPad app entry points -- previously duplicated verbatim in
    /// both ComicArcMacApp.swift and ComicArcIPadApp.swift. Uses `readMigrating()` (not a raw
    /// key read) so an existing install's pre-multi-folder single library path still counts as
    /// "already configured" and never re-triggers onboarding after this update.
    static func isNeeded(completedBuild: String) -> Bool {
        completedBuild.isEmpty && LibraryFolders.readMigrating().isEmpty
    }
}
