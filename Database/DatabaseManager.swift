import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private let queue = DispatchQueue(label: "com.comicarc.mac.db", qos: .userInitiated)
    private var db: OpaquePointer?

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

    /// Not private, unlike the no-arg initializer above — lets tests construct an isolated
    /// instance against a temporary file instead of the real, shared library database.
    /// `DatabaseManager.shared` always goes through the no-arg initializer and the real path;
    /// nothing in the app itself ever calls this directly.
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
    }

    // Registers SQL-callable scalar functions backed by shared Swift logic, so every query
    // (library, series, search, duplicates) agrees on the same "is this a special issue"
    // answer instead of each ORDER BY clause re-implementing its own keyword matching.
    private func registerCustomFunctions() {
        sqlite3_create_function_v2(db, "is_special_issue", 3, SQLITE_UTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 3 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let special = ComicSortClassifier.isSpecialIssue(issueNumber: text(0), title: text(1), series: text(2))
            sqlite3_result_int(context, special ? 1 : 0)
        }, nil, nil, nil)
    }

    // If the DB fails integrity_check, swap in the .bak and reopen.
    // migrate() is idempotent (CREATE IF NOT EXISTS) so it's safe to run on the backup.
    private func recoverIfCorrupted(dbURL: URL) {
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
        registerCustomFunctions()  // lost when the connection was closed and reopened above
    }

    /// Flushes the WAL into the main database file without closing the connection.
    /// Safe to call anytime, including from a state that isn't guaranteed to be a real
    /// shutdown (e.g. iOS backgrounding, which happens constantly during normal use and
    /// is very often followed by returning to the foreground rather than termination).
    /// Reduces the amount of unflushed WAL data at risk if the process is later killed
    /// while suspended, without making the database unusable if the app resumes.
    func checkpoint() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Checkpoints and fully closes the connection. Only for an actual process exit
    /// (macOS quit) — the connection is not reopened automatically, so calling this
    /// anywhere the app might keep running afterward will break every subsequent query.
    func checkpointAndClose() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Low-level helpers

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func scalarInt(_ sql: String, args: [Any?] = []) -> Int {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func rows<T>(_ sql: String, args: [Any?] = [], map: (OpaquePointer) -> T) -> [T] {
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
    func colBool(_ stmt: OpaquePointer, _ col: Int32) -> Bool { sqlite3_column_int(stmt, col) != 0 }

    private func bindArgs(_ stmt: OpaquePointer, args: [Any?]) {
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
    private func run(_ sql: String, args: [Any?] = []) -> Int64 {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return -1 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Schema

    private func migrate() {
        // Backup DB before any migrations so schema changes are reversible
        let dbPath = Self.dataDir.appendingPathComponent("comics.db")
        let bakPath = Self.dataDir.appendingPathComponent("comics.db.bak")
        if FileManager.default.fileExists(atPath: dbPath.path) {
            try? FileManager.default.copyItem(at: dbPath, to: bakPath)
        }
        exec("""
        CREATE TABLE IF NOT EXISTS comics (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            title        TEXT NOT NULL,
            file_path    TEXT UNIQUE NOT NULL,
            publisher    TEXT,
            character    TEXT,
            series       TEXT,
            issue_number TEXT,
            page_count   INTEGER DEFAULT 0,
            added_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            position     INTEGER,
            writer       TEXT,
            penciller    TEXT,
            year         INTEGER,
            story_arc    TEXT,
            language_iso TEXT,
            deleted_at   TIMESTAMP,
            notes        TEXT,
            file_hash    TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_progress (
            comic_id     INTEGER PRIMARY KEY REFERENCES comics(id),
            current_page INTEGER DEFAULT 0,
            last_read    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS ratings (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id),
            rating   INTEGER CHECK(rating BETWEEN 1 AND 5),
            review   TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS favorites (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_list (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tags (
            id   INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS comic_tags (
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            tag_id   INTEGER REFERENCES tags(id)   ON DELETE CASCADE,
            PRIMARY KEY (comic_id, tag_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS runs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            description TEXT,
            rating      INTEGER,
            review      TEXT,
            buy_link    TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS run_items (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id   INTEGER REFERENCES runs(id)   ON DELETE CASCADE,
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            notes    TEXT DEFAULT '',
            UNIQUE(run_id, comic_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS bookmarks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id   INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            page       INTEGER NOT NULL,
            label      TEXT DEFAULT '',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(comic_id, page)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_history (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id   INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            page_start INTEGER NOT NULL DEFAULT 0,
            page_end   INTEGER NOT NULL DEFAULT 0,
            read_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_goals (
            year       INTEGER PRIMARY KEY,
            goal_count INTEGER NOT NULL DEFAULT 52
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS shelves (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT UNIQUE NOT NULL,
            is_builtin INTEGER NOT NULL DEFAULT 0,
            position   INTEGER NOT NULL DEFAULT 0
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS comic_shelves (
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            shelf_id INTEGER REFERENCES shelves(id) ON DELETE CASCADE,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (comic_id, shelf_id)
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_comics_publisher     ON comics(publisher)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_series        ON comics(series)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_pub_series    ON comics(publisher, series) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_deleted       ON comics(deleted_at) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_file_hash     ON comics(file_hash)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_position      ON comics(position) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_rp_last_read         ON reading_progress(last_read DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_rp_comic_id          ON reading_progress(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_character     ON comics(character) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comic_tags_comic_id  ON comic_tags(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_comic_tags_tag_id    ON comic_tags(tag_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_run_items_run_id     ON run_items(run_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_run_items_comic_id   ON run_items(comic_id)")
        exec("""
        CREATE TABLE IF NOT EXISTS series_covers (
            series    TEXT NOT NULL,
            publisher TEXT NOT NULL,
            comic_id  INTEGER REFERENCES comics(id) ON DELETE SET NULL,
            PRIMARY KEY (series, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS series_reader_prefs (
            series        TEXT NOT NULL,
            publisher     TEXT NOT NULL,
            fit_mode      TEXT NOT NULL,
            rtl           INTEGER NOT NULL,
            double_spread INTEGER NOT NULL,
            scroll_mode   INTEGER NOT NULL,
            PRIMARY KEY (series, publisher)
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_read_at    ON reading_history(read_at DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_bookmarks_comic    ON bookmarks(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_comic_shelves      ON comic_shelves(comic_id)")
        exec("""
        CREATE TABLE IF NOT EXISTS character_covers (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            image_path TEXT NOT NULL,
            PRIMARY KEY (group_name, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS series_order (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            series     TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (group_name, publisher, series)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS character_order (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (group_name, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS publisher_order (
            publisher TEXT PRIMARY KEY,
            position  INTEGER NOT NULL DEFAULT 0
        )
        """)

        let builtins = [("Currently Reading", 0), ("Want to Read", 1), ("Finished", 2), ("DNF", 3)]
        for (name, pos) in builtins {
            exec("INSERT OR IGNORE INTO shelves (name, is_builtin, position) VALUES ('\(name)', 1, \(pos))")

        }

        exec("ALTER TABLE comics ADD COLUMN file_hash TEXT")
        exec("ALTER TABLE runs   ADD COLUMN rating INTEGER")
        exec("ALTER TABLE runs   ADD COLUMN review TEXT")
        exec("ALTER TABLE runs   ADD COLUMN buy_link TEXT")
        exec("ALTER TABLE comics ADD COLUMN notes TEXT")
        exec("ALTER TABLE comics ADD COLUMN character TEXT")
        exec("ALTER TABLE comics ADD COLUMN position INTEGER")
        exec("ALTER TABLE comics ADD COLUMN writer TEXT")
        exec("ALTER TABLE comics ADD COLUMN penciller TEXT")
        exec("ALTER TABLE comics ADD COLUMN year INTEGER")
        exec("ALTER TABLE comics ADD COLUMN story_arc TEXT")
        exec("ALTER TABLE comics ADD COLUMN language_iso TEXT")
        exec("ALTER TABLE comics ADD COLUMN deleted_at TIMESTAMP")
        exec("ALTER TABLE comics ADD COLUMN meta_edited INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE comics ADD COLUMN cover_month INTEGER")
        exec("ALTER TABLE runs   ADD COLUMN position INTEGER")
        exec("ALTER TABLE series_covers ADD COLUMN image_path TEXT")
        exec("ALTER TABLE runs   ADD COLUMN cover_image_path TEXT")

        // ReadingOrderEngine columns — kept entirely separate from the existing `position`
        // column rather than replacing it: the default sort reads
        // COALESCE(reading_order_position, position, ...), so the new engine's output is live
        // immediately with no new UI, but a bug in it can never regress the old, still-intact
        // filename/manual-order path, and either can be disabled independently later.
        exec("ALTER TABLE comics ADD COLUMN reading_order_position INTEGER")
        exec("ALTER TABLE comics ADD COLUMN reading_order_confidence INTEGER")
        exec("ALTER TABLE comics ADD COLUMN reading_order_reason TEXT")
        exec("ALTER TABLE comics ADD COLUMN alternate_number TEXT")
        exec("ALTER TABLE comics ADD COLUMN story_arc_number TEXT")
        exec("ALTER TABLE comics ADD COLUMN cover_day INTEGER")
        exec("ALTER TABLE comics ADD COLUMN series_group TEXT")
        exec("""
        CREATE TABLE IF NOT EXISTS reading_order_overrides (
            comic_id   INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
            position   INTEGER NOT NULL,
            reason     TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)

        // Raw ComicInfo.xml <IssueNumber>, captured separately from `issue_number` (which
        // prefers the filename-parsed number, per parseMeta's comment) — needed so the
        // ComicInfo Order reading mode can sort by what the embedded metadata alone says,
        // rather than silently degrading into a duplicate of Legacy Number mode.
        exec("ALTER TABLE comics ADD COLUMN comicinfo_issue_number TEXT")

        // Manual series continuation links (e.g. Amazing Spider-Man #700 -> Superior
        // Spider-Man #1-31 -> Amazing Spider-Man (2014) #1 as one continuous sequence).
        // UNIQUE(child) forces a simple forward chain rather than a graph; sequence_order
        // lets a 3+ series chain be resolved in order.
        exec("""
        CREATE TABLE IF NOT EXISTS series_links (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_publisher TEXT NOT NULL,
            parent_series    TEXT NOT NULL,
            child_publisher  TEXT NOT NULL,
            child_series     TEXT NOT NULL,
            sequence_order   INTEGER NOT NULL,
            created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(child_publisher, child_series)
        )
        """)

        // Mainline issues seed into the low range sorted by issue number (or insertion order
        // as a fallback); annuals/specials/one-shots/etc. seed into a distinct band 1,000,000+
        // above that, so they default to the end of the series instead of interleaving with
        // regular issues just because their issue number happens to collide (e.g. many
        // annuals are numbered "1" same as issue #1 of the ongoing series).
        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        WHERE position IS NULL
        """)

        resortSpecialIssuesIfNeeded()
        widenMainlinePositionStrideIfNeeded()
        positionSpecialsChronologically()
        recomputeReadingOrder()
    }

    // One-time re-seed for libraries that were scanned before special-issue-aware sorting
    // existed: their `position` column is already non-NULL (so the migration above skips
    // them) but was seeded with the old formula that let annuals interleave with regular
    // issues. Recomputes every comic's position with the corrected formula, once, tracked
    // via a marker row so it never re-runs and clobbers a user's later manual reordering.
    private func resortSpecialIssuesIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'specialIssueSortV1'") > 0
        guard !alreadyRun else { return }
        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        """)
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('specialIssueSortV1')")
    }

    // Re-seeds position with a wider stride between mainline issues (100 apart instead of 1)
    // so positionSpecialsChronologically() below has room to interpolate a dated annual
    // between two consecutive issues. Libraries that already ran specialIssueSortV1 before
    // this stride existed would otherwise be stuck on the old dense scheme forever, since
    // that migration never re-runs. One-time and separately gated via its own migration
    // marker — same tradeoff specialIssueSortV1 above already accepted (a blanket re-seed
    // can clobber a manual reorder's dense position values), but it only happens once per
    // library, not on every launch.
    private func widenMainlinePositionStrideIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'positionStride100V1'") > 0
        guard !alreadyRun else { return }
        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        """)
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('positionStride100V1')")
    }

    // migrate()'s NULL-position seeding only covers rows that already existed at app launch —
    // every comic inserted by a scan afterward starts with position = NULL (see _insertRow)
    // and would otherwise stay that way, falling back to COALESCE(position, id) everywhere
    // position is read (roughly insertion order, not special-aware) until the next app
    // restart re-runs migrate(). Called after every scan so newly-imported comics — including
    // any new specials that positionSpecialsChronologically() needs a real position to move —
    // get seeded immediately instead of waiting for a relaunch.
    func seedMissingPositions() {
        queue.sync {
            _ = exec("""
            UPDATE comics SET position =
                is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
            WHERE position IS NULL
            """)
        }
    }

    // Places specials (annual/one-shot/etc., per is_special_issue) somewhere better than
    // "always last" within their series, in two tiers:
    //
    //  Tier 1 — real dates: when a special has both year and cover_month from ComicInfo.xml,
    //  and at least two mainline issues in the same series also have real dates bracketing
    //  it, place it exactly between them (e.g. an Annual cover-dated August 2005 between
    //  Batman #12 (June 2005) and #13 (September 2005)).
    //
    //  Tier 2 — proportional fallback: most real-world libraries have NO ComicInfo.xml at
    //  all (confirmed directly against a real 1478-comic test library: only 10 comics had
    //  any year metadata, zero had month), so tier 1 almost never fires and every annual
    //  across a whole series was still landing dumped at the very end after the highest
    //  mainline issue — not what "chronological where possible" was supposed to mean in
    //  practice. When a special has no date match, but its series does have annual-style
    //  sequential numbering (Annual #1, #2, #3...) and at least 2 mainline issues, spread
    //  the specials proportionally across the mainline issue range by their own sequence
    //  number — Annual #1 of 4 lands about a quarter of the way through the run, #2 about
    //  half way, etc. This is a guess, not a real date, but it's a far better guess than
    //  "every annual after issue #700" and matches how annuals are actually published
    //  (roughly one per year, spread across a series' run) closely enough to be useful.
    //
    // Both tiers respect a manual reorder: reorderComics() collapses a series' positions to
    // a dense 0,1,2... sequence with no headroom, which both tiers' room checks reject —
    // once a user has dragged a series into a custom order, this function leaves it alone
    // rather than fighting it on every scan.
    //
    // Not a one-time migration: called after every scan and metadata refresh so newly-added
    // specials, or specials that just gained real date metadata, keep getting repositioned.
    func positionSpecialsChronologically() {
        queue.sync {
            struct Row { let id: Int64; let seriesKey: String; let special: Bool
                         let year: Int?; let month: Int?; let position: Int }
            var rows: [Row] = []
            let sql = """
            SELECT id, publisher || ':' || series,
                   is_special_issue(issue_number, title, series), year, cover_month,
                   COALESCE(position, id)
            FROM comics WHERE deleted_at IS NULL
            """
            var raw: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return }
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Row(
                    id: sqlite3_column_int64(stmt, 0),
                    seriesKey: String(cString: sqlite3_column_text(stmt, 1)),
                    special: sqlite3_column_int(stmt, 2) != 0,
                    year:  sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil,
                    month: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil,
                    position: Int(sqlite3_column_int64(stmt, 5))
                ))
            }
            sqlite3_finalize(stmt)

            var updates: [(Int64, Int)] = []
            for (_, group) in Dictionary(grouping: rows, by: \.seriesKey) {
                let mainline = group.filter { !$0.special }.sorted { $0.position < $1.position }
                let mainlineDated = mainline.filter { $0.year != nil && $0.month != nil }
                let allSpecials = group.filter { $0.special }

                // Tier 1: real dates
                var placedIds = Set<Int64>()
                if mainlineDated.count >= 2 {
                    for special in allSpecials {
                        guard let y = special.year, let m = special.month else { continue }
                        let specialKey = y * 100 + m
                        guard let afterIdx = mainlineDated.firstIndex(where: { $0.year! * 100 + $0.month! > specialKey }),
                              afterIdx > 0 else { continue }
                        let before = mainlineDated[afterIdx - 1]
                        let after  = mainlineDated[afterIdx]
                        guard after.position - before.position > 1 else { continue }
                        updates.append((special.id, before.position + (after.position - before.position) / 2))
                        placedIds.insert(special.id)
                    }
                }

                // Tier 2: proportional fallback for whatever tier 1 didn't place. Only
                // engages for specials still sitting in the untouched "always last" band
                // (specialBandOffset+) — one already moved by tier 1, or by a manual drag,
                // is left alone.
                guard let minPos = mainline.first?.position, let maxPos = mainline.last?.position,
                      maxPos > minPos, mainline.count >= 2 else { continue }
                let undated = allSpecials
                    .filter { !placedIds.contains($0.id) && $0.position >= ComicSortClassifier.specialBandOffset }
                    .sorted { $0.position < $1.position }
                let n = undated.count
                guard n > 0 else { continue }
                for (idx, special) in undated.enumerated() {
                    let fraction = Double(idx + 1) / Double(n + 1)
                    let target = minPos + Int((Double(maxPos - minPos) * fraction).rounded())
                    updates.append((special.id, target))
                }
            }
            guard !updates.isEmpty else { return }
            exec("BEGIN")
            for (id, pos) in updates {
                _ = run("UPDATE comics SET position = ? WHERE id = ?", args: [pos, id])
            }
            exec("COMMIT")
        }
    }

    // MARK: - Reading Order Engine

    // Drives `comics.reading_order_position` — entirely separate storage from `position`
    // above (see the ALTER TABLE comment in migrate()). Fetches every comic's signals, hands
    // them to the pure ReadingOrderEngine, applies any durable manual override last (locked,
    // skips the engine result), and writes position/confidence/reason back. Called after every
    // scan/resync and once at the end of migrate() — same call sites positionSpecialsChronologically()
    // already uses, left running unchanged alongside this.
    /// `affectedGroupKeys: nil` (every existing call site) recomputes the whole library, same
    /// as before. When provided, only comics whose `publisher:series` groupKey is in the set
    /// are touched — safe because ReadingOrderEngine groups/interpolates strictly within a
    /// groupKey, so narrowing to whole affected groups keeps each one's computation coherent.
    func recomputeReadingOrder(mode: ReadingOrderMode = .current, affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row {
                let id: Int64; let publisher: String; let series: String; let groupKey: String
                let filePath: String; let issueNumber: String?; let comicInfoIssueNumber: String?
                let title: String
                let year: Int?; let month: Int?; let day: Int?; let storyArc: String?
            }

            // A scoped recompute must still see every series in the same link chain as any
            // requested series, or an offset stamped below could be computed against a parent's
            // stale/absent position instead of its real one — so widen the scope to the full
            // chain membership before touching `series_links` (cheap, small table) whenever
            // links exist at all.
            var effectiveKeys = affectedGroupKeys
            if effectiveKeys != nil {
                let allLinkKeys: [String] = rows(
                    "SELECT parent_publisher, parent_series FROM series_links UNION SELECT child_publisher, child_series FROM series_links"
                ) { s in "\(colText(s, 0) ?? ""):\(colText(s, 1) ?? "")" }
                if !allLinkKeys.isEmpty { effectiveKeys!.formUnion(allLinkKeys) }
            }

            var sql = """
            SELECT id, publisher, series, publisher || ':' || COALESCE(NULLIF(series_group,''), series),
                   file_path, issue_number, comicinfo_issue_number, title, year, cover_month, cover_day, story_arc
            FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = effectiveKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || COALESCE(NULLIF(series_group,''), series)) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            let allRows: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), publisher: colText(s, 1) ?? "Unknown", series: colText(s, 2) ?? "General",
                    groupKey: colText(s, 3) ?? "", filePath: colText(s, 4) ?? "",
                    issueNumber: colText(s, 5), comicInfoIssueNumber: colText(s, 6), title: colText(s, 7) ?? "",
                    year:  sqlite3_column_type(s, 8) != SQLITE_NULL ? colInt(s, 8) : nil,
                    month: sqlite3_column_type(s, 9) != SQLITE_NULL ? colInt(s, 9) : nil,
                    day:   sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
                    storyArc: colText(s, 11))
            }

            var positions: [Int64: (position: Int, confidence: Int, reason: String)] = [:]

            switch mode {
            case .intelligent:
                let inputs = allRows.map { row in
                    ReadingOrderEngine.ReadingOrderInput(
                        id: row.id, groupKey: row.groupKey,
                        legacyNumber: ReadingOrderEngine.parseLegacyNumber(row.issueNumber),
                        comicType: ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series),
                        year: row.year, month: row.month, day: row.day, storyArc: row.storyArc,
                        title: row.title
                    )
                }
                let results = ReadingOrderEngine.computeSeriesPositions(inputs)
                for row in allRows {
                    if let r = results[row.id] { positions[row.id] = (r.position, r.confidence, r.reason) }
                }
            case .filename:
                break // handled directly in the write loop below (falls through to legacy `position`)
            case .legacyNumber:
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        (ReadingOrderEngine.parseLegacyNumber($0.issueNumber) ?? .infinity, $0.title) <
                        (ReadingOrderEngine.parseLegacyNumber($1.issueNumber) ?? .infinity, $1.title)
                    }
                    for (idx, row) in ordered.enumerated() { positions[row.id] = (idx, 100, "Sorted by legacy issue number") }
                }
            case .publicationDate:
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        ($0.year ?? 9999, $0.month ?? 13, $0.day ?? 32, $0.title) <
                        ($1.year ?? 9999, $1.month ?? 13, $1.day ?? 32, $1.title)
                    }
                    for (idx, row) in ordered.enumerated() { positions[row.id] = (idx, 100, "Sorted by publication date") }
                }
            case .comicInfoOrder:
                func comicInfoOrderKey(_ row: Row) -> Double {
                    row.comicInfoIssueNumber.flatMap(ReadingOrderEngine.parseLegacyNumber)
                        ?? ReadingOrderEngine.parseLegacyNumber(row.issueNumber) ?? .infinity
                }
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        (comicInfoOrderKey($0), $0.title) < (comicInfoOrderKey($1), $1.title)
                    }
                    for (idx, row) in ordered.enumerated() {
                        let reason = row.comicInfoIssueNumber != nil
                            ? "Sorted by ComicInfo.xml issue number" : "Sorted by legacy issue number (no ComicInfo.xml number)"
                        positions[row.id] = (idx, 100, reason)
                    }
                }
            }

            // Manual series-continuation chains (series_links): stamp a large offset onto every
            // already-computed position of each child series so it sorts after its parent's,
            // walked recursively for multi-hop chains. Skipped entirely when no links exist.
            let links: [(parentKey: String, childKey: String)] = rows(
                "SELECT parent_publisher, parent_series, child_publisher, child_series FROM series_links ORDER BY sequence_order"
            ) { s in
                ("\(colText(s, 0) ?? ""):\(colText(s, 1) ?? "")", "\(colText(s, 2) ?? ""):\(colText(s, 3) ?? "")")
            }
            if !links.isEmpty {
                var idsBySeriesKey: [String: [Int64]] = [:]
                for row in allRows { idsBySeriesKey["\(row.publisher):\(row.series)", default: []].append(row.id) }
                var childrenOf: [String: [String]] = [:]
                var parentOf: [String: String] = [:]
                for link in links {
                    childrenOf[link.parentKey, default: []].append(link.childKey)
                    parentOf[link.childKey] = link.parentKey
                }
                let allKeys = Set(parentOf.keys).union(parentOf.values)
                let roots = allKeys.subtracting(parentOf.keys)
                var visited: Set<String> = []
                func walk(_ seriesKey: String, baseOffset: Int) {
                    guard !visited.contains(seriesKey) else { return } // cycle guard: skip, don't crash
                    visited.insert(seriesKey)
                    var maxPos = baseOffset
                    for id in idsBySeriesKey[seriesKey] ?? [] where positions[id] != nil {
                        positions[id]!.position += baseOffset
                        maxPos = max(maxPos, positions[id]!.position)
                    }
                    for child in childrenOf[seriesKey] ?? [] { walk(child, baseOffset: maxPos + 1_000_000) }
                }
                for root in roots { walk(root, baseOffset: 0) }
            }

            // Durable overrides win outright regardless of mode — the position above was still
            // computed for these ids (needed so per-group interpolation/ordering stays coherent),
            // but is discarded here in favor of whatever the user pinned via reorderComics().
            let overrideMap = Dictionary(uniqueKeysWithValues: rows(
                "SELECT comic_id, position FROM reading_order_overrides", map: { (colInt64($0, 0), colInt($0, 1)) }
            ))

            exec("BEGIN")
            for row in allRows {
                if let overridePos = overrideMap[row.id] {
                    _ = run("""
                        UPDATE comics SET reading_order_position = ?, reading_order_confidence = 100,
                               reading_order_reason = 'Manually placed'
                        WHERE id = ?
                        """, args: [overridePos, row.id])
                } else if mode == .filename {
                    _ = run("""
                        UPDATE comics SET reading_order_position = NULL, reading_order_confidence = NULL,
                               reading_order_reason = NULL
                        WHERE id = ?
                        """, args: [row.id])
                } else if let p = positions[row.id] {
                    _ = run("""
                        UPDATE comics SET reading_order_position = ?, reading_order_confidence = ?,
                               reading_order_reason = ?
                        WHERE id = ?
                        """, args: [p.position, p.confidence, p.reason, row.id])
                }
            }
            exec("COMMIT")
        }
    }


    /// Durable manual override — written whenever a user drags a comic to reorder it
    /// (`reorderComics(orderedIds:)` below), so the correction survives every future rescan
    /// instead of being silently recomputed away the next time `recomputeReadingOrder()` runs.
    func setReadingOrderOverride(comicId: Int64, position: Int, reason: String = "Manually placed") {
        queue.sync {
            _ = run("""
                INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, ?)
                """, args: [comicId, position, reason])
        }
    }

    func clearReadingOrderOverride(comicId: Int64) {
        queue.sync {
            _ = run("DELETE FROM reading_order_overrides WHERE comic_id = ?", args: [comicId])
        }
    }

    func clearAllReadingOrderOverrides() {
        queue.sync { _ = run("DELETE FROM reading_order_overrides") }
    }

    // MARK: - Series links (manual cross-series legacy renumbering)

    struct SeriesLink {
        let id: Int64
        let parentPublisher: String; let parentSeries: String
        let childPublisher: String; let childSeries: String
        let sequenceOrder: Int
    }

    func seriesLinks() -> [SeriesLink] {
        queue.sync {
            rows("""
                SELECT id, parent_publisher, parent_series, child_publisher, child_series, sequence_order
                FROM series_links ORDER BY sequence_order
                """) { s in
                SeriesLink(id: colInt64(s, 0), parentPublisher: colText(s, 1) ?? "", parentSeries: colText(s, 2) ?? "",
                           childPublisher: colText(s, 3) ?? "", childSeries: colText(s, 4) ?? "", sequenceOrder: colInt(s, 5))
            }
        }
    }

    /// A series can be linked as the continuation of at most one parent (UNIQUE(child) in the
    /// schema) — this keeps chain resolution in recomputeReadingOrder() a simple forward walk
    /// rather than a graph. sequence_order is assigned by insertion order so multi-hop chains
    /// (A -> B -> C) resolve in the order they were linked.
    @discardableResult
    func addSeriesLink(parentPublisher: String, parentSeries: String, childPublisher: String, childSeries: String) -> Bool {
        queue.sync {
            let nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")
            let before = scalarInt("SELECT COUNT(*) FROM series_links WHERE child_publisher=? AND child_series=?",
                                    args: [childPublisher, childSeries])
            guard before == 0 else { return false } // already linked to a parent — remove first
            _ = run("""
                INSERT INTO series_links (parent_publisher, parent_series, child_publisher, child_series, sequence_order)
                VALUES (?, ?, ?, ?, ?)
                """, args: [parentPublisher, parentSeries, childPublisher, childSeries, nextSeq])
            return true
        }
    }

    func removeSeriesLink(childPublisher: String, childSeries: String) {
        queue.sync {
            _ = run("DELETE FROM series_links WHERE child_publisher = ? AND child_series = ?",
                    args: [childPublisher, childSeries])
        }
    }

    /// Every distinct (publisher, series) pair in the library — backs the Series Links picker's
    /// "pick the parent series" autocomplete.
    func allSeriesNames() -> [(publisher: String, series: String)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series FROM comics
                WHERE deleted_at IS NULL ORDER BY series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General") }
        }
    }

    // MARK: - Reading Order Manager / Import Wizard support queries

    struct SeriesTriageRow {
        let publisher: String; let series: String
        let issueCount: Int; let minConfidence: Int; let flaggedCount: Int; let overrideCount: Int
    }

    /// One row per series, worst-confidence-first — backs the library-wide Reading Order
    /// Manager triage list. `flaggedCount` reuses the same confidence < 85 threshold
    /// SeriesManagerView's per-issue badge already uses.
    func readingOrderTriageSummary() -> [SeriesTriageRow] {
        queue.sync {
            rows("""
                SELECT c.publisher, c.series, COUNT(*),
                       COALESCE(MIN(c.reading_order_confidence), 100),
                       SUM(CASE WHEN COALESCE(c.reading_order_confidence, 100) < 85 THEN 1 ELSE 0 END),
                       SUM(CASE WHEN o.comic_id IS NOT NULL THEN 1 ELSE 0 END)
                FROM comics c
                LEFT JOIN reading_order_overrides o ON o.comic_id = c.id
                WHERE c.deleted_at IS NULL
                GROUP BY c.publisher, c.series
                ORDER BY MIN(COALESCE(c.reading_order_confidence, 100)) ASC, COUNT(*) DESC
                """) { s in
                SeriesTriageRow(publisher: colText(s, 0) ?? "Unknown", series: colText(s, 1) ?? "General",
                                 issueCount: colInt(s, 2), minConfidence: colInt(s, 3),
                                 flaggedCount: colInt(s, 4), overrideCount: colInt(s, 5))
            }
        }
    }

    /// Series with more than one issue at legacy number 1 (excluding collections/TPBs, which
    /// aren't part of ongoing issue numbering) — an editorial judgment call the app can't make
    /// automatically, surfaced by the Import Wizard as a deep-link into SeriesManagerView.
    func seriesWithMultipleFirstIssues() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND CAST(NULLIF(issue_number, '') AS REAL) = 1
                GROUP BY publisher, series HAVING COUNT(*) > 1
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    /// Comics whose issue_number can't be parsed as a legacy number at all (nil, blank, or
    /// non-numeric with no recognized special-issue keyword) — nothing to auto-fix, but worth
    /// surfacing since it silently degrades every reading-order mode for that comic.
    func unparseableIssueNumberComics() -> [Comic] {
        queue.sync {
            let candidates = rows("\(comicSelect) WHERE c.deleted_at IS NULL", map: comicRow)
            return candidates.filter {
                ReadingOrderEngine.parseLegacyNumber($0.issueNumber) == nil &&
                ReadingOrderEngine.classify(issueNumber: $0.issueNumber, title: $0.title, series: $0.series).needsPlacement == false
            }
        }
    }

    /// Comics with no embedded ComicInfo.xml at all — report-only (never synthesized, per the
    /// "never rewrite files" constraint), but explains why some comics can only reach the
    /// engine's lower confidence tiers.
    func seriesMissingComicInfo() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND comicinfo_issue_number IS NULL
                GROUP BY publisher, series HAVING COUNT(*) > 0
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    /// Series keys currently sitting in the engine's always-last band (confidence 0 — no
    /// mainline sibling to place against) — these are exactly what `positionSpecialsChronologically()`
    /// already knows how to reposition, so the Import Wizard's one real one-click fix is just
    /// calling that existing function for the affected series.
    func seriesNeedingSpecialReposition() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND reading_order_confidence = 0
                GROUP BY publisher, series HAVING COUNT(*) > 0
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }


    // MARK: - Comics

    private func comicRow(_ s: OpaquePointer) -> Comic {
        Comic(
            id: colInt64(s, 0), title: colText(s, 1) ?? "", filePath: colText(s, 2) ?? "",
            publisher: colText(s, 3) ?? "Unknown", character: colText(s, 4),
            series: colText(s, 5) ?? "General", issueNumber: colText(s, 6),
            pageCount: colInt(s, 7), writer: colText(s, 8), penciller: colText(s, 9),
            year: sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
            storyArc: colText(s, 11), languageIso: colText(s, 12), notes: colText(s, 13),
            addedAt: colText(s, 14) ?? "", deletedAt: colText(s, 15),
            position: colInt(s, 16), fileHash: colText(s, 17),
            progress: colInt(s, 18), lastRead: colText(s, 19),
            rating: colInt(s, 20),
            review: colText(s, 23),
            isFavorite: colBool(s, 21), inReadingList: colBool(s, 22),
            readingOrderPosition: sqlite3_column_type(s, 24) != SQLITE_NULL ? colInt(s, 24) : nil,
            readingOrderConfidence: sqlite3_column_type(s, 25) != SQLITE_NULL ? colInt(s, 25) : nil,
            readingOrderReason: colText(s, 26)
        )
    }

    private let comicSelect = """
        SELECT c.id, c.title, c.file_path, c.publisher, c.character, c.series,
               c.issue_number, c.page_count, c.writer, c.penciller, c.year,
               c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
               COALESCE(c.position, c.id), c.file_hash,
               COALESCE(rp.current_page, 0) as progress, rp.last_read,
               COALESCE(r.rating, 0) as rating,
               (f.comic_id IS NOT NULL) as is_favorite,
               (rl.comic_id IS NOT NULL) as in_reading_list,
               r.review, c.reading_order_position, c.reading_order_confidence, c.reading_order_reason
        FROM comics c
        LEFT JOIN reading_progress rp ON c.id = rp.comic_id
        LEFT JOIN ratings r           ON c.id = r.comic_id
        LEFT JOIN favorites f         ON c.id = f.comic_id
        LEFT JOIN reading_list rl     ON c.id = rl.comic_id
    """

    // Orthogonal to SortOrder below: SortOrder answers "how does the library browser
    // group/sort" (by publisher/title/date/rating/progress/custom); ReadingOrderMode answers
    // "what basis decides the order of issues within one series" — it controls what
    // recomputeReadingOrder() writes into reading_order_position, which SortOrder.publisher
    // and .manual then read via COALESCE. Persisted the same way LibraryViewModel.sortOrder
    // is (raw UserDefaults, key "readingOrderMode").
    enum ReadingOrderMode: String, CaseIterable, Identifiable {
        case filename = "Filename", legacyNumber = "Legacy Number",
             publicationDate = "Publication Date", comicInfoOrder = "ComicInfo Order",
             intelligent = "Intelligent Reading Order"
        var id: String { rawValue }

        static var current: ReadingOrderMode {
            ReadingOrderMode(rawValue: UserDefaults.standard.string(forKey: "readingOrderMode") ?? "") ?? .intelligent
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case publisher = "Publisher", title = "Title", dateAdded = "Recently Added",
             rating = "Top Rated", progress = "Most Read", manual = "Custom"
        var id: String { rawValue }
        var clause: String {
            switch self {
            // Reads reading_order_position first (the new ReadingOrderEngine's output — see
            // recomputeReadingOrder()), falling back to the older `position` column
            // (positionSpecialsChronologically()'s output) and finally the live
            // is_special_issue() formula, in that order. A read-time COALESCE rather than a
            // write-time merge: the new engine's improved placement is live immediately for
            // every user with zero new UI, but the two systems stay genuinely decoupled.
            case .publisher: return "c.publisher, c.series, COALESCE(c.reading_order_position, c.position, is_special_issue(c.issue_number, c.title, c.series) * \(ComicSortClassifier.specialBandOffset) + c.id), c.title"
            case .title:     return "c.title"
            case .dateAdded: return "c.added_at DESC"
            case .rating:    return "COALESCE(r.rating, 0) DESC, c.title"
            case .progress:  return "COALESCE(rp.current_page, 0) DESC, c.title"
            case .manual:    return "COALESCE(c.reading_order_position, c.position, c.id)"
            }
        }
    }

    func allComics(publisher: String? = nil, character: String? = nil, series: String? = nil,
                   search: String? = nil, sortOrder: SortOrder = .publisher,
                   favoritesOnly: Bool = false, readingListOnly: Bool = false,
                   nullCharacterOnly: Bool = false, tag: String? = nil) -> [Comic] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if nullCharacterOnly { conds.append("c.character IS NULL") }
            else if let chr = character { conds.append("c.character = ?"); args.append(chr) }
            if let ser = series { conds.append("c.series = ?"); args.append(ser) }
            if let q = search, !q.isEmpty {
                conds.append("(c.title LIKE ? OR c.series LIKE ? OR c.publisher LIKE ? OR c.writer LIKE ? OR c.penciller LIKE ? OR c.character LIKE ?)")
                let p = "%\(q)%"
                args += [p, p, p, p, p, p]
            }
            if favoritesOnly   { conds.append("f.comic_id IS NOT NULL") }
            if readingListOnly { conds.append("rl.comic_id IS NOT NULL") }
            if let tag {
                conds.append("c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON ct.tag_id = t.id WHERE t.name = ?)")
                args.append(tag)
            }
            let sql = "\(comicSelect) WHERE \(conds.joined(separator: " AND ")) ORDER BY \(sortOrder.clause)"
            return rows(sql, args: args, map: comicRow)
        }
    }

    func comic(id: Int64) -> Comic? {
        queue.sync {
            rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [id], map: comicRow).first
        }
    }

    func inProgress(limit: Int = 20) -> [Comic] {
        queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.current_page > 0
                  AND (c.page_count = 0 OR rp.current_page < c.page_count - 2)
                ORDER BY rp.last_read DESC LIMIT ?
            """, args: [limit], map: comicRow)
        }
    }

    func publishers() -> [String] {
        queue.sync {
            rows("""
                SELECT DISTINCT c.publisher FROM comics c
                LEFT JOIN publisher_order po ON po.publisher = c.publisher
                WHERE c.deleted_at IS NULL AND c.publisher IS NOT NULL
                ORDER BY COALESCE(po.position, 999999), c.publisher
                """, map: { colText($0, 0) ?? "" })
        }
    }

    // Mirrors reorderCharacterGroups/reorderSeriesGroups — always called with the entire
    // currently-displayed publisher list so position is never left partially set.
    func reorderPublishers(orderedPublishers: [String]) {
        guard !orderedPublishers.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, pub) in orderedPublishers.enumerated() {
                _ = run("INSERT OR REPLACE INTO publisher_order (publisher, position) VALUES (?,?)",
                        args: [pub, idx])
            }
            exec("COMMIT")
        }
    }

    // Public type used by LibraryScanner to batch-collect inserts before flushing
    struct ComicInsert {
        let title: String, filePath: String, publisher: String, character: String?
        let series: String, issueNumber: String?, pageCount: Int, writer: String?
        let penciller: String?, year: Int?, storyArc: String?, languageIso: String?, fileHash: String?
        var coverMonth: Int? = nil
        var coverDay: Int? = nil
        var alternateNumber: String? = nil
        var storyArcNumber: String? = nil
        var seriesGroup: String? = nil
        var comicInfoIssueNumber: String? = nil
    }

    func insert(comic: (title: String, filePath: String, publisher: String, character: String?,
                        series: String, issueNumber: String?, pageCount: Int, writer: String?,
                        penciller: String?, year: Int?, storyArc: String?, languageIso: String?,
                        fileHash: String?)) {
        queue.sync { _insertRow(comic.title, comic.filePath, comic.publisher, comic.character,
                                comic.series, comic.issueNumber, comic.pageCount, comic.writer,
                                comic.penciller, comic.year, comic.storyArc, comic.languageIso, comic.fileHash) }
    }

    // Batch insert wrapped in a single transaction — dramatically faster than one commit per file.
    // SQLite WAL auto-rolls back on crash, so at most `comics.count` records are uncommitted.
    func batchInsert(_ comics: [ComicInsert]) {
        guard !comics.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for c in comics {
                _insertRow(c.title, c.filePath, c.publisher, c.character,
                           c.series, c.issueNumber, c.pageCount, c.writer,
                           c.penciller, c.year, c.storyArc, c.languageIso, c.fileHash, c.coverMonth,
                           c.coverDay, c.alternateNumber, c.storyArcNumber, c.seriesGroup, c.comicInfoIssueNumber)
            }
            exec("COMMIT")
        }
    }

    private func _insertRow(_ title: String, _ filePath: String, _ publisher: String, _ character: String?,
                             _ series: String, _ issueNumber: String?, _ pageCount: Int, _ writer: String?,
                             _ penciller: String?, _ year: Int?, _ storyArc: String?, _ languageIso: String?,
                             _ fileHash: String?, _ coverMonth: Int? = nil, _ coverDay: Int? = nil,
                             _ alternateNumber: String? = nil, _ storyArcNumber: String? = nil,
                             _ seriesGroup: String? = nil, _ comicInfoIssueNumber: String? = nil) {
        _ = run("""
        INSERT OR IGNORE INTO comics
            (title, file_path, publisher, character, series, issue_number,
             page_count, writer, penciller, year, story_arc, language_iso, file_hash, cover_month,
             cover_day, alternate_number, story_arc_number, series_group, comicinfo_issue_number)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, args: [title, filePath, publisher, character,
                    series, issueNumber, pageCount, writer,
                    penciller, year.map { Int64($0) }, storyArc,
                    languageIso, fileHash, coverMonth.map { Int64($0) },
                    coverDay.map { Int64($0) }, alternateNumber, storyArcNumber, seriesGroup, comicInfoIssueNumber])
    }

    // Comics imported when the archive was unreadable get page_count=0; scanner retries these.
    func zeroPageCountPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE page_count = 0 AND deleted_at IS NULL",
                 map: { (colInt64($0, 0), colText($0, 1) ?? "") })
        }
    }

    func updatePageCount(comicId: Int64, count: Int) {
        queue.sync { _ = run("UPDATE comics SET page_count = ? WHERE id = ?", args: [count, comicId]) }
    }

    func knownPaths() -> Set<String> {
        queue.sync { Set(rows("SELECT file_path FROM comics WHERE deleted_at IS NULL", map: { colText($0, 0) ?? "" })) }
    }

    func knownHashes() -> Set<String> {
        queue.sync {
            Set(rows("SELECT file_hash FROM comics WHERE file_hash IS NOT NULL AND deleted_at IS NULL",
                     map: { colText($0, 0) ?? "" }))
        }
    }

    func softDelete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            let sql = "UPDATE comics SET deleted_at = datetime('now') WHERE id IN (\(ph))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), id) }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func updateProgress(comicId: Int64, page: Int) {
        queue.sync {
            _ = run("""
            INSERT INTO reading_progress (comic_id, current_page, last_read)
            VALUES (?, ?, datetime('now'))
            ON CONFLICT(comic_id) DO UPDATE
              SET current_page = ?, last_read = datetime('now')
            """, args: [comicId, page, page])
        }
    }

    func updateProgress(_ updates: [(comicId: Int64, page: Int)]) {
        guard !updates.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (comicId, page) in updates {
                _ = run("""
                INSERT INTO reading_progress (comic_id, current_page, last_read)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(comic_id) DO UPDATE
                  SET current_page = ?, last_read = datetime('now')
                """, args: [comicId, page, page])
            }
            exec("COMMIT")
        }
    }

    func setRating(_ comicId: Int64, rating: Int) {
        queue.sync {
            // Use UPSERT to preserve the review column when changing rating
            _ = run("""
                INSERT INTO ratings (comic_id, rating) VALUES (?,?)
                ON CONFLICT(comic_id) DO UPDATE SET rating = excluded.rating
            """, args: [comicId, rating])
        }
    }

    func setComicNotes(_ comicId: Int64, notes: String?) {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _ = run("UPDATE comics SET notes = ? WHERE id = ?",
                    args: [(text?.isEmpty == false) ? text : nil, comicId])
        }
    }

    func setComicReview(_ comicId: Int64, review: String?) {
        let text = review?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _ = run("""
                INSERT INTO ratings (comic_id, rating, review) VALUES (?,COALESCE((SELECT rating FROM ratings WHERE comic_id=?),0),?)
                ON CONFLICT(comic_id) DO UPDATE SET review = excluded.review
            """, args: [comicId, comicId, (text?.isEmpty == false) ? text : nil])
        }
    }

    func runsContaining(comicId: Int64) -> [Run] {
        queue.sync {
            rows("""
                SELECT r.id, r.title, COALESCE(r.description,''), COALESCE(r.rating,0), r.review, r.buy_link, r.created_at
                FROM runs r JOIN run_items ri ON ri.run_id = r.id
                WHERE ri.comic_id = ? ORDER BY r.created_at
            """, args: [comicId]) { r in
                Run(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                    rating: { let v = colInt(r, 3); return v > 0 ? v : nil }(),
                    review: colText(r, 4), buyLink: colText(r, 5), createdAt: colText(r, 6) ?? "")
            }
        }
    }

    func updateRun(id: Int64, title: String, description: String, buyLink: String?) {
        queue.sync {
            _ = run("UPDATE runs SET title = ?, description = ?, buy_link = ? WHERE id = ?",
                    args: [title, description, buyLink?.isEmpty == false ? buyLink : nil, id])
        }
    }

    func comicIdsInRun(runId: Int64) -> Set<Int64> {
        queue.sync {
            Set(rows("SELECT comic_id FROM run_items WHERE run_id = ?", args: [runId]) { colInt64($0, 0) })
        }
    }

    func setFavorite(_ comicId: Int64, _ value: Bool) {
        queue.sync {
            if value { run("INSERT OR IGNORE INTO favorites (comic_id) VALUES (?)", args: [comicId]) }
            else      { run("DELETE FROM favorites WHERE comic_id = ?", args: [comicId]) }
        }
    }

    func setInReadingList(_ comicId: Int64, _ value: Bool) {
        queue.sync {
            if value { run("INSERT OR IGNORE INTO reading_list (comic_id) VALUES (?)", args: [comicId]) }
            else      { run("DELETE FROM reading_list WHERE comic_id = ?", args: [comicId]) }
        }
    }

    func setInReadingList(_ ids: [Int64], _ value: Bool) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            let args = ids.map { $0 as Any? }
            if value {
                let values = ids.map { _ in "(?)" }.joined(separator: ",")
                _ = run("INSERT OR IGNORE INTO reading_list (comic_id) VALUES \(values)", args: args)
            } else {
                _ = run("DELETE FROM reading_list WHERE comic_id IN (\(ph))", args: args)
            }
        }
    }

    // Columns that folder-derived reparsing (batchUpdateFolderMeta) also writes.
    // Editing any of these by hand marks the row so a later reparse won't clobber it.
    private static let folderDerivedColumns: Set<String> = ["title", "series", "publisher", "character"]

    // fields is ordered: [(column, value)] to prevent Dict iteration-order bugs
    func updateMeta(comicId: Int64, fields: [(String, Any?)]) {
        guard !fields.isEmpty else { return }
        queue.sync {
            var sets = fields.map { "\($0.0) = ?" }
            var args: [Any?] = fields.map { $0.1 }
            if fields.contains(where: { Self.folderDerivedColumns.contains($0.0) }) {
                sets.append("meta_edited = 1")
            }
            args.append(comicId)
            _ = run("UPDATE comics SET \(sets.joined(separator: ", ")) WHERE id = ?", args: args)
        }
    }

    // MARK: - Tags

    func tags(for comicId: Int64) -> [Tag] {
        queue.sync {
            rows("SELECT t.id, t.name FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id WHERE ct.comic_id = ? ORDER BY t.name",
                 args: [comicId]) { Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "") }
        }
    }

    func addTag(name: String, to comicId: Int64) {
        queue.sync {
            // INSERT OR IGNORE then SELECT covers both new and existing tags in one round-trip
            _ = run("INSERT OR IGNORE INTO tags (name) VALUES (?)", args: [name])
            let resolvedId = scalarInt("SELECT id FROM tags WHERE name = ?", args: [name])
            guard resolvedId > 0 else { return }
            _ = run("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) VALUES (?,?)",
                    args: [comicId, Int64(resolvedId)])
        }
    }

    func comics(withPaths paths: [String]) -> [Comic] {
        guard !paths.isEmpty else { return [] }
        return queue.sync {
            let ph = paths.map { _ in "?" }.joined(separator: ",")
            return rows("\(comicSelect) WHERE c.file_path IN (\(ph)) AND c.deleted_at IS NULL",
                        args: paths.map { $0 as Any? }, map: comicRow)
        }
    }

    func removeTag(tagId: Int64, from comicId: Int64) {
        queue.sync {
            _ = run("DELETE FROM comic_tags WHERE comic_id = ? AND tag_id = ?", args: [comicId, tagId])
            _ = run("DELETE FROM tags WHERE id = ? AND (SELECT COUNT(*) FROM comic_tags WHERE tag_id = ?) = 0",
                    args: [tagId, tagId])
        }
    }

    // MARK: - Folder-based metadata reparse

    func allComicPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") { s in
                (id: self.colInt64(s, 0), path: self.colText(s, 1) ?? "")
            }
        }
    }

    /// Updates publisher/character/series/title derived from folder path and filename.
    /// When `character` is nil, clears any messy roster-style character strings.
    func updateFolderMeta(comicId: Int64, publisher: String?, character: String?, series: String?, title: String?) {
        queue.sync {
            if let pub = publisher {
                _ = run("UPDATE comics SET publisher = ? WHERE id = ?", args: [pub, comicId])
            }
            if let char = character {
                _ = run("UPDATE comics SET character = ? WHERE id = ?", args: [char, comicId])
            } else {
                _ = run("UPDATE comics SET character = NULL WHERE id = ? AND (character LIKE '%,%' OR character LIKE '%[%' OR LENGTH(COALESCE(character,'')) > 60)",
                        args: [comicId])
            }
            if let ser = series {
                _ = run("UPDATE comics SET series = ? WHERE id = ?", args: [ser, comicId])
            }
            if let t = title {
                _ = run("UPDATE comics SET title = ? WHERE id = ?", args: [t, comicId])
            }
        }
    }

    // MARK: - Series management

    func renameSeries(oldName: String, publisher: String?, newName: String) {
        queue.sync {
            if let pub = publisher, !pub.isEmpty, pub != "All" {
                _ = run("UPDATE comics SET series = ? WHERE series = ? AND publisher = ?",
                        args: [newName, oldName, pub])
            } else {
                _ = run("UPDATE comics SET series = ? WHERE series = ?",
                        args: [newName, oldName])
            }
        }
    }

    /// True if `newName` (scoped to `publisher`, if given) already names a different series
    /// than `oldName` — i.e. renaming into it would silently merge the two series' issues.
    func seriesNameCollides(oldName: String, publisher: String?, newName: String) -> Bool {
        guard newName != oldName else { return false }
        return queue.sync {
            if let pub = publisher, !pub.isEmpty, pub != "All" {
                return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ? AND publisher = ?",
                                  args: [newName, pub]) > 0
            }
            return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ?", args: [newName]) > 0
        }
    }

    /// Bulk-reassigns series and/or publisher for the given comics (e.g. correcting a bad
    /// folder-derived guess across several issues at once). Marks each row meta_edited so a
    /// later folder-derived reparse won't silently revert the correction.
    func bulkReassign(ids: [Int64], series: String?, publisher: String?) {
        guard !ids.isEmpty, series != nil || publisher != nil else { return }
        queue.sync {
            exec("BEGIN")
            for id in ids {
                if let ser = series {
                    _ = run("UPDATE comics SET series = ?, meta_edited = 1 WHERE id = ?", args: [ser, id])
                }
                if let pub = publisher {
                    _ = run("UPDATE comics SET publisher = ?, meta_edited = 1 WHERE id = ?", args: [pub, id])
                }
            }
            exec("COMMIT")
        }
    }

    /// Groups of comics sharing the same publisher+series+issue number — likely the same issue
    /// imported twice under different filenames (a rescan, a re-rip, a variant cover, etc.).
    // One joined query instead of a "find the duplicate keys, then one round-trip per key"
    // N+1 pattern — this runs after every scan/import/reassign/delete/rename, serialized on
    // the same DB queue as everything else, so a library with many duplicate groups no
    // longer means many sequential prepared-statement round trips blocking that queue.
    func duplicateGroups() -> [[Comic]] {
        queue.sync {
            let flat = rows("""
                \(comicSelect)
                JOIN (
                    SELECT publisher, series, issue_number
                    FROM comics
                    WHERE deleted_at IS NULL AND issue_number IS NOT NULL AND issue_number != ''
                    GROUP BY publisher, series, issue_number
                    HAVING COUNT(*) > 1
                ) dup ON dup.publisher = c.publisher AND dup.series = c.series AND dup.issue_number = c.issue_number
                WHERE c.deleted_at IS NULL
                ORDER BY c.publisher, c.series, CAST(c.issue_number AS INTEGER)
            """, map: comicRow)

            guard !flat.isEmpty else { return [] }
            var groups: [[Comic]] = []
            var currentKey: (String, String, String)? = nil
            for comic in flat {
                let key = (comic.publisher, comic.series, comic.issueNumber ?? "")
                if currentKey == nil || currentKey! != key {
                    groups.append([comic])
                    currentKey = key
                } else {
                    groups[groups.count - 1].append(comic)
                }
            }
            return groups
        }
    }

    func reorderComics(orderedIds: [Int64]) {
        queue.sync {
            exec("BEGIN")
            for (idx, id) in orderedIds.enumerated() {
                // reading_order_position is also set directly here, not just left to the next
                // recomputeReadingOrder() pass — the sort clauses read reading_order_position
                // first, so a stale higher-priority value there would otherwise mask this drag
                // until the next scan happened to run.
                _ = run("""
                    UPDATE comics SET position = ?, reading_order_position = ?,
                           reading_order_confidence = 100, reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, args: [idx, idx, id])
                // Durable override: a manual drag is the strongest possible signal of intent,
                // so it's recorded the same way in reading_order_overrides — surviving future
                // rescans instead of being silently recomputed away the next time
                // recomputeReadingOrder() runs (which happens after every scan).
                _ = run("""
                    INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')
                    """, args: [id, idx])
            }
            exec("COMMIT")
        }
    }

    // MARK: - Runs

    func allRuns() -> [Run] {
        queue.sync {
            let sql = """
                SELECT r.id, r.title, COALESCE(r.description,''), COALESCE(r.rating,0), r.review, r.buy_link, r.created_at,
                       COUNT(ri.id) as total,
                       SUM(CASE WHEN c.page_count > 1 AND COALESCE(rp.current_page,0) >= c.page_count - 1 THEN 1 ELSE 0 END) as read_ct,
                       r.cover_image_path
                FROM runs r
                LEFT JOIN run_items ri ON ri.run_id = r.id
                LEFT JOIN comics c    ON c.id = ri.comic_id AND c.deleted_at IS NULL
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                GROUP BY r.id
                ORDER BY COALESCE(r.position, r.id * -1)
            """
            return rows(sql, map: { s in
                Run(id: colInt64(s, 0), title: colText(s, 1) ?? "", description: colText(s, 2) ?? "",
                    rating: colInt(s, 3) > 0 ? colInt(s, 3) : nil,
                    review: colText(s, 4), buyLink: colText(s, 5), createdAt: colText(s, 6) ?? "",
                    comicCount: colInt(s, 7), readCount: colInt(s, 8), coverImagePath: colText(s, 9))
            })
        }
    }

    @discardableResult
    func createRun(title: String, description: String) -> Int64 {
        queue.sync { run("INSERT INTO runs (title, description) VALUES (?,?)", args: [title, description]) }
    }

    func setRunCover(runId: Int64, imagePath: String) {
        queue.sync { _ = run("UPDATE runs SET cover_image_path = ? WHERE id = ?", args: [imagePath, runId]) }
    }

    func clearRunCover(runId: Int64) {
        queue.sync { _ = run("UPDATE runs SET cover_image_path = NULL WHERE id = ?", args: [runId]) }
    }

    // Mirrors reorderComics: called with the *entire* currently-displayed runs list every
    // time, not just the two swapped, so position is never left partially NULL/non-NULL —
    // allRuns()'s ORDER BY falls back to newest-first (r.id * -1) only for a library that's
    // never had a manual drag at all.
    func reorderRuns(orderedIds: [Int64]) {
        queue.sync {
            exec("BEGIN")
            for (idx, id) in orderedIds.enumerated() {
                _ = run("UPDATE runs SET position = ? WHERE id = ?", args: [idx, id])
            }
            exec("COMMIT")
        }
    }

    /// Used by backup restore to avoid creating a duplicate run when the same backup is
    /// imported more than once. Not used by the normal "create a run" flow, which
    /// legitimately allows two runs sharing a title.
    func runId(withTitle title: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM runs WHERE title = ? LIMIT 1", args: [title])
            return id > 0 ? Int64(id) : nil
        }
    }

    func deleteRun(_ runId: Int64) {
        queue.sync { _ = run("DELETE FROM runs WHERE id=?", args: [runId]) }
    }

    func runItems(runId: Int64) -> [RunItem] {
        queue.sync {
            let sql = """
            SELECT ri.id, ri.position, COALESCE(ri.notes,''),
                   c.id, c.title, c.file_path, c.publisher, c.character, c.series,
                   c.issue_number, c.page_count, c.writer, c.penciller, c.year,
                   c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
                   COALESCE(c.position, c.id), c.file_hash,
                   COALESCE(rp.current_page, 0), rp.last_read,
                   COALESCE(r.rating, 0), (f.comic_id IS NOT NULL), (rl.comic_id IS NOT NULL)
            FROM run_items ri
            JOIN comics c ON ri.comic_id = c.id AND c.deleted_at IS NULL
            LEFT JOIN reading_progress rp ON c.id = rp.comic_id
            LEFT JOIN ratings r           ON c.id = r.comic_id
            LEFT JOIN favorites f         ON c.id = f.comic_id
            LEFT JOIN reading_list rl     ON c.id = rl.comic_id
            WHERE ri.run_id = ? ORDER BY ri.position
            """
            return rows(sql, args: [runId]) { s -> RunItem in
                let comic = Comic(
                    id: colInt64(s, 3), title: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    publisher: colText(s, 6) ?? "Unknown", character: colText(s, 7), series: colText(s, 8) ?? "General",
                    issueNumber: colText(s, 9), pageCount: colInt(s, 10), writer: colText(s, 11),
                    penciller: colText(s, 12), year: sqlite3_column_type(s, 13) != SQLITE_NULL ? colInt(s, 13) : nil,
                    storyArc: colText(s, 14), languageIso: colText(s, 15), notes: colText(s, 16),
                    addedAt: colText(s, 17) ?? "", deletedAt: colText(s, 18),
                    position: colInt(s, 19), fileHash: colText(s, 20),
                    progress: colInt(s, 21), lastRead: colText(s, 22),
                    rating: colInt(s, 23), isFavorite: colBool(s, 24), inReadingList: colBool(s, 25)
                )
                return RunItem(id: colInt64(s, 0), comic: comic,
                               position: colInt(s, 1), notes: colText(s, 2) ?? "")
            }
        }
    }

    func addToRun(runId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        queue.sync {
            var pos = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?",
                                args: [runId])
            exec("BEGIN")
            for comicId in comicIds {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO run_items (run_id, comic_id, position) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, runId); sqlite3_bind_int64(stmt, 2, comicId); sqlite3_bind_int(stmt, 3, Int32(pos))
                sqlite3_step(stmt); sqlite3_finalize(stmt)
                pos += 1
            }
            exec("COMMIT")
        }
    }

    func removeFromRun(runId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for comicId in comicIds {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM run_items WHERE run_id = ? AND comic_id = ?", -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, runId); sqlite3_bind_int64(stmt, 2, comicId)
                sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
            exec("COMMIT")
        }
    }

    func reorderRun(runId: Int64, orderedIds: [Int64]) {
        queue.sync {
            exec("BEGIN")
            for (pos, id) in orderedIds.enumerated() {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "UPDATE run_items SET position = ? WHERE id = ? AND run_id = ?", -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int(stmt, 1, Int32(pos)); sqlite3_bind_int64(stmt, 2, id); sqlite3_bind_int64(stmt, 3, runId)
                sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
            exec("COMMIT")
        }
    }

    // MARK: - Stats

    func loadStats() -> LibraryStats {
        queue.sync {
            let total     = scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL")
            let pagesRead = scalarInt("SELECT COALESCE(SUM(rp.current_page),0) FROM reading_progress rp JOIN comics c ON rp.comic_id = c.id WHERE c.deleted_at IS NULL")
            let favorites = scalarInt("SELECT COUNT(*) FROM favorites f JOIN comics c ON f.comic_id = c.id WHERE c.deleted_at IS NULL")
            let inProg    = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE rp.current_page > 0 AND (c.page_count = 0 OR rp.current_page < c.page_count - 2) AND c.deleted_at IS NULL
            """)
            let finished  = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE c.page_count > 1 AND rp.current_page >= c.page_count - 2 AND c.deleted_at IS NULL
            """)
            let runsCount = scalarInt("SELECT COUNT(*) FROM runs")

            let streakDates = rows("SELECT DISTINCT date(last_read) FROM reading_progress ORDER BY date(last_read) DESC") {
                colText($0, 0) ?? ""
            }
            let streak = computeStreak(dates: streakDates)

            let activityMap = readingActivityMap(days: 365)

            let pubRows = rows("""
                SELECT publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher ORDER BY COUNT(*) DESC
            """) { PublisherStat(publisher: colText($0, 0) ?? "", count: colInt($0, 1)) }

            let seriesRows = rows("""
                SELECT series, publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher, series ORDER BY COUNT(*) DESC LIMIT 5
            """) { SeriesStat(series: colText($0, 0) ?? "", publisher: colText($0, 1) ?? "", count: colInt($0, 2)) }

            let recent = rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.comic_id IS NOT NULL
                ORDER BY rp.last_read DESC LIMIT 8
            """, map: comicRow)

            let growth = monthlyCollectionGrowth(months: 6)

            return LibraryStats(totalComics: total, pagesRead: pagesRead, favorites: favorites,
                                inProgress: inProg, finished: finished, unread: max(0, total - inProg - finished),
                                runsCount: runsCount, readingStreak: streak, activityMap: activityMap,
                                publisherBreakdown: pubRows, topSeries: seriesRows, recentlyRead: recent,
                                collectionGrowth: growth)
        }
    }

    // Comics added per calendar month, most recent `months` months (oldest first) — powers
    // the Stats dashboard's collection-growth chart. Must be called from inside queue.sync.
    private func monthlyCollectionGrowth(months: Int) -> [GrowthPoint] {
        let raw = rows("""
            SELECT strftime('%Y-%m', added_at) as ym, COUNT(*)
            FROM comics
            WHERE deleted_at IS NULL AND added_at >= date('now', '-\(months) months', 'start of month')
            GROUP BY ym ORDER BY ym
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        let counts = Dictionary(uniqueKeysWithValues: raw)

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let labelFmt = DateFormatter(); labelFmt.dateFormat = "MMM"; labelFmt.locale = Locale(identifier: "en_US_POSIX")

        var points: [GrowthPoint] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .month, value: -offset, to: Date()) else { continue }
            let key = fmt.string(from: date)
            points.append(GrowthPoint(month: key, label: labelFmt.string(from: date), count: counts[key] ?? 0))
        }
        return points
    }

    private static let yyyyMMddFormatter: DateFormatter = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    private func readingActivityMap(days: Int) -> [String: Int] {
        var map: [String: Int] = [:]
        let rows = self.rows("""
            SELECT date(last_read) as d, COUNT(*) FROM reading_progress
            WHERE last_read >= date('now', '-\(days) days')
            GROUP BY d
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        for (d, c) in rows { map[d] = c }
        return map
    }

    private func computeStreak(dates: [String]) -> Int {
        guard !dates.isEmpty else { return 0 }
        let fmt = Self.yyyyMMddFormatter
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var streak = 0; var expected: Date?
        for str in dates {
            guard let d = fmt.date(from: str) else { continue }
            let day = cal.startOfDay(for: d)
            if expected == nil {
                guard day == today || day == yesterday else { break }
                streak = 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else if day == expected {
                streak += 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else { break }
        }
        return streak
    }

    // MARK: - File presence check

    func clearAll() {
        queue.sync {
            exec("DELETE FROM reading_history")
            exec("DELETE FROM reading_progress")
            exec("DELETE FROM reading_goals")
            exec("DELETE FROM bookmarks")
            exec("DELETE FROM ratings")
            exec("DELETE FROM favorites")
            exec("DELETE FROM reading_list")
            exec("DELETE FROM comic_tags")
            exec("DELETE FROM series_covers")
            exec("DELETE FROM comic_shelves")
            exec("DELETE FROM run_items")
            exec("DELETE FROM runs")
            exec("DELETE FROM tags")
            exec("DELETE FROM comics")
            // Re-seed built-in shelves after wiping (must match migrate())
            let builtins = [("Currently Reading", 0), ("Want to Read", 1), ("Finished", 2), ("DNF", 3)]
            for (name, pos) in builtins {
                exec("INSERT OR IGNORE INTO shelves (name, is_builtin, position) VALUES ('\(name)', 1, \(pos))")
            }
        }
    }

    // Skips rows the user has hand-edited (meta_edited=1) so folder-derived
    // reparsing never silently reverts a manual title/series/publisher/character fix.
    func batchUpdateFolderMeta(_ items: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?)]) {
        queue.sync {
            exec("BEGIN")
            for item in items {
                if let pub = item.pub {
                    _ = run("UPDATE comics SET publisher=? WHERE id=? AND meta_edited=0", args: [pub, item.id])
                }
                if let char = item.char {
                    _ = run("UPDATE comics SET character=? WHERE id=? AND meta_edited=0", args: [char, item.id])
                } else {
                    _ = run("UPDATE comics SET character=NULL WHERE id=? AND meta_edited=0 AND (character LIKE '%,%' OR character LIKE '%[%' OR LENGTH(COALESCE(character,''))>60)",
                            args: [item.id])
                }
                if let ser = item.ser {
                    _ = run("UPDATE comics SET series=? WHERE id=? AND meta_edited=0", args: [ser, item.id])
                }
                _ = run("UPDATE comics SET title=? WHERE id=? AND meta_edited=0", args: [item.title, item.id])
                // Only overwrite when the filename actually yielded a number, and only when
                // it disagrees with what's stored — an embedded ComicInfo.xml number that
                // collides with a different issue's number (e.g. legacy vs. current-run
                // numbering) breaks reading order for the whole series.
                if let num = item.issueNumber {
                    _ = run("""
                        UPDATE comics SET issue_number=? WHERE id=? AND meta_edited=0
                        AND (issue_number IS NULL OR issue_number != ?)
                        """, args: [num, item.id, num])
                }
            }
            exec("COMMIT")

            // Issue numbers may have just changed for any number of rows above — recompute
            // every position from scratch rather than trying to figure out which rows were
            // actually touched. Cheap (single UPDATE) and idempotent.
            exec("""
                UPDATE comics SET position =
                    is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                    + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
            """)
        }
        positionSpecialsChronologically()
        recomputeReadingOrder()
    }

    func updateFileHash(id: Int64, hash: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_hash = ? WHERE id = ?", args: [hash, id])
        }
    }

    func updateFilePath(forHash hash: String, newPath: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ? WHERE file_hash = ? AND deleted_at IS NULL",
                    args: [newPath, hash])
        }
    }

    // Used by the "Rename Files to Match Library" tool — the file on disk has already been
    // moved by the time this is called, this just keeps file_path in sync so the app doesn't
    // treat the renamed file as missing on the next scan.
    func updateFilePath(id: Int64, newPath: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ? WHERE id = ?", args: [newPath, id])
        }
    }

    func stalePaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") {
                (colInt64($0, 0), colText($0, 1) ?? "")
            }
        }
    }

    func allTags() -> [(tag: Tag, count: Int)] {
        queue.sync {
            rows("""
                SELECT t.id, t.name, COUNT(ct.comic_id) as cnt
                FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id
                JOIN comics c ON ct.comic_id = c.id
                WHERE c.deleted_at IS NULL
                GROUP BY t.id ORDER BY cnt DESC, t.name
            """) { (Tag(id: colInt64($0, 0), name: colText($0, 1) ?? ""), colInt($0, 2)) }
        }
    }

    func setRunRating(_ runId: Int64, rating: Int, review: String?) {
        queue.sync {
            _ = run("UPDATE runs SET rating = ?, review = ? WHERE id = ?",
                    args: [rating > 0 ? rating : nil, review, runId])
        }
    }

    func setRunItemNotes(_ itemId: Int64, notes: String) {
        queue.sync {
            _ = run("UPDATE run_items SET notes = ? WHERE id = ?",
                    args: [notes.isEmpty ? nil : notes, itemId])
        }
    }

    // MARK: - Browse groups

    struct CharacterGroup: Identifiable {
        let id: String
        let groupName: String
        let character: String?
        let publisher: String
        let count: Int
        let coverId: Int64
        let coverImagePath: String?
        let started: Int
        let finished: Int
    }

    struct SeriesGroup: Identifiable {
        let id: String
        let series: String
        let publisher: String
        let count: Int
        let coverId: Int64
        let started: Int
        let finished: Int
        var coverImagePath: String? = nil
    }

    func characterGroups(publisher: String? = nil, search: String? = nil) -> [CharacterGroup] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if let q = search, !q.isEmpty {
                conds.append("(c.series LIKE ? OR (c.character NOT LIKE '%,%' AND c.character NOT LIKE '%[%' AND LENGTH(COALESCE(c.character,'')) <= 60 AND c.character LIKE ?))")
                let p = "%\(q)%"
                args += [p, p]
            }
            // If character looks like a roster list (has commas, brackets, or >60 chars),
            // fall back to series name — so messy ComicInfo.xml character lists don't pollute grouping.
            let cleanChar = """
                CASE
                  WHEN c.character IS NULL
                    OR c.character LIKE '%,%'
                    OR c.character LIKE '%[%'
                    OR c.character LIKE '%(%'
                    OR LENGTH(c.character) > 60
                  THEN c.series
                  ELSE c.character
                END
            """
            let sql = """
                SELECT \(cleanChar) as group_name,
                       c.character, c.publisher,
                       COUNT(*) as cnt,
                       COALESCE(sc.comic_id, MIN(c.id)) as cover_id,
                       SUM(CASE WHEN rp.current_page > 0 THEN 1 ELSE 0 END) as started,
                       SUM(CASE WHEN c.page_count > 1 AND rp.current_page >= c.page_count - 1 THEN 1 ELSE 0 END) as finished,
                       cc.image_path
                FROM comics c
                LEFT JOIN reading_progress rp ON c.id = rp.comic_id
                LEFT JOIN series_covers sc ON sc.series = c.series AND sc.publisher = c.publisher
                LEFT JOIN character_covers cc ON cc.group_name = (\(cleanChar)) AND cc.publisher = c.publisher
                LEFT JOIN character_order co ON co.group_name = (\(cleanChar)) AND co.publisher = c.publisher
                WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.publisher, \(cleanChar)
                ORDER BY c.publisher, COALESCE(co.position, 999999), group_name
            """
            return rows(sql, args: args) { s in
                let gn  = colText(s, 0) ?? ""
                let pub = colText(s, 2) ?? ""
                return CharacterGroup(
                    id: "\(pub):\(gn)",
                    groupName: gn,
                    character: colText(s, 1),
                    publisher: pub,
                    count: colInt(s, 3),
                    coverId: colInt64(s, 4),
                    coverImagePath: colText(s, 7),
                    started: colInt(s, 5),
                    finished: colInt(s, 6)
                )
            }
        }
    }

    func seriesGroups(groupName: String, publisher: String? = nil) -> [SeriesGroup] {
        queue.sync {
            // Match the same cleanChar logic used in characterGroups so drill-through is consistent
            let cleanChar = """
                CASE
                  WHEN c.character IS NULL
                    OR c.character LIKE '%,%'
                    OR c.character LIKE '%[%'
                    OR c.character LIKE '%(%'
                    OR LENGTH(c.character) > 60
                  THEN c.series
                  ELSE c.character
                END
            """
            var conds = ["c.deleted_at IS NULL", "(\(cleanChar)) = ?"]
            var args: [Any?] = [groupName]
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            let sql = """
                SELECT c.series, c.publisher, COUNT(*) as cnt,
                       COALESCE(sc.comic_id, MIN(c.id)) as cover_id,
                       SUM(CASE WHEN rp.current_page > 0 THEN 1 ELSE 0 END) as started,
                       SUM(CASE WHEN c.page_count > 1 AND rp.current_page >= c.page_count - 1 THEN 1 ELSE 0 END) as finished,
                       sc.image_path
                FROM comics c
                LEFT JOIN reading_progress rp ON c.id = rp.comic_id
                LEFT JOIN series_covers sc ON sc.series = c.series AND sc.publisher = c.publisher
                WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.series
                ORDER BY COALESCE(
                    (SELECT so.position FROM series_order so
                     WHERE so.group_name = ? AND so.publisher = ? AND so.series = c.series),
                    9999
                ), c.series
            """
            args.append(groupName)
            args.append(publisher ?? "")
            return rows(sql, args: args) { s in
                let ser = colText(s, 0) ?? ""
                let pub = colText(s, 1) ?? ""
                return SeriesGroup(id: "\(pub):\(ser)", series: ser, publisher: pub,
                                   count: colInt(s, 2), coverId: colInt64(s, 3),
                                   started: colInt(s, 4), finished: colInt(s, 5),
                                   coverImagePath: colText(s, 6))
            }
        }
    }

    // MARK: - Series covers

    func setSeriesCover(series: String, publisher: String, comicId: Int64) {
        queue.sync {
            _ = run("INSERT OR REPLACE INTO series_covers (series, publisher, comic_id) VALUES (?, ?, ?)",
                    args: [series, publisher, comicId])
        }
    }

    func clearSeriesCover(series: String, publisher: String) {
        queue.sync {
            _ = run("DELETE FROM series_covers WHERE series = ? AND publisher = ?",
                    args: [series, publisher])
        }
    }

    // A custom image and "use this issue's cover" are mutually exclusive — setting one clears
    // the other's comic_id, since a stale comic_id sitting alongside a custom image_path would
    // leave it ambiguous which one currentSeriesCover()/the cover-loading code should prefer.
    func setSeriesCoverImage(series: String, publisher: String, imagePath: String) {
        queue.sync {
            _ = run("""
            INSERT INTO series_covers (series, publisher, comic_id, image_path) VALUES (?, ?, NULL, ?)
            ON CONFLICT(series, publisher) DO UPDATE SET image_path = excluded.image_path, comic_id = NULL
            """, args: [series, publisher, imagePath])
        }
    }

    func currentSeriesCover(series: String, publisher: String) -> Int64? {
        queue.sync {
            var raw: OpaquePointer?
            let sql = "SELECT comic_id FROM series_covers WHERE series = ? AND publisher = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args: [series, publisher])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    // MARK: - Series reader preferences

    struct SeriesReaderPrefs {
        let fitMode:      String
        let rtl:          Bool
        let doubleSpread: Bool
        let scrollMode:   Bool
    }

    func setSeriesReaderPrefs(series: String, publisher: String, fitMode: String, rtl: Bool, doubleSpread: Bool, scrollMode: Bool) {
        queue.sync {
            _ = run("""
            INSERT OR REPLACE INTO series_reader_prefs (series, publisher, fit_mode, rtl, double_spread, scroll_mode)
            VALUES (?, ?, ?, ?, ?, ?)
            """, args: [series, publisher, fitMode, rtl ? 1 : 0, doubleSpread ? 1 : 0, scrollMode ? 1 : 0])
        }
    }

    func seriesReaderPrefs(series: String, publisher: String) -> SeriesReaderPrefs? {
        queue.sync {
            var raw: OpaquePointer?
            let sql = "SELECT fit_mode, rtl, double_spread, scroll_mode FROM series_reader_prefs WHERE series = ? AND publisher = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args: [series, publisher])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let fitMode = String(cString: sqlite3_column_text(stmt, 0))
            return SeriesReaderPrefs(fitMode: fitMode,
                                      rtl:          sqlite3_column_int(stmt, 1) != 0,
                                      doubleSpread: sqlite3_column_int(stmt, 2) != 0,
                                      scrollMode:   sqlite3_column_int(stmt, 3) != 0)
        }
    }

    // MARK: - Character group covers

    func setCharacterGroupCover(groupName: String, publisher: String, imagePath: String) {
        queue.sync {
            _ = run("INSERT OR REPLACE INTO character_covers (group_name, publisher, image_path) VALUES (?,?,?)",
                    args: [groupName, publisher, imagePath])
        }
    }

    func clearCharacterGroupCover(groupName: String, publisher: String) {
        queue.sync {
            _ = run("DELETE FROM character_covers WHERE group_name = ? AND publisher = ?",
                    args: [groupName, publisher])
        }
    }

    // MARK: - Series group ordering

    func reorderSeriesGroups(groupName: String, publisher: String, orderedSeries: [String]) {
        guard !orderedSeries.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, series) in orderedSeries.enumerated() {
                _ = run("INSERT OR REPLACE INTO series_order (group_name, publisher, series, position) VALUES (?,?,?,?)",
                        args: [groupName, publisher, series, idx])
            }
            exec("COMMIT")
        }
    }

    // Same pattern as reorderSeriesGroups, one level up: manual ordering for the
    // character/collection cards shown before drilling into a specific group's series.
    func reorderCharacterGroups(publisher: String, orderedGroupNames: [String]) {
        guard !orderedGroupNames.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, groupName) in orderedGroupNames.enumerated() {
                _ = run("INSERT OR REPLACE INTO character_order (group_name, publisher, position) VALUES (?,?,?)",
                        args: [groupName, publisher, idx])
            }
            exec("COMMIT")
        }
    }

    // MARK: - Bookmarks

    func bookmarks(comicId: Int64) -> [Bookmark] {
        queue.sync {
            rows("SELECT id, comic_id, page, label, created_at FROM bookmarks WHERE comic_id = ? ORDER BY page",
                 args: [comicId]) { s in
                Bookmark(id: colInt64(s, 0), comicId: colInt64(s, 1),
                         page: colInt(s, 2), label: colText(s, 3) ?? "",
                         createdAt: colText(s, 4) ?? "")
            }
        }
    }

    @discardableResult
    func toggleBookmark(comicId: Int64, page: Int) -> Bool {
        queue.sync {
            let exists = scalarInt("SELECT COUNT(*) FROM bookmarks WHERE comic_id=? AND page=?",
                                   args: [comicId, page]) > 0
            if exists {
                _ = run("DELETE FROM bookmarks WHERE comic_id=? AND page=?", args: [comicId, page])
                return false
            } else {
                _ = run("INSERT OR REPLACE INTO bookmarks (comic_id, page) VALUES (?,?)", args: [comicId, page])
                return true
            }
        }
    }

    func setBookmarkLabel(comicId: Int64, page: Int, label: String) {
        queue.async {
            _ = self.run("UPDATE bookmarks SET label=? WHERE comic_id=? AND page=?",
                         args: [label, comicId, page])
        }
    }

    func isBookmarked(comicId: Int64, page: Int) -> Bool {
        queue.sync {
            scalarInt("SELECT COUNT(*) FROM bookmarks WHERE comic_id=? AND page=?",
                      args: [comicId, page]) > 0
        }
    }

    // MARK: - Reading history

    func logReadingSession(comicId: Int64, pageStart: Int, pageEnd: Int) {
        guard pageEnd > pageStart else { return }
        queue.async {
            _ = self.run("INSERT INTO reading_history (comic_id, page_start, page_end) VALUES (?,?,?)",
                         args: [comicId, pageStart, pageEnd])
        }
    }

    func readingHistory(limit: Int = 100) -> [HistoryEntry] {
        queue.sync {
            let sql = """
                SELECT h.id, h.comic_id, c.title, c.publisher, c.series,
                       h.page_start, h.page_end, h.read_at
                FROM reading_history h
                JOIN comics c ON c.id = h.comic_id
                ORDER BY h.read_at DESC
                LIMIT \(limit)
            """
            return rows(sql) { s in
                HistoryEntry(
                    id: colInt64(s, 0), comicId: colInt64(s, 1),
                    title: colText(s, 2) ?? "", publisher: colText(s, 3) ?? "",
                    series: colText(s, 4) ?? "",
                    pageStart: colInt(s, 5), pageEnd: colInt(s, 6),
                    readAt: colText(s, 7) ?? ""
                )
            }
        }
    }

    func issuesReadThisYear() -> Int {
        queue.sync {
            let year = String(Calendar.current.component(.year, from: Date()))
            return scalarInt("SELECT COUNT(DISTINCT comic_id) FROM reading_history WHERE strftime('%Y', read_at) = ?",
                             args: [year])
        }
    }

    // MARK: - Reading goals

    func readingGoal(year: Int) -> Int {
        queue.sync {
            let v = scalarInt("SELECT goal_count FROM reading_goals WHERE year=?", args: [year])
            return v == 0 ? 52 : v
        }
    }

    func setReadingGoal(year: Int, count: Int) {
        queue.async {
            _ = self.run("INSERT OR REPLACE INTO reading_goals (year, goal_count) VALUES (?,?)", args: [year, count])
        }
    }


    // MARK: - Series gap detection

    func missingIssueNumbers(series: String, publisher: String) -> [String] {
        queue.sync {
            let nums = rows("""
                SELECT CAST(issue_number AS INTEGER) as n FROM comics
                WHERE deleted_at IS NULL AND series=? AND publisher=?
                  AND issue_number IS NOT NULL AND issue_number != ''
                  AND CAST(issue_number AS INTEGER) > 0
                ORDER BY n
            """, args: [series, publisher]) { colInt($0, 0) }
            guard nums.count > 1 else { return [] }
            var missing: [String] = []
            for i in 1..<nums.count {
                let prev = nums[i-1], curr = nums[i]
                if curr - prev > 1 {
                    for n in (prev+1)..<curr { missing.append("#\(n)") }
                }
            }
            return missing
        }
    }

    // MARK: - Shelves

    func allShelves() -> [Shelf] {
        queue.sync {
            rows("SELECT id, name, is_builtin FROM shelves ORDER BY position, name", map: { s in
                Shelf(id: colInt64(s, 0), name: colText(s, 1) ?? "", isBuiltIn: colInt(s, 2) > 0)
            })
        }
    }

    func shelvesForComic(comicId: Int64) -> [Int64] {
        queue.sync {
            rows("SELECT shelf_id FROM comic_shelves WHERE comic_id = ?", args: [comicId], map: { colInt64($0, 0) })
        }
    }

    func addToShelf(comicId: Int64, shelfId: Int64) {
        queue.async { _ = self.run("INSERT OR IGNORE INTO comic_shelves (comic_id, shelf_id) VALUES (?,?)", args: [comicId, shelfId]) }
    }

    func removeFromShelf(comicId: Int64, shelfId: Int64) {
        queue.async { _ = self.run("DELETE FROM comic_shelves WHERE comic_id = ? AND shelf_id = ?", args: [comicId, shelfId]) }
    }

    func createShelf(name: String) -> Int64 {
        queue.sync {
            _ = run("INSERT OR IGNORE INTO shelves (name, is_builtin, position) VALUES (?,0,99)", args: [name])
            return Int64(scalarInt("SELECT id FROM shelves WHERE name = ?", args: [name]))
        }
    }

    func deleteShelf(_ shelfId: Int64) {
        queue.async { _ = self.run("DELETE FROM shelves WHERE id = ? AND is_builtin = 0", args: [shelfId]) }
    }

    // MARK: - Trash / restore

    func trashedComics() -> [Comic] {
        queue.sync {
            let sql = "\(comicSelect) WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC"
            return rows(sql, map: comicRow)
        }
    }

    func restoreComic(id: Int64) {
        queue.async { _ = self.run("UPDATE comics SET deleted_at = NULL WHERE id = ?", args: [id]) }
    }

    // Synchronous (unlike restoreComic's fire-and-forget queue.async) — callers doing an
    // undo need the restore to have actually landed before they reload(), or the just-undone
    // comics would still show as deleted for one more frame.
    func restore(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            let sql = "UPDATE comics SET deleted_at = NULL WHERE id IN (\(ph))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), id) }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

}
