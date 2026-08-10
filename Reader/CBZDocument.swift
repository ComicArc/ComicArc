import Foundation
import ZIPFoundation

final class CBZDocument: ComicDocument, @unchecked Sendable {
    /// Same cap `ThumbnailCache` uses for cover extraction -- generous enough for even a
    /// high-DPI scanned page, but bounds how much a single crafted/corrupted entry can force a
    /// decompress into memory.
    private static let maxPageSizeBytes: UInt64 = 50 * 1024 * 1024

    private let archive: Archive
    private let entries: [Entry]
    /// ZIPFoundation's `Archive` wraps a single file handle/position -- concurrent `extract`
    /// calls on one instance (which `PageStore`'s concurrent prefetch queue can produce) would
    /// race. Serializing just the raw-bytes extraction (not the ImageIO decode that follows it)
    /// keeps the entry-list-reuse win without reintroducing that race.
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
