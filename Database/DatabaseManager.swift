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

    private func migrate() {

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

        exec("ALTER TABLE comics ADD COLUMN comicinfo_issue_number TEXT")

        exec("""
        CREATE TABLE IF NOT EXISTS series_links (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_publisher TEXT NOT NULL,
            parent_series    TEXT NOT NULL,
            child_publisher  TEXT NOT NULL,
            child_series     TEXT NOT NULL,
            sequence_order   INTEGER NOT NULL,
            created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source           TEXT NOT NULL DEFAULT 'manual',
            UNIQUE(child_publisher, child_series)
        )
        """)
        exec("ALTER TABLE series_links ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'")

        // Offline comics-database match (see Services/OfflineMetadataStore.swift) — a real
        // publication date/order looked up from a downloaded reference database, entirely
        // separate from anything derived from the file itself. Feeds ReadingOrderEngine's
        // highest-confidence tier when present; never required, never overwrites the file.
        exec("ALTER TABLE comics ADD COLUMN gcd_issue_id INTEGER")
        exec("ALTER TABLE comics ADD COLUMN gcd_cover_date TEXT")
        exec("ALTER TABLE comics ADD COLUMN gcd_match_confidence INTEGER")
        exec("ALTER TABLE comics ADD COLUMN gcd_match_reason TEXT")

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

    func recomputeReadingOrder(mode: ReadingOrderMode = .current, affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row {
                let id: Int64; let publisher: String; let series: String; let groupKey: String
                let filePath: String; let issueNumber: String?; let comicInfoIssueNumber: String?
                let title: String
                let year: Int?; let month: Int?; let day: Int?; let storyArc: String?
                let gcdCoverDate: String?
            }

            var effectiveKeys = affectedGroupKeys
            if effectiveKeys != nil {
                let allLinkKeys: [String] = rows(
                    "SELECT parent_publisher, parent_series FROM series_links UNION SELECT child_publisher, child_series FROM series_links"
                ) { s in "\(colText(s, 0) ?? ""):\(colText(s, 1) ?? "")" }
                if !allLinkKeys.isEmpty { effectiveKeys!.formUnion(allLinkKeys) }
            }

            var sql = """
            SELECT id, publisher, series, publisher || ':' || COALESCE(NULLIF(series_group,''), series),
                   file_path, issue_number, comicinfo_issue_number, title, year, cover_month, cover_day, story_arc,
                   gcd_cover_date
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
                    storyArc: colText(s, 11), gcdCoverDate: colText(s, 12))
            }

            var positions: [Int64: (position: Int, confidence: Int, reason: String)] = [:]

            switch mode {
            case .intelligent:
                // A verified cover date from the offline comics database always outranks a
                // locally-parsed one — it's real editorial data, not inference — so it feeds
                // the engine's existing date-interpolation tier as if it were a perfect filename.
                var usedGCDDate: Set<Int64> = []
                let inputs = allRows.map { row -> ReadingOrderEngine.ReadingOrderInput in
                    var y = row.year, m = row.month, d = row.day
                    if let gcd = row.gcdCoverDate, let parsed = Self.parseGCDDate(gcd) {
                        y = parsed.year; m = parsed.month; d = parsed.day
                        usedGCDDate.insert(row.id)
                    }
                    return ReadingOrderEngine.ReadingOrderInput(
                        id: row.id, groupKey: row.groupKey,
                        legacyNumber: ReadingOrderEngine.parseLegacyNumber(row.issueNumber),
                        comicType: ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series),
                        year: y, month: m, day: d, storyArc: row.storyArc,
                        title: row.title
                    )
                }
                let results = ReadingOrderEngine.computeSeriesPositions(inputs)
                for row in allRows {
                    guard let r = results[row.id] else { continue }
                    if usedGCDDate.contains(row.id) {
                        positions[row.id] = (r.position, r.confidence, "Placed using its real publication date from the offline comics database")
                    } else {
                        positions[row.id] = (r.position, r.confidence, r.reason)
                    }
                }
            case .filename:
                break
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
                    guard !visited.contains(seriesKey) else { return }
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

    /// GCD's key_date format is "YYYY-MM-DD" with "00" for an unknown month/day segment.
    private static func parseGCDDate(_ raw: String) -> (year: Int, month: Int?, day: Int?)? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), year > 0 else { return nil }
        let month = Int(parts[1]).flatMap { $0 > 0 ? $0 : nil }
        let day = month != nil ? Int(parts[2]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (year, month, day)
    }

    /// Matches every comic against the offline comics database (if downloaded) by series name,
    /// publisher, issue number, and year — conservative by design, see OfflineMetadataStore.
    /// A comic that already has a match keeps it unless recompute finds a different one, and a
    /// comic with no match at all is left completely alone (no columns touched).
    func recomputeGCDMatches(affectedGroupKeys: Set<String>? = nil) {
        guard OfflineMetadataStore.shared.isAvailable else { return }
        queue.sync {
            var sql = """
                SELECT id, series, publisher, issue_number, year, title,
                       publisher || ':' || COALESCE(NULLIF(series_group,''), series)
                FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = affectedGroupKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || COALESCE(NULLIF(series_group,''), series)) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            struct Row { let id: Int64; let series: String; let publisher: String; let issueNumber: String?; let year: Int?; let title: String }
            let candidates: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), series: colText(s, 1) ?? "General", publisher: colText(s, 2) ?? "Unknown",
                    issueNumber: colText(s, 3), year: sqlite3_column_type(s, 4) != SQLITE_NULL ? colInt(s, 4) : nil,
                    title: colText(s, 5) ?? "")
            }
            exec("BEGIN")
            for row in candidates {
                let comicType = ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series)
                guard let match = OfflineMetadataStore.shared.lookupIssue(
                    series: row.series, publisher: row.publisher, issueNumber: row.issueNumber, year: row.year,
                    comicType: comicType
                ) else { continue }
                _ = run("""
                    UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = ?, gcd_match_reason = ?
                    WHERE id = ?
                    """, args: [match.gcdIssueId, match.coverDate, match.confidence, match.reason, row.id])
            }
            exec("COMMIT")
        }
    }

    /// Auto-derives series_links from the offline database's known real-world series
    /// continuations (see OfflineMetadataStore.allSeriesBonds), matched against the user's own
    /// library by normalized series name + publisher. Only ever touches links this function
    /// created itself (source = 'gcd') — a manual link the user made always takes precedence
    /// and is never overwritten or removed here.
    func autoPopulateSeriesLinksFromGCD() {
        let bonds = OfflineMetadataStore.shared.allSeriesBonds()
        guard !bonds.isEmpty else { return }
        queue.sync {
            struct LibSeries { let publisher: String; let series: String; let normName: String }
            let librarySeries: [LibSeries] = rows(
                "SELECT DISTINCT publisher, series FROM comics WHERE deleted_at IS NULL"
            ) { s in
                let series = colText(s, 1) ?? "General"
                return LibSeries(publisher: colText(s, 0) ?? "Unknown", series: series,
                                  normName: OfflineMetadataStore.normalizeSeriesName(series))
            }
            guard librarySeries.count > 1 else { return }
            var byNormName: [String: [LibSeries]] = [:]
            for s in librarySeries { byNormName[s.normName, default: []].append(s) }

            for bond in bonds {
                guard let origin = byNormName[OfflineMetadataStore.normalizeSeriesName(bond.originName)]?.first,
                      let target = byNormName[OfflineMetadataStore.normalizeSeriesName(bond.targetName)]?.first,
                      origin.publisher != target.publisher || origin.series != target.series else { continue }
                let alreadyLinked = scalarInt(
                    "SELECT COUNT(*) FROM series_links WHERE child_publisher = ? AND child_series = ?",
                    args: [target.publisher, target.series]
                ) > 0
                guard !alreadyLinked else { continue }
                let nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")
                _ = run("""
                    INSERT OR IGNORE INTO series_links
                        (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source)
                    VALUES (?, ?, ?, ?, ?, 'gcd')
                    """, args: [origin.publisher, origin.series, target.publisher, target.series, nextSeq])
            }
        }
    }

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

    struct SeriesLink {
        let id: Int64
        let parentPublisher: String; let parentSeries: String
        let childPublisher: String; let childSeries: String
        let sequenceOrder: Int
        let source: String
    }

    func seriesLinks() -> [SeriesLink] {
        queue.sync {
            rows("""
                SELECT id, parent_publisher, parent_series, child_publisher, child_series, sequence_order, source
                FROM series_links ORDER BY sequence_order
                """) { s in
                SeriesLink(id: colInt64(s, 0), parentPublisher: colText(s, 1) ?? "", parentSeries: colText(s, 2) ?? "",
                           childPublisher: colText(s, 3) ?? "", childSeries: colText(s, 4) ?? "", sequenceOrder: colInt(s, 5),
                           source: colText(s, 6) ?? "manual")
            }
        }
    }

    /// `source` distinguishes a link the user made explicitly ("manual", always wins, never
    /// auto-removed) from one derived automatically from the offline comics database
    /// ("gcd") — auto-derived links are safe to re-derive/replace on a future database refresh,
    /// manual ones never are.
    @discardableResult
    func addSeriesLink(parentPublisher: String, parentSeries: String, childPublisher: String, childSeries: String,
                       source: String = "manual") -> Bool {
        queue.sync {
            let nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")
            let before = scalarInt("SELECT COUNT(*) FROM series_links WHERE child_publisher=? AND child_series=?",
                                    args: [childPublisher, childSeries])
            guard before == 0 else { return false }
            _ = run("""
                INSERT INTO series_links (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source)
                VALUES (?, ?, ?, ?, ?, ?)
                """, args: [parentPublisher, parentSeries, childPublisher, childSeries, nextSeq, source])
            return true
        }
    }

    func removeSeriesLink(childPublisher: String, childSeries: String) {
        queue.sync {
            _ = run("DELETE FROM series_links WHERE child_publisher = ? AND child_series = ?",
                    args: [childPublisher, childSeries])
        }
    }

    func allSeriesNames() -> [(publisher: String, series: String)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series FROM comics
                WHERE deleted_at IS NULL ORDER BY series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General") }
        }
    }

    func seriesWithMultipleFirstIssues() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND CAST(NULLIF(issue_number, '') AS REAL) = 1
                GROUP BY publisher, series HAVING COUNT(*) > 1
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func seriesNeedingSpecialReposition() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND reading_order_confidence = 0
                GROUP BY publisher, series HAVING COUNT(*) > 0
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

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
            readingOrderReason: colText(s, 26),
            gcdMatchConfidence: sqlite3_column_type(s, 27) != SQLITE_NULL ? colInt(s, 27) : nil
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
               r.review, c.reading_order_position, c.reading_order_confidence, c.reading_order_reason,
               c.gcd_match_confidence
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

    enum SortOrder: String, CaseIterable, Identifiable {
        case publisher = "Publisher", title = "Title", dateAdded = "Recently Added",
             rating = "Top Rated", progress = "Most Read", manual = "Custom"
        var id: String { rawValue }
        var clause: String {
            switch self {

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

    private static let folderDerivedColumns: Set<String> = ["title", "series", "publisher", "character"]

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

    func tags(for comicId: Int64) -> [Tag] {
        queue.sync {
            rows("SELECT t.id, t.name FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id WHERE ct.comic_id = ? ORDER BY t.name",
                 args: [comicId]) { Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "") }
        }
    }

    func addTag(name: String, to comicId: Int64) {
        queue.sync {

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

    func allComicPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") { s in
                (id: self.colInt64(s, 0), path: self.colText(s, 1) ?? "")
            }
        }
    }

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

                _ = run("""
                    UPDATE comics SET position = ?, reading_order_position = ?,
                           reading_order_confidence = 100, reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, args: [idx, idx, id])

                _ = run("""
                    INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')
                    """, args: [id, idx])
            }
            exec("COMMIT")
        }
    }

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

    func reorderRuns(orderedIds: [Int64]) {
        queue.sync {
            exec("BEGIN")
            for (idx, id) in orderedIds.enumerated() {
                _ = run("UPDATE runs SET position = ? WHERE id = ?", args: [idx, id])
            }
            exec("COMMIT")
        }
    }

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

            let builtins = [("Currently Reading", 0), ("Want to Read", 1), ("Finished", 2), ("DNF", 3)]
            for (name, pos) in builtins {
                exec("INSERT OR IGNORE INTO shelves (name, is_builtin, position) VALUES ('\(name)', 1, \(pos))")
            }
        }
    }

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

                if let num = item.issueNumber {
                    _ = run("""
                        UPDATE comics SET issue_number=? WHERE id=? AND meta_edited=0
                        AND (issue_number IS NULL OR issue_number != ?)
                        """, args: [num, item.id, num])
                }
            }
            exec("COMMIT")

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

    func trashedComics() -> [Comic] {
        queue.sync {
            let sql = "\(comicSelect) WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC"
            return rows(sql, map: comicRow)
        }
    }

    func restoreComic(id: Int64) {
        queue.async { _ = self.run("UPDATE comics SET deleted_at = NULL WHERE id = ?", args: [id]) }
    }

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
