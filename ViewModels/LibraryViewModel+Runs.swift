import Foundation

extension LibraryViewModel {
    /// Called at launch and after any mutation that changes the run *list* (create/delete/
    /// reorder) -- edits to a single run's fields (title, cover, notes) don't need this since
    /// they don't change membership/order of `runs` itself.
    func refreshRuns() {
        runsGeneration += 1
        let gen = runsGeneration
        Task.detached(priority: .utility) { [db] in
            let loaded = db.allRuns()
            await MainActor.run {
                guard gen == self.runsGeneration else { return }
                self.runs = loaded
            }
        }
    }

    @discardableResult
    func createRun(title: String, description: String) -> Int64 {
        let id = db.createRun(title: title, description: description)
        refreshRuns()
        return id
    }

    func deleteRunWithUndo(_ run: Run) {
        let items = db.runItems(runId: run.id)
        db.deleteRun(run.id)
        refreshRuns()
        NotificationCenter.default.post(name: .runDeleted, object: nil)
        offerUndo("Reading order \"\(run.title)\" deleted") { [weak self] in
            guard let self else { return }
            let newId = self.db.createRun(title: run.title, description: run.description)
            if let buyLink = run.buyLink, !buyLink.isEmpty {
                self.db.updateRun(id: newId, title: run.title, description: run.description, buyLink: buyLink)
            }
            if let cover = run.coverImagePath {
                self.db.setRunCover(runId: newId, imagePath: cover)
            }
            self.db.addToRun(runId: newId, comicIds: items.map(\.comic.id))

            let newItems = self.db.runItems(runId: newId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setRunItemNotes(match.id, notes: item.notes)
                }
            }
            self.refreshRuns()
            NotificationCenter.default.post(name: .runDeleted, object: nil)
        }
    }

    func addToRun(runId: Int64, comicIds: [Int64]) { db.addToRun(runId: runId, comicIds: comicIds) }

    func removeFromRunWithUndo(runId: Int64, items: [RunItem], onRestored: @escaping () -> Void = {}) {
        let ids = items.map(\.comic.id)
        db.removeFromRun(runId: runId, comicIds: ids)
        let label = items.count == 1 ? "\"\(items[0].comic.title)\" removed" : "\(items.count) comics removed"
        offerUndo(label) { [weak self] in
            guard let self else { return }
            self.db.addToRun(runId: runId, comicIds: ids)
            let newItems = self.db.runItems(runId: runId)
            for item in items where !item.notes.isEmpty {
                if let match = newItems.first(where: { $0.comic.id == item.comic.id }) {
                    self.db.setRunItemNotes(match.id, notes: item.notes)
                }
            }
            onRestored()
        }
    }
    func reorderRun(runId: Int64, orderedIds: [Int64]) { db.reorderRun(runId: runId, orderedIds: orderedIds) }
    func reorderRuns(orderedIds: [Int64]) { db.reorderRuns(orderedIds: orderedIds); refreshRuns() }

    @discardableResult
    func setRunCover(runId: Int64, imageURL: URL) -> String? {
        guard let path = ThumbnailCache.shared.saveCustomRunCover(runId: runId, imageURL: imageURL) else { return nil }
        db.setRunCover(runId: runId, imagePath: path)
        return path
    }
    func clearRunCover(runId: Int64) { db.clearRunCover(runId: runId) }

    func setRunCover(runId: Int64, usingCoverOf comic: Comic, onDone: @escaping () -> Void = {}) {
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: "run_\(runId)") else { return }
            db.setRunCover(runId: runId, imagePath: path)
            await MainActor.run { onDone() }
        }
    }

    func updateRun(id: Int64, title: String, description: String, buyLink: String?) {
        db.updateRun(id: id, title: title, description: description, buyLink: buyLink)
        NotificationCenter.default.post(name: .runUpdated, object: nil)
    }
    /// Adds comics to a Reading Path in the given order (skipping any already in it) and offers
    /// an undo -- the multi-comic entry point behind bulk-select and "Add Series to Reading Path".
    func addToRunWithUndo(runId: Int64, runTitle: String, comicIds: [Int64]) {
        let already = db.comicIdsInRun(runId: runId)
        let added = comicIds.filter { !already.contains($0) }
        guard !added.isEmpty else { return }
        db.addToRun(runId: runId, comicIds: added)
        refreshRuns()
        NotificationCenter.default.post(name: .runUpdated, object: nil)
        offerUndo(added.count == 1 ? "Added 1 comic to \u{201C}\(runTitle)\u{201D}"
                                   : "Added \(added.count) comics to \u{201C}\(runTitle)\u{201D}") { [weak self] in
            guard let self else { return }
            self.db.removeFromRun(runId: runId, comicIds: added)
            self.refreshRuns()
            NotificationCenter.default.post(name: .runUpdated, object: nil)
        }
    }

    /// Bulk-select: adds the selected comics in the order they're shown in the grid.
    func bulkAddToRun(runId: Int64, runTitle: String) {
        let ids = comics.filter { selectedComicIds.contains($0.id) }.map(\.id)
        selectedComicIds.removeAll()
        addToRunWithUndo(runId: runId, runTitle: runTitle, comicIds: ids)
    }

    /// Adds every issue of a series, in series order (the same order the series view shows).
    func addSeriesToRun(series: String, publisher: String?, runId: Int64, runTitle: String) {
        Task.detached(priority: .userInitiated) { [db] in
            let ids = db.allComics(publisher: publisher, series: series, sortOrder: .manual).map(\.id)
            await MainActor.run { self.addToRunWithUndo(runId: runId, runTitle: runTitle, comicIds: ids) }
        }
    }

    /// Opens Reading Paths with the built-in "Reading List" path selected (if it exists yet).
    func showReadingList() {
        select(.runs)
        selectedRun = db.allRuns().first { $0.title == DatabaseManager.readingListTitle }
    }

    func setRunItemNotes(_ itemId: Int64, notes: String) { db.setRunItemNotes(itemId, notes: notes) }
}
