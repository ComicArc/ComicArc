import Foundation

/// What to load for a comic grid. Every field narrows the result; all nil means the whole library.
struct ComicFilter: Hashable, Sendable {
    var publisher: String?
    var group: String?            // character group name (with `publisher`)
    var series: String?           // with `publisher`
    var tag: String?
    var era: String?              // folder group such as "Classic" or "Modern"
    var search: String?
    var favoritesOnly = false
    var inProgressOnly = false
    var unreadOnly = false
    var sort: SortOrder = .issue
    var limit: Int?
}

enum ComicSQL {
    /// Columns read by `comic(from:)`, in order.
    static let columns = """
        c.id, c.title, c.file_path, c.publisher, c.character, c.series, c.issue_number, c.page_count,
        c.year, c.writer, c.penciller, c.story_arc, c.notes, c.volume, c.format, c.language_iso,
        c.folder_group, c.added_at, COALESCE(c.position, c.id), c.file_hash,
        COALESCE(rp.current_page, 0), rp.last_read, rp.finished_at,
        (f.comic_id IS NOT NULL), (rl.comic_id IS NOT NULL), c.deleted_reason
        """
    static let columnCount: Int32 = 26

    static let readingListID = "(SELECT id FROM runs WHERE title = '\(ReadingPath.readingListTitle)' ORDER BY id LIMIT 1)"

    static let joins = """
        LEFT JOIN reading_progress rp ON rp.comic_id = c.id
        LEFT JOIN favorites f ON f.comic_id = c.id
        LEFT JOIN run_items rl ON rl.comic_id = c.id AND rl.run_id = \(readingListID)
        """

    static let select = "SELECT \(columns) FROM comics c \(joins)"

    /// The character-group name a comic belongs to: its character, or its series when the
    /// character field is missing or looks like a list rather than a name.
    static let groupName = """
        (CASE WHEN c.character IS NULL OR c.character LIKE '%,%' OR c.character LIKE '%[%'
                   OR c.character LIKE '%(%' OR LENGTH(c.character) > 60
              THEN c.series ELSE c.character END)
        """

    static func comic(from r: Row, offset o: Int32 = 0) -> Comic {
        Comic(
            id: r.int64(o), title: r.string(o + 1) ?? "", filePath: r.string(o + 2) ?? "",
            publisher: r.string(o + 3) ?? "Unknown", character: r.string(o + 4),
            series: r.string(o + 5) ?? "General", issueNumber: r.string(o + 6), pageCount: r.int(o + 7),
            year: r.optionalInt(o + 8), writer: r.string(o + 9), penciller: r.string(o + 10),
            storyArc: r.string(o + 11), notes: r.string(o + 12), volume: r.string(o + 13),
            format: r.string(o + 14), languageISO: r.string(o + 15), folderGroup: r.string(o + 16),
            addedAt: r.string(o + 17) ?? "", position: r.int(o + 18), fileHash: r.string(o + 19),
            currentPage: r.int(o + 20), lastRead: r.string(o + 21), finishedAt: r.string(o + 22),
            isFavorite: r.bool(o + 23), inReadingList: r.bool(o + 24), deletedReason: r.string(o + 25)
        )
    }

    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Every word must match some field, so "batman classic 1987" narrows step by step. Covers the
    /// folder hierarchy (publisher, character, folder group, series), title, issue, year, credits,
    /// story arc, notes and tags.
    static func searchClause(_ query: String) -> (sql: String, args: [SQLBindable?])? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let fields = ["c.title", "c.series", "c.publisher", "c.character", "c.folder_group", "c.issue_number",
                      "CAST(c.year AS TEXT)", "c.writer", "c.penciller", "c.story_arc", "c.notes"]
        var clauses: [String] = []
        var args: [SQLBindable?] = []
        for word in words {
            let pattern = "%\(likeEscaped(word))%"
            var parts = fields.map { "\($0) LIKE ? ESCAPE '\\'" }
            parts.append("c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON t.id = ct.tag_id WHERE t.name LIKE ? ESCAPE '\\')")
            args += Array(repeating: pattern, count: parts.count)
            clauses.append("(" + parts.joined(separator: " OR ") + ")")
        }
        return (clauses.joined(separator: " AND "), args)
    }

    static func orderBy(_ sort: SortOrder) -> String {
        switch sort {
        case .issue: return "c.publisher, c.series, COALESCE(c.position, c.id), c.title"
        case .title: return "c.title COLLATE NOCASE"
        case .recentlyAdded: return "c.added_at DESC, c.id DESC"
        case .recentlyRead: return "rp.last_read IS NULL, rp.last_read DESC, c.title"
        case .year: return "c.year IS NULL, c.year DESC, c.title"
        case .pageCount: return "c.page_count DESC, c.title"
        }
    }

    /// Started and not finished. The last two pages count as done, so a skipped back cover or ad
    /// page doesn't leave a comic stuck in Continue Reading.
    static let inProgressCondition = "rp.current_page > 0 AND rp.finished_at IS NULL AND (c.page_count = 0 OR rp.current_page < c.page_count - 2)"
}

extension Database {
    func comics(_ f: ComicFilter) async throws -> [Comic] {
        try await read { db in
            var conds = ["c.deleted_at IS NULL"]
            var args: [SQLBindable?] = []
            if let p = f.publisher { conds.append("c.publisher = ?"); args.append(p) }
            if let g = f.group { conds.append("\(ComicSQL.groupName) = ?"); args.append(g) }
            if let s = f.series { conds.append("c.series = ?"); args.append(s) }
            if let t = f.tag {
                conds.append("c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON t.id = ct.tag_id WHERE t.name = ?)")
                args.append(t)
            }
            if let e = f.era { conds.append("c.folder_group = ?"); args.append(e) }
            if let q = f.search, let clause = ComicSQL.searchClause(q) { conds.append(clause.sql); args += clause.args }
            if f.favoritesOnly { conds.append("f.comic_id IS NOT NULL") }
            if f.inProgressOnly { conds.append(ComicSQL.inProgressCondition) }
            if f.unreadOnly { conds.append("rp.finished_at IS NULL") }
            let order = f.inProgressOnly && f.sort == .issue ? "rp.last_read DESC" : ComicSQL.orderBy(f.sort)
            var sql = "\(ComicSQL.select) WHERE \(conds.joined(separator: " AND ")) ORDER BY \(order)"
            if let limit = f.limit { sql += " LIMIT \(limit)" }
            return try db.query(sql, args) { ComicSQL.comic(from: $0) }
        }
    }

    func comic(id: Int64) async throws -> Comic? {
        try await read { db in try db.first("\(ComicSQL.select) WHERE c.id = ?", [id]) { ComicSQL.comic(from: $0) } }
    }

    func comicSync(id: Int64) -> Comic? {
        try? readSync { db in try db.first("\(ComicSQL.select) WHERE c.id = ?", [id]) { ComicSQL.comic(from: $0) } }
    }

    func comics(ids: [Int64]) async throws -> [Comic] {
        guard !ids.isEmpty else { return [] }
        return try await read { db in
            var out: [Comic] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                out += try db.query("\(ComicSQL.select) WHERE c.id IN (\(marks))", chunk) { ComicSQL.comic(from: $0) }
            }
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return out.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }

    func inProgressCount() async throws -> Int {
        try await read { db in
            try db.scalarInt("SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON rp.comic_id = c.id WHERE c.deleted_at IS NULL AND \(ComicSQL.inProgressCondition)")
        }
    }

    /// The next or previous comic in the same series, in issue order.
    func adjacentComic(to comic: Comic, forward: Bool) -> Comic? {
        let op = forward ? ">" : "<"
        let dir = forward ? "ASC" : "DESC"
        return try? readSync { db in
            try db.first("""
                \(ComicSQL.select)
                WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ?
                  AND (COALESCE(c.position, c.id) \(op) ? OR (COALESCE(c.position, c.id) = ? AND c.id \(op) ?))
                ORDER BY COALESCE(c.position, c.id) \(dir), c.id \(dir)
                """, [comic.publisher, comic.series, comic.position, comic.position, comic.id]) { ComicSQL.comic(from: $0) }
        }
    }

    /// For each series you've recently finished an issue of, the issue after the furthest one
    /// you've finished, if you haven't started it.
    func upNext(limit: Int = 12) async throws -> [Comic] {
        let recent = try await read { db in
            try db.query("""
                \(ComicSQL.select) WHERE c.deleted_at IS NULL AND rp.finished_at IS NOT NULL
                ORDER BY rp.finished_at DESC LIMIT 60
                """) { ComicSQL.comic(from: $0) }
        }
        var seen = Set<String>()
        var out: [Comic] = []
        for comic in recent where seen.insert("\(comic.publisher)/\(comic.series)").inserted {
            let furthest = try await read { db in
                try db.first("""
                    \(ComicSQL.select) WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ?
                      AND rp.finished_at IS NOT NULL ORDER BY COALESCE(c.position, c.id) DESC
                    """, [comic.publisher, comic.series]) { ComicSQL.comic(from: $0) }
            } ?? comic
            if let next = adjacentComic(to: furthest, forward: true), !next.isStarted, !next.isFinished {
                out.append(next)
                if out.count == limit { break }
            }
        }
        return out
    }

    func publishers() async throws -> [String] {
        try await read { db in
            try db.query("""
                SELECT DISTINCT c.publisher FROM comics c LEFT JOIN publisher_order po ON po.publisher = c.publisher
                WHERE c.deleted_at IS NULL AND c.publisher IS NOT NULL
                ORDER BY COALESCE(po.position, 999999), c.publisher
                """) { $0.string(0) ?? "" }
        }
    }

    /// Eras come from the folder between character and series (e.g. Classic / Modern) and act as
    /// automatic tags.
    func eras() async throws -> [Tag] {
        try await read { db in
            try db.query("""
                SELECT folder_group, COUNT(*) FROM comics WHERE deleted_at IS NULL AND folder_group IS NOT NULL AND folder_group != ''
                GROUP BY folder_group ORDER BY folder_group COLLATE NOCASE
                """) { Tag(id: -1, name: $0.string(0) ?? "", count: $0.int(1)) }
        }
    }

    /// Most recently added comics.
    func recentlyAdded(limit: Int = 14) async throws -> [Comic] {
        try await comics(ComicFilter(sort: .recentlyAdded, limit: limit))
    }

    /// A random unread first issue of a series you haven't started, for "Surprise Me".
    func surprise() async throws -> Comic? {
        try await read { db in
            try db.first("""
                \(ComicSQL.select) WHERE c.deleted_at IS NULL AND rp.finished_at IS NULL AND COALESCE(rp.current_page, 0) = 0
                  AND NOT EXISTS (SELECT 1 FROM comics s JOIN reading_progress r ON r.comic_id = s.id
                                  WHERE s.publisher = c.publisher AND s.series = c.series AND s.deleted_at IS NULL
                                    AND (r.current_page > 0 OR r.finished_at IS NOT NULL))
                  AND COALESCE(c.position, c.id) = (SELECT MIN(COALESCE(x.position, x.id)) FROM comics x
                                  WHERE x.publisher = c.publisher AND x.series = c.series AND x.deleted_at IS NULL)
                ORDER BY RANDOM() LIMIT 1
                """) { ComicSQL.comic(from: $0) }
        }
    }

    func libraryCount() async throws -> Int {
        try await read { db in try db.scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL") }
    }
}
