import Foundation
import CoreSpotlight

extension LibraryViewModel {
    func toggleBulkMode() {
        bulkMode.toggle()
        if !bulkMode { selectedComicIds.removeAll() }
    }

    func toggleSelection(_ id: Int64) {
        if selectedComicIds.contains(id) { selectedComicIds.remove(id) }
        else { selectedComicIds.insert(id) }
    }

    func selectAll() { selectedComicIds = Set(comics.map(\.id)) }

    func bulkMarkRead() {
        let selected = comics.filter { selectedComicIds.contains($0.id) }
        selectedComicIds.removeAll()
        markRead(selected)
    }

    func bulkMarkUnread() {
        let selected = comics.filter { selectedComicIds.contains($0.id) }
        selectedComicIds.removeAll()
        markUnread(selected)
    }

    func bulkAddToReadingList() {
        db.setInReadingList(comics.filter { selectedComicIds.contains($0.id) }.map(\.id), true)
        selectedComicIds.removeAll()
        reload()
        refreshRuns()
    }

    func bulkRemoveFromReadingList() {
        db.setInReadingList(visibleSelectedIds(), false)
        selectedComicIds.removeAll()
        reload()
        refreshRuns()
    }

    /// Unlike delete/run-delete/tier-list-delete, this previously had no undo -- a bulk reassign
    /// is exactly the kind of "affects N comics at once, easy to fat-finger the wrong series name"
    /// action that most needs one. Snapshots each comic's own (series, publisher) *before* the
    /// change, since a bulk reassign can apply to comics that started out in different series --
    /// undo has to restore each one to its own original values individually, not just re-apply
    /// one shared pair.
    func bulkReassign(series: String?, publisher: String?) {
        let ids = visibleSelectedIds()
        guard !ids.isEmpty else { return }
        let previous: [(id: Int64, series: String, publisher: String)] = comics
            .filter { ids.contains($0.id) }
            .map { (id: $0.id, series: $0.series, publisher: $0.publisher) }

        db.bulkReassign(ids: ids, series: series, publisher: publisher)
        selectedComicIds.removeAll()
        reload()
        refreshDuplicates()

        offerUndo(ids.count == 1 ? "1 comic reassigned" : "\(ids.count) comics reassigned") { [weak self] in
            guard let self else { return }
            for snap in previous {
                self.db.bulkReassign(ids: [snap.id], series: snap.series, publisher: snap.publisher)
            }
            self.reload()
            self.refreshDuplicates()
        }
    }

    /// `selectedComicIds` is meant to be scoped to whatever grid is currently on screen, but
    /// nothing besides navigation (see `select()`/`drillIntoGroup()`/`drillIntoSeries()`/
    /// `navigateBack()`) actually clears it -- filtering against `comics` here is the same
    /// belt-and-suspenders check `bulkMarkRead()`/`bulkDelete()` already apply, so a selection
    /// that somehow survives a navigation change (or a filter/search change within the same
    /// screen) can't silently mutate comics that aren't even visible anymore.
    private func visibleSelectedIds() -> [Int64] {
        let visible = Set(comics.map(\.id))
        return selectedComicIds.filter { visible.contains($0) }
    }

    /// Same trash-and-undo behavior as `delete(_:fileService:)` (single/multi-comic delete from a
    /// card or Duplicates), just reached from bulk-select instead -- previously this path never
    /// moved files to Trash at all, only `delete(_:)` did, so bulk-deleting left every file
    /// untouched on disk while the per-comic delete button genuinely trashed it.
    func bulkDelete(fileService: (any FileServiceProtocol)? = nil) {
        let toDelete = comics.filter { selectedComicIds.contains($0.id) }
        selectedComicIds.removeAll()
        bulkMode = false
        delete(toDelete, fileService: fileService)
    }

    func clearLibrary(resetPreferences: Bool = false) {
        LibraryScanner.shared.cancel()
        isScanning = false

        selectedComic = nil; selectedRun = nil; readerComic = nil
        selectedGroup = nil; selectedSeries = nil
        bulkMode = false; selectedComicIds.removeAll()
        comics = []; characterGroups = []; seriesGroups = []

        if resetPreferences {
            let keep: Set<String> = ["onboardingCompletedForBuild"]
            let all = UserDefaults.standard.dictionaryRepresentation().keys
            for key in all where !keep.contains(key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        LibraryScanner.shared.runAfterCurrentWork { [weak self, db] in
            db.clearAll()
            ThumbnailCache.shared.clearAll()
            CSSearchableIndex.default().deleteAllSearchableItems { _ in }
            DispatchQueue.main.async { self?.reload() }
        }
    }

    /// Deletes comics from the library AND moves their underlying files to the system Trash
    /// (not a permanent delete) -- previously "Delete" only hid the row from the library while
    /// silently leaving the file untouched on disk, which meant there was never an in-app way to
    /// actually reclaim space or clear out a bad/duplicate file. `fileService` is optional so
    /// call sites without one (or platforms where trashing isn't supported) still get the
    /// existing library-only removal, just without the file being touched.
    func delete(_ toDelete: [Comic], fileService: (any FileServiceProtocol)? = nil) {
        let ids = toDelete.map(\.id)
        if let fileService {
            for c in toDelete {
                if let trashedURL = fileService.moveToTrash(URL(fileURLWithPath: c.filePath)) {
                    // Persisted (not just held in this closure) so a restore from the Settings ->
                    // Trash screen -- which can happen long after this toast expires, even after
                    // an app relaunch -- still knows where to move the file back from.
                    db.setTrashedFilePath(id: c.id, path: trashedURL.path)
                }
            }
        }
        db.softDelete(ids)
        for c in toDelete { ThumbnailCache.shared.evict(c.id) }
        removeFromSpotlight(ids)
        reload()
        refreshDuplicates()
        offerUndo(toDelete.count == 1 ? "\"\(toDelete[0].title)\" deleted" : "\(toDelete.count) comics deleted") { [weak self] in
            guard let self else { return }
            for id in ids { self.restoreFromTrash(id: id) }
            self.indexSpotlight()
        }
    }

    /// Moves a comic's file back from the system Trash (if it was moved there by `delete`) to its
    /// original path, then restores the database row -- the single restore path shared by the
    /// delete undo toast above and the Settings -> Trash screen's "Restore" button, so both
    /// actually un-trash the file instead of just bringing the row back and leaving the file
    /// stranded in Trash.
    func restoreFromTrash(id: Int64) {
        if let trashedPath = db.trashedFilePath(id: id), let originalPath = db.filePath(forComicId: id) {
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: trashedPath), to: URL(fileURLWithPath: originalPath))
            db.setTrashedFilePath(id: id, path: nil)
        }
        db.restore([id])
        reload()
    }

    /// Permanently removes a single trashed comic's row (and, via `ON DELETE CASCADE`, its
    /// bookmarks/rating/progress/tags/run-items/tier-list-items/diary entries) -- Trash previously
    /// had no purge path at all. Never touches a file on disk: if `delete(fileService:)` already
    /// moved the file to the real system Trash, that's the user's Finder Trash to empty
    /// separately; a row soft-deleted without a file move ("missing"/"folder_removed") has no file
    /// here to touch either way.
    func purgeFromTrash(id: Int64) {
        db.purge([id])
        ThumbnailCache.shared.evict(id)
        reload()
    }

    /// Empties the whole Trash in one action -- the header "Empty Trash" button.
    func emptyTrash(_ trashedIds: [Int64]) {
        db.purgeAllTrashed()
        trashedIds.forEach { ThumbnailCache.shared.evict($0) }
        reload()
    }
}
