import Foundation
import SQLite3

extension DatabaseManager {
    /// Escapes literal `%`/`_`/`\` in free-text search input so a LIKE '%...%' pattern treats
    /// them as literal characters instead of wildcards (paired with `ESCAPE '\'` at each call site).
    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    static func parseGCDDate(_ raw: String) -> (year: Int, month: Int?, day: Int?)? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), year > 0 else { return nil }
        let month = Int(parts[1]).flatMap { $0 > 0 ? $0 : nil }
        let day = month != nil ? Int(parts[2]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (year, month, day)
    }

    func recomputeGCDMatches(affectedGroupKeys: Set<String>? = nil, store: OfflineMetadataStore = .shared) {
        guard store.isAvailable else { return }
        queue.sync {
            var effectiveKeys = affectedGroupKeys
            if let keys = effectiveKeys, !keys.isEmpty {
                // Mirrors recomputeReadingOrder's bare-key expansion: a caller (LibraryScanner,
                // most commonly, whether from a freshly-derived series or one just re-derived
                // after a folder rename) may not know a comic's current volume yet, so its key is
                // a bare "publisher:series". If a PRIOR pass already backfilled comics.volume for
                // that row (from a previous GCD match, or an edit), its real composite groupKey
                // now includes a volume suffix the bare key never had -- without this expansion
                // the row would be silently excluded and never get rematched.
                effectiveKeys = expandBareGroupKeys(keys)
            }

            var sql = """
                SELECT id, series, publisher, issue_number, year, title,
                       publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), '')),
                       format
                FROM comics WHERE deleted_at IS NULL AND gcd_match_source != 'manual'
            """
            var args: [Any?] = []
            if let keys = effectiveKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            struct Row { let id: Int64; let series: String; let publisher: String; let issueNumber: String?; let year: Int?; let title: String; let format: String? }
            let candidates: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), series: colText(s, 1) ?? "General", publisher: colText(s, 2) ?? "Unknown",
                    issueNumber: colText(s, 3), year: sqlite3_column_type(s, 4) != SQLITE_NULL ? colInt(s, 4) : nil,
                    title: colText(s, 5) ?? "", format: colText(s, 7))
            }
            var updateRows: [[Any?]] = []
            for row in candidates {
                let comicType = ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series, format: row.format)
                let match = store.lookupIssue(
                    series: row.series, publisher: row.publisher, issueNumber: row.issueNumber, year: row.year,
                    comicType: comicType
                )
                // Always write a row, even with every gcd_* field nil -- a comic that matched on a
                // previous pass (e.g. before an ambiguity fix like the ASM-Modern/1965 mismatch)
                // but no longer matches now must have that stale, possibly-wrong attribution
                // cleared, not silently left in place because this pass found nothing to replace
                // it with.
                updateRows.append([match?.gcdIssueId, match?.coverDate, match?.confidence, match?.reason,
                                   match?.canonicalSeriesName, match?.canonicalIssueNumber,
                                   match?.matchedSeriesYearBegan.map(String.init), row.id])
            }
            inTransaction {
                // GCD frequently catalogs a same-named restart or legacy-numbering continuation as
                // an entirely distinct series id sharing one display name (e.g. Amazing Spider-Man
                // Vol. 1 vs Vol. 2), so backfilling the matched GCD series' own start year here is
                // what lets the volume-aware series link/reading-order/rename logic tell them
                // apart. `has_comicinfo` (not a plain "is volume already set" check) decides
                // whether this pass may touch it: when true, a comic's Volume came from its own
                // ComicInfo.xml and must never be overwritten by a GCD guess; when false (the
                // overwhelming majority of real libraries -- ComicInfo.xml is often present on
                // under 1% of files), the GCD match is the ONLY possible source of truth for this
                // field, so a corrected/retracted match on a later pass must always be allowed to
                // correct/clear a previous pass's guess, not leave it permanently stuck the first
                // time a match happened to exist.
                runBatch("""
                    UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = ?, gcd_match_reason = ?,
                           gcd_series_name = ?, gcd_issue_number = ?,
                           volume = CASE WHEN has_comicinfo = 1 THEN volume ELSE ? END
                    WHERE id = ?
                    """, rows: updateRows)
            }
        }
    }

    func autoPopulateSeriesLinksFromGCD(store: OfflineMetadataStore = .shared) {
        let bonds = store.allSeriesBonds()
        guard !bonds.isEmpty else { return }
        queue.sync {
            let librarySeries: [SeriesContinuity.LibrarySeries] = rows(
                "SELECT DISTINCT publisher, series FROM comics WHERE deleted_at IS NULL"
            ) { s in SeriesContinuity.LibrarySeries(publisher: colText(s, 0) ?? "Unknown", series: colText(s, 1) ?? "General") }

            let proposals = SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: librarySeries)
            guard !proposals.isEmpty else { return }

            // Precompute the already-linked set and track the next sequence number locally
            // instead of re-querying COUNT(*)/MAX(sequence_order) once per bond -- both were
            // constant across the whole loop except for links this same loop just inserted,
            // which the local Set/counter accounts for directly.
            var alreadyLinked = Set(rows("SELECT child_publisher, child_series FROM series_links") { s in
                "\(colText(s, 0) ?? ""):\(colText(s, 1) ?? "")"
            })
            var nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")

            var insertRows: [[Any?]] = []
            for proposal in proposals {
                let key = "\(proposal.child.publisher):\(proposal.child.series)"
                guard !alreadyLinked.contains(key) else { continue }
                insertRows.append([proposal.parent.publisher, proposal.parent.series,
                                    proposal.child.publisher, proposal.child.series, nextSeq])
                alreadyLinked.insert(key)
                nextSeq += 1
            }
            inTransaction {
                runBatch("""
                    INSERT OR IGNORE INTO series_links
                        (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source)
                    VALUES (?, ?, ?, ?, ?, 'gcd')
                    """, rows: insertRows)
            }
        }
    }

    /// Records a user's deliberate pick from the "Fix Match" picker -- the one place in the app
    /// where a GCD match is set by explicit human choice rather than `recomputeGCDMatches`' own
    /// automatic scoring. Sets `gcd_match_source = 'manual'` so no future rescan can silently
    /// revert it (see the guard added to `recomputeGCDMatches`'s own candidate query). Confidence
    /// is always 100 -- a human pick is definitionally certain, not a scored guess. Volume backfill
    /// mirrors the automatic path exactly: only touches `volume` when there's no real ComicInfo.xml
    /// tag to protect (`has_comicinfo = 0`), never overwrites a genuine Volume tag.
    func setManualGCDMatch(comicId: Int64, gcdIssueId: Int, seriesName: String, issueNumber: String,
                           coverDate: String?, seriesYearBegan: Int?) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = 100,
                       gcd_match_reason = 'Manually matched', gcd_series_name = ?, gcd_issue_number = ?,
                       gcd_match_source = 'manual',
                       volume = CASE WHEN has_comicinfo = 1 THEN volume ELSE ? END
                WHERE id = ?
                """, args: [gcdIssueId, coverDate, seriesName, issueNumber,
                            seriesYearBegan.map(String.init), comicId])
        }
    }

    /// `BackupService`'s restore path for a manual match -- deliberately does NOT touch `volume`
    /// the way `setManualGCDMatch` does, since a backup doesn't carry the matched series' own
    /// start year and blindly writing `NULL` here would silently clear a volume value the comic
    /// may have picked up from an unrelated automatic match since the backup was taken.
    func restoreManualGCDMatch(comicId: Int64, gcdIssueId: Int, seriesName: String?, issueNumber: String?, coverDate: String?) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = 100,
                       gcd_match_reason = 'Manually matched', gcd_series_name = ?, gcd_issue_number = ?,
                       gcd_match_source = 'manual'
                WHERE id = ?
                """, args: [gcdIssueId, coverDate, seriesName, issueNumber, comicId])
        }
    }

    /// Reverts a manual match back to automatic control -- clears the match entirely (rather than
    /// leaving the stale manual values in place) so the row honestly shows "unmatched" until the
    /// next `recomputeGCDMatches` pass re-evaluates it on its own.
    func clearManualGCDMatch(comicId: Int64) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = NULL, gcd_cover_date = NULL, gcd_match_confidence = NULL,
                       gcd_match_reason = NULL, gcd_series_name = NULL, gcd_issue_number = NULL,
                       gcd_match_source = 'auto'
                WHERE id = ?
                """, args: [comicId])
        }
    }

    struct GCDManualMatchDetail {
        let comicId: Int64
        let gcdIssueId: Int
        let seriesName: String?
        let issueNumber: String?
        let coverDate: String?
    }

    /// Every comic whose current GCD match is a deliberate manual pick, not `recomputeGCDMatches`'
    /// own automatic guess -- used by `BackupService` to decide which comics need their match
    /// exported, since a manual pick is a user choice worth preserving across a restore while an
    /// automatic match is disposable derived data the next scan regenerates on its own.
    func manualGCDMatchDetails() -> [GCDManualMatchDetail] {
        queue.sync {
            rows("""
                SELECT id, gcd_issue_id, gcd_series_name, gcd_issue_number, gcd_cover_date
                FROM comics
                WHERE gcd_match_source = 'manual' AND deleted_at IS NULL AND gcd_issue_id IS NOT NULL
                """) { s in
                GCDManualMatchDetail(comicId: colInt64(s, 0), gcdIssueId: colInt(s, 1),
                                      seriesName: colText(s, 2), issueNumber: colText(s, 3), coverDate: colText(s, 4))
            }
        }
    }
}
