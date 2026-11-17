import Foundation

/// A JSON backup of everything you've added to the library: progress, finished status,
/// favorites, notes, tags, bookmarks, Reading Paths, manual orders and series cover picks.
/// Comics are matched by file path on restore. Compatible with backups from earlier versions.
enum BackupService {
    struct RestoreSummary { var comics = 0; var paths = 0; var unmatched = 0 }

    static func export(to url: URL) async throws {
        let json = try await Database.shared.read { db -> [String: Any] in
            let comics = try db.query("\(ComicSQL.select) WHERE c.deleted_at IS NULL") { ComicSQL.comic(from: $0) }
            let tags = Dictionary(grouping: try db.query("SELECT ct.comic_id, t.name FROM comic_tags ct JOIN tags t ON t.id = ct.tag_id") {
                ($0.int64(0), $0.string(1) ?? "")
            }, by: \.0).mapValues { $0.map(\.1) }
            let marks = Dictionary(grouping: try db.query("SELECT comic_id, page, label, is_favorite FROM bookmarks") {
                ($0.int64(0), ["page": $0.int(1), "label": $0.string(2) ?? "", "is_favorite": $0.bool(3)] as [String: Any])
            }, by: \.0).mapValues { $0.map(\.1) }
            let comicsJSON: [[String: Any]] = comics.compactMap { c in
                guard c.isStarted || c.isFinished || c.isFavorite || c.notes != nil || tags[c.id] != nil || marks[c.id] != nil else { return nil }
                var d: [String: Any] = ["file_path": c.filePath, "title": c.title, "series": c.series, "publisher": c.publisher,
                                        "progress": c.currentPage, "is_favorite": c.isFavorite, "in_reading_list": c.inReadingList,
                                        "finished": c.isFinished]
                if let n = c.notes, !n.isEmpty { d["notes"] = n }
                if let t = tags[c.id] { d["tags"] = t }
                if let m = marks[c.id] { d["bookmarks"] = m }
                return d
            }
            let paths = try db.query("SELECT id, title, COALESCE(description,''), buy_link FROM runs ORDER BY COALESCE(position, 999999), id") {
                ($0.int64(0), $0.string(1) ?? "", $0.string(2) ?? "", $0.string(3))
            }
            let pathsJSON: [[String: Any]] = try paths.map { p in
                var d: [String: Any] = ["title": p.1, "description": p.2]
                if let link = p.3 { d["buy_link"] = link }
                d["items"] = try db.query("""
                    SELECT c.file_path, ri.position, COALESCE(ri.notes,'') FROM run_items ri JOIN comics c ON c.id = ri.comic_id
                    WHERE ri.run_id = ? ORDER BY ri.position
                    """, [p.0]) { ["file_path": $0.string(0) ?? "", "position": $0.int(1), "notes": $0.string(2) ?? ""] }
                return d
            }
            return [
                "version": 2,
                "comics": comicsJSON,
                "runs": pathsJSON,
                "reading_order_overrides": try db.query("""
                    SELECT c.file_path, o.position, COALESCE(o.reason,'') FROM reading_order_overrides o JOIN comics c ON c.id = o.comic_id
                    """) { ["file_path": $0.string(0) ?? "", "position": $0.int(1), "reason": $0.string(2) ?? ""] },
                "series_order": try db.query("SELECT group_name, publisher, series, position FROM series_order") {
                    ["group_name": $0.string(0) ?? "", "publisher": $0.string(1) ?? "", "series": $0.string(2) ?? "", "position": $0.int(3)]
                },
                "character_order": try db.query("SELECT group_name, publisher, position FROM character_order") {
                    ["group_name": $0.string(0) ?? "", "publisher": $0.string(1) ?? "", "position": $0.int(2)]
                },
                "publisher_order": try db.query("SELECT publisher FROM publisher_order ORDER BY position") { $0.string(0) ?? "" },
                "series_covers": try db.query("""
                    SELECT sc.series, sc.publisher, c.file_path FROM series_covers sc JOIN comics c ON c.id = sc.comic_id
                    """) { ["series": $0.string(0) ?? "", "publisher": $0.string(1) ?? "", "file_path": $0.string(2) ?? ""] },
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Merges a backup into the current library. Nothing already in the library is removed.
    static func restore(from url: URL) async throws -> RestoreSummary {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await Database.shared.write { db in
            try db.transaction {
                var summary = RestoreSummary()
                let ids = Dictionary(try db.query("SELECT file_path, id FROM comics WHERE deleted_at IS NULL") {
                    ($0.string(0) ?? "", $0.int64(1))
                }, uniquingKeysWith: { a, _ in a })

                for item in root["comics"] as? [[String: Any]] ?? [] {
                    guard let path = item["file_path"] as? String, let id = ids[path] else { summary.unmatched += 1; continue }
                    summary.comics += 1
                    let page = item["progress"] as? Int ?? 0
                    let finished = item["finished"] as? Bool ?? false
                    if page > 0 || finished {
                        try db.run("""
                            INSERT INTO reading_progress (comic_id, current_page, last_read, finished_at)
                            VALUES (?, ?, datetime('now'), CASE WHEN ? THEN datetime('now') END)
                            ON CONFLICT(comic_id) DO UPDATE SET current_page = MAX(current_page, excluded.current_page),
                                finished_at = COALESCE(finished_at, excluded.finished_at)
                            """, [id, page, finished])
                    }
                    if item["is_favorite"] as? Bool == true { try db.run("INSERT OR IGNORE INTO favorites (comic_id) VALUES (?)", [id]) }
                    if let notes = item["notes"] as? String, !notes.isEmpty { try db.run("UPDATE comics SET notes = ? WHERE id = ?", [notes, id]) }
                    for tag in item["tags"] as? [String] ?? [] {
                        try db.run("INSERT OR IGNORE INTO tags (name, category) VALUES (?, 'Custom')", [tag])
                        try db.run("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) SELECT ?, id FROM tags WHERE name = ?", [id, tag])
                    }
                    for mark in item["bookmarks"] as? [[String: Any]] ?? [] {
                        guard let p = mark["page"] as? Int else { continue }
                        try db.run("""
                            INSERT INTO bookmarks (comic_id, page, label, is_favorite) VALUES (?,?,?,?)
                            ON CONFLICT(comic_id, page) DO UPDATE SET label = excluded.label, is_favorite = MAX(is_favorite, excluded.is_favorite)
                            """, [id, p, mark["label"] as? String ?? "", mark["is_favorite"] as? Bool ?? false])
                    }
                    if item["in_reading_list"] as? Bool == true {
                        try addToPath(db, title: ReadingPath.readingListTitle, description: "", comicIDs: [id])
                    }
                }

                for path in root["runs"] as? [[String: Any]] ?? [] {
                    guard let title = path["title"] as? String else { continue }
                    let items = (path["items"] as? [[String: Any]] ?? []).sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                    try addToPath(db, title: title, description: path["description"] as? String ?? "",
                                  comicIDs: items.compactMap { ($0["file_path"] as? String).flatMap { ids[$0] } })
                    summary.paths += 1
                }

                for o in root["reading_order_overrides"] as? [[String: Any]] ?? [] {
                    guard let p = o["file_path"] as? String, let id = ids[p], let pos = o["position"] as? Int else { continue }
                    try db.run("INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?,?,?)",
                               [id, pos, o["reason"] as? String ?? "Manually placed"])
                    try db.run("UPDATE comics SET position = ? WHERE id = ?", [pos, id])
                }
                for o in root["series_order"] as? [[String: Any]] ?? [] {
                    try db.run("INSERT OR REPLACE INTO series_order (group_name, publisher, series, position) VALUES (?,?,?,?)",
                               [o["group_name"] as? String, o["publisher"] as? String, o["series"] as? String, o["position"] as? Int ?? 0])
                }
                for o in root["character_order"] as? [[String: Any]] ?? [] {
                    try db.run("INSERT OR REPLACE INTO character_order (group_name, publisher, position) VALUES (?,?,?)",
                               [o["group_name"] as? String, o["publisher"] as? String, o["position"] as? Int ?? 0])
                }
                for (i, p) in (root["publisher_order"] as? [String] ?? []).enumerated() {
                    try db.run("INSERT OR REPLACE INTO publisher_order (publisher, position) VALUES (?,?)", [p, i])
                }
                for s in root["series_covers"] as? [[String: Any]] ?? [] {
                    guard let p = s["file_path"] as? String, let id = ids[p] else { continue }
                    try db.run("INSERT OR REPLACE INTO series_covers (series, publisher, comic_id) VALUES (?,?,?)",
                               [s["series"] as? String, s["publisher"] as? String, id])
                }
                return summary
            }
        }
    }

    private static func addToPath(_ db: SQLiteConnection, title: String, description: String, comicIDs: [Int64]) throws {
        var pathID = try db.first("SELECT id FROM runs WHERE title = ? ORDER BY id", [title]) { $0.int64(0) }
        if pathID == nil {
            try db.run("INSERT INTO runs (title, description, position) VALUES (?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM runs))",
                       [title, description])
            pathID = db.lastInsertRowID
        }
        var next = try db.scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?", [pathID!])
        for id in comicIDs {
            if try db.run("INSERT OR IGNORE INTO run_items (run_id, comic_id, position) VALUES (?,?,?)", [pathID!, id, next]) > 0 { next += 1 }
        }
    }
}
