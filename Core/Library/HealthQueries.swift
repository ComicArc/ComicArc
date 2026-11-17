import Foundation

struct SeriesFinding: Identifiable, Hashable, Sendable {
    var id: String { "\(publisher)/\(series)" }
    let publisher: String
    let series: String
    let detail: String
}

struct HealthReport: Sendable {
    var missingIssues: [SeriesFinding] = []
    var duplicateFirstIssues: [SeriesFinding] = []
    var mixedVolumes: [SeriesFinding] = []
    var unreadable: [Comic] = []
    var duplicateGroups: [[Comic]] = []
    var conflicts: [MetadataConflict] = []
    var renameCandidates = 0
    var cbrCount = 0

    var issueCount: Int {
        missingIssues.count + duplicateFirstIssues.count + mixedVolumes.count + unreadable.count
            + duplicateGroups.count + conflicts.count
    }
}

extension Database {
    /// A jump of more than this many issue numbers is renumbering (#441 → #500), a DC One
    /// Million-style issue, or a collection that starts mid-run — not missing comics.
    static let maxReportedGap = 10

    func healthReport() async throws -> HealthReport {
        var report = try await read { db -> HealthReport in
            var r = HealthReport()
            let regular = "comic_type(issue_number, title, series, format) = 'regular'"
            let numbers = try db.query("""
                SELECT DISTINCT publisher, series, CAST(issue_number AS INTEGER) FROM comics
                WHERE deleted_at IS NULL AND issue_number GLOB '[0-9]*' AND \(regular)
                ORDER BY publisher, series, 3
                """) { ($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2)) }
            var bySeries: [String: (String, String, [Int])] = [:]
            for (p, s, n) in numbers { bySeries["\(p)/\(s)", default: (p, s, [])].2.append(n) }
            r.missingIssues = bySeries.values.compactMap { p, s, nums in
                let missing = Self.missingNumbers(nums)
                guard !missing.isEmpty else { return nil }
                return SeriesFinding(publisher: p, series: s, detail: Self.describe(missing))
            }.sorted { ($0.publisher, $0.series) < ($1.publisher, $1.series) }

            r.duplicateFirstIssues = try db.query("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND CAST(NULLIF(issue_number, '') AS REAL) = 1 AND \(regular)
                GROUP BY publisher, series HAVING COUNT(*) > 1
                """) { SeriesFinding(publisher: $0.string(0) ?? "", series: $0.string(1) ?? "", detail: "\($0.int(2)) issues numbered #1") }
            r.mixedVolumes = try db.query("""
                SELECT publisher, series, COUNT(DISTINCT volume) FROM comics
                WHERE deleted_at IS NULL AND volume IS NOT NULL AND volume != ''
                GROUP BY publisher, series HAVING COUNT(DISTINCT volume) > 1
                """) { SeriesFinding(publisher: $0.string(0) ?? "", series: $0.string(1) ?? "", detail: "\($0.int(2)) volumes in one folder") }
            r.unreadable = try db.query("\(ComicSQL.select) WHERE c.deleted_at IS NULL AND c.page_count = 0 ORDER BY c.title") {
                ComicSQL.comic(from: $0)
            }
            r.conflicts = try db.query("""
                SELECT m.id, m.field, m.current_value, m.proposed_value, m.proposed_source, \(ComicSQL.columns)
                FROM metadata_conflicts m JOIN comics c ON c.id = m.comic_id AND c.deleted_at IS NULL \(ComicSQL.joins)
                WHERE m.status = 'pending' ORDER BY c.series, c.title
                """) { r in
                MetadataConflict(id: r.int64(0), comic: ComicSQL.comic(from: r, offset: 5), field: r.string(1) ?? "",
                                 currentValue: r.string(2), proposedValue: r.string(3), source: r.string(4) ?? "")
            }
            r.cbrCount = try db.scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND lower(file_path) LIKE '%.cbr'")
            let paths = try db.query("SELECT file_path FROM comics WHERE deleted_at IS NULL") { $0.string(0) ?? "" }
            r.renameCandidates = paths.filter(FilenameCleanup.needsCleanup).count
            return r
        }
        report.duplicateGroups = try await duplicateGroups()
        return report
    }

    /// Missing regular issue numbers in one series (issue page "Missing Issues").
    func missingIssues(series: String, publisher: String) async throws -> [Int] {
        let nums = try await read { db in
            try db.query("""
                SELECT DISTINCT CAST(issue_number AS INTEGER) FROM comics
                WHERE deleted_at IS NULL AND series = ? AND publisher = ? AND issue_number GLOB '[0-9]*'
                  AND comic_type(issue_number, title, series, format) = 'regular' ORDER BY 1
                """, [series, publisher]) { $0.int(0) }
        }
        return Self.missingNumbers(nums)
    }

    static func missingNumbers(_ sorted: [Int]) -> [Int] {
        guard sorted.count > 1 else { return [] }
        var missing: [Int] = []
        for i in 1..<sorted.count {
            let gap = sorted[i] - sorted[i - 1]
            if gap > 1 && gap <= maxReportedGap + 1 { missing += Array((sorted[i - 1] + 1)..<sorted[i]) }
        }
        return missing
    }

    private static func describe(_ missing: [Int]) -> String {
        let shown = missing.prefix(6).map { "#\($0)" }.joined(separator: ", ")
        return "Missing " + shown + (missing.count > 6 ? " and \(missing.count - 6) more" : "")
    }

    // MARK: - Duplicates

    /// Strict duplicates: same file name, byte-identical file, or byte-identical cover. Matching
    /// metadata alone never counts. Groups are transitive (union-find).
    func duplicateGroups() async throws -> [[Comic]] {
        let entries = try await read { db in
            try db.query("SELECT id, file_path, file_hash, page_count FROM comics WHERE deleted_at IS NULL") {
                (id: $0.int64(0), path: $0.string(1) ?? "", hash: $0.string(2), pages: $0.int(3))
            }
        }
        let covers = AppPaths.covers
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var parent = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.id) })
        func find(_ x: Int64) -> Int64 {
            var root = x
            while let p = parent[root], p != root { root = p }
            parent[x] = root
            return root
        }
        func union(_ ids: [Int64]) { for id in ids.dropFirst() { parent[find(id)] = find(ids[0]) } }

        for group in Dictionary(grouping: entries, by: { ($0.path as NSString).lastPathComponent }).values where group.count > 1 {
            union(group.map(\.id))
        }
        for group in Dictionary(grouping: entries.filter { $0.hash != nil }, by: { $0.hash! }).values where group.count > 1 {
            union(group.map(\.id))
        }
        // Covers are only read when another cover has the same byte size.
        var bySize: [Int: [Int64]] = [:]
        for e in entries {
            if let size = try? covers.appendingPathComponent("\(e.id).jpg").resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                bySize[size, default: []].append(e.id)
            }
        }
        for ids in bySize.values where ids.count > 1 {
            var byData: [Data: [Int64]] = [:]
            for id in ids {
                if let d = try? Data(contentsOf: covers.appendingPathComponent("\(id).jpg")) { byData[d, default: []].append(id) }
            }
            // A shared first page alone can be a scan group's banner, so a cover match also needs
            // the same page count and a file size within 2%.
            for group in byData.values where group.count > 1 {
                let info = group.compactMap { id -> (Int64, Int, Int)? in
                    guard let e = byID[id],
                          let size = try? URL(fileURLWithPath: e.path).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
                    return (id, e.pages, size)
                }
                for (i, a) in info.enumerated() {
                    for b in info[(i + 1)...] where a.1 == b.1 && abs(a.2 - b.2) <= max(a.2, b.2) / 50 { union([a.0, b.0]) }
                }
            }
        }
        let components = Dictionary(grouping: entries.map(\.id), by: find).values.filter { $0.count > 1 }
        guard !components.isEmpty else { return [] }
        let loaded = Dictionary(uniqueKeysWithValues: try await comics(ids: components.flatMap { $0 }).map { ($0.id, $0) })
        return components.map { $0.sorted().compactMap { loaded[$0] } }.filter { $0.count > 1 }
            .sorted { ($0[0].series, $0[0].title) < ($1[0].series, $1[0].title) }
    }

    // MARK: - Metadata conflicts

    struct ConflictInput: Sendable { let comicID: Int64; let field: String; let current: String?; let proposed: String?; let source: String }

    /// Re-detecting a conflict reopens it, so an old dismissal can't hide a still-real disagreement.
    static func upsertConflicts(_ items: [ConflictInput], on db: SQLiteConnection) throws {
        try db.runBatch("""
            INSERT INTO metadata_conflicts (comic_id, field, current_value, proposed_value, proposed_source, status, detected_at)
            VALUES (?,?,?,?,?, 'pending', datetime('now'))
            ON CONFLICT(comic_id, field) DO UPDATE SET current_value = excluded.current_value,
                proposed_value = excluded.proposed_value, proposed_source = excluded.proposed_source,
                status = 'pending', detected_at = excluded.detected_at, resolved_at = NULL
            """, items.map { [$0.comicID, $0.field, $0.current, $0.proposed, $0.source] })
    }

    /// `apply` writes the proposed value (marking the comic as edited); `dismiss` keeps the current one.
    func resolveConflict(_ c: MetadataConflict, apply: Bool) async throws {
        try await write { db in
            try db.transaction {
                if apply, ["series", "publisher", "issue_number"].contains(c.field) {
                    try db.run("UPDATE comics SET \(c.field) = ?, meta_edited = 1 WHERE id = ?", [c.proposedValue, c.comic.id])
                }
                try db.run("UPDATE metadata_conflicts SET status = ?, resolved_at = datetime('now') WHERE id = ?",
                           [apply ? "applied" : "dismissed", c.id])
            }
        }
    }

    /// Nil when `current` is empty or a placeholder, or agrees with `proposed` (case-insensitive).
    static func conflict(field: String, current: String?, proposed: String?, comicID: Int64) -> ConflictInput? {
        let placeholders: Set<String> = ["", "general", "unknown"]
        guard let current, let proposed else { return nil }
        let a = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = proposed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !placeholders.contains(a), !b.isEmpty, a != b else { return nil }
        return ConflictInput(comicID: comicID, field: field, current: current, proposed: proposed, source: "ComicInfo.xml")
    }
}
