import Foundation
import CoreSpotlight
import os

extension LibraryViewModel {
    // `nonisolated` so it can be used from detached tasks.
    nonisolated private static let spotlightLogger = Logger(subsystem: "com.comicarc", category: "spotlight")

    // Spotlight indexing is additive, so deleted comics must be removed explicitly.
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

    /// Bump when the indexed fields change, so existing libraries are re-indexed once.
    nonisolated static let spotlightIndexVersion = 2
    nonisolated private static let spotlightIndexVersionKey = "spotlightIndexVersion"
    var spotlightIndexIsOutdated: Bool {
        UserDefaults.standard.integer(forKey: Self.spotlightIndexVersionKey) < Self.spotlightIndexVersion
    }

    func indexSpotlight() {
        Task.detached(priority: .background) {
            let all = DatabaseManager.shared.allComics()
            let items: [CSSearchableItem] = all.map { comic in
                let attrs = CSSearchableItemAttributeSet(contentType: .data)
                attrs.title            = comic.title
                attrs.contentDescription = [comic.series, comic.folderGroup, comic.publisher]
                    .compactMap { $0 }.joined(separator: " · ")
                attrs.keywords = [comic.series, comic.publisher, comic.title, comic.character,
                                  comic.folderGroup, comic.issueNumber, comic.year.map(String.init),
                                  comic.storyArc, comic.writer, comic.penciller]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                return CSSearchableItem(
                    uniqueIdentifier: "comicarc-\(comic.id)",
                    domainIdentifier: "com.comicarc.library",
                    attributeSet: attrs
                )
            }
            do {
                try await CSSearchableIndex.default().indexSearchableItems(items)
                UserDefaults.standard.set(Self.spotlightIndexVersion, forKey: Self.spotlightIndexVersionKey)
            } catch {
                Self.spotlightLogger.error("Failed to index \(items.count) item(s) in Spotlight: \(error.localizedDescription)")
            }
        }
    }

    /// Opens the comic behind a tapped Spotlight result (identifier "comicarc-<id>").
    func openComicFromSpotlight(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix("comicarc-"),
              let id = Int64(identifier.dropFirst("comicarc-".count)) else { return }
        openReader(id: id)
    }

}
