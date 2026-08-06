import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension DatabaseManager {
    func allComics(publisher: String? = nil, character: String? = nil, series: String? = nil,
                   search: String? = nil, sortOrder: SortOrder = .publisher,
                   favoritesOnly: Bool = false, readingListOnly: Bool = false,
                   nullCharacterOnly: Bool = false, tag: String? = nil,
                   unreadOnly: Bool = false, minRating: Int? = nil) -> [Comic] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if nullCharacterOnly { conds.append("c.character IS NULL") }
            else if let chr = character { conds.append("c.character = ?"); args.append(chr) }
            if let ser = series { conds.append("c.series = ?"); args.append(ser) }
            if let q = search, !q.isEmpty {
                // Covers everything a user might reasonably remember tagging/writing about a
                // comic, not just its catalog metadata -- previously notes, reviews, and tags
                // were all things you could attach to a comic but never actually search by.
                conds.append("""
                    (c.title LIKE ? ESCAPE '\\' OR c.series LIKE ? ESCAPE '\\' OR c.publisher LIKE ? ESCAPE '\\'
                     OR c.writer LIKE ? ESCAPE '\\' OR c.penciller LIKE ? ESCAPE '\\' OR c.character LIKE ? ESCAPE '\\'
                     OR c.notes LIKE ? ESCAPE '\\' OR r.review LIKE ? ESCAPE '\\'
                     OR c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON ct.tag_id = t.id WHERE t.name LIKE ? ESCAPE '\\'))
                    """)
                let p = "%\(Self.likeEscaped(q))%"
                args += [p, p, p, p, p, p, p, p, p]
            }
            if favoritesOnly   { conds.append("f.comic_id IS NOT NULL") }
            if readingListOnly { conds.append("rl.comic_id IS NOT NULL") }
            if unreadOnly      { conds.append("COALESCE(rp.current_page, 0) = 0") }
            if let minRating   { conds.append("COALESCE(r.rating, 0) >= ?"); args.append(minRating) }
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

    /// The next comic after `comic` in the same (publisher, series), using the exact same
    /// ordering as `.manual` sort (reading_order_position, falling back to position, then id) --
    /// the same order Series Manager and the reading-order engine already treat as authoritative,
    /// so "next" here always matches what a user would see if they scrolled the series manually.
    /// Returns nil at the end of the series -- deliberately doesn't cross into a linked child
    /// series (e.g. a legacy renumbering); that's a real reading-order continuation, but a
    /// different, larger question than "what's the next file after this one."
    func nextComic(after comic: Comic) -> Comic? {
        queue.sync {
            let orderExpr = "COALESCE(c.reading_order_position, c.position, c.id)"
            let sql = """
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ?
                  AND \(orderExpr) > (SELECT COALESCE(reading_order_position, position, id) FROM comics WHERE id = ?)
                ORDER BY \(orderExpr), c.title LIMIT 1
                """
            return rows(sql, args: [comic.publisher, comic.series, comic.id], map: comicRow).first
        }
    }

    /// Mirror of `nextComic(after:)` -- same series-scoped ordering, opposite direction. Lets the
    /// reader carry a page-turn backward across a comic boundary the same way it does forward.
    func previousComic(before comic: Comic) -> Comic? {
        queue.sync {
            let orderExpr = "COALESCE(c.reading_order_position, c.position, c.id)"
            let sql = """
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ?
                  AND \(orderExpr) < (SELECT COALESCE(reading_order_position, position, id) FROM comics WHERE id = ?)
                ORDER BY \(orderExpr) DESC, c.title DESC LIMIT 1
                """
            return rows(sql, args: [comic.publisher, comic.series, comic.id], map: comicRow).first
        }
    }

    struct MetadataInspectorInfo {
        let comic: Comic
        let comicType: ComicType
        let legacyNumber: Double?
        let coverMonth: Int?
        let coverDay: Int?
        let comicInfoIssueNumber: String?
        let alternateNumber: String?
        let storyArcNumber: String?
        let seriesGroup: String?
        let gcdMatchReason: String?
        let hasComicInfo: Bool?
        let gcdMatchSource: String
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
                let gcdMatchReason: String?; let hasComicInfo: Int?; let gcdMatchSource: String
            }
            guard let extra = rows("""
                SELECT cover_month, cover_day, comicinfo_issue_number, alternate_number,
                       story_arc_number, series_group, gcd_match_reason, has_comicinfo, gcd_match_source
                FROM comics WHERE id = ?
                """, args: [comicId], map: { s in
                Extra(coverMonth: sqlite3_column_type(s, 0) != SQLITE_NULL ? colInt(s, 0) : nil,
                      coverDay: sqlite3_column_type(s, 1) != SQLITE_NULL ? colInt(s, 1) : nil,
                      comicInfoIssueNumber: colText(s, 2), alternateNumber: colText(s, 3),
                      storyArcNumber: colText(s, 4), seriesGroup: colText(s, 5), gcdMatchReason: colText(s, 6),
                      hasComicInfo: sqlite3_column_type(s, 7) != SQLITE_NULL ? colInt(s, 7) : nil,
                      gcdMatchSource: colText(s, 8) ?? "auto")
            }).first else { return nil }

            let comicType = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title,
                                                         series: comic.series, format: comic.format)
            let legacyNumber = ReadingOrderEngine.parseLegacyNumber(comic.issueNumber)

            return MetadataInspectorInfo(
                comic: comic, comicType: comicType, legacyNumber: legacyNumber,
                coverMonth: extra.coverMonth, coverDay: extra.coverDay,
                comicInfoIssueNumber: extra.comicInfoIssueNumber, alternateNumber: extra.alternateNumber,
                storyArcNumber: extra.storyArcNumber, seriesGroup: extra.seriesGroup,
                gcdMatchReason: extra.gcdMatchReason,
                hasComicInfo: extra.hasComicInfo.map { $0 != 0 },
                gcdMatchSource: extra.gcdMatchSource,
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

    /// The ideal filename for one comic, computed with the exact same canonical-name/volume/title
    /// disambiguation logic the bulk Rename Files tool uses (`ComicFileNaming`), scoped to just
    /// this comic's (publisher, series) siblings rather than the whole library. Returns nil when
    /// the file's current name already matches -- i.e. nothing to fix.
    func proposedFilename(comicId: Int64) -> String? {
        queue.sync {
            guard let target = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL",
                                     args: [comicId], map: comicRow).first else { return nil }
            guard let ideal = ComicFileNaming.idealFilenames(for: [target])[comicId] else { return nil }
            let currentName = URL(fileURLWithPath: target.filePath).lastPathComponent
            return currentName == ideal ? nil : ideal
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

    /// Nil if `current` is empty/a placeholder, or if it doesn't actually disagree with
    /// `proposed` (after case/whitespace-insensitive comparison) -- i.e. nil means "safe to
    /// auto-apply `proposed`, nothing worth flagging." Shared with `LibraryScanner`'s existing-
    /// library audit migration, so both use exactly the same disagreement rule.
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
        // `upsertMetadataConflicts` takes `queue` itself -- collected here and applied AFTER this
        // function's own `queue.sync` block returns, never from inside it, or a nested `queue.sync`
        // on this serial queue would deadlock.
        let conflicts: [MetadataConflictInput] = queue.sync {
            // If any of this batch's paths already have a row with meta_edited = 0, compare the
            // newly-resolved series/publisher/issue_number against what's already there instead of
            // blindly overwriting it -- a real disagreement (not a placeholder being filled in for
            // the first time) gets flagged for review instead of silently applied in either
            // direction. Empty/cheap on a normal new-files-only scan, where none of these paths
            // exist yet.
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
                // Each of these two statements is identical text across every comic in the
                // batch -- prepared once and reused across all rows instead of `_insertRow`'s
                // former per-comic prepare/finalize, which mattered for first-time imports of
                // large libraries (chunks of up to 100 comics per flush, potentially many chunks).
                let insertRows: [[Any?]] = resolvedComics.map { c in
                    [c.title, c.filePath, c.publisher, c.character,
                     c.series, c.issueNumber, c.pageCount, c.writer,
                     c.penciller, c.year.map { Int64($0) }, c.storyArc,
                     c.languageIso, c.fileHash, c.coverMonth.map { Int64($0) },
                     c.coverDay.map { Int64($0) }, c.alternateNumber, c.storyArcNumber, c.seriesGroup, c.comicInfoIssueNumber,
                     c.volume, c.format, c.hasComicInfo.map { $0 ? Int64(1) : Int64(0) },
                     c.comicInfoSeries, c.comicInfoPublisher, c.folderSeries, c.folderPublisher, c.folderGroup]
                }
                // ON CONFLICT (not OR IGNORE): file_path is UNIQUE, and a soft-deleted comic keeps
                // its row (deleted_at set, never removed) forever at that same path. If the file
                // later reappears after being wrongly marked stale (e.g. a flaky/waking external
                // drive during a scan), INSERT OR IGNORE would silently no-op on the UNIQUE
                // conflict -- the comic would never come back, permanently orphaned. Reviving the
                // SAME row on conflict instead means its reading_progress/ratings/tags/list-
                // memberships (all keyed by this comic_id) are still correctly attached -- a plain
                // "delete and re-insert" would have orphaned all of that. added_at and position
                // are deliberately left untouched: a revival isn't a new addition. The folder-
                // derived identity columns (matching `folderDerivedColumns`, plus issue_number)
                // are gated behind meta_edited like every other write path touches them -- without
                // this, a user's manual correction survives right up until the file goes briefly
                // missing (e.g. a flaky external drive) and reappears, at which point the revival
                // would have silently reset it back to the raw filename/folder-parsed guess.
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

                // A revival (or a metadata refresh) can leave a comic's page_count smaller than
                // whatever page reading_progress last saved -- clamp it down so Stats/Continue
                // Reading stop treating stale out-of-range progress as "finished", and the reader
                // doesn't need to be the only place enforcing this.
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
            // See _insertRow's matching comment -- a corrected page count can leave saved
            // progress out of range.
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

    /// Returns the id of a soft-deleted comic at this exact path, if one exists -- used to evict its
    /// (possibly stale/wrong) cached cover before the row is revived by a rescan.
    func softDeletedComicId(atPath path: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM comics WHERE file_path = ? AND deleted_at IS NOT NULL", args: [path])
            return id > 0 ? Int64(id) : nil
        }
    }

    /// Every active comic whose file lives under `folderPath` -- used when a library folder is
    /// removed from configuration, so those comics can be soft-deleted along with it instead of
    /// lingering in the library forever, pointing at a folder ComicArc no longer manages at all.
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

    /// `reason` is "user" for an explicit delete, or "missing" for the scanner's own stale-file
    /// cleanup -- lets the Trash screen (and its Restore action) tell the two apart instead of
    /// treating a file that vanished off a drive identically to one someone chose to delete.
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

    func updateProgress(_ updates: [(comicId: Int64, page: Int)]) {
        guard !updates.isEmpty else { return }
        queue.sync {
            _ = inTransaction {
                runBatch("""
                    INSERT INTO reading_progress (comic_id, current_page, last_read)
                    VALUES (?, ?, datetime('now'))
                    ON CONFLICT(comic_id) DO UPDATE
                      SET current_page = ?, last_read = datetime('now')
                    """, rows: updates.map { [$0.comicId, $0.page, $0.page] })
            }
        }
    }

    func setRating(_ comicId: Int64, rating: Int) {
        queue.sync {
            _ = run("""
                INSERT INTO ratings (comic_id, rating) VALUES (?,?)
                ON CONFLICT(comic_id) DO UPDATE SET rating = excluded.rating
            """, args: [comicId, rating])
            _logDiaryEntryUnlocked(comicId: comicId)
        }
    }

    /// Snapshots the current rating/review into `diary_entries`, called after every
    /// `setRating`/`setComicReview` write. Same-day edits collapse into the existing
    /// entry (rapid star-taps in one sitting shouldn't spam the diary); a genuinely new
    /// day always starts a new entry, marked `is_reread` if any prior entry exists.
    /// Must run already inside `queue.sync` — not itself queue-wrapped.
    func _logDiaryEntryUnlocked(comicId: Int64) {
        guard let current: (rating: Int, review: String?) = rows(
            "SELECT rating, review FROM ratings WHERE comic_id = ?", args: [comicId],
            map: { s in (colInt(s, 0), colText(s, 1)) }
        ).first, current.rating > 0 else { return }

        // logged_at is stored as CURRENT_TIMESTAMP (UTC). Comparing raw date(...) without a
        // 'localtime' conversion collapses/splits entries on a UTC midnight boundary that has
        // nothing to do with the user's actual calendar day -- e.g. for US timezones, UTC
        // midnight falls in the late afternoon/evening local time, a common reading window,
        // so two ratings minutes apart could get split into two entries; conversely, in
        // timezones ahead of UTC, two ratings on different local days could collapse into one,
        // silently overwriting the earlier day's rating/review.
        let todayId: Int64? = rows(
            "SELECT id FROM diary_entries WHERE comic_id = ? AND date(logged_at, 'localtime') = date('now', 'localtime') ORDER BY id DESC LIMIT 1",
            args: [comicId], map: { colInt64($0, 0) }
        ).first

        if let todayId {
            _ = run("UPDATE diary_entries SET rating = ?, review = ? WHERE id = ?",
                    args: [current.rating, current.review, todayId])
        } else {
            let hasPriorEntry = scalarInt("SELECT COUNT(*) FROM diary_entries WHERE comic_id = ?", args: [comicId]) > 0
            _ = run("""
                INSERT INTO diary_entries (comic_id, rating, review, is_reread) VALUES (?,?,?,?)
            """, args: [comicId, current.rating, current.review, hasPriorEntry ? 1 : 0])
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
            _logDiaryEntryUnlocked(comicId: comicId)
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
            for chunk in idChunks(ids) {
                let args = chunk.map { $0 as Any? }
                if value {
                    let values = chunk.map { _ in "(?)" }.joined(separator: ",")
                    _ = run("INSERT OR IGNORE INTO reading_list (comic_id) VALUES \(values)", args: args)
                } else {
                    let ph = chunk.map { _ in "?" }.joined(separator: ",")
                    _ = run("DELETE FROM reading_list WHERE comic_id IN (\(ph))", args: args)
                }
            }
        }
    }

    static let folderDerivedColumns: Set<String> = ["title", "series", "publisher", "character"]

    /// Every column `updateMeta` is allowed to touch -- every call site today passes compile-time
    /// string literals, but the column name still gets interpolated straight into the SQL text
    /// (only the value is bound), so this is the one thing standing between that and a real
    /// injection vector the day some caller builds `fields` from anything less trusted than a
    /// literal.
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
                    UPDATE comics SET position = ?, reading_order_position = ?,
                           reading_order_confidence = 100, reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, rows: orderedIds.enumerated().map { [$0.offset, $0.offset, $0.element] })
                let ok2 = runBatch("""
                    INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')
                    """, rows: orderedIds.enumerated().map { [$0.element, $0.offset] })
                return ok1 && ok2
            }
        }
    }

    func batchUpdateFolderMeta(_ items: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)]) {
        queue.sync {
            // Captured before the update -- a folder rename that changes a comic's (publisher,
            // series) would otherwise silently orphan any series_links row still pointing at the
            // old name (it no longer matches anything in `comics`), breaking whatever
            // volume-aware reading-order chaining that link was providing. Only rows this update
            // will actually touch (meta_edited=0) count, matching the same guard the update
            // itself uses below.
            var renameMappings: Set<[String]> = []
            let idsWithNewSeries = items.compactMap { $0.ser != nil ? $0.id : nil }
            if !idsWithNewSeries.isEmpty {
                var current: [Int64: (pub: String, ser: String)] = [:]
                for chunk in idChunks(idsWithNewSeries) {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    for (id, row) in rows(
                        "SELECT id, publisher, series FROM comics WHERE id IN (\(placeholders)) AND meta_edited = 0",
                        args: chunk.map { $0 as Any? },
                        map: { s in (colInt64(s, 0), (pub: colText(s, 1) ?? "", ser: colText(s, 2) ?? "")) }
                    ) {
                        current[id] = row
                    }
                }
                for item in items {
                    guard let newSer = item.ser, let old = current[item.id] else { continue }
                    let newPub = item.pub ?? old.pub
                    guard old.ser != newSer || old.pub != newPub else { continue }
                    renameMappings.insert([old.pub, old.ser, newPub, newSer])
                }
            }

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
                    // Purely structural (which folder a file sits in), not user-editable content, but
                    // still gated by meta_edited like every other folder-derived column -- unconditional
                    // so a folder-group that's been removed (file moved up a level) correctly clears
                    // back to NULL instead of keeping a stale value forever.
                    if run("UPDATE comics SET folder_group=? WHERE id=? AND meta_edited=0", args: [item.group, item.id]) == -1 { ok = false }
                    if run("UPDATE comics SET title=? WHERE id=? AND meta_edited=0", args: [item.title, item.id]) == -1 { ok = false }

                    if let num = item.issueNumber {
                        if run("""
                            UPDATE comics SET issue_number=? WHERE id=? AND meta_edited=0
                            AND (issue_number IS NULL OR issue_number != ?)
                            """, args: [num, item.id, num]) == -1 { ok = false }
                    }
                    if let year = item.year {
                        // Only ever fills a genuinely empty year -- a real ComicInfo.xml <Year> tag
                        // (on the rare file that has one) is always a better source than a filename
                        // guess and must never be overwritten by it.
                        if run("UPDATE comics SET year=? WHERE id=? AND meta_edited=0 AND year IS NULL", args: [year, item.id]) == -1 { ok = false }
                    }
                }
                return ok
            }

            // Wrapped in its own transaction: a crash between the parent-side and child-side
            // update for one mapping, or between mappings when several series are renamed in the
            // same batch, would otherwise leave series_links partially resynced against comics
            // rows that have already committed their new names.
            if !renameMappings.isEmpty {
                inTransaction {
                    renameMappings.allSatisfy { mapping in
                        let (oldPub, oldSer, newPub, newSer) = (mapping[0], mapping[1], mapping[2], mapping[3])
                        let ok1 = run("UPDATE series_links SET parent_publisher = ?, parent_series = ? WHERE parent_publisher = ? AND parent_series = ?",
                                     args: [newPub, newSer, oldPub, oldSer]) != -1
                        let ok2 = run("UPDATE series_links SET child_publisher = ?, child_series = ? WHERE child_publisher = ? AND child_series = ?",
                                     args: [newPub, newSer, oldPub, oldSer]) != -1
                        return ok1 && ok2
                    }
                }
            }

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

    /// Reading progress for every comic that has actually been started, keyed by file hash rather
    /// than id -- ids are meaningless across two devices' separate databases (different scan
    /// history/order), but a comic's file hash identifies the same underlying file wherever it
    /// was imported. Used by local Mac<->iPad progress sync; no ratings/tags/diary/reviews here,
    /// since those have much messier merge semantics than a single scalar page number.
    func progressSyncSnapshot() -> [(fileHash: String, progress: Int, pageCount: Int, lastRead: String)] {
        queue.sync {
            rows("""
                SELECT c.file_hash, rp.current_page, c.page_count, rp.last_read
                FROM reading_progress rp JOIN comics c ON c.id = rp.comic_id
                WHERE c.deleted_at IS NULL AND c.file_hash IS NOT NULL AND rp.current_page > 0
                """) { s in
                (fileHash: colText(s, 0) ?? "", progress: colInt(s, 1), pageCount: colInt(s, 2), lastRead: colText(s, 3) ?? "")
            }
        }
    }

    /// Applies incoming progress from another device -- last-write-wins by `lastRead` timestamp,
    /// per comic, matched by file hash. A comic this device doesn't have (different hash, not in
    /// its library) is silently skipped rather than treated as an error -- the two devices'
    /// libraries are not guaranteed to be identical. Returns how many comics were actually updated,
    /// for a user-facing summary.
    func applySyncedProgress(_ items: [(fileHash: String, progress: Int, lastRead: String)]) -> Int {
        queue.sync {
            var updated = 0
            for item in items {
                guard let id = rows("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL",
                                    args: [item.fileHash], map: { colInt64($0, 0) }).first else { continue }
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

    /// For CBR-to-CBZ conversion: unlike a plain rename/move, the file's bytes genuinely change
    /// (re-encoded as a zip), so its `file_hash` must be updated alongside `file_path` -- leaving
    /// the old hash in place would make this comic look "moved away" from its own real location
    /// on the next scan's hash-based move detection.
    func updateFilePathAndHash(id: Int64, newPath: String, newHash: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ?, file_hash = ? WHERE id = ?", args: [newPath, newHash, id])
        }
    }

    /// Every comic currently backed by a `.cbr` file -- population for a "Convert CBR to CBZ"
    /// batch tool.
    func cbrComics() -> [Comic] {
        queue.sync {
            rows("\(comicSelect) WHERE c.deleted_at IS NULL AND c.file_path LIKE '%.cbr'", map: comicRow)
        }
    }

    /// Same query as `allComicPaths()` under a name that reads better at its "which of these
    /// are still on disk" call sites; kept as a single query so the two never drift apart.
    func stalePaths() -> [(id: Int64, path: String)] { allComicPaths() }

}
