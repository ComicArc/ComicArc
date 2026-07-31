import Foundation
import UniformTypeIdentifiers

enum BackupService {
    /// Exports a specific, already-curated set of comics (a series, a reading path, a tier list)
    /// as a plain CSV -- distinct from `export()`'s full-library JSON backup, which round-trips
    /// through the app but isn't meant for opening in a spreadsheet to print a checklist, share
    /// a want-list, or hand off to another tool.
    @MainActor
    static func exportCSV(comics: [Comic], fileService: any FileServiceProtocol,
                          filename: String, onError: @escaping (String) -> Void) {
        fileService.pickSaveDestination(filename: filename) { savedURL in
            guard let url = savedURL else { return }
            let header = ["Title", "Series", "Publisher", "Issue Number", "Volume", "Format",
                           "Year", "Rating", "Read", "File Path"]
            var rows = [header]
            for c in comics {
                rows.append([
                    c.title, c.series, c.publisher, c.issueNumber ?? "", c.volume ?? "", c.format ?? "",
                    c.year.map(String.init) ?? "", c.rating > 0 ? String(c.rating) : "",
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
                    let manualMatchesById = Dictionary(uniqueKeysWithValues:
                        db.manualGCDMatchDetails().map { ($0.comicId, $0) })

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
                            d["bookmarks"] = marks.map { ["page": $0.page, "label": $0.label, "is_favorite": $0.isFavorite] }
                        }
                        // A manual GCD match is a deliberate user choice (via the "Fix Match"
                        // picker) -- worth preserving across a restore, unlike an automatic match,
                        // which is disposable derived data the next scan regenerates on its own.
                        if let manual = manualMatchesById[c.id] {
                            var match: [String: Any] = ["gcd_issue_id": manual.gcdIssueId]
                            if let s = manual.seriesName { match["gcd_series_name"] = s }
                            if let n = manual.issueNumber { match["gcd_issue_number"] = n }
                            if let cd = manual.coverDate { match["gcd_cover_date"] = cd }
                            d["gcd_manual_match"] = match
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

                    let tierListsJSON: [[String: Any]] = db.allTierLists().map { tierList in
                        var d: [String: Any] = ["title": tierList.title, "description": tierList.description]
                        if let r = tierList.rating { d["rating"] = r }
                        if let rv = tierList.review { d["review"] = rv }
                        d["items"] = db.tierListItems(tierListId: tierList.id).compactMap { item -> [String: Any]? in
                            guard let path = pathById[item.comic.id] else { return nil }
                            return ["file_path": path, "tier": item.tier, "position": item.position]
                        }
                        return d
                    }

                    let diaryJSON: [[String: Any]] = db.diaryEntries(limit: Int.max).compactMap { entry -> [String: Any]? in
                        guard let path = pathById[entry.comic.id] else { return nil }
                        var d: [String: Any] = ["file_path": path, "rating": entry.rating,
                                                "is_reread": entry.isReread, "logged_at": entry.loggedAt]
                        if let rv = entry.review, !rv.isEmpty { d["review"] = rv }
                        return d
                    }

                    let seriesLinksJSON: [[String: Any]] = db.seriesLinks().map { link in
                        ["parent_publisher": link.parentPublisher, "parent_series": link.parentSeries,
                         "child_publisher": link.childPublisher, "child_series": link.childSeries,
                         "sequence_order": link.sequenceOrder, "source": link.source]
                    }

                    let overridesJSON: [[String: Any]] = db.allReadingOrderOverrides().map { o in
                        ["file_path": o.filePath, "position": o.position, "reason": o.reason]
                    }

                    // Manual sidebar/grid reordering and a series' custom "use this issue's cover"
                    // pick -- deliberate user customizations with no automatic way to regenerate
                    // them, same reasoning as the manual GCD match above. Previously silently
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
                            "tier_lists": tierListsJSON,
                            "diary": diaryJSON, "series_links": seriesLinksJSON,
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
                    // overwrite an unrelated comic's rating/favorites/progress/notes/tags/bookmarks.
                    let pathsInBackup = comicsArr.compactMap { $0["file_path"] as? String }
                    let currentIdByPath = Dictionary(uniqueKeysWithValues: db.comics(withPaths: pathsInBackup).map { ($0.filePath, $0.id) })
                    var comicIdByPath: [String: Int64] = [:]
                    for item in comicsArr {
                        guard let path = item["file_path"] as? String,
                              let comicId = currentIdByPath[path] else { continue }
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
                                if let fav = m["is_favorite"] as? Bool, fav { db.setBookmarkFavorite(comicId: comicId, page: page, isFavorite: true) }
                            }
                        }
                        if let match = item["gcd_manual_match"] as? [String: Any], let gcdIssueId = match["gcd_issue_id"] as? Int {
                            db.restoreManualGCDMatch(
                                comicId: comicId, gcdIssueId: gcdIssueId,
                                seriesName: match["gcd_series_name"] as? String,
                                issueNumber: match["gcd_issue_number"] as? String,
                                coverDate: match["gcd_cover_date"] as? String
                            )
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

                    if let tierListsArr = root?["tier_lists"] as? [[String: Any]] {
                        for tl in tierListsArr {
                            guard let title = tl["title"] as? String,
                                  let items = tl["items"] as? [[String: Any]], !items.isEmpty else { continue }
                            let tierListId = db.tierListId(withTitle: title)
                                ?? db.createTierList(title: title, description: tl["description"] as? String ?? "")
                            let byTier = Dictionary(grouping: items) { $0["tier"] as? String ?? "B" }
                            for (tier, tierItems) in byTier {
                                let orderedComicIds: [Int64] = tierItems
                                    .sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                                    .compactMap { i in (i["file_path"] as? String).flatMap { currentIdByPath[$0] } }
                                guard !orderedComicIds.isEmpty else { continue }
                                db.addToTierList(tierListId: tierListId, comicIds: orderedComicIds, tier: tier)
                            }
                            if let rating = tl["rating"] as? Int {
                                db.setTierListRating(tierListId, rating: rating, review: tl["review"] as? String)
                            }
                        }
                    }

                    if let diaryArr = root?["diary"] as? [[String: Any]] {
                        for entry in diaryArr {
                            guard let path = entry["file_path"] as? String,
                                  let comicId = currentIdByPath[path],
                                  let rating = entry["rating"] as? Int,
                                  let loggedAt = entry["logged_at"] as? String else { continue }
                            db.restoreDiaryEntry(comicId: comicId, rating: rating,
                                                  review: entry["review"] as? String,
                                                  isReread: entry["is_reread"] as? Bool ?? false,
                                                  loggedAt: loggedAt)
                        }
                    }

                    if let linksArr = root?["series_links"] as? [[String: Any]] {
                        for link in linksArr {
                            guard let parentPub = link["parent_publisher"] as? String,
                                  let parentSer = link["parent_series"] as? String,
                                  let childPub = link["child_publisher"] as? String,
                                  let childSer = link["child_series"] as? String else { continue }
                            db.addSeriesLink(parentPublisher: parentPub, parentSeries: parentSer,
                                              childPublisher: childPub, childSeries: childSer,
                                              source: link["source"] as? String ?? "manual")
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
