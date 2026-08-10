import Foundation
import CoreGraphics

/// One openable comic file, kept alive for the duration of a reading session. Replaces
/// re-deriving the format and re-opening the archive/PDF from scratch on every single page
/// request (the old `LibraryScanner.page(path:index:)` did exactly that) -- open once via
/// `ComicDocumentFactory.open`, serve pages through `pageSource(index:)`, `close()` on eviction.
protocol ComicDocument: AnyObject {
    var pageCount: Int { get }
    func pageSource(index: Int) throws -> PageSource
    func close()
}

/// What a page actually is before decoding: compressed image bytes (CBZ/CBR/loose image) or a
/// PDF page object, which needs direct rendering rather than ImageIO decoding. `PageDecoder`
/// branches on this so every document type funnels through one decode path regardless of shape.
enum PageSource {
    case imageData(Data)
    case pdfPage(CGPDFPage)
}

enum ComicDocumentError: Error {
    case unsupportedFormat
    case openFailed
    case pageOutOfRange
    case pageTooLarge
    case fileUnavailable
}

enum ComicDocumentFactory {
    /// Opens the right `ComicDocument` implementation for `path`'s extension -- the one place
    /// that maps a file extension to a format, done once per reading session instead of once per
    /// page. The underlying opens (archive listing, CBR extraction, PDF parsing) are synchronous
    /// blocking work, so this always hops off the caller's thread; never call this expecting it
    /// to be safe from the main actor otherwise.
    static func open(path: String) async throws -> ComicDocument {
        try await Task.detached(priority: .userInitiated) {
            try openSync(path: path)
        }.value
    }

    static func openSync(path: String) throws -> ComicDocument {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz": return try CBZDocument(path: path)
        case "pdf": return try PDFDocument(path: path)
        case "jpg", "jpeg", "png": return try ImageSetDocument(path: path)
        case "cbr":
            #if os(macOS)
            return try CBRDocument(path: path)
            #else
            throw ComicDocumentError.unsupportedFormat
            #endif
        default: throw ComicDocumentError.unsupportedFormat
        }
    }
}
