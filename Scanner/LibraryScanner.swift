import Foundation
import CoreGraphics
import CryptoKit
import ZIPFoundation
#if os(macOS)
import AppKit
#endif

final class LibraryScanner: @unchecked Sendable {
    static let shared = LibraryScanner()
    private init() {}

    private let db = DatabaseManager.shared
    private let queue = DispatchQueue(label: "com.comicarc.scanner", qos: .utility)

    static var supportedExtensions: Set<String> {
        #if os(macOS)
        let cbrEnabled = UserDefaults.standard.object(forKey: "cbrEnabled") == nil
            || UserDefaults.standard.bool(forKey: "cbrEnabled")
        return cbrEnabled ? ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"] : ["cbz", "pdf", "jpg", "jpeg", "png"]
        #else
        ["cbz", "pdf", "jpg", "jpeg", "png"]
        #endif
    }
    private var supported: Set<String> { Self.supportedExtensions }

    struct ScanState: Sendable {
        var running = false; var total = 0; var done = 0; var added = 0
        var removed = 0; var recovered = 0; var stillCorrupted = 0
        var cancelled = false; var error: String?
        /// Ids soft-deleted by this scan, so a caller can remove their stale Spotlight entries --
        /// indexSearchableItems is additive-only and would otherwise leave them permanently
        /// discoverable, the same gap already fixed for interactive delete in LibraryViewModel.
        var removedIds: [Int64] = []
    }

    private let stateLock = NSLock()
    private var _state = ScanState()

    var state: ScanState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ block: (inout ScanState) -> Void) { stateLock.lock(); defer { stateLock.unlock() }; block(&_state) }
    func cancel() { setState { $0.cancelled = true } }

    func runAfterCurrentWork(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// Longest-prefix match among the configured library roots for a real file path -- roots
    /// aren't expected to nest, but matching the longest one first is a cheap safety net if they
    /// somehow do. Returns `nil` if the path doesn't fall under any currently configured root
    /// (e.g. a folder was removed from the library after comics were already imported from it).
    func matchingRoot(for path: String, in roots: [String]) -> String? {
        roots.filter { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path == root || path.hasPrefix(prefix)
        }.max { $0.count < $1.count }
    }

    func scan(libraryPaths: [String], onProgress: @escaping (ScanState) -> Void) {
        // Check-and-set must happen as one atomic step under `stateLock` -- reading `state.running`
        // here and only flipping it to true later, inside `_scan` once it actually starts on
        // `queue`, leaves a window where two near-simultaneous callers (e.g. an auto-scan trigger
        // and a manual Resync click) both see `running == false` and both get enqueued.
        var shouldRun = false
        setState { if !$0.running { $0 = ScanState(running: true); shouldRun = true } }
        guard shouldRun else { return }
        queue.async { [self] in self._scan(libraryPaths: libraryPaths, onProgress: onProgress) }
    }

    private func _scan(libraryPaths: [String], onProgress: @escaping (ScanState) -> Void) {
        runImportPriorityAudit()

        let fm = FileManager.default
        let reachableRoots = libraryPaths.filter { fm.fileExists(atPath: $0) }
        guard !reachableRoots.isEmpty else {
            setState { $0.running = false; $0.error = "None of your configured library folders are accessible" }
            DispatchQueue.main.async { onProgress(self.state) }
            return
        }

        var allFiles: [URL] = []
        for root in reachableRoots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if supported.contains(url.pathExtension.lowercased()) { allFiles.append(url) }
            }
        }
        allFiles.sort { $0.path < $1.path }
        setState { $0.total = allFiles.count }

        var knownPaths  = db.knownPaths()
        var knownHashes = db.knownHashes()
        var added = 0

        let chunkSize = 100
        var pending: [DatabaseManager.ComicInsert] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            db.batchInsert(pending)
            pending.removeAll()
        }

        var touchedRawKeys: Set<String> = []
        var touchedEffectiveKeys: Set<String> = []

        func insertNewComic(url: URL, fp: String, hash: String?) {
            // A soft-deleted comic at this exact path is about to be revived (see _insertRow's
            // ON CONFLICT). Its cached cover may have been generated from a bad read while the
            // file was flaky/inaccessible right before it got marked stale -- evict it now so the
            // revived comic gets a genuinely fresh extraction instead of a possibly-wrong cover.
            if let staleId = db.softDeletedComicId(atPath: fp) {
                ThumbnailCache.shared.evict(staleId)
            }
            let root = matchingRoot(for: fp, in: reachableRoots) ?? reachableRoots.first ?? ""
            let meta = parseMeta(url: url, libraryPath: root)
            pending.append(DatabaseManager.ComicInsert(
                title: meta.title, filePath: fp, publisher: meta.publisher,
                character: meta.character, series: meta.series,
                issueNumber: meta.issueNumber, pageCount: pageCount(fp),
                writer: meta.writer, penciller: meta.penciller,
                year: meta.year, storyArc: meta.storyArc,
                languageIso: meta.languageIso, fileHash: hash,
                coverMonth: meta.coverMonth, coverDay: meta.coverDay,
                alternateNumber: meta.alternateNumber, storyArcNumber: meta.storyArcNumber,
                seriesGroup: meta.seriesGroup, comicInfoIssueNumber: meta.comicInfoIssueNumber,
                volume: meta.volume, format: meta.format, hasComicInfo: meta.hasComicInfo,
                comicInfoSeries: meta.comicInfoSeries, comicInfoPublisher: meta.comicInfoPublisher,
                folderSeries: meta.folderSeries, folderPublisher: meta.folderPublisher, folderGroup: meta.folderGroup,
                seriesSource: meta.seriesSource, publisherSource: meta.publisherSource,
                issueNumberSource: meta.issueNumberSource
            ))
            added += 1; knownPaths.insert(fp)
            if let hash { knownHashes.insert(hash) }
            touchedRawKeys.insert("\(meta.publisher):\(meta.series)")
            let effectiveSeries = meta.seriesGroup?.isEmpty == false ? meta.seriesGroup! : meta.series
            let effectiveKey = meta.volume?.isEmpty == false
                ? "\(meta.publisher):\(effectiveSeries):\(meta.volume!)" : "\(meta.publisher):\(effectiveSeries)"
            touchedEffectiveKeys.insert(effectiveKey)
            if pending.count >= chunkSize { flushPending() }
        }

        var anyRemoved = false
        var movedComics: [(id: Int64, url: URL)] = []

        for (i, url) in allFiles.enumerated() {
            if state.cancelled { break }
            let fp = url.path
            if !knownPaths.contains(fp) {
                let hash = fileHash(fp)
                if let h = hash, knownHashes.contains(h) {
                    if let existingPath = db.path(forHash: h), fm.fileExists(atPath: existingPath) {
                        insertNewComic(url: url, fp: fp, hash: h)
                    } else {
                        db.updateFilePath(forHash: h, newPath: fp)
                        knownPaths.insert(fp)
                        if let id = db.idForHash(h) { movedComics.append((id, url)) }
                    }
                } else {
                    insertNewComic(url: url, fp: fp, hash: hash)
                }
            }
            let done = i + 1
            setState { $0.done = done; $0.added = added }
            if i % 25 == 0 { onProgress(state) }
        }
        flushPending()

        if !movedComics.isEmpty {
            // A file's identity survives a move/rename via its hash, but the folder-derived
            // publisher/character/series/title/issue-number it was tagged with at its OLD path
            // don't automatically follow -- a renamed folder (every file inside inherits a new
            // path) would otherwise leave every comic in it permanently tagged with whatever
            // series name the old folder happened to have, disconnected from GCD matching,
            // reading order, and series links for the real (new) series going forward. Reuses
            // the same folder-metadata derivation `reparseAllMeta` uses for a full manual
            // resync, respecting meta_edited the same way, just scoped to only the files that
            // actually moved this scan instead of the whole library.
            var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)] = []
            for (id, url) in movedComics {
                let root = matchingRoot(for: url.path, in: libraryPaths) ?? ""
                let (pub, char, group, ser) = folderComponents(url: url, libraryPath: root)
                let filename = url.deletingPathExtension().lastPathComponent
                updates.append((id, pub, char, ser, filename, extractIssueNumber(from: filename), extractYear(from: filename), group))
                if let ser {
                    let key = "\(pub ?? "Unknown"):\(ser)"
                    touchedRawKeys.insert(key)
                    touchedEffectiveKeys.insert(key)
                }
            }
            db.batchUpdateFolderMeta(updates)
        }

        if !state.cancelled && !reachableRoots.isEmpty {
            let active = db.stalePaths()
            // Only comics whose matching root is CURRENTLY reachable are even considered for
            // staleness -- a root that's temporarily unreachable (asleep NAS, ejected drive) must
            // not have its comics judged missing just because we can't check them right now, and
            // a comic whose root was removed from the configured folder list entirely is left
            // alone rather than silently deleted just because the folder itself was unconfigured.
            let checkable = active.filter { comic in
                guard let root = matchingRoot(for: comic.path, in: libraryPaths) else { return false }
                return reachableRoots.contains(root)
            }
            let stale = checkable.filter { !fm.fileExists(atPath: $0.path) }.map(\.id)
            // A flaky/waking external drive or network share can resolve the library ROOT path
            // fine while individual file-existence checks transiently false-negative -- if that
            // happens, this would otherwise read as "most of the library vanished overnight" and
            // soft-delete all of it. A single user genuinely deleting most of a small library is
            // plausible and shouldn't be blocked, so this only guards a large ABSOLUTE count too.
            let suspiciouslyLarge = checkable.count >= 20 && stale.count > checkable.count / 2
            if !stale.isEmpty && !suspiciouslyLarge {
                db.softDelete(stale, reason: "missing"); anyRemoved = true
                stale.forEach { ThumbnailCache.shared.evict($0) }
                setState { $0.removed = stale.count; $0.removedIds = stale }
            } else if suspiciouslyLarge {
                setState { $0.error = "Skipped removing \(stale.count) of \(checkable.count) comics that looked missing -- this usually means the drive was slow to wake up or briefly disconnected, not that the files are actually gone. Rescan once the drive is fully available to confirm." }
            }
        }

        if !state.cancelled {
            var recovered = 0
            var stillCorrupted = 0
            for (id, path) in db.zeroPageCountPaths() {
                if state.cancelled { break }
                let count = pageCount(path)
                if count > 0 { db.updatePageCount(comicId: id, count: count); recovered += 1 }
                else { db.incrementScanRetryCount(comicId: id); stillCorrupted += 1 }
            }
            setState { $0.recovered = recovered; $0.stillCorrupted = stillCorrupted }
        }

        let somethingChanged = added > 0 || anyRemoved || !movedComics.isEmpty
        if !state.cancelled && somethingChanged {
            db.seedMissingPositions()
            if anyRemoved {
                db.positionSpecialsChronologically()
                db.recomputeGCDMatches()
                db.autoPopulateSeriesLinksFromGCD()
                db.recomputeReadingOrder()
            } else {
                db.positionSpecialsChronologically(affectedGroupKeys: touchedRawKeys)
                db.recomputeGCDMatches(affectedGroupKeys: touchedEffectiveKeys)
                db.autoPopulateSeriesLinksFromGCD()
                db.recomputeReadingOrder(affectedGroupKeys: touchedEffectiveKeys)
            }
        }

        setState { $0.running = false }
        onProgress(state)
    }

    enum AddSingleResult: Equatable {
        case added
        case movedOrRenamed
        case alreadyInLibrary
        case fileNotFound
        case unsupportedFormat
    }

    @discardableResult
    func addSingle(url: URL, libraryRoots: [String]) -> AddSingleResult {
        queue.sync {
            let fm = FileManager.default
            let fp = url.path
            guard fm.fileExists(atPath: fp) else { return .fileNotFound }
            guard supported.contains(url.pathExtension.lowercased()) else { return .unsupportedFormat }
            let knownPaths = db.knownPaths()
            guard !knownPaths.contains(fp) else { return .alreadyInLibrary }
            let hash = fileHash(fp)
            // A hash match against a known comic could mean two things: a genuine duplicate file
            // (the original is still where it was), or this IS the original, just renamed/moved
            // by Finder -- the file watcher reports that as a new path with no matching "removed"
            // linkage. Mirrors _scan()'s disambiguation: a move/rename updates the existing row in
            // place, but a genuine duplicate (the original path still exists) falls through to the
            // normal insert below instead of being silently dropped -- this exact branch used to
            // just `return` here, meaning any drag-and-dropped or file-watcher-detected file that
            // happened to be byte-identical to an already-known comic (a reprint, a duplicate copy,
            // the same crossover issue filed under two series) was silently never added at all.
            if let h = hash, db.knownHashes().contains(h) {
                if let existingPath = db.path(forHash: h), fm.fileExists(atPath: existingPath) {
                    // Genuine duplicate -- fall through to the insert below so it's actually added
                    // (and becomes visible to Possible Duplicates, like a full rescan would do).
                } else {
                    db.updateFilePath(forHash: h, newPath: fp)
                    return .movedOrRenamed
                }
            }
            if let staleId = db.softDeletedComicId(atPath: fp) {
                ThumbnailCache.shared.evict(staleId)
            }
            let root = matchingRoot(for: fp, in: libraryRoots) ?? libraryRoots.first ?? ""
            let meta = parseMeta(url: url, libraryPath: root)
            // Use batchInsert (ComicInsert), not the narrow 13-field insert(comic:) tuple overload
            // -- that overload silently drops coverMonth/coverDay/alternateNumber/storyArcNumber/
            // seriesGroup/comicInfoIssueNumber/volume/format/hasComicInfo even though parseMeta
            // computes all of them, permanently losing ComicInfo.xml metadata for every
            // drag-and-drop import and every file-watcher-detected new file.
            db.batchInsert([DatabaseManager.ComicInsert(
                title: meta.title, filePath: fp, publisher: meta.publisher,
                character: meta.character, series: meta.series,
                issueNumber: meta.issueNumber, pageCount: pageCount(fp),
                writer: meta.writer, penciller: meta.penciller,
                year: meta.year, storyArc: meta.storyArc,
                languageIso: meta.languageIso, fileHash: hash,
                coverMonth: meta.coverMonth, coverDay: meta.coverDay,
                alternateNumber: meta.alternateNumber, storyArcNumber: meta.storyArcNumber,
                seriesGroup: meta.seriesGroup, comicInfoIssueNumber: meta.comicInfoIssueNumber,
                volume: meta.volume, format: meta.format, hasComicInfo: meta.hasComicInfo,
                comicInfoSeries: meta.comicInfoSeries, comicInfoPublisher: meta.comicInfoPublisher,
                folderSeries: meta.folderSeries, folderPublisher: meta.folderPublisher, folderGroup: meta.folderGroup,
                seriesSource: meta.seriesSource, publisherSource: meta.publisherSource,
                issueNumberSource: meta.issueNumberSource
            )])
            return .added
        }
    }

    /// Returns the ids soft-deleted, if any, so the caller can remove their Spotlight entries --
    /// see `ScanState.removedIds`.
    @discardableResult
    func removeSingle(path: String) -> [Int64] {
        queue.sync {
            let stale = db.stalePaths().filter { $0.path == path }.map(\.id)
            if !stale.isEmpty {
                db.softDelete(stale, reason: "missing")
                stale.forEach { ThumbnailCache.shared.evict($0) }
            }
            return stale
        }
    }

    private func fileHash(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let prefix = fh.readData(ofLength: 65536)
        guard !prefix.isEmpty else { return nil }
        let size = fh.seekToEndOfFile()
        let tailStart = size > 65536 ? size - 65536 : 0
        fh.seek(toFileOffset: tailStart)
        let tail = fh.readDataToEndOfFile()
        var hasher = SHA256()
        hasher.update(data: prefix)
        hasher.update(data: withUnsafeBytes(of: size) { Data($0) })
        hasher.update(data: tail)
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    func pageCount(_ path: String) -> Int {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz":
            guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return 0 }
            return archive.filter { imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }.count
        case "pdf":
            guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
                  let pdf = CGPDFDocument(provider) else { return 0 }
            return pdf.numberOfPages
        case "jpg", "jpeg", "png": return 1
        case "cbr":
            #if os(macOS)
            return cbrPageCount(path)
            #else
            return 0
            #endif
        default: return 0
        }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
    private let imageExts = LibraryScanner.imageExtensions

    #if os(macOS)
    private func cbrPageCount(_ path: String) -> Int {
        guard which("unar") != nil else { return 0 }
        return cbrImageListing(path).count
    }

    private let cbrListingLock = NSLock()
    private var cbrListingCache: [String: [String]] = [:]

    private static let maxCBRSizeBytes: UInt64 = 5 * 1024 * 1024 * 1024

    private func cbrImageListing(_ path: String) -> [String] {
        cbrListingLock.lock()
        if let cached = cbrListingCache[path] { cbrListingLock.unlock(); return cached }
        cbrListingLock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard UInt64(size) <= Self.maxCBRSizeBytes else { return [] }
        guard let lsar = which("lsar") else { return [] }
        let listing = shell(lsar, args: [path])
        let images = listing.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { imageExts.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cbrListingLock.lock()
        if cbrListingCache.count >= 500 { cbrListingCache.removeAll() }
        cbrListingCache[path] = images
        cbrListingLock.unlock()
        return images
    }

    enum CBRConversionError: Error {
        case unarNotFound, notACBR, extractionFailed, noImagesFound, destinationExists, zipWriteFailed
    }

    /// Converts one CBR/RAR archive to a CBZ at the same location, extracting every image (and
    /// any ComicInfo.xml) via the same bundled `unar` CBR reading already depends on elsewhere in
    /// this file, then re-zipping with ZIPFoundation -- reduces the app's own runtime dependency
    /// on unar/lsar being present for that specific file going forward. Runs on `queue` like every
    /// other scan-adjacent archive operation, never on the caller's thread.
    func convertCBRToCBZ(path: String) -> Result<URL, CBRConversionError> {
        let sourceURL = URL(fileURLWithPath: path)
        guard sourceURL.pathExtension.lowercased() == "cbr" else { return .failure(.notACBR) }
        guard let unar = which("unar") else { return .failure(.unarNotFound) }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path])

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

    /// Full pipeline for one comic: convert its CBR to CBZ, point the library record at the new
    /// file (with a fresh hash -- see `updateFilePathAndHash`'s doc comment), then remove the
    /// original .cbr so the library doesn't end up with both.
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

    /// Batch entry point for the "Convert CBR to CBZ" Settings tool -- runs on `queue`, same as
    /// every other archive-touching operation in this file, so it can never race a concurrent scan.
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

    /// The exact field-name set this app's own reader (`comicInfoXML` above) looks for -- writing
    /// back under the same names guarantees a comic ComicArc itself writes then re-scans reads
    /// back identically, which is the write-back feature's core safety requirement. CBZ only (no
    /// RAR write support); a narrow, explicitly-listed field set deliberately smaller than every
    /// field this app tracks -- only the identity fields that map cleanly onto the standard
    /// schema, not app-only concepts like ratings/tags/reading-order overrides.
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
        // Preserves every field this app doesn't manage (Summary, Notes, Web, LanguageISO, etc.)
        // untouched if a ComicInfo.xml already exists; starts fresh only if there was none.
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
    #endif

    private struct ComicMeta {
        var title: String; var publisher: String; var character: String?
        var series: String; var issueNumber: String?; var writer: String?
        var penciller: String?; var year: Int?; var coverMonth: Int?; var coverDay: Int?
        var storyArc: String?; var languageIso: String?
        var alternateNumber: String?; var storyArcNumber: String?; var seriesGroup: String?
        var comicInfoIssueNumber: String?
        var volume: String?
        var format: String?
        var hasComicInfo: Bool
        var comicInfoSeries: String?
        var comicInfoPublisher: String?
        var folderSeries: String?
        var folderPublisher: String?
        var folderGroup: String?
        var seriesSource: String
        var publisherSource: String
        var issueNumberSource: String
    }

    /// One-time, post-upgrade pass over comics that predate the raw-fact mirror columns: reopens
    /// each one's archive to see what its ComicInfo.xml actually says, records it as a raw fact
    /// (comicinfo_series/comicinfo_publisher) regardless of the outcome, and flags a review
    /// conflict if it genuinely disagrees with what the file's series/publisher already are (the
    /// same disagreement rule `batchInsert` uses going forward, via
    /// `DatabaseManager.detectMetadataConflict`). Scoped to `has_comicinfo = 1` rows only -- well
    /// under 1% of a real library per the same rarity this scanner already assumes elsewhere --
    /// so reopening archives here is bounded, not a full-library rescan. Self-gated so it only
    /// ever does real work once per install; piggybacks on the next scan instead of adding a
    /// separate blocking step to app launch.
    func runImportPriorityAudit() {
        guard !db.hasCompletedImportPriorityAudit() else { return }
        let pending = db.pendingImportPriorityAuditPaths()
        guard !pending.isEmpty else {
            db.markImportPriorityAuditComplete()
            return
        }

        let currentValues = db.identitySnapshots(for: pending.map(\.id))
        var mirrorUpdates: [(id: Int64, comicInfoSeries: String?, comicInfoPublisher: String?)] = []
        var conflicts: [DatabaseManager.MetadataConflictInput] = []

        for (id, path) in pending {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let ci = comicInfoXML(url: URL(fileURLWithPath: path))
            let comicInfoSeries = ci["Series"].map(normalizeSeriesName)
            let comicInfoPublisher = ci["Publisher"].map(normalizePublisher)
            mirrorUpdates.append((id, comicInfoSeries, comicInfoPublisher))

            guard let current = currentValues[id], !current.metaEdited else { continue }
            if let conflict = DatabaseManager.detectMetadataConflict(
                field: "series", current: current.series, proposed: comicInfoSeries,
                source: "ComicInfo.xml", comicId: id
            ) {
                conflicts.append(conflict)
            }
            if let conflict = DatabaseManager.detectMetadataConflict(
                field: "publisher", current: current.publisher, proposed: comicInfoPublisher,
                source: "ComicInfo.xml", comicId: id
            ) {
                conflicts.append(conflict)
            }
        }

        db.updateComicInfoMirrors(mirrorUpdates)
        if !conflicts.isEmpty { db.upsertMetadataConflicts(conflicts) }
        db.markImportPriorityAuditComplete()
    }

    private func parseMeta(url: URL, libraryPath: String) -> ComicMeta {
        let ci = comicInfoXML(url: url)
        let filename = url.deletingPathExtension().lastPathComponent
        let (folderPublisher, folderCharacter, folderGroup, folderSeries) = folderComponents(url: url, libraryPath: libraryPath)
        let comicInfoSeries = ci["Series"].map(normalizeSeriesName)
        let comicInfoPublisher = ci["Publisher"].map(normalizePublisher)

        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: comicInfoSeries, comicInfoPublisher: comicInfoPublisher,
            comicInfoIssueNumber: ci["IssueNumber"],
            folderSeries: folderSeries, folderPublisher: folderPublisher,
            filenameIssueNumber: extractIssueNumber(from: filename)
        ))

        let character: String?
        if let fc = folderCharacter { character = fc }
        else if let c = ci["Characters"], isCleanCharacterName(c) { character = c }
        else { character = nil }

        let title = filename

        let year = ci["Year"].flatMap(Int.init) ?? extractYear(from: filename)
        let month = year != nil ? ci["Month"].flatMap(Int.init).flatMap { (1...12).contains($0) ? $0 : nil } : nil
        let day = month != nil ? ci["Day"].flatMap(Int.init).flatMap { (1...31).contains($0) ? $0 : nil } : nil
        return ComicMeta(title: title, publisher: resolved.publisher, character: character,
                         series: resolved.series, issueNumber: resolved.issueNumber,
                         writer: ci["Writer"], penciller: ci["Penciller"],
                         year: year, coverMonth: month, coverDay: day,
                         storyArc: ci["StoryArc"], languageIso: ci["LanguageISO"],
                         alternateNumber: ci["AlternateNumber"], storyArcNumber: ci["StoryArcNumber"],
                         seriesGroup: ci["SeriesGroup"].map(normalizeSeriesName),
                         comicInfoIssueNumber: ci["IssueNumber"],
                         volume: ci["Volume"], format: ci["Format"],
                         hasComicInfo: !ci.isEmpty,
                         comicInfoSeries: comicInfoSeries, comicInfoPublisher: comicInfoPublisher,
                         folderSeries: folderSeries, folderPublisher: folderPublisher, folderGroup: folderGroup,
                         seriesSource: resolved.seriesSource, publisherSource: resolved.publisherSource,
                         issueNumberSource: resolved.issueNumberSource)
    }

    /// `group` is whatever folder(s) sit between the Character folder and the Series folder
    /// itself -- e.g. "Batman (Modern)" in `DC/Batman/Batman (Modern)/Batman (2016)/file.cbz`.
    /// Previously silently discarded (only the first, second, and last folder mattered), so a
    /// 4th level a user built to group volumes/eras existed on disk but was invisible everywhere
    /// in the app. Multiple in-between folders (5+ levels deep) are joined with " / ", though
    /// that's a rare, unusual layout -- nil for the much more common 1-3 level case.
    func folderComponents(url: URL, libraryPath: String) -> (publisher: String?, character: String?, group: String?, series: String?) {
        let libURL = URL(fileURLWithPath: libraryPath).standardized

        let libPrefix = libURL.path.hasSuffix("/") ? libURL.path : libURL.path + "/"
        let dirURL = url.standardized.deletingLastPathComponent()
        var folders: [String] = []
        var cur = dirURL
        while cur.standardized.path.hasPrefix(libPrefix) && cur.standardized != libURL {
            folders.insert(cur.lastPathComponent, at: 0)
            cur = cur.deletingLastPathComponent()
        }
        switch folders.count {
        case 0: return (nil, nil, nil, nil)
        case 1: return (nil, nil, nil, folders[0])
        case 2: return (normalizePublisher(folders[0]), nil, nil, folders[1])
        case 3:
            return (normalizePublisher(folders[0]), folders[1], nil, folders[2])
        default:
            let group = folders[2..<(folders.count - 1)].joined(separator: " / ")
            return (normalizePublisher(folders[0]), folders[1], group, folders[folders.count - 1])
        }
    }

    private func isCleanCharacterName(_ name: String) -> Bool {
        !name.contains(",") && !name.contains("[") && !name.contains("(") && name.count <= 60
    }

    func rehashAll() {
        let comics = DatabaseManager.shared.allComicPaths()
        for (id, path) in comics {
            guard let hash = fileHash(path) else { continue }
            DatabaseManager.shared.updateFileHash(id: id, hash: hash)
        }
    }

    func reparseAllMeta(libraryRoots: [String]) {
        let comics = DatabaseManager.shared.allComicPaths()
        var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)] = []
        for (id, path) in comics {
            let url = URL(fileURLWithPath: path)
            let root = matchingRoot(for: path, in: libraryRoots) ?? ""
            let (pub, char, group, ser) = folderComponents(url: url, libraryPath: root)
            let filename = url.deletingPathExtension().lastPathComponent
            updates.append((id, pub, char, ser, filename, extractIssueNumber(from: filename), extractYear(from: filename), group))
        }
        DatabaseManager.shared.batchUpdateFolderMeta(updates)
        DatabaseManager.shared.resetScanRetryCounts()
    }

    /// A real ComicInfo.xml is a few KB at most -- this caps decompression at 5MB, generous
    /// headroom over any legitimate file, so a crafted or corrupted entry that claims a tiny
    /// compressed size but a huge uncompressed one can't be used to exhaust memory during an
    /// ordinary scan (this runs on every CBZ found, unconditionally, no user action needed).
    private static let maxComicInfoXMLSizeBytes: UInt64 = 5 * 1024 * 1024

    private func comicInfoXML(url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "cbz",
              let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }),
              entry.uncompressedSize <= Self.maxComicInfoXMLSizeBytes else { return [:] }
        var data = Data()
        _ = try? archive.extract(entry, consumer: { data.append($0) })
        let keys: Set<String> = ["Series", "Title", "IssueNumber", "Publisher", "Writer", "Penciller",
                                  "Year", "Month", "Day", "StoryArc", "LanguageISO", "Characters",
                                  "AlternateNumber", "StoryArcNumber", "SeriesGroup", "Volume", "Format"]
#if os(macOS)
        guard let root = try? XMLDocument(data: data).rootElement() else { return [:] }
        var result: [String: String] = [:]
        for key in keys {
            if let val = root.elements(forName: key).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty { result[key] = val }
        }
        return result
#else
        let delegate = _ComicInfoXMLParser(keys: keys)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
#endif
    }

    private static let issuePatterns: [NSRegularExpression] = [
        "#(\\d+(?:\\.\\d+)?)", "(?:^|\\s|_)(\\d{1,4})(?:\\s|_|$)",
        "(?:issue|iss|no\\.?)\\s*(\\d+)", "v\\d+\\s*#(\\d+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private func extractIssueNumber(from filename: String) -> String? {
        for regex in Self.issuePatterns {
            if let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
               let range = Range(match.range(at: 1), in: filename) { return String(filename[range]) }
        }
        return nil
    }

    // Matches a "(YYYY)" or "(YYYY-)" (ongoing series) year annotation anywhere in the filename,
    // e.g. "The_Amazing_Spider-Man_(2014)_Issue_#10" or "The_Amazing_Spider-Man_(2015-)_#1-4".
    private static let yearPattern = try? NSRegularExpression(pattern: #"\((19|20)(\d{2})-?\)"#)

    /// Fallback for the overwhelming majority of real libraries that have no ComicInfo.xml at all
    /// (confirmed: <1% of comics in a real 1900+ issue library had it) -- without this, `year` is
    /// simply never populated for those files even though the year is often sitting right in the
    /// filename already, which starves GCD matching of its single strongest disambiguating signal
    /// (used to break ties between same-named volumes/restarts, e.g. two different real runs both
    /// dumped in one loosely-organized folder with low, overlapping issue numbers).
    func extractYear(from filename: String) -> Int? {
        guard let regex = Self.yearPattern,
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let centuryRange = Range(match.range(at: 1), in: filename),
              let yearRange = Range(match.range(at: 2), in: filename)
        else { return nil }
        return Int(filename[centuryRange] + filename[yearRange])
    }

    private func normalizePublisher(_ raw: String) -> String {
        let map = ["dc": "DC", "marvel": "Marvel", "image": "Image", "dark horse": "Dark Horse",
                   "idw": "IDW", "boom": "BOOM!", "dynamite": "Dynamite"]
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return map[lower] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSeriesName(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }

    #if os(macOS)
    private let whichLock = NSLock()
    private var whichCache: [String: String?] = [:]

    func which(_ name: String) -> String? {
        whichLock.lock()
        if let cached = whichCache[name] { whichLock.unlock(); return cached }
        whichLock.unlock()
        let resolved = resolveWhich(name)
        whichLock.lock(); whichCache[name] = resolved; whichLock.unlock()
        return resolved
    }

    private func resolveWhich(_ name: String) -> String? {
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(name).path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        let brewPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let found = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) { return found }
        let result = shell("/usr/bin/which", args: [name])
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    @discardableResult
    func shell(_ executable: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()

        activeProcessLock.lock()
        activeProcess = proc
        activeProcessLock.unlock()
        defer { activeProcessLock.lock(); activeProcess = nil; activeProcessLock.unlock() }

        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private let activeProcessLock = NSLock()
    private var activeProcess: Process?

    func terminateActiveProcess() {
        activeProcessLock.lock()
        let proc = activeProcess
        activeProcessLock.unlock()
        if proc?.isRunning == true { proc?.terminate() }
    }
    #endif

    func page(path: String, index: Int) -> PlatformImage? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz": return cbzPage(path: path, index: index)
        case "pdf": return pdfPage(path: path, index: index)
        case "jpg", "jpeg", "png": return index == 0 ? PlatformImage.fromFile(path) : nil
        case "cbr":
            #if os(macOS)
            return cbrPage(path: path, index: index)
            #else
            return nil
            #endif
        default: return nil
        }
    }

    /// Same cap already used by ThumbnailCache for cover extraction -- generous enough for even a
    /// high-DPI scanned page, but bounds how much a single crafted/corrupted entry can force this
    /// to decompress into memory when a user opens or the app prefetches that comic.
    private static let maxPageSizeBytes: UInt64 = 50 * 1024 * 1024

    private func cbzPage(path: String, index: Int) -> PlatformImage? {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return nil }
        let images = archive
            .filter { imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard index < images.count, images[index].uncompressedSize <= Self.maxPageSizeBytes else { return nil }
        var data = Data()
        _ = try? archive.extract(images[index], consumer: { data.append($0) })
        return PlatformImage.fromData(data)
    }

    private func pdfPage(path: String, index: Int) -> PlatformImage? {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let pdf = CGPDFDocument(provider),
              index < pdf.numberOfPages,
              let page = pdf.page(at: index + 1) else { return nil }
        return PlatformImage.renderPDFPage(page, scale: 1.5)
    }

    #if os(macOS)
    private func cbrPage(path: String, index: Int) -> PlatformImage? {
        guard let unar = which("unar") else { return nil }
        let images = cbrImageListing(path)
        guard index < images.count else { return nil }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path, "--", images[index]])
        let enumerator = FileManager.default.enumerator(atPath: tmpDir.path)
        while let file = enumerator?.nextObject() as? String {
            if imageExts.contains(URL(fileURLWithPath: file).pathExtension.lowercased()) {
                return PlatformImage.fromFile(tmpDir.appendingPathComponent(file).path)
            }
        }
        return nil
    }
    #endif
}

#if !os(macOS)
private final class _ComicInfoXMLParser: NSObject, XMLParserDelegate {
    let keys: Set<String>
    var result: [String: String] = [:]
    private var currentElement: String?
    private var currentText = ""

    init(keys: Set<String>) { self.keys = keys }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if keys.contains(elementName) {
            currentElement = elementName
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if let key = currentElement, key == elementName {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[key] = trimmed }
            currentElement = nil
        }
    }
}
#endif
