import Foundation
import SQLite3

extension DatabaseManager {
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

    func positionSpecialsChronologically(affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row { let id: Int64; let seriesKey: String; let special: Bool
                         let year: Int?; let month: Int?; let position: Int }
            var sql = """
            SELECT id, publisher || ':' || series,
                   is_special_issue(issue_number, title, series), year, cover_month,
                   COALESCE(position, id)
            FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = affectedGroupKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || series) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            let allRows: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), seriesKey: colText(s, 1) ?? "",
                    special: colInt(s, 2) != 0,
                    year:  sqlite3_column_type(s, 3) != SQLITE_NULL ? colInt(s, 3) : nil,
                    month: sqlite3_column_type(s, 4) != SQLITE_NULL ? colInt(s, 4) : nil,
                    position: colInt(s, 5))
            }

            var updates: [(Int64, Int)] = []
            for (_, group) in Dictionary(grouping: allRows, by: \.seriesKey) {
                let mainline = group.filter { !$0.special }.sorted { $0.position < $1.position }
                let mainlineDated = mainline.filter { $0.year != nil && $0.month != nil }
                let allSpecials = group.filter { $0.special }

                var placedIds = Set<Int64>()
                if mainlineDated.count >= 2 {
                    var byBracket: [Int: [(id: Int64, specialKey: Int)]] = [:]
                    for special in allSpecials {
                        guard let y = special.year, let m = special.month else { continue }
                        let specialKey = y * 100 + m
                        guard let afterIdx = mainlineDated.firstIndex(where: { $0.year! * 100 + $0.month! > specialKey }),
                              afterIdx > 0 else { continue }
                        byBracket[afterIdx - 1, default: []].append((special.id, specialKey))
                    }
                    for (beforeIdx, bracket) in byBracket {
                        let before = mainlineDated[beforeIdx]
                        let after  = mainlineDated[beforeIdx + 1]
                        guard after.position - before.position > 1 else { continue }
                        let sorted = bracket.sorted { $0.specialKey != $1.specialKey ? $0.specialKey < $1.specialKey : $0.id < $1.id }
                        let n = sorted.count
                        for (idx, item) in sorted.enumerated() {
                            let pos = n == 1
                                ? before.position + (after.position - before.position) / 2
                                : before.position + Int((Double(after.position - before.position) * (Double(idx + 1) / Double(n + 1))).rounded())
                            updates.append((item.id, pos))
                            placedIds.insert(item.id)
                        }
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
            inTransaction {
                runBatch("UPDATE comics SET position = ? WHERE id = ?",
                         rows: updates.map { [$0.1, $0.0] })
            }
        }
    }

    func recomputeReadingOrder(mode: ReadingOrderMode = .current, affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row {
                let id: Int64; let publisher: String; let series: String; let volume: String?; let groupKey: String
                let filePath: String; let issueNumber: String?; let comicInfoIssueNumber: String?
                let title: String
                let year: Int?; let month: Int?; let day: Int?; let storyArc: String?
                let gcdCoverDate: String?; let alternateNumber: String?; let format: String?
                let gcdIssueNumber: String?
            }

            let links: [(parentKey: String, childKey: String)] = rows("""
                SELECT parent_publisher, parent_series, COALESCE(NULLIF(parent_volume,''),''),
                       child_publisher, child_series, COALESCE(NULLIF(child_volume,''),'')
                FROM series_links ORDER BY sequence_order
                """
            ) { s in
                ("\(colText(s, 0) ?? ""):\(colText(s, 1) ?? ""):\(colText(s, 2) ?? "")",
                 "\(colText(s, 3) ?? ""):\(colText(s, 4) ?? ""):\(colText(s, 5) ?? "")")
            }
            let childSeriesKeys = Set(links.map(\.childKey))

            var effectiveKeys = affectedGroupKeys
            if effectiveKeys != nil, !links.isEmpty {
                // series_links stores raw "publisher:series:volume" keys, but the WHERE filter
                // below scopes rows by the composite groupKey (series_group/volume aware) that
                // LibraryScanner actually uses for affectedGroupKeys. A linked child whose
                // series_group differs from a plain "publisher:series:volume" (a normal pattern
                // for crossover tie-ins) would never match that raw key in the composite filter,
                // silently dropping its rows from allRows -- walk()'s parent offset would then
                // never reach it. Resolve each raw link key to every real composite groupKey
                // currently in use for it instead of unioning the raw key in directly.
                let linkedRawKeys = Set(links.map(\.parentKey) + links.map(\.childKey))
                if !linkedRawKeys.isEmpty {
                    let placeholders = linkedRawKeys.map { _ in "?" }.joined(separator: ",")
                    let resolvedKeys: [String] = rows("""
                        SELECT DISTINCT publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))
                        FROM comics WHERE deleted_at IS NULL
                        AND (publisher || ':' || series || ':' || COALESCE(NULLIF(volume,''),'')) IN (\(placeholders))
                        """, args: linkedRawKeys.map { $0 as Any? }) { s in colText(s, 0) ?? "" }
                    effectiveKeys!.formUnion(resolvedKeys)
                }
            }

            if let keys = effectiveKeys, !keys.isEmpty {
                // A caller (LibraryScanner, most commonly) can compute an affected key before
                // recomputeGCDMatches has run -- if the comic had no ComicInfo.xml <Volume> tag
                // yet, that key is a bare "publisher:series" with no volume component at all. If
                // recomputeGCDMatches then backfills comics.volume from the matched GCD series'
                // own year, the row's real composite groupKey gains a volume suffix the caller's
                // key never had, silently dropping it from the filter below -- its
                // reading_order_position would never get set. Expand every such bare key to every
                // real composite groupKey currently sharing that publisher/series, the same way
                // series_links keys are resolved above.
                effectiveKeys = expandBareGroupKeys(keys)
            }

            var sql = """
            SELECT id, publisher, series, volume,
                   publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), '')),
                   file_path, issue_number, comicinfo_issue_number, title, year, cover_month, cover_day, story_arc,
                   gcd_cover_date, alternate_number, format, gcd_issue_number
            FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = effectiveKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            let allRows: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), publisher: colText(s, 1) ?? "Unknown", series: colText(s, 2) ?? "General",
                    volume: colText(s, 3), groupKey: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    issueNumber: colText(s, 6), comicInfoIssueNumber: colText(s, 7), title: colText(s, 8) ?? "",
                    year:  sqlite3_column_type(s, 9) != SQLITE_NULL ? colInt(s, 9) : nil,
                    month: sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
                    day:   sqlite3_column_type(s, 11) != SQLITE_NULL ? colInt(s, 11) : nil,
                    storyArc: colText(s, 12), gcdCoverDate: colText(s, 13), alternateNumber: colText(s, 14),
                    format: colText(s, 15), gcdIssueNumber: colText(s, 16))
            }

            var positions: [Int64: (position: Int, confidence: Int, reason: String)] = [:]

            switch mode {
            case .intelligent:
                var usedGCDDate: Set<Int64> = []
                let inputs = allRows.map { row -> ReadingOrderEngine.ReadingOrderInput in
                    var y = row.year, m = row.month, d = row.day
                    if let gcd = row.gcdCoverDate, let parsed = Self.parseGCDDate(gcd) {
                        y = parsed.year; m = parsed.month; d = parsed.day
                        usedGCDDate.insert(row.id)
                    }
                    let isChild = childSeriesKeys.contains(Self.seriesVolumeKey(publisher: row.publisher, series: row.series, volume: row.volume))
                    // alternate_number (an explicit ComicInfo.xml <AlternateNumber> tag) is the
                    // highest-trust signal when present, but it's set on well under 1% of real
                    // files. gcd_issue_number is recomputeGCDMatches' own verified legacy/
                    // continuity number for a matched volume restart -- without falling back to
                    // it here, a correctly-matched legacy renumbering (e.g. Amazing Spider-Man
                    // Vol. 2 continuing Vol. 1's numbering) would still sort by its bare
                    // volume-relative issue_number ("1") instead of its real place in the
                    // continuity, for every comic that doesn't also happen to carry the rare
                    // ComicInfo tag.
                    let legacyNumber = (isChild ? row.alternateNumber.flatMap(ReadingOrderEngine.parseLegacyNumber) : nil)
                        ?? (isChild ? row.gcdIssueNumber.flatMap(ReadingOrderEngine.parseLegacyNumber) : nil)
                        ?? ReadingOrderEngine.parseLegacyNumber(row.issueNumber)
                    return ReadingOrderEngine.ReadingOrderInput(
                        id: row.id, groupKey: row.groupKey,
                        legacyNumber: legacyNumber,
                        comicType: ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series, format: row.format),
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

            if !links.isEmpty {
                var idsBySeriesKey: [String: [Int64]] = [:]
                for row in allRows {
                    idsBySeriesKey[Self.seriesVolumeKey(publisher: row.publisher, series: row.series, volume: row.volume), default: []].append(row.id)
                }
                let offsets = SeriesContinuity.chainOffsets(
                    links: links, idsBySeriesKey: idsBySeriesKey,
                    positions: positions.mapValues(\.position)
                )
                for (id, offset) in offsets {
                    positions[id]?.position += offset
                }
            }

            let overrideMap = Dictionary(uniqueKeysWithValues: rows(
                "SELECT comic_id, position FROM reading_order_overrides", map: { (colInt64($0, 0), colInt($0, 1)) }
            ))

            // Grouped by which UPDATE each row needs instead of interleaving one prepare/step
            // per row -- this runs over the whole affected set after every scan/reorder, so
            // reusing one compiled statement per branch instead of re-parsing identical SQL
            // text on every row matters at real-library scale.
            var overrideRows: [[Any?]] = []
            var filenameResetRows: [[Any?]] = []
            var positionRows: [[Any?]] = []
            for row in allRows {
                if let overridePos = overrideMap[row.id] {
                    overrideRows.append([overridePos, row.id])
                } else if mode == .filename {
                    filenameResetRows.append([row.id])
                } else if let p = positions[row.id] {
                    positionRows.append([p.position, p.confidence, p.reason, row.id])
                }
            }
            inTransaction {
                let ok1 = runBatch("""
                    UPDATE comics SET reading_order_position = ?, reading_order_confidence = 100,
                           reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, rows: overrideRows)
                let ok2 = runBatch("""
                    UPDATE comics SET reading_order_position = NULL, reading_order_confidence = NULL,
                           reading_order_reason = NULL
                    WHERE id = ?
                    """, rows: filenameResetRows)
                let ok3 = runBatch("""
                    UPDATE comics SET reading_order_position = ?, reading_order_confidence = ?,
                           reading_order_reason = ?
                    WHERE id = ?
                    """, rows: positionRows)
                return ok1 && ok2 && ok3
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

    func clearAllReadingOrderOverrides() {
        queue.sync { _ = run("DELETE FROM reading_order_overrides") }
    }

    func allReadingOrderOverrides() -> [(filePath: String, position: Int, reason: String)] {
        queue.sync {
            rows("""
                SELECT c.file_path, o.position, o.reason
                FROM reading_order_overrides o JOIN comics c ON c.id = o.comic_id
                WHERE c.deleted_at IS NULL
                """) { s in
                (colText(s, 0) ?? "", colInt(s, 1), colText(s, 2) ?? "Manually placed")
            }
        }
    }

}
