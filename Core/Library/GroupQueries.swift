import Foundation

extension Database {
    /// Character groups, optionally within one publisher or narrowed by a search.
    func characterGroups(publisher: String?, search: String? = nil) async throws -> [CharacterGroup] {
        try await read { db in
            var conds = ["c.deleted_at IS NULL"]
            var args: [SQLBindable?] = []
            if let publisher { conds.append("c.publisher = ?"); args.append(publisher) }
            if let search, let clause = ComicSQL.searchClause(search) { conds.append(clause.sql); args += clause.args }
            let group = ComicSQL.groupName
            return try db.query("""
                SELECT \(group) AS name, MAX(c.character), c.publisher, COUNT(*),
                       COALESCE(MIN(CASE WHEN c.issue_number IN ('1','01','001') THEN c.id END), MIN(c.id)),
                       cc.image_path,
                       SUM(rp.current_page > 0), SUM(rp.finished_at IS NOT NULL)
                FROM comics c
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                LEFT JOIN character_covers cc ON cc.group_name = \(group) AND cc.publisher = c.publisher
                LEFT JOIN character_order co ON co.group_name = \(group) AND co.publisher = c.publisher
                WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.publisher, name
                ORDER BY (SELECT COALESCE(po.position, 999999) FROM publisher_order po WHERE po.publisher = c.publisher),
                         c.publisher, COALESCE(MIN(co.position), 999999), name COLLATE NOCASE
                """, args) { r in
                CharacterGroup(name: r.string(0) ?? "", character: r.string(1), publisher: r.string(2) ?? "",
                               count: r.int(3), coverComicID: r.int64(4), customCoverPath: r.string(5),
                               started: r.int(6), finished: r.int(7))
            }
        }
    }

    func seriesGroups(group: String, publisher: String) async throws -> [SeriesGroup] {
        try await read { db in
            try db.query("""
                SELECT c.series, c.publisher, COUNT(*),
                       COALESCE(MAX(sc.comic_id), MIN(CASE WHEN c.position = (SELECT MIN(COALESCE(c2.position, c2.id))
                            FROM comics c2 WHERE c2.publisher = c.publisher AND c2.series = c.series AND c2.deleted_at IS NULL)
                            THEN c.id END), MIN(c.id)),
                       MAX(sc.image_path), SUM(rp.current_page > 0), SUM(rp.finished_at IS NOT NULL), MAX(c.folder_group)
                FROM comics c
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                LEFT JOIN series_covers sc ON sc.series = c.series AND sc.publisher = c.publisher
                WHERE c.deleted_at IS NULL AND c.publisher = ? AND \(ComicSQL.groupName) = ?
                GROUP BY c.series
                ORDER BY COALESCE((SELECT so.position FROM series_order so WHERE so.group_name = ? AND so.publisher = ?
                                   AND so.series = c.series), 9999), c.series COLLATE NOCASE
                """, [publisher, group, group, publisher]) { r in
                SeriesGroup(series: r.string(0) ?? "", publisher: r.string(1) ?? "", groupName: group,
                            count: r.int(2), coverComicID: r.int64(3), customCoverPath: r.string(4),
                            started: r.int(5), finished: r.int(6), folderGroup: r.string(7))
            }
        }
    }

    // MARK: - Ordering

    func reorderPublishers(_ publishers: [String]) async throws {
        try await write { db in
            try db.transaction {
                try db.runBatch("INSERT OR REPLACE INTO publisher_order (publisher, position) VALUES (?,?)",
                                publishers.enumerated().map { [$0.element, $0.offset] })
            }
        }
    }

    func reorderCharacterGroups(_ names: [String], publisher: String) async throws {
        try await write { db in
            try db.transaction {
                try db.runBatch("INSERT OR REPLACE INTO character_order (group_name, publisher, position) VALUES (?,?,?)",
                                names.enumerated().map { [$0.element, publisher, $0.offset] })
            }
        }
    }

    func reorderSeries(_ series: [String], group: String, publisher: String) async throws {
        try await write { db in
            try db.transaction {
                try db.runBatch("INSERT OR REPLACE INTO series_order (group_name, publisher, series, position) VALUES (?,?,?,?)",
                                series.enumerated().map { [group, publisher, $0.element, $0.offset] })
            }
        }
    }

    /// Manual issue order. Stored both as the position and as an override so rescans keep it.
    func reorderIssues(_ ids: [Int64]) async throws {
        try await write { db in
            try db.transaction {
                let rows = ids.enumerated().map { [($0.offset + 1) * ComicClassifier.positionStride, $0.element] as [SQLBindable?] }
                try db.runBatch("UPDATE comics SET position = ? WHERE id = ?", rows)
                try db.runBatch("INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')",
                                rows.map { [$0[1], $0[0]] })
            }
        }
    }

    /// Restores automatic issue-number order for a series.
    func resetIssueOrder(series: String, publisher: String) async throws {
        try await write { db in
            try db.transaction {
                try db.run("""
                    DELETE FROM reading_order_overrides WHERE comic_id IN
                    (SELECT id FROM comics WHERE series = ? AND publisher = ?)
                    """, [series, publisher])
                try db.run("UPDATE comics SET position = NULL WHERE series = ? AND publisher = ?", [series, publisher])
                try Database.seedPositions(db)
            }
        }
    }

    /// Fills in sort positions for comics that don't have one: specials after the regular run.
    static func seedPositions(_ db: SQLiteConnection) throws {
        try db.run("""
            UPDATE comics SET position =
                is_special_issue(issue_number, title, series) * \(ComicClassifier.specialBandOffset)
                + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicClassifier.positionStride)
            WHERE position IS NULL
            """)
    }

    // MARK: - Series

    func renameSeries(_ old: String, to new: String, publisher: String) async throws {
        try await write { db in
            try db.transaction {
                for table in ["comics", "series_covers", "series_reader_prefs", "series_order"] {
                    try db.run("UPDATE \(table) SET series = ? WHERE series = ? AND publisher = ?", [new, old, publisher])
                }
                try db.run("UPDATE comics SET meta_edited = 1 WHERE series = ? AND publisher = ?", [new, publisher])
            }
        }
    }

    func seriesExists(_ name: String, publisher: String) async throws -> Bool {
        try await read { db in
            try db.scalarInt("SELECT COUNT(*) FROM comics WHERE series = ? AND publisher = ? AND deleted_at IS NULL",
                             [name, publisher]) > 0
        }
    }

    func setSeriesCover(series: String, publisher: String, comicID: Int64?, imagePath: String?) async throws {
        try await write { db in
            if comicID == nil && imagePath == nil {
                try db.run("DELETE FROM series_covers WHERE series = ? AND publisher = ?", [series, publisher])
            } else {
                try db.run("""
                    INSERT INTO series_covers (series, publisher, comic_id, image_path) VALUES (?,?,?,?)
                    ON CONFLICT(series, publisher) DO UPDATE SET comic_id = excluded.comic_id, image_path = excluded.image_path
                    """, [series, publisher, comicID, imagePath])
            }
        }
    }

    func setCharacterCover(group: String, publisher: String, imagePath: String?) async throws {
        try await write { db in
            if let imagePath {
                try db.run("INSERT OR REPLACE INTO character_covers (group_name, publisher, image_path) VALUES (?,?,?)",
                           [group, publisher, imagePath])
            } else {
                try db.run("DELETE FROM character_covers WHERE group_name = ? AND publisher = ?", [group, publisher])
            }
        }
    }

    func readerPrefs(series: String, publisher: String) -> SeriesReaderPrefs? {
        try? readSync { db in
            try db.first("SELECT fit_mode, rtl, double_spread, scroll_mode FROM series_reader_prefs WHERE series = ? AND publisher = ?",
                         [series, publisher]) { r in
                SeriesReaderPrefs(fitMode: FitMode(rawValue: r.string(0) ?? "") ?? .fitPage, rightToLeft: r.bool(1),
                                  doublePage: r.bool(2), scrollMode: r.bool(3))
            }
        } ?? nil
    }

    func setReaderPrefs(_ p: SeriesReaderPrefs, series: String, publisher: String) async throws {
        try await write { db in
            try db.run("INSERT OR REPLACE INTO series_reader_prefs VALUES (?,?,?,?,?,?)",
                       [series, publisher, p.fitMode.rawValue, p.rightToLeft, p.doublePage, p.scrollMode])
        }
    }
}
