import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.comicarc", category: "scanner")

struct ScanSummary: Sendable {
    var added = 0, moved = 0, missing = 0, recovered = 0, unreadable = 0
    var removedIDs: [Int64] = []
    var warning: String?
    var changed: Bool { added > 0 || moved > 0 || missing > 0 || recovered > 0 }
}

enum AddResult: Sendable { case added(Int64), alreadyInLibrary, moved, unsupported, missing }

/// Finds comics in the library folders and keeps the database in step with the files on disk.
/// A file's identity is a hash of its first and last 64 KB plus its size, so moving or renaming a
/// file keeps its reading progress, tags and Reading Path entries.
actor LibraryScanner {
    static let shared = LibraryScanner()
    private let db = Database.shared
    private var cancelled = false

    func cancel() { cancelled = true }

    /// Scans every reachable root. `progress` receives (done, total).
    func scan(roots: [String], progress: @escaping @Sendable (Int, Int) -> Void) async -> ScanSummary {
        cancelled = false
        var summary = ScanSummary()
        let fm = FileManager.default
        let reachable = roots.filter { fm.fileExists(atPath: $0) }
        guard !reachable.isEmpty else {
            summary.warning = roots.isEmpty ? nil : "Your library folder isn't available. If it's on an external drive, connect it and scan again."
            return summary
        }

        let files = reachable.flatMap(Self.comicFiles)
        progress(0, files.count)
        let known = (try? db.readSync { db in
            try db.query("SELECT id, file_path, file_hash, deleted_at IS NOT NULL FROM comics") {
                (id: $0.int64(0), path: $0.string(1) ?? "", hash: $0.string(2), deleted: $0.bool(3))
            }
        }) ?? []
        let livePaths = Set(known.filter { !$0.deleted }.map(\.path))
        let deletedPaths = Set(known.filter(\.deleted).map(\.path))
        // Live rows win over soft-deleted ones with the same fingerprint, so a missing comic that
        // reappears elsewhere is revived with its progress instead of added as a new comic.
        var byHash: [String: (id: Int64, path: String)] = [:]
        for k in known where k.deleted { if let h = k.hash { byHash[h] = (k.id, k.path) } }
        for k in known where !k.deleted { if let h = k.hash { byHash[h] = (k.id, k.path) } }

        var inserts: [Insert] = []
        var moves: [(id: Int64, url: URL)] = []
        for (i, url) in files.enumerated() {
            if cancelled { break }
            let path = url.path
            if !livePaths.contains(path) {
                let hash = Self.fingerprint(path)
                // A soft-deleted row at this exact path is revived by the insert below.
                if !deletedPaths.contains(path), let hash, let existing = byHash[hash], existing.path != path,
                   !fm.fileExists(atPath: existing.path) {
                    moves.append((existing.id, url))
                    byHash[hash] = (existing.id, path)
                } else {
                    let root = Self.root(for: path, in: reachable) ?? reachable[0]
                    inserts.append(Insert(path: path, hash: hash, meta: ComicMetadata.parse(url: url, libraryRoot: root),
                                          pages: Documents.pageCount(path)))
                    if inserts.count >= 100 { summary.added += flush(&inserts) }
                }
            }
            if i % 50 == 0 { progress(i + 1, files.count) }
        }
        summary.added += flush(&inserts)
        if !moves.isEmpty { summary.moved = applyMoves(moves, roots: reachable) }

        if !cancelled { markMissing(roots: roots, reachable: reachable, summary: &summary) }
        if !cancelled { retryUnreadable(&summary) }
        try? db.writeSync { try Database.seedPositions($0) }
        progress(files.count, files.count)
        if summary.changed { db.refreshBackup() }
        log.info("Scan: +\(summary.added) moved \(summary.moved) missing \(summary.missing)")
        return summary
    }

    /// Adds one file (drag and drop, Open, Services). Files outside the library folders are
    /// added where they are.
    func add(_ url: URL, roots: [String]) -> AddResult {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard Documents.libraryExtensions.contains(url.pathExtension.lowercased()) else { return .unsupported }
        let existing = try? db.readSync { db in
            try db.first("SELECT id, deleted_at IS NOT NULL FROM comics WHERE file_path = ?", [path]) { ($0.int64(0), $0.bool(1)) }
        }
        if let existing = existing ?? nil, !existing.1 { return .alreadyInLibrary }
        let hash = Self.fingerprint(path)
        let match = hash.flatMap { hash in
            (try? db.readSync { db in
                try db.first("SELECT id, file_path FROM comics WHERE file_hash = ? AND deleted_at IS NULL", [hash]) { ($0.int64(0), $0.string(1) ?? "") }
            }) ?? nil
        }
        if let match, !FileManager.default.fileExists(atPath: match.1) {
            _ = applyMoves([(match.0, url)], roots: roots)
            return .moved
        }
        let root = Self.root(for: path, in: roots) ?? ""
        var batch = [Insert(path: path, hash: hash, meta: ComicMetadata.parse(url: url, libraryRoot: root),
                            pages: Documents.pageCount(path))]
        _ = flush(&batch)
        try? db.writeSync { try Database.seedPositions($0) }
        let id = (try? db.readSync { try $0.first("SELECT id FROM comics WHERE file_path = ?", [path]) { $0.int64(0) } }) ?? nil
        return id.map { .added($0) } ?? .missing
    }

    /// Re-derives series, publisher, character and issue number for every comic from its folder,
    /// filename and stored ComicInfo.xml values (skipping comics edited by hand), then rescans.
    func resync(roots: [String], progress: @escaping @Sendable (Int, Int) -> Void) async -> ScanSummary {
        let rows = (try? db.readSync { db in
            try db.query("SELECT id, file_path, comicinfo_series, comicinfo_publisher, comicinfo_issue_number FROM comics WHERE deleted_at IS NULL AND meta_edited = 0") {
                (id: $0.int64(0), path: $0.string(1) ?? "", ciSeries: $0.string(2), ciPublisher: $0.string(3), ciIssue: $0.string(4))
            }
        }) ?? []
        let updates = rows.map { r -> [SQLBindable?] in
            let url = URL(fileURLWithPath: r.path)
            let folders = ComicMetadata.folderComponents(of: url, root: Self.root(for: r.path, in: roots) ?? "")
            let name = url.deletingPathExtension().lastPathComponent
            return [r.ciPublisher ?? folders.publisher ?? "Unknown", folders.character, r.ciSeries ?? folders.series ?? "General",
                    folders.group, name, r.ciIssue ?? ComicMetadata.issueNumber(in: name), ComicMetadata.year(in: name),
                    folders.series, folders.publisher, r.id]
        }
        try? db.writeSync { db in
            try db.transaction {
                try db.runBatch("""
                    UPDATE comics SET publisher = ?, character = ?, series = ?, folder_group = ?, title = ?,
                        issue_number = ?, year = COALESCE(year, ?), folder_series = ?, folder_publisher = ?,
                        scan_retry_count = 0 WHERE id = ?
                    """, updates)
                try db.run("UPDATE comics SET position = NULL WHERE id NOT IN (SELECT comic_id FROM reading_order_overrides)")
                try db.run("UPDATE comics SET position = (SELECT position FROM reading_order_overrides o WHERE o.comic_id = comics.id) WHERE id IN (SELECT comic_id FROM reading_order_overrides)")
                try Database.seedPositions(db)
            }
        }
        return await scan(roots: roots, progress: progress)
    }

    // MARK: - Steps

    private struct Insert { let path: String; let hash: String?; let meta: ParsedComic; let pages: Int }

    /// Inserts new comics. A soft-deleted row at the same path is revived instead, keeping its
    /// progress, tags and path entries.
    private func flush(_ batch: inout [Insert]) -> Int {
        guard !batch.isEmpty else { return 0 }
        defer { batch.removeAll() }
        let rows: [[SQLBindable?]] = batch.map { i in
            let m = i.meta
            return [m.title, i.path, m.publisher, m.character, m.series, m.issueNumber, i.pages, m.writer, m.penciller,
                    m.year, m.storyArc, m.languageISO, i.hash, m.month, m.day, m.alternateNumber, m.storyArcNumber,
                    m.seriesGroup, m.comicInfoIssueNumber, m.volume, m.format, m.hasComicInfo, m.comicInfoSeries,
                    m.comicInfoPublisher, m.folderSeries, m.folderPublisher, m.folderGroup]
        }
        do {
            try db.writeSync { db in
                try db.transaction {
                    try db.runBatch("""
                        INSERT INTO comics (title, file_path, publisher, character, series, issue_number, page_count, writer,
                            penciller, year, story_arc, language_iso, file_hash, cover_month, cover_day, alternate_number,
                            story_arc_number, series_group, comicinfo_issue_number, volume, format, has_comicinfo,
                            comicinfo_series, comicinfo_publisher, folder_series, folder_publisher, folder_group)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(file_path) DO UPDATE SET deleted_at = NULL, deleted_reason = NULL,
                            trashed_file_path = NULL, page_count = excluded.page_count, file_hash = excluded.file_hash
                        """, rows)
                }
            }
        } catch {
            log.error("Insert failed: \(String(describing: error))")
            return 0
        }
        return rows.count
    }

    /// Points moved/renamed comics at their new paths and refreshes folder-derived metadata
    /// (unless edited by hand). Manual issue order is kept.
    private func applyMoves(_ moves: [(id: Int64, url: URL)], roots: [String]) -> Int {
        let rows = moves.map { m -> [SQLBindable?] in
            let folders = ComicMetadata.folderComponents(of: m.url, root: Self.root(for: m.url.path, in: roots) ?? "")
            let name = m.url.deletingPathExtension().lastPathComponent
            return [m.url.path, folders.publisher, folders.character, folders.series, folders.group, name,
                    ComicMetadata.issueNumber(in: name), ComicMetadata.year(in: name), m.id]
        }
        try? db.writeSync { db in
            try db.transaction {
                for r in rows {
                    try db.run("""
                        UPDATE comics SET file_path = ?, deleted_at = NULL, deleted_reason = NULL, trashed_file_path = NULL
                        WHERE id = ?
                        """, [r[0], r[8]])
                    try db.run("""
                        UPDATE comics SET publisher = COALESCE(comicinfo_publisher, ?, publisher), character = ?,
                            series = COALESCE(comicinfo_series, ?, series), folder_group = ?, title = ?,
                            issue_number = COALESCE(comicinfo_issue_number, ?), year = COALESCE(year, ?),
                            position = (SELECT position FROM reading_order_overrides WHERE comic_id = comics.id)
                        WHERE id = ? AND meta_edited = 0
                        """, Array(r[1...8]))
                }
                try Database.seedPositions(db)
            }
        }
        return rows.count
    }

    /// Soft-deletes comics whose files are gone, but only under roots that are reachable, and not
    /// when most of the library vanished at once (usually a drive that hasn't woken up).
    private func markMissing(roots: [String], reachable: [String], summary: inout ScanSummary) {
        let fm = FileManager.default
        let live = (try? db.readSync { db in
            try db.query("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") { ($0.int64(0), $0.string(1) ?? "") }
        }) ?? []
        let checkable = live.filter { item in Self.root(for: item.1, in: roots).map(reachable.contains) ?? false }
        let gone = checkable.filter { !fm.fileExists(atPath: $0.1) }.map(\.0)
        guard !gone.isEmpty else { return }
        if checkable.count >= 20 && gone.count > checkable.count / 2 {
            summary.warning = "\(gone.count) comics looked missing, so nothing was removed. This usually means a drive was slow to connect. Scan again once it's available."
            return
        }
        try? db.writeSync { db in
            try db.transaction {
                for id in gone { try db.run("UPDATE comics SET deleted_at = datetime('now'), deleted_reason = 'missing' WHERE id = ?", [id]) }
            }
        }
        summary.missing = gone.count
        summary.removedIDs = gone
    }

    /// Gives unreadable (zero-page) files another try, up to three scans.
    private func retryUnreadable(_ summary: inout ScanSummary) {
        let rows = (try? db.readSync { db in
            try db.query("SELECT id, file_path FROM comics WHERE deleted_at IS NULL AND page_count = 0 AND scan_retry_count < 3") {
                ($0.int64(0), $0.string(1) ?? "")
            }
        }) ?? []
        for (id, path) in rows {
            let pages = Documents.pageCount(path)
            _ = try? db.writeSync { db in
                if pages > 0 { try db.run("UPDATE comics SET page_count = ? WHERE id = ?", [pages, id]) }
                else { try db.run("UPDATE comics SET scan_retry_count = scan_retry_count + 1 WHERE id = ?", [id]) }
            }
            if pages > 0 { summary.recovered += 1 } else { summary.unreadable += 1 }
        }
    }

    // MARK: - Helpers

    static func comicFiles(in root: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where Documents.libraryExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url.standardizedFileURL)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The configured root that contains `path` (longest match).
    static func root(for path: String, in roots: [String]) -> String? {
        roots.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }

    /// SHA-256 of the first and last 64 KB plus the size. Unchanged from earlier versions, so
    /// stored fingerprints stay valid.
    static func fingerprint(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 65536)
        guard !head.isEmpty else { return nil }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 65536 ? size - 65536 : 0)
        let tail = fh.readDataToEndOfFile()
        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: withUnsafeBytes(of: size) { Data($0) })
        hasher.update(data: tail)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
