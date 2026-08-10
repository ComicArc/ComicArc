import Foundation

extension LibraryViewModel {
    /// Called at launch and after any mutation that changes the tier-list *list* (create/delete/
    /// reorder) -- edits to a single tier list's fields (rating, cover) don't need this.
    func refreshTierLists() {
        tierListsGeneration += 1
        let gen = tierListsGeneration
        Task.detached(priority: .utility) { [db] in
            let loaded = db.allTierLists()
            await MainActor.run {
                guard gen == self.tierListsGeneration else { return }
                self.tierLists = loaded
            }
        }
    }

    @discardableResult
    func createTierList(title: String, description: String) -> Int64 {
        let id = db.createTierList(title: title, description: description)
        refreshTierLists()
        return id
    }
    func deleteTierListWithUndo(_ tierList: TierList) {
        let items = db.tierListItems(tierListId: tierList.id)
        db.deleteTierList(tierList.id)
        refreshTierLists()
        NotificationCenter.default.post(name: .tierListDeleted, object: nil)
        offerUndo("Tier List \"\(tierList.title)\" deleted") { [weak self] in
            guard let self else { return }
            let newId = self.db.createTierList(title: tierList.title, description: tierList.description)
            if let rating = tierList.rating {
                self.db.setTierListRating(newId, rating: rating, review: tierList.review)
            }
            if let cover = tierList.coverImagePath {
                self.db.setTierListCover(tierListId: newId, imagePath: cover)
            }
            for tier in ComicTier.allCases {
                let ids = items.filter { $0.tier == tier.rawValue }.map(\.comic.id)
                if !ids.isEmpty { self.db.addToTierList(tierListId: newId, comicIds: ids, tier: tier.rawValue) }
            }
            self.refreshTierLists()
            NotificationCenter.default.post(name: .tierListDeleted, object: nil)
        }
    }
    func updateTierList(id: Int64, title: String, description: String) {
        db.updateTierList(id: id, title: title, description: description)
        NotificationCenter.default.post(name: .tierListUpdated, object: nil)
    }
    func setTierListRating(_ tierListId: Int64, rating: Int, review: String?) {
        db.setTierListRating(tierListId, rating: rating, review: review)
        NotificationCenter.default.post(name: .tierListUpdated, object: nil)
    }
    func reorderTierLists(orderedIds: [Int64]) { db.reorderTierLists(orderedIds: orderedIds); refreshTierLists() }
    func addToTierList(tierListId: Int64, comicIds: [Int64], tier: String = "B") {
        db.addToTierList(tierListId: tierListId, comicIds: comicIds, tier: tier)
    }
    func removeFromTierList(tierListId: Int64, comicIds: [Int64]) {
        db.removeFromTierList(tierListId: tierListId, comicIds: comicIds)
    }
    func setTierListItemTier(itemId: Int64, tierListId: Int64, tier: String) {
        db.setTierListItemTier(itemId: itemId, tierListId: tierListId, tier: tier)
    }

    @discardableResult
    func setTierListCover(tierListId: Int64, imageURL: URL) -> String? {
        guard let path = ThumbnailCache.shared.saveCustomTierListCover(tierListId: tierListId, imageURL: imageURL) else { return nil }
        db.setTierListCover(tierListId: tierListId, imagePath: path)
        return path
    }
    func clearTierListCover(tierListId: Int64) { db.clearTierListCover(tierListId: tierListId) }

    func setTierListCover(tierListId: Int64, usingCoverOf comic: Comic, onDone: @escaping () -> Void = {}) {
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: "tierlist_\(tierListId)") else { return }
            db.setTierListCover(tierListId: tierListId, imagePath: path)
            await MainActor.run { onDone() }
        }
    }

}
