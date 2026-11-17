import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension DatabaseManager {
    /// Escapes `%`, `_` and `\` so user input is matched literally by LIKE (paired with `ESCAPE
    /// '\'`).
    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Every word must match at least one field, so "batman classic 1987" narrows step by step.
    /// Covers the folder hierarchy (publisher, character, folder group such as "Classic", series)
    /// as well as title, issue number, year, credits, story arc, notes and tags.
    static func searchCondition(_ query: String) -> (sql: String, args: [Any?])? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let fields = ["c.title", "c.series", "c.publisher", "c.character", "c.folder_group",
                      "c.issue_number", "CAST(c.year AS TEXT)", "c.writer", "c.penciller",
                      "c.story_arc", "c.notes"]
        var clauses: [String] = []
        var args: [Any?] = []
        for word in words {
            let pattern = "%\(likeEscaped(word))%"
            var matches = fields.map { "\($0) LIKE ? ESCAPE '\\'" }
            matches.append("c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON ct.tag_id = t.id WHERE t.name LIKE ? ESCAPE '\\')")
            args += Array(repeating: pattern, count: matches.count)
            clauses.append("(" + matches.joined(separator: " OR ") + ")")
        }
        return (clauses.joined(separator: " AND "), args)
    }

    func allComics(publisher: String? = nil, character: String? = nil, series: String? = nil,
                   search: String? = nil, sortOrder: SortOrder = .publisher,
                   favoritesOnly: Bool = false,
                   nullCharacterOnly: Bool = false, tag: String? = nil,
                   unreadOnly: Bool = false) -> [Comic] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if nullCharacterOnly { conds.append("c.character IS NULL") }
            else if let chr = character { conds.append("c.character = ?"); args.append(chr) }
            if let ser = series { conds.append("c.series = ?"); args.append(ser) }
            if let q = search, let match = Self.searchCondition(q) {
                conds.append(match.sql); args += match.args
            }
            if favoritesOnly   { conds.append("f.comic_id IS NOT NULL") }
            if unreadOnly      { conds.append("COALESCE(rp.current_page, 0) = 0") }
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

    /// The next comic in the same series, in manual order (position, then id). Nil at the end.
    func nextComic(after comic: Comic) -> Comic? { adjacentComic(to: comic, forward: true) }

    func previousComic(before comic: Comic) -> Comic? { adjacentComic(to: comic, forward: false) }

    private func adjacentComic(to comic: Comic, forward: Bool) -> Comic? {
        queue.sync {
            let orderExpr = "COALESCE(c.position, c.id)"
            let comparison = forward ? ">" : "<"
            let direction = forward ? "" : " DESC"
            let sql = """
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ?
                  AND \(orderExpr) \(comparison) (SELECT COALESCE(position, id) FROM comics WHERE id = ?)
                ORDER BY \(orderExpr)\(direction), c.title\(direction) LIMIT 1
                """
            return rows(sql, args: [comic.publisher, comic.series, comic.id], map: comicRow).first
        }
    }

    struct MetadataInspectorInfo {
        let comic: Comic
        let coverMonth: Int?
        let coverDay: Int?
        let comicInfoIssueNumber: String?
        let alternateNumber: String?
        let storyArcNumber: String?
        let seriesGroup: String?
        let hasComicInfo: Bool?
        let duplicateMatchCount: Int
    }

    func metadataInspectorInfo(comicId: Int64) -> MetadataInspectorInfo? {
        queue.sync {
            guard let comic = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [comicId], map: comicRow).first else {
                return nil
            }
            struct Extra {
                let coverMonth: Int?; let coverDay: Int?; let comicInfoIssueNumber: String?
                let alternateNumber: String?; let storyArcNumber: String?; let seriesGroup: String?
                let hasComicInfo: Int?
            }
            guard let extra = rows("""
                SELECT cover_month, cover_day, comicinfo_issue_number, alternate_number,
                       story_arc_number, series_group, has_comicinfo
                FROM comics WHERE id = ?
                """, args: [comicId], map: { s in
                Extra(coverMonth: sqlite3_column_type(s, 0) != SQLITE_NULL ? colInt(s, 0) : nil,
                      coverDay: sqlite3_column_type(s, 1) != SQLITE_NULL ? colInt(s, 1) : nil,
                      comicInfoIssueNumber: colText(s, 2), alternateNumber: colText(s, 3),
                      storyArcNumber: colText(s, 4), seriesGroup: colText(s, 5),
                      hasComicInfo: sqlite3_column_type(s, 6) != SQLITE_NULL ? colInt(s, 6) : nil)
            }).first else { return nil }

            return MetadataInspectorInfo(
                comic: comic,
                coverMonth: extra.coverMonth, coverDay: extra.coverDay,
                comicInfoIssueNumber: extra.comicInfoIssueNumber, alternateNumber: extra.alternateNumber,
                storyArcNumber: extra.storyArcNumber, seriesGroup: extra.seriesGroup,
                hasComicInfo: extra.hasComicInfo.map { $0 != 0 },
                duplicateMatchCount: _duplicateMatchCountUnlocked(for: comicId)
            )
        }
    }

    func filePath(forComicId id: Int64) -> String? {
        queue.sync {
            rows("SELECT file_path FROM comics WHERE id = ? AND deleted_at IS NULL", args: [id],
                 map: { colText($0, 0) ?? "" }).first
        }
    }

    /// The ideal filename for this comic (see `ComicFileNaming`), or nil if it already matches.
    func proposedFilename(comicId: Int64) -> String? {
        queue.sync {
            guard let target = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL",
                                     args: [comicId], map: comicRow).first else { return nil }
            guard let ideal = ComicFileNaming.idealFilenames(for: [target])[comicId] else { return nil }
            let currentName = URL(fileURLWithPath: target.filePath).lastPathComponent
            return currentName == ideal ? nil : ideal
        }
    }

    /// Started but unfinished comics, most recently read first. `limit` nil returns all of them.
    func inProgress(limit: Int? = nil, search: String? = nil) -> [Comic] {
        let match = search.flatMap(Self.searchCondition)
        return queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.current_page > 0
                  AND (c.page_count = 0 OR rp.current_page < c.page_count - 2)
                  \(match.map { "AND \($0.sql)" } ?? "")
                ORDER BY rp.last_read DESC LIMIT ?
            """, args: (match?.args ?? []) + [limit ?? -1], map: comicRow)
        }
    }

    func inProgressCount() -> Int {
        queue.sync {
            scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON rp.comic_id = c.id
                WHERE c.deleted_at IS NULL AND rp.current_page > 0
                  AND (c.page_count = 0 OR rp.current_page < c.page_count - 2)
            """)
        }
    }

    func recentlyFinished(limit: Int) -> [Comic] {
        queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.finished_at IS NOT NULL
                ORDER BY rp.finished_at DESC LIMIT ?
            """, args: [limit], map: comicRow)
        }
    }

    /// Nil when `current` is empty/a placeholder or agrees with `proposed`, i.e. safe to auto-
    /// apply.
    static func detectMetadataConflict(
        field: String, current: String?, proposed: String?, source: String, comicId: Int64
    ) -> MetadataConflictInput? {
        guard let current else { return nil }
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCurrent.isEmpty, !identityPlaceholders.contains(normalizedCurrent) else { return nil }
        let normalizedProposed = (proposed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCurrent != normalizedProposed else { return nil }
        return MetadataConflictInput(comicId: comicId, field: field, current: current, proposed: proposed, source: source)
    }

    func batchInsert(_ comics: [ComicInsert]) {
        guard !comics.isEmpty else { return }
        // Applied after this queue.sync returns: `upsertMetadataConflicts` takes the queue itself.
        let conflicts: [MetadataConflictInput] = queue.sync {
            // For paths already in the library, a genuine disagreement with existing metadata is
            // flagged for review instead of overwritten.
            struct Existing { let id: Int64; let series: String?; let publisher: String?; let issueNumber: String?; let metaEdited: Bool }
            let paths = comics.map(\.filePath)
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let existingByPath: [String: Existing] = Dictionary(uniqueKeysWithValues: rows(
                "SELECT file_path, id, series, publisher, issue_number, meta_edited FROM comics WHERE file_path IN (\(placeholders))",
                args: paths.map { $0 as Any? }
            ) { s in
                (colText(s, 0) ?? "", Existing(id: colInt64(s, 1), series: colText(s, 2), publisher: colText(s, 3),
                                                issueNumber: colText(s, 4), metaEdited: colInt(s, 5) != 0))
            })

            var conflicts: [MetadataConflictInput] = []
            let resolvedComics: [ComicInsert] = comics.map { c in
                guard let existing = existingByPath[c.filePath], !existing.metaEdited else { return c }
                var adjusted = c
                if let conflict = Self.detectMetadataConflict(field: "series", current: existing.series, proposed: c.series,
                                                                source: c.seriesSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.series = existing.series ?? c.series
                }
                if let conflict = Self.detectMetadataConflict(field: "publisher", current: existing.publisher, proposed: c.publisher,
                                                                source: c.publisherSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.publisher = existing.publisher ?? c.publisher
                }
                if let conflict = Self.detectMetadataConflict(field: "issue_number", current: existing.issueNumber, proposed: c.issueNumber,
                                                                source: c.issueNumberSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.issueNumber = existing.issueNumber
                }
                return adjusted
            }

            _ = inTransaction {
                let insertRows: [[Any?]] = resolvedComics.map { c in
                    [c.title, c.filePath, c.publisher, c.character,
                     c.series, c.issueNumber, c.pageCount, c.writer,
                     c.penciller, c.year.map { Int64($0) }, c.storyArc,
                     c.languageIso, c.fileHash, c.coverMonth.map { Int64($0) },
                     c.coverDay.map { Int64($0) }, c.alternateNumber, c.storyArcNumber, c.seriesGroup, c.comicInfoIssueNumber,
                     c.volume, c.format, c.hasComicInfo.map { $0 ? Int64(1) : Int64(0) },
                     c.comicInfoSeries, c.comicInfoPublisher, c.folderSeries, c.folderPublisher, c.folderGroup]
                }
                // ON CONFLICT revives a soft-deleted row at the same path, so its progress, tags
                // and path memberships stay attached.
                let ok1 = runBatch("""
                    INSERT INTO comics
                        (title, file_path, publisher, character, series, issue_number,
                         page_count, writer, penciller, year, story_arc, language_iso, file_hash, cover_month,
                         cover_day, alternate_number, story_arc_number, series_group, comicinfo_issue_number, volume,
                         format, has_comicinfo, comicinfo_series, comicinfo_publisher, folder_series, folder_publisher,
                         folder_group)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(file_path) DO UPDATE SET
                        deleted_at = NULL, scan_retry_count = 0,
                        title = CASE WHEN comics.meta_edited = 0 THEN excluded.title ELSE comics.title END,
                        publisher = CASE WHEN comics.meta_edited = 0 THEN excluded.publisher ELSE comics.publisher END,
                        character = CASE WHEN comics.meta_edited = 0 THEN excluded.character ELSE comics.character END,
                        series = CASE WHEN comics.meta_edited = 0 THEN excluded.series ELSE comics.series END,
                        issue_number = CASE WHEN comics.meta_edited = 0 THEN excluded.issue_number ELSE comics.issue_number END,
                        page_count = excluded.page_count,
                        writer = excluded.writer, penciller = excluded.penciller, year = excluded.year,
                        story_arc = excluded.story_arc, language_iso = excluded.language_iso, file_hash = excluded.file_hash,
                        cover_month = excluded.cover_month, cover_day = excluded.cover_day,
                        alternate_number = excluded.alternate_number, story_arc_number = excluded.story_arc_number,
                        series_group = excluded.series_group, comicinfo_issue_number = excluded.comicinfo_issue_number,
                        volume = excluded.volume, format = excluded.format, has_comicinfo = excluded.has_comicinfo,
                        comicinfo_series = excluded.comicinfo_series, comicinfo_publisher = excluded.comicinfo_publisher,
                        folder_series = excluded.folder_series, folder_publisher = excluded.folder_publisher,
                        folder_group = excluded.folder_group
                    """, rows: insertRows)

                // Clamp saved progress if the page count shrank.
                let clampRows: [[Any?]] = comics.map { [$0.filePath, $0.filePath, $0.filePath] }
                let ok2 = runBatch("""
                    UPDATE reading_progress SET current_page = MAX(0, (SELECT page_count FROM comics WHERE file_path = ?) - 1)
                    WHERE comic_id = (SELECT id FROM comics WHERE file_path = ?)
                      AND current_page > MAX(0, (SELECT page_count FROM comics WHERE file_path = ?) - 1)
                    """, rows: clampRows)
                return ok1 && ok2
            }
            return conflicts
        }
        if !conflicts.isEmpty { upsertMetadataConflicts(conflicts) }
    }

    func zeroPageCountPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE page_count = 0 AND deleted_at IS NULL AND scan_retry_count < 3",
                 map: { (colInt64($0, 0), colText($0, 1) ?? "") })
        }
    }

    func updatePageCount(comicId: Int64, count: Int) {
        queue.sync {
            _ = run("UPDATE comics SET page_count = ? WHERE id = ?", args: [count, comicId])
            // Clamp saved progress if the page count shrank.
            _ = run("""
                UPDATE reading_progress SET current_page = MAX(0, ? - 1)
                WHERE comic_id = ? AND current_page > MAX(0, ? - 1)
                """, args: [count, comicId, count])
        }
    }

    func incrementScanRetryCount(comicId: Int64) {
        queue.sync { _ = run("UPDATE comics SET scan_retry_count = scan_retry_count + 1 WHERE id = ?", args: [comicId]) }
    }

    func resetScanRetryCounts() {
        queue.sync { _ = exec("UPDATE comics SET scan_retry_count = 0") }
    }

    func knownPaths() -> Set<String> {
        queue.sync { Set(rows("SELECT file_path FROM comics WHERE deleted_at IS NULL", map: { colText($0, 0) ?? "" })) }
    }

    func softDeletedComicId(atPath path: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM comics WHERE file_path = ? AND deleted_at IS NOT NULL", args: [path])
            return id > 0 ? Int64(id) : nil
        }
    }

    /// Active comics under `folderPath`, soft-deleted when that library folder is removed.
    func comicIds(underFolder folderPath: String) -> [Int64] {
        queue.sync {
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            return rows(
                "SELECT id FROM comics WHERE deleted_at IS NULL AND (file_path = ? OR file_path LIKE ? ESCAPE '\\')",
                args: [folderPath, "\(Self.likeEscaped(prefix))%"],
                map: { colInt64($0, 0) }
            )
        }
    }

    func knownHashes() -> Set<String> {
        queue.sync {
            Set(rows("SELECT file_hash FROM comics WHERE file_hash IS NOT NULL AND deleted_at IS NULL",
                     map: { colText($0, 0) ?? "" }))
        }
    }

    /// `reason`: "user" for an explicit delete, "missing" when the scanner can't find the file.
    func softDelete(_ ids: [Int64], reason: String = "user") {
        guard !ids.isEmpty else { return }
        queue.sync {
            for chunk in idChunks(ids) {
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                var stmt: OpaquePointer?
                let sql = "UPDATE comics SET deleted_at = datetime('now'), deleted_reason = ? WHERE id IN (\(ph))"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_text(stmt, 1, (reason as NSString).utf8String, -1, SQLITE_TRANSIENT)
                for (i, id) in chunk.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 2), id) }
                sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
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

    /// `finished_at` is sticky: set by reading to the end or Mark Read, never cleared by a reread.
    func markFinished(comicId: Int64) {
        queue.sync {
            _ = run("""
            INSERT INTO reading_progress (comic_id, finished_at)
            VALUES (?, datetime('now'))
            ON CONFLICT(comic_id) DO UPDATE
              SET finished_at = COALESCE(finished_at, datetime('now'))
            """, args: [comicId])
        }
    }

    func markUnfinished(comicId: Int64) {
        queue.sync {
            _ = run("""
            INSERT INTO reading_progress (comic_id, finished_at)
            VALUES (?, NULL)
            ON CONFLICT(comic_id) DO UPDATE SET finished_at = NULL
            """, args: [comicId])
        }
    }

    func setFinished(_ comics: [(comicId: Int64, lastPage: Int)], finished: Bool) {
        guard !comics.isEmpty else { return }
        queue.sync {
            _ = inTransaction {
                runBatch("""
                    INSERT INTO reading_progress (comic_id, current_page, last_read, finished_at)
                    VALUES (?, ?, datetime('now'), CASE WHEN ? THEN datetime('now') END)
                    ON CONFLICT(comic_id) DO UPDATE
                      SET current_page = excluded.current_page, last_read = excluded.last_read,
                          finished_at = CASE WHEN ? THEN COALESCE(finished_at, excluded.finished_at) END
                    """, rows: comics.map { [$0.comicId, finished ? $0.lastPage : 0, finished ? 1 : 0, finished ? 1 : 0] })
            }
        }
    }

    func setComicNotes(_ comicId: Int64, notes: String?) {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _ = run("UPDATE comics SET notes = ? WHERE id = ?",
                    args: [(text?.isEmpty == false) ? text : nil, comicId])
        }
    }

    func setFavorite(_ comicId: Int64, _ value: Bool) {
        queue.sync {
            if value { run("INSERT OR IGNORE INTO favorites (comic_id) VALUES (?)", args: [comicId]) }
            else      { run("DELETE FROM favorites WHERE comic_id = ?", args: [comicId]) }
        }
    }

    /// The Reading List is an ordinary Reading Path with this title.
    static let readingListTitle = "Reading List"

    static let readingListRunIdSQL = "(SELECT id FROM runs WHERE title = 'Reading List' ORDER BY id LIMIT 1)"

    func setInReadingList(_ comicId: Int64, _ value: Bool) { setInReadingList([comicId], value) }

    func setInReadingList(_ ids: [Int64], _ value: Bool) {
        guard !ids.isEmpty else { return }
        queue.sync {
            var runId = scalarInt("SELECT COALESCE(\(Self.readingListRunIdSQL), 0)")
            if value && runId == 0 {
                runId = Int(run("INSERT INTO runs (title, description) VALUES (?, '')", args: [Self.readingListTitle]))
            }
            guard runId > 0 else { return }
            _ = inTransaction {
                if value {
                    let start = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?", args: [runId])
                    return runBatch("INSERT OR IGNORE INTO run_items (run_id, comic_id, position) VALUES (?,?,?)",
                                    rows: ids.enumerated().map { [Int64(runId), $0.element, Int64(start + $0.offset)] })
                }
                return runBatch("DELETE FROM run_items WHERE run_id = ? AND comic_id = ?",
                                rows: ids.map { [Int64(runId), $0] })
            }
        }
    }

    static let folderDerivedColumns: Set<String> = ["title", "series", "publisher", "character"]

    /// Column names are interpolated into SQL, so only these are allowed.
    static let updatableMetaColumns: Set<String> = folderDerivedColumns.union(["issue_number", "notes", "year"])

    func updateMeta(comicId: Int64, fields: [(String, Any?)]) {
        let fields = fields.filter { Self.updatableMetaColumns.contains($0.0) }
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

    func comics(withPaths paths: [String]) -> [Comic] {
        guard !paths.isEmpty else { return [] }
        return queue.sync {
            idChunks(paths).flatMap { chunk -> [Comic] in
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                return rows("\(comicSelect) WHERE c.file_path IN (\(ph)) AND c.deleted_at IS NULL",
                            args: chunk.map { $0 as Any? }, map: comicRow)
            }
        }
    }

    func comics(ids: [Int64]) -> [Comic] {
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            idChunks(ids).flatMap { chunk -> [Comic] in
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                return rows("\(comicSelect) WHERE c.id IN (\(ph)) AND c.deleted_at IS NULL",
                            args: chunk.map { $0 as Any? }, map: comicRow)
            }
        }
    }

    func allComicPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") { s in
                (id: self.colInt64(s, 0), path: self.colText(s, 1) ?? "")
            }
        }
    }

    func bulkReassign(ids: [Int64], series: String?, publisher: String?) {
        guard !ids.isEmpty, series != nil || publisher != nil else { return }
        _ = queue.sync {
            inTransaction {
                var ok = true
                if let ser = series {
                    ok = runBatch("UPDATE comics SET series = ?, meta_edited = 1 WHERE id = ?",
                                   rows: ids.map { [ser, $0] })
                }
                if ok, let pub = publisher {
                    ok = runBatch("UPDATE comics SET publisher = ?, meta_edited = 1 WHERE id = ?",
                                   rows: ids.map { [pub, $0] })
                }
                return ok
            }
        }
    }

    func reorderComics(orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                let ok1 = runBatch("""
                    UPDATE comics SET position = ? WHERE id = ?
                    """, rows: orderedIds.enumerated().map { [$0.offset, $0.element] })
                let ok2 = runBatch("""
                    INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')
                    """, rows: orderedIds.enumerated().map { [$0.element, $0.offset] })
                return ok1 && ok2
            }
        }
    }

    func batchUpdateFolderMeta(_ items: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)]) {
        queue.sync {
            inTransaction {
                var ok = true
                for item in items {
                    if let pub = item.pub {
                        if run("UPDATE comics SET publisher=? WHERE id=? AND meta_edited=0", args: [pub, item.id]) == -1 { ok = false }
                    }
                    if let char = item.char {
                        if run("UPDATE comics SET character=? WHERE id=? AND meta_edited=0", args: [char, item.id]) == -1 { ok = false }
                    } else {
                        if run("UPDATE comics SET character=NULL WHERE id=? AND meta_edited=0 AND (character LIKE '%,%' OR character LIKE '%[%' OR LENGTH(COALESCE(character,''))>60)",
                               args: [item.id]) == -1 { ok = false }
                    }
                    if let ser = item.ser {
                        if run("UPDATE comics SET series=? WHERE id=? AND meta_edited=0", args: [ser, item.id]) == -1 { ok = false }
                    }
                    if run("UPDATE comics SET folder_group=? WHERE id=? AND meta_edited=0", args: [item.group, item.id]) == -1 { ok = false }
                    if run("UPDATE comics SET title=? WHERE id=? AND meta_edited=0", args: [item.title, item.id]) == -1 { ok = false }

                    if let num = item.issueNumber {
                        if run("""
                            UPDATE comics SET issue_number=? WHERE id=? AND meta_edited=0
                            AND (issue_number IS NULL OR issue_number != ?)
                            """, args: [num, item.id, num]) == -1 { ok = false }
                    }
                    if let year = item.year {
                        // Only fills an empty year; a ComicInfo.xml year always wins over a
                        // filename guess.
                        if run("UPDATE comics SET year=? WHERE id=? AND meta_edited=0 AND year IS NULL", args: [year, item.id]) == -1 { ok = false }
                    }
                }
                return ok
            }

            exec("""
                UPDATE comics SET position =
                    is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                    + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
                WHERE id NOT IN (SELECT comic_id FROM reading_order_overrides)
            """)
        }
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

    func path(forHash hash: String) -> String? {
        queue.sync {
            scalarText("SELECT file_path FROM comics WHERE file_hash = ? AND deleted_at IS NULL", args: [hash])
        }
    }

    func idForHash(_ hash: String) -> Int64? {
        queue.sync {
            rows("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL", args: [hash], map: { colInt64($0, 0) }).first
        }
    }

    /// Progress for every started comic, keyed by file hash so it matches across devices.
    func progressSyncSnapshot() -> [(fileHash: String, progress: Int, pageCount: Int, lastRead: String, finished: Bool)] {
        queue.sync {
            rows("""
                SELECT c.file_hash, rp.current_page, c.page_count, rp.last_read, rp.finished_at IS NOT NULL
                FROM reading_progress rp JOIN comics c ON c.id = rp.comic_id
                WHERE c.deleted_at IS NULL AND c.file_hash IS NOT NULL
                  AND (rp.current_page > 0 OR rp.finished_at IS NOT NULL)
                """) { s in
                (fileHash: colText(s, 0) ?? "", progress: colInt(s, 1), pageCount: colInt(s, 2),
                 lastRead: colText(s, 3) ?? "", finished: colBool(s, 4))
            }
        }
    }

    /// Applies another device's progress: last write wins by timestamp, matched by file hash,
    /// unknown comics skipped. Finished is sticky. Returns how many changed.
    func applySyncedProgress(_ items: [(fileHash: String, progress: Int, lastRead: String, finished: Bool)]) -> Int {
        queue.sync {
            var updated = 0
            for item in items {
                guard let id = rows("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL",
                                    args: [item.fileHash], map: { colInt64($0, 0) }).first else { continue }
                if item.finished,
                   scalarInt("SELECT COUNT(*) FROM reading_progress WHERE comic_id = ? AND finished_at IS NOT NULL", args: [id]) == 0 {
                    _ = run("""
                        INSERT INTO reading_progress (comic_id, current_page, finished_at) VALUES (?, ?, datetime('now'))
                        ON CONFLICT(comic_id) DO UPDATE SET finished_at = COALESCE(finished_at, excluded.finished_at)
                        """, args: [id, item.progress])
                    updated += 1
                }
                let localLastRead = scalarText(
                    "SELECT last_read FROM reading_progress WHERE comic_id = ?", args: [id]) ?? ""
                guard item.lastRead > localLastRead else { continue }
                _ = run("""
                    INSERT INTO reading_progress (comic_id, current_page, last_read) VALUES (?,?,?)
                    ON CONFLICT(comic_id) DO UPDATE SET current_page = excluded.current_page, last_read = excluded.last_read
                    """, args: [id, item.progress, item.lastRead])
                updated += 1
            }
            return updated
        }
    }

    func updateFilePath(id: Int64, newPath: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ? WHERE id = ?", args: [newPath, id])
        }
    }

    /// Conversion re-encodes the file, so its hash changes along with its path.
    func updateFilePathAndHash(id: Int64, newPath: String, newHash: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ?, file_hash = ? WHERE id = ?", args: [newPath, newHash, id])
        }
    }

    func cbrComics() -> [Comic] {
        queue.sync {
            rows("\(comicSelect) WHERE c.deleted_at IS NULL AND c.file_path LIKE '%.cbr'", map: comicRow)
        }
    }

    func stalePaths() -> [(id: Int64, path: String)] { allComicPaths() }

}
