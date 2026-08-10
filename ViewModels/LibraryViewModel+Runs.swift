import Foundation

extension LibraryViewModel {
    /// Called at launch and after any mutation that changes the run *list* (create/delete/
    /// reorder) -- edits to a single run's fields (rating, cover, notes) don't need this since
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
    func deleteRun(_ runId: Int64) { db.deleteRun(runId); refreshRuns() }

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
            if let rating = run.rating {
                self.db.setRunRating(newId, rating: rating, review: run.review)
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
    func removeFromRun(runId: Int64, comicIds: [Int64]) { db.removeFromRun(runId: runId, comicIds: comicIds) }

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
    func setRunRating(_ runId: Int64, rating: Int, review: String?) {
        db.setRunRating(runId, rating: rating, review: review)
        NotificationCenter.default.post(name: .runUpdated, object: nil)
    }
    func setRunItemNotes(_ itemId: Int64, notes: String) { db.setRunItemNotes(itemId, notes: notes) }
}
