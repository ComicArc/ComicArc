import Foundation
import Combine
import CoreSpotlight
import os

extension LibraryViewModel {
    func saveCurrentAsView(name: String) {
        let view = SavedLibraryView(name: name, publisher: activePublisher, tag: activeTag,
                                     sortOrder: sortOrder, unreadOnly: unreadOnly,
                                     minRatingFilter: minRatingFilter, searchText: searchText)
        savedViews.append(view)
        SavedLibraryViews.write(savedViews)
    }

    func applySavedView(_ view: SavedLibraryView) {
        select(view.destination)
        sortOrder = view.sortOrder
        unreadOnly = view.unreadOnly
        minRatingFilter = view.minRatingFilter
        searchText = view.searchText
        // select()'s own reload() already ran with the previous sort/filter/search values (and
        // sortOrder's didSet only persists to UserDefaults, it doesn't reload) -- this final call
        // is what actually makes the view reflect everything just restored, immediately rather
        // than waiting on searchText's separate debounced reload.
        reload()
    }

    func renameSavedView(id: UUID, to newName: String) {
        guard let idx = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[idx].name = newName
        SavedLibraryViews.write(savedViews)
    }

    func deleteSavedView(id: UUID) {
        savedViews.removeAll { $0.id == id }
        SavedLibraryViews.write(savedViews)
    }

}
