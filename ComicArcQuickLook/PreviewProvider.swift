import Quartz
import AppKit
import ZIPFoundation

/// Quick Look preview of a CBZ or PDF's cover. Self-contained, since the extension runs in its own
/// sandboxed process with no database.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        guard let image = Self.firstPageImage(at: url) else {
            handler(nil, NSError(domain: "com.comicarc.app.quicklook", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Couldn't read a page from this file."]))
            return
        }

        let reply = QLPreviewReply(contextSize: image.size, isBitmap: true) { context, _ in
            let rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            context.draw(cgImage, in: rect)
        }
        handler(reply, nil)
    }

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp"]

    private static func firstPageImage(at url: URL) -> NSImage? {
        switch url.pathExtension.lowercased() {
        case "cbz": return firstCBZPage(url)
        case "pdf": return firstPDFPage(url)
        default: return nil
        }
    }

    private static func firstCBZPage(_ url: URL) -> NSImage? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
        let entries = archive
            .filter { imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard let first = entries.first, first.uncompressedSize <= 50 * 1024 * 1024 else { return nil }
        var data = Data()
        _ = try? archive.extract(first, consumer: { data.append($0) })
        return NSImage(data: data)
    }

    private static func firstPDFPage(_ url: URL) -> NSImage? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: 1) else { return nil }
        let rect = page.getBoxRect(.mediaBox)
        let image = NSImage(size: rect.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(.white)
            ctx.fill(rect)
            ctx.saveGState()
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image
    }
}
