#if os(macOS)
import Foundation

/// The actual extraction-once-per-archive cache `CBRDocument` instances share, kept independent
/// of any single document's lifetime. A comic can be opened (a session started), closed, and
/// reopened -- backing out of the reader and returning, or the reader prefetching the next
/// issue's cover before the user actually advances into it -- within one app run; re-extracting
/// on every open would undo the whole point of extracting once. FIFO of 3 archives, each a real
/// extracted directory on disk (tens to hundreds of MB), not just cached bytes.
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
        // Same ordering key `LibraryScanner.cbrImageListing` uses at scan time (the entry's path
        // as reported by `lsar`, compared with `localizedStandardCompare`) so page N here matches
        // page N there -- `unar` preserves each entry's original archive-relative path when
        // extracting to `-o`.
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
