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

    /// Jumps of more than this many issue numbers are legacy renumbering (e.g. #441 -> #500),
    /// DC One Million-style issues, or a collection starting mid-run -- not missing comics.
    static let maxReportedGap = 10

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
                WHERE prev IS NOT NULL AND n - prev > 1 AND n - prev <= \(Self.maxReportedGap + 1)
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

    func corruptArchiveCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND page_count = 0") }
    }

    /// Zero-page comics the scanner has given up on after 3 retries, as opposed to ones not yet
    /// rescanned.
    func brokenComicIds() -> Set<Int64> {
        queue.sync {
            Set(rows("SELECT id FROM comics WHERE deleted_at IS NULL AND page_count = 0 AND scan_retry_count >= 3") {
                colInt64($0, 0)
            })
        }
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

    /// Strict duplicates: same file name, byte-identical cover, or byte-identical file. Metadata
    /// alone never matches. Groups are transitive.
    func duplicateGroups() -> [[Comic]] {
        let components = queue.sync { () -> [[Int64]] in
            let entries = rows("SELECT id, file_path, file_hash FROM comics WHERE deleted_at IS NULL") {
                (id: colInt64($0, 0), path: colText($0, 1) ?? "", hash: colText($0, 2))
            }
            return Self.duplicateComponents(entries, coversDir: coversDir)
        }
        guard !components.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: comics(ids: components.flatMap { $0 }).map { ($0.id, $0) })
        return components
            .map { $0.compactMap { byId[$0] } }
            .filter { $0.count > 1 }
            .sorted { ($0[0].series, $0[0].title) < ($1[0].series, $1[0].title) }
    }

    func _duplicateMatchCountUnlocked(for comicId: Int64) -> Int {
        let entries = rows("SELECT id, file_path, file_hash FROM comics WHERE deleted_at IS NULL") {
            (id: colInt64($0, 0), path: colText($0, 1) ?? "", hash: colText($0, 2))
        }
        let group = Self.duplicateComponents(entries, coversDir: coversDir).first { $0.contains(comicId) } ?? []
        return max(0, group.count - 1)
    }

    /// Union-find over the three keys. Covers are only hashed when another cover has the same byte
    /// size.
    static func duplicateComponents(_ entries: [(id: Int64, path: String, hash: String?)], coversDir: URL) -> [[Int64]] {
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var root = x
            while let p = parent[root], p != root { root = p }
            parent[x] = root
            return root
        }
        func unionAll(_ ids: [Int64]) {
            guard let first = ids.first else { return }
            for id in ids.dropFirst() { parent[find(id)] = find(first) }
        }
        for e in entries { parent[e.id] = e.id }

        let byName = Dictionary(grouping: entries) { ($0.path as NSString).lastPathComponent }
        for (name, members) in byName where !name.isEmpty && members.count > 1 { unionAll(members.map(\.id)) }

        let byHash = Dictionary(grouping: entries.filter { $0.hash != nil }) { $0.hash! }
        for members in byHash.values where members.count > 1 { unionAll(members.map(\.id)) }

        var bySize: [Int: [Int64]] = [:]
        for e in entries {
            let url = coversDir.appendingPathComponent("\(e.id).jpg")
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                bySize[size, default: []].append(e.id)
            }
        }
        for ids in bySize.values where ids.count > 1 {
            var byContent: [Data: [Int64]] = [:]
            for id in ids {
                guard let data = try? Data(contentsOf: coversDir.appendingPathComponent("\(id).jpg")) else { continue }
                byContent[data, default: []].append(id)
            }
            for members in byContent.values where members.count > 1 { unionAll(members) }
        }

        var groups: [Int64: [Int64]] = [:]
        for e in entries { groups[find(e.id), default: []].append(e.id) }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    func missingIssueNumbers(series: String, publisher: String) -> [String] {
        queue.sync {
            let nums = rows("""
                SELECT DISTINCT CAST(issue_number AS INTEGER) as n FROM comics
                WHERE deleted_at IS NULL AND series=? AND publisher=?
                  AND issue_number GLOB '[0-9]*'
                  AND comic_type(issue_number, title, series, format) = 'regular'
                ORDER BY n
            """, args: [series, publisher]) { colInt($0, 0) }
            guard nums.count > 1 else { return [] }
            var missing: [String] = []
            for i in 1..<nums.count {
                let prev = nums[i-1], curr = nums[i]
                if curr - prev > 1, curr - prev <= Self.maxReportedGap + 1 {
                    for n in (prev+1)..<curr { missing.append("#\(n)") }
                }
            }
            return missing
        }
    }

}

struct LibraryHealthReport {
    struct SeriesIssue: Identifiable {
        let publisher: String; let series: String; let count: Int
        var id: String { "\(publisher):\(series)" }
    }

    var duplicateGroupCount: Int = 0
    var multipleFirstIssues: [SeriesIssue] = []
    var numberingGaps: [SeriesIssue] = []
    var multipleVolumes: [SeriesIssue] = []
    var corruptArchiveCount: Int = 0
    var numberingMismatches: [SeriesIssue] = []

    var isEmpty: Bool {
        duplicateGroupCount == 0 && multipleFirstIssues.isEmpty
            && numberingGaps.isEmpty && multipleVolumes.isEmpty
            && corruptArchiveCount == 0 && numberingMismatches.isEmpty
    }

    var totalCount: Int {
        duplicateGroupCount + multipleFirstIssues.count
            + numberingGaps.count + multipleVolumes.count
            + corruptArchiveCount + numberingMismatches.count
    }
}

enum LibraryHealthAnalyzer {
    static func analyze(db: DatabaseManager = .shared) -> LibraryHealthReport {
        LibraryHealthReport(
            duplicateGroupCount: db.duplicateGroups().count,
            multipleFirstIssues: db.seriesWithMultipleFirstIssues().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            numberingGaps: db.seriesWithNumberingGaps().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            multipleVolumes: db.seriesWithMultipleVolumes().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            corruptArchiveCount: db.corruptArchiveCount(),
            numberingMismatches: db.seriesWithNumberingMismatches().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            }
        )
    }
}
