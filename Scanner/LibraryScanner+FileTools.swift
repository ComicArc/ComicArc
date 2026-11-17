import Foundation
import CoreGraphics
import CryptoKit
import ZIPFoundation
#if os(macOS)
import AppKit
#endif

/// CBR-to-CBZ conversion and ComicInfo.xml write-back.
#if os(macOS)
extension LibraryScanner {
    enum CBRConversionError: Error {
        case unarNotFound, notACBR, extractionFailed, noImagesFound, destinationExists, zipWriteFailed
    }

    /// Converts one CBR to a CBZ at the same location (extract with `unar`, re-zip with
    /// ZIPFoundation). Runs on `queue`.
    func convertCBRToCBZ(path: String) -> Result<URL, CBRConversionError> {
        let sourceURL = URL(fileURLWithPath: path)
        guard sourceURL.pathExtension.lowercased() == "cbr" else { return .failure(.notACBR) }
        guard let unar = ExternalTool.shared.which("unar") else { return .failure(.unarNotFound) }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = ExternalTool.shared.shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path])

        guard let enumerator = FileManager.default.enumerator(
            at: tmpDir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return .failure(.extractionFailed) }

        var entryFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = fileURL.lastPathComponent
            if imageExts.contains(fileURL.pathExtension.lowercased()) || name.lowercased() == "comicinfo.xml" {
                entryFiles.append(fileURL)
            }
        }
        guard !entryFiles.isEmpty else { return .failure(.noImagesFound) }
        entryFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let destURL = sourceURL.deletingPathExtension().appendingPathExtension("cbz")
        guard !FileManager.default.fileExists(atPath: destURL.path) else { return .failure(.destinationExists) }

        guard let archive = try? Archive(url: destURL, accessMode: .create, pathEncoding: nil) else { return .failure(.zipWriteFailed) }
        do {
            for file in entryFiles {
                try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent(),
                                     compressionMethod: .deflate)
            }
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            return .failure(.zipWriteFailed)
        }
        return .success(destURL)
    }

    /// Converts a comic's CBR, points its record at the new file and hash, then removes the .cbr.
    private func convertAndUpdateLibraryEntry(comicId: Int64, path: String) -> Result<URL, CBRConversionError> {
        let result = convertCBRToCBZ(path: path)
        guard case .success(let newURL) = result else { return result }
        guard let newHash = fileHash(newURL.path) else {
            try? FileManager.default.removeItem(at: newURL)
            return .failure(.zipWriteFailed)
        }
        db.updateFilePathAndHash(id: comicId, newPath: newURL.path, newHash: newHash)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        return .success(newURL)
    }

    /// Batch conversion for the Convert CBR to CBZ tool. Runs on `queue` so it can't race a scan.
    func convertAllCBRToCBZ(_ comics: [(id: Int64, path: String)],
                            onProgress: @escaping (Int, Int) -> Void,
                            completion: @escaping (Int, [(path: String, error: CBRConversionError)]) -> Void) {
        queue.async { [self] in
            var successCount = 0
            var failures: [(path: String, error: CBRConversionError)] = []
            for (i, item) in comics.enumerated() {
                switch convertAndUpdateLibraryEntry(comicId: item.id, path: item.path) {
                case .success: successCount += 1
                case .failure(let err): failures.append((item.path, err))
                }
                let done = i + 1
                DispatchQueue.main.async { onProgress(done, comics.count) }
            }
            DispatchQueue.main.async { completion(successCount, failures) }
        }
    }

    enum ComicInfoWriteError: Error {
        case notACBZ, archiveOpenFailed, zipWriteFailed
    }

    /// Writes the identity fields back under the exact names `comicInfoXML` reads, so a rescan
    /// reads them back identically. CBZ only.
    func writeComicInfoBack(comic: Comic) -> Result<Void, ComicInfoWriteError> {
        guard comic.filePath.lowercased().hasSuffix(".cbz") else { return .failure(.notACBZ) }
        guard let archive = try? Archive(url: URL(fileURLWithPath: comic.filePath), accessMode: .update, pathEncoding: nil) else {
            return .failure(.archiveOpenFailed)
        }

        let existingEntry = archive.first { $0.path.lowercased().hasSuffix("comicinfo.xml") }
        let entryPath = existingEntry?.path ?? "ComicInfo.xml"

        var existingRoot: XMLElement?
        if let existingEntry {
            var data = Data()
            _ = try? archive.extract(existingEntry, consumer: { data.append($0) })
            existingRoot = try? XMLDocument(data: data).rootElement()
        }
        // Fields this app doesn't manage are preserved if a ComicInfo.xml already exists.
        let root = existingRoot ?? XMLElement(name: "ComicInfo")

        func setField(_ name: String, _ value: String?) {
            root.elements(forName: name).forEach { $0.detach() }
            guard let value, !value.isEmpty else { return }
            root.addChild(XMLElement(name: name, stringValue: value))
        }
        setField("Series", comic.series)
        setField("Title", comic.title)
        setField("IssueNumber", comic.issueNumber)
        setField("Publisher", comic.publisher)
        setField("Writer", comic.writer)
        setField("Penciller", comic.penciller)
        setField("Volume", comic.volume)
        if let year = comic.year { setField("Year", String(year)) }

        let xmlData = XMLDocument(rootElement: root).xmlData(options: .nodePrettyPrint)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        do {
            try xmlData.write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            if let existingEntry { try archive.remove(existingEntry) }
            try archive.addEntry(with: entryPath, fileURL: tmpURL, compressionMethod: .deflate)
        } catch {
            return .failure(.zipWriteFailed)
        }
        return .success(())
    }
}
#endif
