import Foundation

extension LibraryViewModel {
    func refreshDuplicates() {
        duplicatesGeneration += 1
        let gen = duplicatesGeneration
        Task.detached(priority: .utility) { [db] in
            let groups = db.duplicateGroups()
            let autoPlaced = db.autoPlacedSpecialIssues()
            let conflicts = db.pendingMetadataConflicts().map { MetadataConflictRow(conflict: $0.conflict, comic: $0.comic) }
            await MainActor.run {
                guard gen == self.duplicatesGeneration else { return }
                self.duplicateGroups = groups
                self.autoPlacedIssues = autoPlaced
                self.pendingMetadataConflicts = conflicts
            }
        }
    }

    /// Pins the current sort/filter/search combination -- deliberately just a snapshot of what
    /// select()/reload() already track, not a new query concept, so applying one later is just
    /// setting these same published properties back.
    func refreshLibraryHealth() {
        healthGeneration += 1
        let gen = healthGeneration
        Task.detached(priority: .utility) {
            let report = LibraryHealthAnalyzer.analyze()
            await MainActor.run {
                guard gen == self.healthGeneration else { return }
                self.libraryHealthReport = report.isEmpty ? nil : report
            }
        }
    }

    /// Surfaces "N files could be renamed to match the library" as a dismissible sidebar banner
    /// after a scan, rather than requiring the user to remember Settings > Rename Files exists.
    /// Renaming itself stays a manual, reviewable action (RenameFilesView) -- it moves files on
    /// disk, which is exactly the kind of permanent change the app's own philosophy says should
    /// always be confirmed, not auto-applied.
    func refreshRenameCandidates() {
        renameCandidatesGeneration += 1
        let gen = renameCandidatesGeneration
        Task.detached(priority: .utility) { [db] in
            let count = ComicFileNaming.renameCandidateCount(for: db.allComics())
            await MainActor.run {
                guard gen == self.renameCandidatesGeneration else { return }
                if count != self.renameCandidateCount { self.renameSuggestionDismissed = false }
                self.renameCandidateCount = count
            }
        }
    }

    func dismissRenameSuggestion() {
        renameSuggestionDismissed = true
    }

    func runManualHealthCheck() {
        Task.detached(priority: .utility) {
            let report = LibraryHealthAnalyzer.analyze()
            await MainActor.run {
                self.libraryHealthReport = report
                self.showImportWizard = true
            }
        }
    }

    /// `apply`: adopts the proposed ComicInfo.xml-derived value (and reruns GCD matching/series
    /// linking/reading order, since a corrected series/publisher can change all three). `dismiss`:
    /// keeps the comic's current value untouched -- the conflict just stops being pending until
    /// something re-detects it (e.g. a future rescan with a still-differing value).
    func resolveMetadataConflict(_ row: MetadataConflictRow, apply: Bool) {
        Task.detached(priority: .userInitiated) { [db] in
            db.resolveMetadataConflict(id: row.conflict.id, apply: apply)
            if apply {
                db.recomputeGCDMatches()
                db.autoPopulateSeriesLinksFromGCD()
                db.recomputeReadingOrder()
            }
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }

    func rejectAutoPlacement(_ comic: Comic) {
        Task.detached(priority: .userInitiated) { [db] in
            db.setReadingOrderOverride(comicId: comic.id, position: comic.position, reason: "Manually placed")
            db.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }

    func confirmAutoPlacement(_ comic: Comic) {
        Task.detached(priority: .userInitiated) { [db] in
            let pinned = comic.readingOrderPosition ?? comic.position
            db.setReadingOrderOverride(comicId: comic.id, position: pinned, reason: "Confirmed correct")
            db.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }
}
