import Foundation

extension LibraryViewModel {
    func refreshDuplicates() {
        duplicatesGeneration += 1
        let gen = duplicatesGeneration
        Task.detached(priority: .utility) { [db] in
            let groups = db.duplicateGroups()
            let conflicts = db.pendingMetadataConflicts().map { MetadataConflictRow(conflict: $0.conflict, comic: $0.comic) }
            await MainActor.run {
                guard gen == self.duplicatesGeneration else { return }
                self.duplicateGroups = groups
                self.pendingMetadataConflicts = conflicts
            }
        }
    }

    /// Recomputes the Library Health report and the set of broken (unreadable) comics.
    func refreshLibraryHealth() {
        healthGeneration += 1
        let gen = healthGeneration
        Task.detached(priority: .utility) { [db] in
            let report = LibraryHealthAnalyzer.analyze()
            let broken = db.brokenComicIds()
            let emptySorts = db.sortOrdersWithoutData()
            await MainActor.run {
                guard gen == self.healthGeneration else { return }
                self.libraryHealthReport = report.isEmpty ? nil : report
                self.brokenComicIds = broken
                self.emptySortOrders = emptySorts
            }
        }
    }

    /// Counts files whose names don't match the library's naming convention, for the sidebar
    /// suggestion. Renaming stays a manual, reviewed action.
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

    /// `apply` adopts the ComicInfo.xml value; `dismiss` keeps the current one.
    func resolveMetadataConflict(_ row: MetadataConflictRow, apply: Bool) {
        Task.detached(priority: .userInitiated) { [db] in
            db.resolveMetadataConflict(id: row.conflict.id, apply: apply)
            await MainActor.run { self.reload(); self.refreshDuplicates() }
        }
    }

}
