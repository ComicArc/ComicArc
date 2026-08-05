import SwiftUI

/// Rasterizes a small SwiftUI view into a PNG on disk, for use with SwiftUI's `ShareLink(item:)`.
/// A plain file `URL` is `Transferable` on both platforms with zero custom conformance, unlike
/// raw `Data`/`PlatformImage` -- this is the reason the render target is a temp file, not bytes
/// kept in memory.
@MainActor
enum ShareCardRenderer {
    static func renderToTempPNG<Content: View>(_ content: Content, filename: String) -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0

        let pngData: Data?
        #if os(macOS)
        if let nsImage = renderer.nsImage,
           let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        #else
        pngData = renderer.uiImage?.pngData()
        #endif

        guard let pngData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
