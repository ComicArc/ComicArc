import SwiftUI
import Foundation

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

    static func fromData(_ data: Data) -> NSImage? { NSImage(data: data) }
    static func fromFile(_ path: String) -> NSImage? { NSImage(contentsOfFile: path) }
    static func fromURL(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }

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

    static func fromData(_ data: Data) -> UIImage? { UIImage(data: data) }
    static func fromFile(_ path: String) -> UIImage? { UIImage(contentsOfFile: path) }
    static func fromURL(_ url: URL) -> UIImage? { guard let data = try? Data(contentsOf: url) else { return nil }; return UIImage(data: data) }

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
