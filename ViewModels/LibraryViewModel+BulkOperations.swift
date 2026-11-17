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

    /// Undoable: each comic's own original series/publisher is snapshotted first.
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

    /// Only act on selected comics that are in the current grid.
    private func visibleSelectedIds() -> [Int64] {
        let visible = Set(comics.map(\.id))
        return selectedComicIds.filter { visible.contains($0) }
    }

    /// Same trash-and-undo behavior as `delete(_:fileService:)`.
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

    /// Removes comics from the library and moves their files to the system Trash (undoable).
    func delete(_ toDelete: [Comic], fileService: (any FileServiceProtocol)? = nil) {
        let ids = toDelete.map(\.id)
        if let fileService {
            for c in toDelete {
                if let trashedURL = fileService.moveToTrash(URL(fileURLWithPath: c.filePath)) {
                    // Persisted so Settings > Trash can still restore the file after this toast is
                    // gone.
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

    /// Moves a trashed file back to its original path and restores the row. Shared by the undo
    /// toast and Settings > Trash.
    func restoreFromTrash(id: Int64) {
        if let trashedPath = db.trashedFilePath(id: id), let originalPath = db.filePath(forComicId: id) {
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: trashedPath), to: URL(fileURLWithPath: originalPath))
            db.setTrashedFilePath(id: id, path: nil)
        }
        db.restore([id])
        reload()
    }

    /// Permanently removes a trashed comic's row (cascading to its bookmarks, progress, tags and
    /// path entries). Never touches files.
    func purgeFromTrash(id: Int64) {
        db.purge([id])
        ThumbnailCache.shared.evict(id)
        reload()
    }

    func emptyTrash(_ trashedIds: [Int64]) {
        db.purgeAllTrashed()
        trashedIds.forEach { ThumbnailCache.shared.evict($0) }
        reload()
    }
}
