import Foundation

enum BackupService {
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
                                                "progress": c.progress, "rating": c.rating,
                                                "is_favorite": c.isFavorite, "in_reading_list": c.inReadingList]
                        if let i = c.issueNumber { d["issue_number"] = i }
                        if let n = c.notes, !n.isEmpty { d["notes"] = n }
                        if let rv = c.review, !rv.isEmpty { d["review"] = rv }
                        let tagNames = db.tags(for: c.id).map(\.name)
                        if !tagNames.isEmpty { d["tags"] = tagNames }
                        let marks = db.bookmarks(comicId: c.id)
                        if !marks.isEmpty {
                            d["bookmarks"] = marks.map { ["page": $0.page, "label": $0.label] }
                        }
                        return d
                    }

                    let pathById = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0.filePath) })
                    let runsJSON: [[String: Any]] = db.allRuns().map { run in
                        var d: [String: Any] = ["title": run.title, "description": run.description]
                        if let bl = run.buyLink { d["buy_link"] = bl }
                        if let r = run.rating { d["rating"] = r }
                        if let rv = run.review { d["review"] = rv }
                        d["items"] = db.runItems(runId: run.id).compactMap { item -> [String: Any]? in
                            guard let path = pathById[item.comic.id] else { return nil }
                            return ["file_path": path, "position": item.position, "notes": item.notes]
                        }
                        return d
                    }

                    return ["comics": comicsJSON, "runs": runsJSON]
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
        fileService.pickFiles(allowsMultiple: false, message: "", prompt: "Import") { urls in
            guard let url = urls.first else { return }
            Task {
                let result = await Task.detached(priority: .utility) { () -> String? in
                    guard let data = try? Data(contentsOf: url),
                          let parsed = try? JSONSerialization.jsonObject(with: data) else {
                        return "Could not read backup file."
                    }
                    let db = DatabaseManager.shared
                    let knownPaths = db.knownPaths()

                    let root = parsed as? [String: Any]
                    let comicsArr = root?["comics"] as? [[String: Any]] ?? (parsed as? [[String: Any]]) ?? []
                    var comicIdByPath: [String: Int64] = [:]
                    for item in comicsArr {
                        guard let path = item["file_path"] as? String, knownPaths.contains(path) else { continue }
                        let id = (item["id"] as? Int64) ?? (item["id"] as? Int).map(Int64.init)
                               ?? (item["id"] as? Double).map(Int64.init) ?? nil
                        guard let comicId = id, comicId > 0 else { continue }
                        comicIdByPath[path] = comicId
                        if let r = item["rating"] as? Int, r > 0 { db.setRating(comicId, rating: r) }
                        if let f = item["is_favorite"] as? Bool   { db.setFavorite(comicId, f) }
                        if let rl = item["in_reading_list"] as? Bool { db.setInReadingList(comicId, rl) }
                        if let p = item["progress"] as? Int, p > 0 { db.updateProgress(comicId: comicId, page: p) }
                        if let rv = item["review"] as? String, !rv.isEmpty { db.setComicReview(comicId, review: rv) }
                        if let n = item["notes"] as? String, !n.isEmpty { db.setComicNotes(comicId, notes: n) }
                        if let tags = item["tags"] as? [String] {
                            for name in tags { db.addTag(name: name, to: comicId) }
                        }
                        if let marks = item["bookmarks"] as? [[String: Any]] {
                            for m in marks {
                                guard let page = m["page"] as? Int else { continue }
                                if !db.isBookmarked(comicId: comicId, page: page) { db.toggleBookmark(comicId: comicId, page: page) }
                                if let label = m["label"] as? String, !label.isEmpty { db.setBookmarkLabel(comicId: comicId, page: page, label: label) }
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
                            if let rating = r["rating"] as? Int {
                                db.setRunRating(runId, rating: rating, review: r["review"] as? String)
                            }
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
