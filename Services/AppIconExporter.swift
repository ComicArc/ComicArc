import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Debug-only developer utility: renders `AppIconArt` to a single 1024x1024 master PNG at the
/// project root. Not part of any shipped user-facing flow -- exists purely so the icon's source
/// of truth can stay reviewable Swift code (`Views/AppIconArt.swift`) instead of a one-off binary
/// with no editable origin. Reuses the exact `ImageRenderer` -> `NSBitmapImageRep` -> PNG pipeline
/// `Services/ShareCardRenderer.swift` already proves works in this app.
///
/// Deliberately renders ONE master at 1:1 scale rather than asking `ImageRenderer` for every
/// oddball icon size directly -- scale factors well under 1.0 (a 16pt icon from a 1024pt view is
/// scale ~0.016) risk degraded antialiasing. `sips` (standard on every Mac) downsamples the
/// master into every exact size `AppIcon.appiconset`'s `Contents.json` lists far more reliably.
#if DEBUG
@MainActor
enum AppIconExporter {
    static func exportMaster() -> String {
        let renderer = ImageRenderer(content: AppIconArt())
        renderer.scale = 1.0

        #if os(macOS)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return "Render failed"
        }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/ComicArc/icon_master_1024.png")
        do {
            try pngData.write(to: url, options: .atomic)
            return "Wrote master to \(url.path)"
        } catch {
            return "Write failed: \(error.localizedDescription)"
        }
        #else
        return "macOS only"
        #endif
    }
}
#endif
