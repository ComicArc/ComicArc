import Foundation
import CoreSpotlight
import os

extension LibraryViewModel {
    // `nonisolated`: os.Logger is safe to use concurrently, and both call sites below log from
    // inside Task.detached (a nonisolated context) -- without this, the MainActor isolation
    // inferred for the rest of this class would make the logger uncallable from there.
    nonisolated private static let spotlightLogger = Logger(subsystem: "com.comicarc", category: "spotlight")

    // indexSpotlight()'s indexSearchableItems is additive/overwriting only -- it never removes
    // identifiers absent from a later batch. Without this, a deleted comic's title/series/
    // publisher stays permanently discoverable system-wide via Spotlight until the entire
    // library is cleared (the only other place that calls deleteAllSearchableItems).
    func removeFromSpotlight(_ ids: [Int64]) {
        let identifiers = ids.map { "comicarc-\($0)" }
        Task.detached(priority: .background) {
            do {
                try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
            } catch {
                Self.spotlightLogger.error("Failed to remove \(identifiers.count) item(s) from Spotlight: \(error.localizedDescription)")
            }
        }
    }

    func indexSpotlight() {
        Task.detached(priority: .background) {
            let all = DatabaseManager.shared.allComics()
            let items: [CSSearchableItem] = all.map { comic in
                let attrs = CSSearchableItemAttributeSet(contentType: .data)
                attrs.title            = comic.title
                attrs.contentDescription = "\(comic.series) · \(comic.publisher)"
                attrs.keywords         = [comic.series, comic.publisher, comic.title]
                return CSSearchableItem(
                    uniqueIdentifier: "comicarc-\(comic.id)",
                    domainIdentifier: "com.comicarc.library",
                    attributeSet: attrs
                )
            }
            do {
                try await CSSearchableIndex.default().indexSearchableItems(items)
            } catch {
                Self.spotlightLogger.error("Failed to index \(items.count) item(s) in Spotlight: \(error.localizedDescription)")
            }
        }
    }

    /// Handles a Spotlight search result tap. `CSSearchableItemActionType` activities carry the
    /// tapped item's uniqueIdentifier (the same "comicarc-<id>" string indexSpotlight() assigned)
    /// in userInfo -- previously nothing consumed this, so tapping a search result just launched
    /// the app to whatever screen was already open instead of the comic that was searched for.
    func openComicFromSpotlight(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix("comicarc-"),
              let id = Int64(identifier.dropFirst("comicarc-".count)) else { return }
        openReader(id: id)
    }

}
