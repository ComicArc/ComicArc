import Foundation
import Combine
import CoreSpotlight
import os

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
        let updates = comics
            .filter { selectedComicIds.contains($0.id) }
            .map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) }
        db.updateProgress(updates)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkMarkUnread() {
        db.updateProgress(selectedComicIds.map { (comicId: $0, page: 0) })
        selectedComicIds.removeAll()
        reload()
    }

    func bulkAddToReadingList() {
        db.setInReadingList(Array(selectedComicIds), true)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkRemoveFromReadingList() {
        db.setInReadingList(Array(selectedComicIds), false)
        selectedComicIds.removeAll()
        reload()
    }

    func bulkReassign(series: String?, publisher: String?) {
        db.bulkReassign(ids: Array(selectedComicIds), series: series, publisher: publisher)
        selectedComicIds.removeAll()
        reload()
        refreshDuplicates()
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

    func markAllRead() {
        db.updateProgress(comics.map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) })
        reload()
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
}
