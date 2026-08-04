import Foundation
import SQLite3

extension DatabaseManager {
    func seriesWithMultipleFirstIssues() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND CAST(NULLIF(issue_number, '') AS REAL) = 1
                      AND comic_type(issue_number, title, series, format) = 'regular'
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

    func seriesWithNumberingGaps() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                WITH nums AS (
                    SELECT DISTINCT publisher, series, CAST(issue_number AS INTEGER) AS n
                    FROM comics
                    WHERE deleted_at IS NULL AND issue_number GLOB '[0-9]*'
                          AND comic_type(issue_number, title, series, format) = 'regular'
                ),
                ranked AS (
                    SELECT publisher, series, n,
                           LAG(n) OVER (PARTITION BY publisher, series ORDER BY n) AS prev
                    FROM nums
                )
                SELECT publisher, series, COUNT(*) FROM ranked
                WHERE prev IS NOT NULL AND n - prev > 1
                GROUP BY publisher, series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func seriesWithMultipleVolumes() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(DISTINCT volume) FROM comics
                WHERE deleted_at IS NULL AND volume IS NOT NULL AND volume != ''
                GROUP BY publisher, series HAVING COUNT(DISTINCT volume) > 1
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func missingComicInfoCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND has_comicinfo = 0") }
    }

    func corruptArchiveCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND page_count = 0") }
    }

    func seriesWithNumberingMismatches() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT a.publisher, a.series, COUNT(*) FROM comics a
                JOIN comics b ON a.publisher = b.publisher AND a.series = b.series AND a.id < b.id
                WHERE a.deleted_at IS NULL AND b.deleted_at IS NULL
                      AND a.issue_number IS NOT NULL AND b.issue_number IS NOT NULL
                      AND CAST(a.issue_number AS REAL) = CAST(b.issue_number AS REAL)
                      AND a.issue_number != b.issue_number
                      AND comic_type(a.issue_number, a.title, a.series, a.format) = 'regular'
                      AND comic_type(b.issue_number, b.title, b.series, b.format) = 'regular'
                GROUP BY a.publisher, a.series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func duplicateGroups() -> [[Comic]] {
        queue.sync {
            let flat = rows("""
                \(comicSelect)
                JOIN (
                    SELECT publisher, series, issue_number,
                           comic_type(issue_number, title, series, format) AS ctype
                    FROM comics
                    WHERE deleted_at IS NULL AND issue_number IS NOT NULL AND issue_number != ''
                    GROUP BY publisher, series, issue_number, ctype
                    HAVING COUNT(*) > 1
                ) dup ON dup.publisher = c.publisher AND dup.series = c.series
                     AND dup.issue_number = c.issue_number
                     AND dup.ctype = comic_type(c.issue_number, c.title, c.series, c.format)
                WHERE c.deleted_at IS NULL
                ORDER BY c.publisher, c.series, CAST(c.issue_number AS INTEGER),
                         comic_type(c.issue_number, c.title, c.series, c.format)
            """, map: comicRow)

            guard !flat.isEmpty else { return [] }
            var groups: [[Comic]] = []
            var currentKey: (String, String, String, ComicType)? = nil
            for comic in flat {
                let type = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title, series: comic.series, format: comic.format)
                let key = (comic.publisher, comic.series, comic.issueNumber ?? "", type)
                if currentKey == nil || currentKey! != key {
                    groups.append([comic])
                    currentKey = key
                } else {
                    groups[groups.count - 1].append(comic)
                }
            }

            var result = groups.flatMap(splitByVolumeOrYear)

            let hashMatches: [Comic] = rows("""
                \(comicSelect)
                JOIN (
                    SELECT file_hash FROM comics
                    WHERE deleted_at IS NULL AND file_hash IS NOT NULL
                    GROUP BY file_hash HAVING COUNT(*) > 1
                ) dh ON dh.file_hash = c.file_hash
                WHERE c.deleted_at IS NULL
                ORDER BY c.file_hash
            """, map: comicRow)
            var byHash: [String: [Comic]] = [:]
            for comic in hashMatches { byHash[comic.fileHash ?? "", default: []].append(comic) }
            var knownGroupIdSets = Set(result.map { Set($0.map(\.id)) })
            for members in byHash.values where members.count > 1 {
                let idSet = Set(members.map(\.id))
                guard !knownGroupIdSets.contains(idSet) else { continue }
                result.append(members)
                knownGroupIdSets.insert(idSet)
            }

            return result
        }
    }

    func duplicateMatchCount(for comicId: Int64) -> Int {
        queue.sync { _duplicateMatchCountUnlocked(for: comicId) }
    }

    func _duplicateMatchCountUnlocked(for comicId: Int64) -> Int {
        guard let comic = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [comicId], map: comicRow).first else {
            return 0
        }
        let comicType = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title,
                                                     series: comic.series, format: comic.format)
        let candidates: [Comic] = rows("""
            \(comicSelect)
            WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ? AND c.issue_number = ?
                  AND comic_type(c.issue_number, c.title, c.series, c.format) = ?
            """, args: [comic.publisher, comic.series, comic.issueNumber ?? "", comicType.rawValue], map: comicRow)
        let matchingBucket = splitByVolumeOrYear(candidates).first { $0.contains { $0.id == comicId } } ?? []
        var matchedIds = Set(matchingBucket.map(\.id))

        if let hash = comic.fileHash {
            let hashMatches = rows("SELECT id FROM comics WHERE deleted_at IS NULL AND file_hash = ?",
                                    args: [hash]) { colInt64($0, 0) }
            matchedIds.formUnion(hashMatches)
        }
        matchedIds.remove(comicId)
        return matchedIds.count
    }

    func splitByVolumeOrYear(_ group: [Comic]) -> [[Comic]] {
        guard group.count > 1 else { return [group] }
        var buckets: [[Comic]] = []
        outer: for comic in group {
            for i in buckets.indices {
                let compatible = buckets[i].allSatisfy { existing in
                    if let v1 = comic.volume, let v2 = existing.volume, v1 != v2 { return false }
                    if let y1 = comic.year, let y2 = existing.year, abs(y1 - y2) > 1 { return false }
                    return true
                }
                if compatible {
                    buckets[i].append(comic)
                    continue outer
                }
            }
            buckets.append([comic])
        }
        return buckets.filter { $0.count > 1 }
    }

    func autoPlacedSpecialIssues() -> [Comic] {
        queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL
                      AND c.reading_order_confidence IS NOT NULL
                      AND c.reading_order_confidence BETWEEN 1 AND 99
                ORDER BY c.publisher, c.series, c.reading_order_position, c.title
            """, map: comicRow)
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

}
