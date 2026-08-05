import Foundation
import Combine
import CoreSpotlight
import os

extension LibraryViewModel {
    func toggleFavorite(_ comic: Comic) {
        let newValue = !comic.isFavorite
        db.setFavorite(comic.id, newValue)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .favorites && !newValue) {
            $0.isFavorite = newValue
        }
    }

    func toggleReadingList(_ comic: Comic) {
        let newValue = !comic.inReadingList
        db.setInReadingList(comic.id, newValue)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .readingList && !newValue) {
            $0.inReadingList = newValue
        }
    }

    func setRating(_ comic: Comic, rating: Int) {
        db.setRating(comic.id, rating: rating)
        patchComicLocally(comic.id) { $0.rating = rating }
    }

    func markRead(_ comic: Comic) {
        let page = max(0, comic.pageCount - 1)
        db.updateProgress(comicId: comic.id, page: page)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .continueReading) {
            $0.progress = page
        }
    }

    func markUnread(_ comic: Comic) {
        db.updateProgress(comicId: comic.id, page: 0)
        patchComicLocally(comic.id, removeIfNoLongerVisible: selectedSection == .continueReading) {
            $0.progress = 0
        }
    }
    func markRead(_ comics: [Comic]) {
        db.updateProgress(comics.map { (comicId: $0.id, page: max(0, $0.pageCount - 1)) })
        reload()
    }

    func setReview(_ comic: Comic, review: String?) { db.setComicReview(comic.id, review: review?.isEmpty == false ? review : nil) }
    func updateMeta(comicId: Int64, fields: [(String, Any?)]) { db.updateMeta(comicId: comicId, fields: fields) }

    func addTag(name: String, to comic: Comic, category: TagCategory = .custom) { db.addTag(name: name, to: comic.id, category: category) }
    func removeTag(tagId: Int64, from comic: Comic) { db.removeTag(tagId: tagId, from: comic.id) }
    func renameTag(id: Int64, newName: String) { db.renameTag(id: id, newName: newName); reload() }
    func deleteTagGlobally(id: Int64) { db.deleteTagGlobally(id: id); reload() }
    func setTagCategory(id: Int64, category: TagCategory) { db.setTagCategory(id: id, category: category); reload() }

    func setReadingGoal(year: Int, count: Int) { db.setReadingGoal(year: year, count: count) }

    func setManualGCDMatch(comicId: Int64, gcdIssueId: Int, seriesName: String, issueNumber: String,
                           coverDate: String?, seriesYearBegan: Int?) {
        db.setManualGCDMatch(comicId: comicId, gcdIssueId: gcdIssueId, seriesName: seriesName,
                              issueNumber: issueNumber, coverDate: coverDate, seriesYearBegan: seriesYearBegan)
    }
    func clearManualGCDMatch(comicId: Int64) {
        db.clearManualGCDMatch(comicId: comicId)
    }
}
