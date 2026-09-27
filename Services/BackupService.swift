import Foundation
import UniformTypeIdentifiers

enum BackupService {
    /// Exports a specific, already-curated set of comics (a series or a reading path)
    /// as a plain CSV -- distinct from `export()`'s full-library JSON backup, which round-trips
    /// through the app but isn't meant for opening in a spreadsheet to print a checklist, share
    /// a want-list, or hand off to another tool.
    @MainActor
    static func exportCSV(comics: [Comic], fileService: any FileServiceProtocol,
                          filename: String, onError: @escaping (String) -> Void) {
        fileService.pickSaveDestination(filename: filename) { savedURL in
            guard let url = savedURL else { return }
            let header = ["Title", "Series", "Publisher", "Issue Number", "Volume", "Format",
                           "Year", "Read", "File Path"]
            var rows = [header]
            for c in comics {
                rows.append([
                    c.title, c.series, c.publisher, c.issueNumber ?? "", c.volume ?? "", c.format ?? "",
                    c.year.map(String.init) ?? "",
                    c.isFinished ? "Yes" : "No", c.filePath
                ])
            }
            let csv = rows.map { row in
                row.map(csvField).joined(separator: ",")
            }.joined(separator: "\r\n")
            do {
                try csv.data(using: .utf8)?.write(to: url, options: .atomic)
                fileService.shareFile(url)
            } catch {
                onError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    @MainActor
    static func export(fileService: any FileServiceProtocol, filename: String = "ComicArc-backup.json",
                        onError: @escaping (String) -> Void) {
        fileService.pickSaveDestination(filename: filename) { savedURL in
            guard let url = savedURL else { return }
            Task {
                let backup: [String: Any] = await Task.detached(priority: .utility) {
                    let db = DatabaseManager.shared
                    let comics = db.allComics()

                    let comicsJSON: [[String: Any]] = comics.map { c in
                        var d: [String: Any] = ["id": c.id, "title": c.title, "file_path": c.filePath,
                                                "publisher": c.publisher, "series": c.series,
                                                "progress": c.progress,
                                                "is_favorite": c.isFavorite, "in_reading_list": c.inReadingList]
                        if let i = c.issueNumber { d["issue_number"] = i }
                        if let n = c.notes, !n.isEmpty { d["notes"] = n }
                        let tagNames = db.tags(for: c.id).map(\.name)
                        if !tagNames.isEmpty { d["tags"] = tagNames }
                        let marks = db.bookmarks(comicId: c.id)
                        if !marks.isEmpty {
                            d["bookmarks"] = marks.map { ["page": $0.page, "label": $0.label, "is_favorite": $0.isFavorite] }
                        }
                        return d
                    }

                    let pathById = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0.filePath) })
                    let runsJSON: [[String: Any]] = db.allRuns().map { run in
                        var d: [String: Any] = ["title": run.title, "description": run.description]
                        if let bl = run.buyLink { d["buy_link"] = bl }
                        d["items"] = db.runItems(runId: run.id).compactMap { item -> [String: Any]? in
                            guard let path = pathById[item.comic.id] else { return nil }
                            return ["file_path": path, "position": item.position, "notes": item.notes]
                        }
                        return d
                    }

                    let overridesJSON: [[String: Any]] = db.allReadingOrderOverrides().map { o in
                        ["file_path": o.filePath, "position": o.position, "reason": o.reason]
                    }

                    // Manual sidebar/grid reordering and a series' custom "use this issue's cover"
                    // pick -- deliberate user customizations with no automatic way to regenerate
                    // them. Previously silently
                    // dropped by both export and import.
                    let seriesOrderJSON: [[String: Any]] = db.allSeriesOrderPositions().map {
                        ["group_name": $0.groupName, "publisher": $0.publisher, "series": $0.series, "position": $0.position]
                    }
                    let characterOrderJSON: [[String: Any]] = db.allCharacterOrderPositions().map {
                        ["group_name": $0.groupName, "publisher": $0.publisher, "position": $0.position]
                    }
                    let publisherOrderJSON: [String] = db.allPublisherOrderPositions()
                        .sorted { $0.position < $1.position }
                        .map { $0.publisher }
                    let seriesCoversJSON: [[String: Any]] = db.allSeriesCoverComicAssignments().compactMap { assignment in
                        guard let path = pathById[assignment.comicId] else { return nil }
                        return ["series": assignment.series, "publisher": assignment.publisher, "file_path": path]
                    }

                    return ["comics": comicsJSON, "runs": runsJSON,
                            "reading_order_overrides": overridesJSON,
                            "series_order": seriesOrderJSON, "character_order": characterOrderJSON,
                            "publisher_order": publisherOrderJSON, "series_covers": seriesCoversJSON]
                }.value
                do {
                    let data = try JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted)
                    try data.write(to: url, options: .atomic)
                    fileService.shareFile(url)
                } catch {
                    await MainActor.run { onError("Export failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    @MainActor
    static func `import`(fileService: any FileServiceProtocol, vm: LibraryViewModel,
                          onError: @escaping (String) -> Void) {
        fileService.pickFiles(allowsMultiple: false, message: "", prompt: "Import", contentTypes: [.json]) { urls in
            guard let url = urls.first else { return }
            Task {
                let result = await Task.detached(priority: .utility) { () -> String? in
                    let data: Data
                    do {
                        data = try Data(contentsOf: url)
                    } catch {
                        return "Could not read backup file: \(error.localizedDescription)"
                    }
                    let parsed: Any
                    do {
                        parsed = try JSONSerialization.jsonObject(with: data)
                    } catch {
                        return "Backup file is not valid JSON: \(error.localizedDescription)"
                    }
                    let db = DatabaseManager.shared

                    let root = parsed as? [String: Any]
                    let comicsArr = root?["comics"] as? [[String: Any]] ?? (parsed as? [[String: Any]]) ?? []
                    // Resolve each backed-up comic to its *current* row by file path rather than
                    // trusting the numeric "id" stored in the backup JSON -- SQLite autoincrement
                    // ids are reassigned after clearLibrary()/resyncLibrary(), both user-triggered,
                    // so a path that still exists can belong to a different row than the id
                    // recorded at backup time. Restoring against the wrong id would silently
                    // overwrite an unrelated comic's favorites/progress/notes/tags/bookmarks.
                    let pathsInBackup = comicsArr.compactMap { $0["file_path"] as? String }
                    let currentIdByPath = Dictionary(uniqueKeysWithValues: db.comics(withPaths: pathsInBackup).map { ($0.filePath, $0.id) })
                    var comicIdByPath: [String: Int64] = [:]
                    for item in comicsArr {
                        guard let path = item["file_path"] as? String,
                              let comicId = currentIdByPath[path] else { continue }
                        comicIdByPath[path] = comicId
                        if let f = item["is_favorite"] as? Bool   { db.setFavorite(comicId, f) }
                        if let rl = item["in_reading_list"] as? Bool { db.setInReadingList(comicId, rl) }
                        if let p = item["progress"] as? Int, p > 0 { db.updateProgress(comicId: comicId, page: p) }
                        if let n = item["notes"] as? String, !n.isEmpty { db.setComicNotes(comicId, notes: n) }
                        if let tags = item["tags"] as? [String] {
                            for name in tags { db.addTag(name: name, to: comicId) }
                        }
                        if let marks = item["bookmarks"] as? [[String: Any]] {
                            for m in marks {
                                guard let page = m["page"] as? Int else { continue }
                                if !db.isBookmarked(comicId: comicId, page: page) { db.toggleBookmark(comicId: comicId, page: page) }
                                if let label = m["label"] as? String, !label.isEmpty { db.setBookmarkLabel(comicId: comicId, page: page, label: label) }
                                if let fav = m["is_favorite"] as? Bool, fav { db.setBookmarkFavorite(comicId: comicId, page: page, isFavorite: true) }
                            }
                        }
                    }

                    if let runsArr = root?["runs"] as? [[String: Any]] {
                        for r in runsArr {
                            guard let title = r["title"] as? String,
                                  let items = r["items"] as? [[String: Any]], !items.isEmpty else { continue }
                            let orderedComicIds: [Int64] = items
                                .sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                                .compactMap { i in (i["file_path"] as? String).flatMap { comicIdByPath[$0] } }
                            guard !orderedComicIds.isEmpty else { continue }

                            let runId = db.runId(withTitle: title)
                                ?? db.createRun(title: title, description: r["description"] as? String ?? "")
                            db.addToRun(runId: runId, comicIds: orderedComicIds)
                            db.reorderRun(runId: runId, orderedIds: orderedComicIds)
                            let notesByPath: [String: String] = Dictionary(uniqueKeysWithValues: items.compactMap { i in
                                guard let path = i["file_path"] as? String, let notes = i["notes"] as? String, !notes.isEmpty else { return nil }
                                return (path, notes)
                            })
                            if !notesByPath.isEmpty {
                                for runItem in db.runItems(runId: runId) {
                                    if let notes = notesByPath[runItem.comic.filePath] {
                                        db.setRunItemNotes(runItem.id, notes: notes)
                                    }
                                }
                            }
                        }
                    }

                    if let overridesArr = root?["reading_order_overrides"] as? [[String: Any]] {
                        for o in overridesArr {
                            guard let path = o["file_path"] as? String,
                                  let comicId = currentIdByPath[path],
                                  let position = o["position"] as? Int else { continue }
                            db.setReadingOrderOverride(comicId: comicId, position: position,
                                                        reason: o["reason"] as? String ?? "Manually placed")
                        }
                    }

                    if let seriesOrderArr = root?["series_order"] as? [[String: Any]] {
                        for (groupName, publisher) in Set(seriesOrderArr.compactMap { item -> [String]? in
                            guard let g = item["group_name"] as? String, let p = item["publisher"] as? String else { return nil }
                            return [g, p]
                        }).map({ (groupName: $0[0], publisher: $0[1]) }) {
                            let ordered = seriesOrderArr
                                .filter { ($0["group_name"] as? String) == groupName && ($0["publisher"] as? String) == publisher }
                                .sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                                .compactMap { $0["series"] as? String }
                            db.reorderSeriesGroups(groupName: groupName, publisher: publisher, orderedSeries: ordered)
                        }
                    }

                    if let characterOrderArr = root?["character_order"] as? [[String: Any]] {
                        for publisher in Set(characterOrderArr.compactMap { $0["publisher"] as? String }) {
                            let ordered = characterOrderArr
                                .filter { ($0["publisher"] as? String) == publisher }
                                .sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                                .compactMap { $0["group_name"] as? String }
                            db.reorderCharacterGroups(publisher: publisher, orderedGroupNames: ordered)
                        }
                    }

                    if let publisherOrderArr = root?["publisher_order"] as? [String], !publisherOrderArr.isEmpty {
                        db.reorderPublishers(orderedPublishers: publisherOrderArr)
                    }

                    if let seriesCoversArr = root?["series_covers"] as? [[String: Any]] {
                        for sc in seriesCoversArr {
                            guard let series = sc["series"] as? String, let publisher = sc["publisher"] as? String,
                                  let path = sc["file_path"] as? String, let comicId = currentIdByPath[path] else { continue }
                            db.setSeriesCover(series: series, publisher: publisher, comicId: comicId)
                        }
                    }
                    return nil
                }.value
                await MainActor.run {
                    if let errorMsg = result { onError(errorMsg) }
                    vm.reload()
                }
            }
        }
    }
}
