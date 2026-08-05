import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    let queue = DispatchQueue(label: "com.comicarc.mac.db", qos: .userInitiated)
    var db: OpaquePointer?

    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ComicArc")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    convenience init() {
        self.init(dbPath: Self.dataDir.appendingPathComponent("comics.db").path)
    }

    init(dbPath path: String) {
        let dbURL = URL(fileURLWithPath: path)
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000")
        exec("PRAGMA journal_size_limit = 67108864")
        exec("PRAGMA mmap_size = 268435456")
        registerCustomFunctions()
        recoverIfCorrupted(dbURL: dbURL)
        migrate()
        // Backup freshness doesn't gate query correctness the way the integrity check above
        // does (queries are safe to run against this file regardless of when it was last backed
        // up) -- deferred onto a background queue so a full WAL checkpoint + file copy can't
        // block app launch on a large library or a slow disk. Must NOT use `self.queue` here:
        // refreshBackup() itself calls `queue.sync`, and dispatching it via `queue.async` would
        // mean that sync call re-enters a queue already running on the current thread --
        // `libdispatch` detects that and crashes outright rather than deadlocking silently.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshBackup() }
    }

    func registerCustomFunctions() {
        let deterministicUTF8 = Int32(SQLITE_UTF8) | Int32(SQLITE_DETERMINISTIC)

        sqlite3_create_function_v2(db, "is_special_issue", 3, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 3 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let special = ComicSortClassifier.isSpecialIssue(issueNumber: text(0), title: text(1), series: text(2))
            sqlite3_result_int(context, special ? 1 : 0)
        }, nil, nil, nil)

        sqlite3_create_function_v2(db, "comic_type", 4, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 4 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let type = ReadingOrderEngine.classify(issueNumber: text(0), title: text(1), series: text(2), format: text(3))
            sqlite3_result_text(context, type.rawValue, -1, SQLITE_TRANSIENT)
        }, nil, nil, nil)
    }

    func recoverIfCorrupted(dbURL: URL) {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &raw, nil) == SQLITE_OK,
              let stmt = raw else { return }
        defer { sqlite3_finalize(stmt) }
        var ok = false
        if sqlite3_step(stmt) == SQLITE_ROW,
           let p = sqlite3_column_text(stmt, 0),
           String(cString: p) == "ok" { ok = true }
        guard !ok else { return }

        let bakURL = Self.dataDir.appendingPathComponent("comics.db.bak")
        guard FileManager.default.fileExists(atPath: bakURL.path) else { return }
        sqlite3_close(db); db = nil
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.copyItem(at: bakURL, to: dbURL)
        _ = sqlite3_open(dbURL.path, &db)
        // PRAGMAs are per-connection, not persisted in the file -- this is a brand new
        // connection, so foreign_keys/journal_mode/etc. default back off/unset unless
        // reapplied here. Without this, every ON DELETE CASCADE in the schema silently
        // stops firing for the rest of the app session after a corruption recovery.
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000")
        exec("PRAGMA journal_size_limit = 67108864")
        exec("PRAGMA mmap_size = 268435456")
        registerCustomFunctions()
    }

    func checkpoint() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func checkpointAndClose() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            sqlite3_close(db)
            db = nil
        }
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func scalarInt(_ sql: String, args: [Any?] = []) -> Int {
        guard db != nil else { return 0 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func scalarText(_ sql: String, args: [Any?] = []) -> String? {
        guard db != nil else { return nil }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              let p = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: p)
    }

    func rows<T>(_ sql: String, args: [Any?] = [], map: (OpaquePointer) -> T) -> [T] {
        guard db != nil else { return [] }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(map(stmt)) }
        return results
    }

    func colText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
    func colInt(_ stmt: OpaquePointer, _ col: Int32) -> Int { Int(sqlite3_column_int(stmt, col)) }
    func colInt64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

    /// A caller (LibraryScanner, most commonly) can compute an affected group key before a
    /// backfill (Volume from a GCD match, series_group edit, etc.) has run -- if the row had no
    /// value yet, that key is a bare "publisher:series" with no volume/series_group component.
    /// Once the backfill lands, the row's real composite groupKey gains a suffix the caller's
    /// bare key never had, silently dropping it from a scoped WHERE ... IN filter. Expand every
    /// bare key to every real composite groupKey currently sharing that publisher/series so
    /// scoped recomputes (`recomputeReadingOrder`, `recomputeGCDMatches`) never miss a row purely
    /// because the caller's key predates a backfill.
    func expandBareGroupKeys(_ keys: Set<String>) -> Set<String> {
        let bareKeys = keys.filter { $0.split(separator: ":", omittingEmptySubsequences: false).count <= 2 }
        guard !bareKeys.isEmpty else { return keys }
        let placeholders = bareKeys.map { _ in "?" }.joined(separator: ",")
        let resolvedKeys: [String] = rows("""
            SELECT DISTINCT publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))
            FROM comics WHERE deleted_at IS NULL AND (publisher || ':' || series) IN (\(placeholders))
            """, args: bareKeys.map { $0 as Any? }) { s in colText(s, 0) ?? "" }
        return keys.union(resolvedKeys)
    }
    func colBool(_ stmt: OpaquePointer, _ col: Int32) -> Bool { sqlite3_column_int(stmt, col) != 0 }

    func bindArgs(_ stmt: OpaquePointer, args: [Any?]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:  sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case let n as Int64:   sqlite3_bind_int64(stmt, idx, n)
            case let n as Int:     sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Double:  sqlite3_bind_double(stmt, idx, n)
            case .none:            sqlite3_bind_null(stmt, idx)
            default:               sqlite3_bind_null(stmt, idx)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, args: [Any?] = []) -> Int64 {
        guard db != nil else { return -1 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return -1 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        // Must actually check the result: silently ignoring a failed step (constraint violation,
        // SQLITE_BUSY, etc.) would fall through to sqlite3_last_insert_rowid, which on failure
        // still returns the *previous* successful insert's rowid -- handing callers a wrong id
        // that looks valid instead of a way to detect the write never happened.
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Runs `body` inside a transaction, rolling back if it returns `false` (e.g. a `run(...)`
    /// call inside it returned -1). Used for batch mutations where a partial failure mid-loop
    /// would otherwise commit inconsistent data with no way to detect it after the fact.
    @discardableResult
    func inTransaction(_ body: () -> Bool) -> Bool {
        exec("BEGIN")
        guard body() else { exec("ROLLBACK"); return false }
        exec("COMMIT")
        return true
    }

    /// Prepares `sql` once and reuses that single compiled statement across every row in
    /// `rows` (reset + re-bound each iteration) instead of calling `run(...)` per row, which
    /// re-parses and re-plans identical SQL text on every iteration. Meant to be called inside
    /// `inTransaction`; returns `false` on the first row that fails to step to completion.
    @discardableResult
    func runBatch(_ sql: String, rows: [[Any?]]) -> Bool {
        guard !rows.isEmpty else { return true }
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return false }
        defer { sqlite3_finalize(s) }
        for args in rows {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            bindArgs(s, args: args)
            guard sqlite3_step(s) == SQLITE_DONE else { return false }
        }
        return true
    }

    /// Splits a large id/path array for use in an `IN (...)` clause -- past SQLite's bound-
    /// parameter ceiling, `sqlite3_prepare_v2` fails and callers that don't check for that
    /// silently no-op on the whole operation. 500 is comfortably under even the old, most
    /// conservative default (999), so a single chunk never risks tripping it.
    func idChunks<T>(_ ids: [T], size: Int = 500) -> [[T]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<Swift.min($0 + size, ids.count)]) }
    }

    /// Refreshes `comics.db.bak`, the snapshot `recoverIfCorrupted` falls back to. Called at
    /// launch (via `migrate()`) and again after a scan/resync completes -- previously this only
    /// ever ran once per launch, so a corruption discovered after a long reading/tagging/rating
    /// session, or right after importing a big batch of new comics, would recover to a backup
    /// that predated all of it. Cheap enough to call again after a scan: a WAL checkpoint plus a
    /// file copy, not a full re-export.
    func refreshBackup() {
        queue.sync {
            let dbPath = Self.dataDir.appendingPathComponent("comics.db")
            let bakPath = Self.dataDir.appendingPathComponent("comics.db.bak")
            guard FileManager.default.fileExists(atPath: dbPath.path) else { return }
            // Checkpoint first so the backup reflects all committed data, not just whatever has
            // landed in the main file so far -- WAL-mode commits can live only in the -wal file
            // for a while, and a prior session that ended without a full checkpoint (killed, not
            // quit normally) would otherwise be missing its most recent writes from this backup.
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            // copyItem throws if the destination already exists -- remove the stale backup first
            // so this snapshot is genuinely replaced each time, not silently left as the very
            // first one ever written.
            try? FileManager.default.removeItem(at: bakPath)
            try? FileManager.default.copyItem(at: dbPath, to: bakPath)
        }
    }

    func comicRow(_ s: OpaquePointer) -> Comic {
        Comic(
            id: colInt64(s, 0), title: colText(s, 1) ?? "", filePath: colText(s, 2) ?? "",
            publisher: colText(s, 3) ?? "Unknown", character: colText(s, 4),
            series: colText(s, 5) ?? "General", issueNumber: colText(s, 6),
            pageCount: colInt(s, 7), writer: colText(s, 8), penciller: colText(s, 9),
            year: sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
            volume: colText(s, 30), format: colText(s, 31),
            storyArc: colText(s, 11), languageIso: colText(s, 12), notes: colText(s, 13),
            addedAt: colText(s, 14) ?? "", deletedAt: colText(s, 15),
            position: colInt(s, 16), fileHash: colText(s, 17),
            progress: colInt(s, 18), lastRead: colText(s, 19),
            rating: colInt(s, 20),
            review: colText(s, 23),
            isFavorite: colBool(s, 21), inReadingList: colBool(s, 22),
            readingOrderPosition: sqlite3_column_type(s, 24) != SQLITE_NULL ? colInt(s, 24) : nil,
            readingOrderConfidence: sqlite3_column_type(s, 25) != SQLITE_NULL ? colInt(s, 25) : nil,
            readingOrderReason: colText(s, 26),
            gcdMatchConfidence: sqlite3_column_type(s, 27) != SQLITE_NULL ? colInt(s, 27) : nil,
            gcdSeriesName: colText(s, 28), gcdIssueNumber: colText(s, 29),
            deletedReason: colText(s, 32)
        )
    }

    let comicSelect = """
        SELECT c.id, c.title, c.file_path, c.publisher, c.character, c.series,
               c.issue_number, c.page_count, c.writer, c.penciller, c.year,
               c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
               COALESCE(c.position, c.id), c.file_hash,
               COALESCE(rp.current_page, 0) as progress, rp.last_read,
               COALESCE(r.rating, 0) as rating,
               (f.comic_id IS NOT NULL) as is_favorite,
               (rl.comic_id IS NOT NULL) as in_reading_list,
               r.review, c.reading_order_position, c.reading_order_confidence, c.reading_order_reason,
               c.gcd_match_confidence, c.gcd_series_name, c.gcd_issue_number, c.volume, c.format,
               c.deleted_reason
        FROM comics c
        LEFT JOIN reading_progress rp ON c.id = rp.comic_id
        LEFT JOIN ratings r           ON c.id = r.comic_id
        LEFT JOIN favorites f         ON c.id = f.comic_id
        LEFT JOIN reading_list rl     ON c.id = rl.comic_id
    """

    enum ReadingOrderMode: String, CaseIterable, Identifiable {
        case filename = "Filename", legacyNumber = "Legacy Number",
             publicationDate = "Publication Date", comicInfoOrder = "ComicInfo Order",
             intelligent = "Intelligent Reading Order"
        var id: String { rawValue }

        static var current: ReadingOrderMode {
            ReadingOrderMode(rawValue: UserDefaults.standard.string(forKey: "readingOrderMode") ?? "") ?? .intelligent
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable, Codable {
        case publisher = "Publisher", title = "Title", dateAdded = "Recently Added",
             rating = "Top Rated", progress = "Most Read", manual = "Custom",
             year = "Year", storyArc = "Story Arc", pageCount = "Page Count",
             dateRead = "Recently Read", writer = "Writer"
        var id: String { rawValue }
        var clause: String {
            switch self {
            case .publisher: return "c.publisher, c.series, COALESCE(c.reading_order_position, c.position, is_special_issue(c.issue_number, c.title, c.series) * \(ComicSortClassifier.specialBandOffset) + c.id), c.title"
            case .title:     return "c.title"
            case .dateAdded: return "c.added_at DESC"
            case .rating:    return "COALESCE(r.rating, 0) DESC, c.title"
            case .progress:  return "COALESCE(rp.current_page, 0) DESC, c.title"
            case .manual:    return "COALESCE(c.reading_order_position, c.position, c.id), c.title"
            case .year:      return "COALESCE(c.year, 0) DESC, c.title"
            case .storyArc:  return "COALESCE(c.story_arc, ''), c.title"
            case .pageCount: return "c.page_count DESC, c.title"
            case .dateRead:  return "COALESCE(rp.last_read, '') DESC, c.title"
            case .writer:    return "COALESCE(c.writer, ''), c.title"
            }
        }
    }

    struct ComicInsert {
        let title: String, filePath: String
        var publisher: String
        let character: String?
        var series: String
        var issueNumber: String?
        let pageCount: Int, writer: String?
        let penciller: String?, year: Int?, storyArc: String?, languageIso: String?, fileHash: String?
        var coverMonth: Int? = nil
        var coverDay: Int? = nil
        var alternateNumber: String? = nil
        var storyArcNumber: String? = nil
        var seriesGroup: String? = nil
        var comicInfoIssueNumber: String? = nil
        var volume: String? = nil
        var format: String? = nil
        var hasComicInfo: Bool? = nil
        /// Raw-fact mirrors: what ComicInfo.xml/the folder actually said, independent of which one
        /// won for the primary series/publisher columns above -- lets a priority decision made at
        /// import time be revisited later instead of being permanently lost. See
        /// `ComicIdentityResolver`.
        var comicInfoSeries: String? = nil
        var comicInfoPublisher: String? = nil
        var folderSeries: String? = nil
        var folderPublisher: String? = nil
        var folderGroup: String? = nil
        /// Which raw-fact source actually won for series/publisher/issueNumber above -- used to
        /// label a metadata conflict with where the proposed value came from (e.g. "ComicInfo.xml"
        /// vs "folder"), not persisted on `comics` itself.
        var seriesSource: String = ComicIdentityResolver.defaultSource
        var publisherSource: String = ComicIdentityResolver.defaultSource
        var issueNumberSource: String = ComicIdentityResolver.defaultSource
    }

    /// The placeholder values the scanner itself writes when a source has nothing real to offer --
    /// never worth protecting as if they were a genuine prior value.
    static let identityPlaceholders: Set<String> = ["general", "unknown"]
}
