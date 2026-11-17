import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Decodes pages and covers into ready-to-draw bitmaps, off the main thread.
enum ImageDecoder {
    /// Pages are never decoded past this long edge, so a huge scan can't use gigabytes of memory.
    static let maxDimension = 8192

    /// Decodes at up to `maxPixelSize` on the long edge (nil = full size, capped).
    static func decode(_ source: PageSource, maxPixelSize: Int?) -> CGImage? {
        let limit = min(maxPixelSize ?? maxDimension, maxDimension)
        switch source {
        case .data(let data):
            guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return decode(src, limit: limit)
        case .pdf(let page):
            return render(page, longEdge: limit)
        }
    }

    static func decodeFile(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decode(src, limit: maxPixelSize)
    }

    private static func decode(_ src: CGImageSource, limit: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Pixel size of an encoded page without decoding it (for spread detection and layout).
    static func pixelSize(_ source: PageSource) -> CGSize? {
        switch source {
        case .data(let data):
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let rotated = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            return rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        case .pdf(let page):
            return page.getBoxRect(.cropBox).size
        }
    }

    private static func render(_ page: CGPDFPage, longEdge: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(longEdge) / max(box.width, box.height)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The image's average color, by drawing it into a single pixel.
    static func averageColor(_ image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    static func byteCost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }
}
