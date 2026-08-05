import Foundation
import Combine
import CoreSpotlight
import os

extension LibraryViewModel {
    func setSeriesCover(_ comic: Comic) {
        db.setSeriesCover(series: comic.series, publisher: comic.publisher, comicId: comic.id)
        reload()
    }

    func moveComic(id: Int64, before targetId: Int64) {
        guard id != targetId else { return }
        var list = comics
        guard let fromIdx = list.firstIndex(where: { $0.id == id }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.id == targetId }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        comics = list
        db.reorderComics(orderedIds: list.map(\.id))

        if sortOrder != .manual { sortOrder = .manual }
    }

    func moveSeriesGroup(fromSeries: String, toSeries: String) {
        guard fromSeries != toSeries,
              let group = selectedGroup else { return }
        var list = seriesGroups
        guard let fromIdx = list.firstIndex(where: { $0.series == fromSeries }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.series == toSeries }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        seriesGroups = list
        db.reorderSeriesGroups(groupName: group.groupName, publisher: group.publisher,
                               orderedSeries: list.map(\.series))
    }

    func moveCharacterGroup(from: DatabaseManager.CharacterGroup, to: DatabaseManager.CharacterGroup) {
        guard from.id != to.id, from.publisher == to.publisher else { return }
        var list = characterGroups
        guard let fromIdx = list.firstIndex(where: { $0.id == from.id }) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(where: { $0.id == to.id }) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        characterGroups = list
        let sameGroups = list.filter { $0.publisher == from.publisher }.map(\.groupName)
        db.reorderCharacterGroups(publisher: from.publisher, orderedGroupNames: sameGroups)
    }

    func movePublisher(from: String, to: String) {
        guard from != to else { return }
        var list = publishers
        guard let fromIdx = list.firstIndex(of: from) else { return }
        let moved = list.remove(at: fromIdx)
        if let toIdx = list.firstIndex(of: to) {
            list.insert(moved, at: toIdx)
        } else {
            list.append(moved)
        }
        publishers = list
        db.reorderPublishers(orderedPublishers: list)
    }

    func setCharacterGroupCover(group: DatabaseManager.CharacterGroup, imageURL: URL) {
        guard let path = ThumbnailCache.shared.saveCustomGroupCover(
            groupName: group.groupName,
            publisher: group.publisher,
            imageURL: imageURL
        ) else { return }
        db.setCharacterGroupCover(groupName: group.groupName, publisher: group.publisher, imagePath: path)
        reload()
    }

    func clearCharacterGroupCover(group: DatabaseManager.CharacterGroup) {
        db.clearCharacterGroupCover(groupName: group.groupName, publisher: group.publisher)
        ThumbnailCache.shared.evictGroupAccentColor(key: "chargroup_\(group.publisher)_\(group.groupName)")
        reload()
    }

    func setCharacterGroupCover(group: DatabaseManager.CharacterGroup, usingCoverOf comic: Comic) {
        let key = "chargroup_\(group.publisher)_\(group.groupName)"
        let safe = key.components(separatedBy: .init(charactersIn: "/:")).joined(separator: "_")
        Task.detached(priority: .userInitiated) { [db] in
            guard let path = ThumbnailCache.shared.saveCoverFromComic(comic, destinationName: safe) else { return }
            db.setCharacterGroupCover(groupName: group.groupName, publisher: group.publisher, imagePath: path)
            ThumbnailCache.shared.evictGroupAccentColor(key: key)
            await MainActor.run { LibraryViewModel.shared.reload() }
        }
    }

    func setSeriesCoverById(series: String, publisher: String, comicId: Int64) {
        db.setSeriesCover(series: series, publisher: publisher, comicId: comicId)
        ThumbnailCache.shared.evict(comicId)
        ThumbnailCache.shared.evictGroupAccentColor(key: "series_\(publisher)_\(series)")
        reload()
    }
    func clearSeriesCoverByName(series: String, publisher: String) {
        db.clearSeriesCover(series: series, publisher: publisher)
        ThumbnailCache.shared.evictGroupAccentColor(key: "series_\(publisher)_\(series)")
        reload()
    }
    func renameSeries(oldName: String, publisher: String?, newName: String) {
        db.renameSeries(oldName: oldName, publisher: publisher, newName: newName)
        reload()
        refreshDuplicates()
    }
    func seriesNameCollides(oldName: String, publisher: String?, newName: String) -> Bool {
        db.seriesNameCollides(oldName: oldName, publisher: publisher, newName: newName)
    }

    func reorderComics(orderedIds: [Int64]) {
        db.reorderComics(orderedIds: orderedIds)
        if sortOrder != .manual { sortOrder = .manual }
    }

    func setSeriesCoverImage(series: String, publisher: String, imageURL: URL) {
        guard let path = ThumbnailCache.shared.saveCustomSeriesCover(series: series, publisher: publisher, imageURL: imageURL) else { return }
        db.setSeriesCoverImage(series: series, publisher: publisher, imagePath: path)
        reload()
    }

    func setSeriesCover(series: String, publisher: String, usingCoverOf comic: Comic) {
        db.setSeriesCover(series: series, publisher: publisher, comicId: comic.id)
        ThumbnailCache.shared.evictGroupAccentColor(key: "series_\(publisher)_\(series)")
        reload()
    }
    func clearSeriesCover(_ series: String, publisher: String) {
        db.clearSeriesCover(series: series, publisher: publisher)
        ThumbnailCache.shared.evictGroupAccentColor(key: "series_\(publisher)_\(series)")
        reload()
    }
}
