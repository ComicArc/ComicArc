import Foundation
import CoreGraphics
import ZIPFoundation

/// An open comic file, kept alive for a reading session. Open via `ComicDocumentFactory.open`,
/// `close()` when done.
protocol ComicDocument: AnyObject {
    var pageCount: Int { get }
    func pageSource(index: Int) throws -> PageSource
    func close()
}

/// A page before decoding: compressed image bytes, or a PDF page that is rendered directly.
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
    /// Opens the right `ComicDocument` for the file's extension, off the caller's thread (opening
    /// can block).
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

final class CBZDocument: ComicDocument, @unchecked Sendable {
    /// Per-entry decompression cap, bounding memory for a malformed entry.
    private static let maxPageSizeBytes: UInt64 = 50 * 1024 * 1024

    private let archive: Archive
    private let entries: [Entry]
    /// `Archive` wraps a single file handle, so concurrent extracts are serialized (decoding still
    /// runs concurrently).
    private let lock = NSLock()

    init(path: String) throws {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else {
            throw ComicDocumentError.openFailed
        }
        self.archive = archive
        self.entries = archive
            .filter { LibraryScanner.imageExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var pageCount: Int { entries.count }

    func pageSource(index: Int) throws -> PageSource {
        guard index >= 0, index < entries.count else { throw ComicDocumentError.pageOutOfRange }
        let entry = entries[index]
        guard entry.uncompressedSize <= Self.maxPageSizeBytes else { throw ComicDocumentError.pageTooLarge }
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        _ = try? archive.extract(entry, consumer: { data.append($0) })
        return .imageData(data)
    }

    func close() {}
}

#if os(macOS)
import Foundation

/// Extraction cache shared across `CBRDocument` instances, so reopening a CBR in the same run
/// doesn't re-extract it.
final class CBRExtractionCache: @unchecked Sendable {
    static let shared = CBRExtractionCache()
    private init() {}

    private let lock = NSLock()
    private var entries: [(path: String, dir: URL, files: [URL])] = []
    private static let maxEntries = 3
    private static let maxSizeBytes: UInt64 = 5 * 1024 * 1024 * 1024

    func extractedFiles(for path: String) -> [URL]? {
        lock.lock()
        if let existing = entries.first(where: { $0.path == path }) { lock.unlock(); return existing.files }
        lock.unlock()

        guard let unar = ExternalTool.shared.which("unar") else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard UInt64(size) <= Self.maxSizeBytes else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("comicarc-cbr-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)) != nil else { return nil }
        ExternalTool.shared.shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path])

        guard let enumerator = FileManager.default.enumerator(
            at: tmpDir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { try? FileManager.default.removeItem(at: tmpDir); return nil }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if LibraryScanner.imageExtensions.contains(fileURL.pathExtension.lowercased()) { files.append(fileURL) }
        }
        // Same ordering as `LibraryScanner.cbrImageListing`, so page N here matches page N there.
        let sorted = files.sorted {
            $0.path.replacingOccurrences(of: tmpDir.path, with: "")
                .localizedStandardCompare($1.path.replacingOccurrences(of: tmpDir.path, with: "")) == .orderedAscending
        }

        lock.lock()
        entries.append((path: path, dir: tmpDir, files: sorted))
        var toDelete: [URL] = []
        while entries.count > Self.maxEntries { toDelete.append(entries.removeFirst().dir) }
        lock.unlock()
        for dir in toDelete { try? FileManager.default.removeItem(at: dir) }

        return sorted
    }
}

final class CBRDocument: ComicDocument, @unchecked Sendable {
    private let files: [URL]

    init(path: String) throws {
        guard let files = CBRExtractionCache.shared.extractedFiles(for: path), !files.isEmpty else {
            throw ComicDocumentError.openFailed
        }
        self.files = files
    }

    var pageCount: Int { files.count }

    func pageSource(index: Int) throws -> PageSource {
        guard index >= 0, index < files.count else { throw ComicDocumentError.pageOutOfRange }
        guard let data = FileManager.default.contents(atPath: files[index].path) else { throw ComicDocumentError.openFailed }
        return .imageData(data)
    }

    func close() {}
}
#endif

final class PDFDocument: ComicDocument, @unchecked Sendable {
    private let document: CGPDFDocument

    init(path: String) throws {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let doc = CGPDFDocument(provider) else {
            throw ComicDocumentError.openFailed
        }
        self.document = doc
    }

    var pageCount: Int { document.numberOfPages }

    func pageSource(index: Int) throws -> PageSource {
        guard index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1) else { throw ComicDocumentError.pageOutOfRange }
        return .pdfPage(page)
    }

    func close() {}
}

/// A standalone image file treated as a one-page comic.
final class ImageSetDocument: ComicDocument {
    private let path: String

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ComicDocumentError.fileUnavailable }
        self.path = path
    }

    var pageCount: Int { 1 }

    func pageSource(index: Int) throws -> PageSource {
        guard index == 0 else { throw ComicDocumentError.pageOutOfRange }
        guard let data = FileManager.default.contents(atPath: path) else { throw ComicDocumentError.openFailed }
        return .imageData(data)
    }

    func close() {}
}
