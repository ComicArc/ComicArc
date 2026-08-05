import Foundation
import SQLite3

extension DatabaseManager {
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
            _ = inTransaction {
                runBatch("INSERT OR REPLACE INTO publisher_order (publisher, position) VALUES (?,?)",
                         rows: orderedPublishers.enumerated().map { [$0.element, $0.offset] })
            }
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
        /// The folder between the Character folder and this series' own folder, if the library's
        /// on-disk layout has one (e.g. "Batman (Modern)") -- nil for the common 1-3 level layout.
        var folderGroup: String? = nil
    }

    func characterGroups(publisher: String? = nil, search: String? = nil) -> [CharacterGroup] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if let q = search, !q.isEmpty {
                conds.append("(c.series LIKE ? ESCAPE '\\' OR (c.character NOT LIKE '%,%' AND c.character NOT LIKE '%[%' AND LENGTH(COALESCE(c.character,'')) <= 60 AND c.character LIKE ? ESCAPE '\\'))")
                let p = "%\(Self.likeEscaped(q))%"
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
                       sc.image_path,
                       MAX(c.folder_group) as folder_group
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
                                   coverImagePath: colText(s, 6), folderGroup: colText(s, 7))
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
            _ = inTransaction {
                runBatch("INSERT OR REPLACE INTO series_order (group_name, publisher, series, position) VALUES (?,?,?,?)",
                         rows: orderedSeries.enumerated().map { [groupName, publisher, $0.element, $0.offset] })
            }
        }
    }

    func reorderCharacterGroups(publisher: String, orderedGroupNames: [String]) {
        guard !orderedGroupNames.isEmpty else { return }
        queue.sync {
            _ = inTransaction {
                runBatch("INSERT OR REPLACE INTO character_order (group_name, publisher, position) VALUES (?,?,?)",
                         rows: orderedGroupNames.enumerated().map { [$0.element, publisher, $0.offset] })
            }
        }
    }

    /// Every manual series/character/publisher reorder and every series' custom cover assignment
    /// (comic-based only -- a custom *uploaded image* cover isn't included here, since restoring
    /// one would mean embedding actual image bytes in the backup, not just a reference). All four
    /// are deliberate user customizations with no automatic way to regenerate them, exactly like
    /// the manual GCD match above -- previously silently absent from backup/restore.
    func allSeriesOrderPositions() -> [(groupName: String, publisher: String, series: String, position: Int)] {
        queue.sync {
            rows("SELECT group_name, publisher, series, position FROM series_order") { s in
                (colText(s, 0) ?? "", colText(s, 1) ?? "", colText(s, 2) ?? "", colInt(s, 3))
            }
        }
    }

    func allCharacterOrderPositions() -> [(groupName: String, publisher: String, position: Int)] {
        queue.sync {
            rows("SELECT group_name, publisher, position FROM character_order") { s in
                (colText(s, 0) ?? "", colText(s, 1) ?? "", colInt(s, 2))
            }
        }
    }

    func allPublisherOrderPositions() -> [(publisher: String, position: Int)] {
        queue.sync {
            rows("SELECT publisher, position FROM publisher_order") { s in
                (colText(s, 0) ?? "", colInt(s, 1))
            }
        }
    }

    func allSeriesCoverComicAssignments() -> [(series: String, publisher: String, comicId: Int64)] {
        queue.sync {
            rows("SELECT series, publisher, comic_id FROM series_covers WHERE comic_id IS NOT NULL") { s in
                (colText(s, 0) ?? "", colText(s, 1) ?? "", colInt64(s, 2))
            }
        }
    }

}
