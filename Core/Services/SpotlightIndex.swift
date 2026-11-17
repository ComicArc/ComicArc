import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import os

/// Makes comics findable from Spotlight; choosing a result opens the comic in the reader.
enum SpotlightIndex {
    static let prefix = "comicarc-"
    /// Bump when the indexed fields change, so existing libraries re-index once.
    static let version = 3
    private static let log = Logger(subsystem: "com.comicarc", category: "spotlight")

    static var isOutdated: Bool { UserDefaults.standard.integer(forKey: Prefs.spotlightVersion) < version }

    static func reindex() async {
        guard let comics = try? await Database.shared.comics(ComicFilter()) else { return }
        let items = comics.map { c -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = c.title
            attrs.contentDescription = [c.series, c.folderGroup, c.publisher].compactMap { $0 }.joined(separator: " · ")
            attrs.keywords = [c.series, c.publisher, c.character, c.folderGroup, c.issueNumber, c.year.map(String.init),
                              c.storyArc, c.writer, c.penciller].compactMap { $0 }.filter { !$0.isEmpty }
            attrs.thumbnailURL = AppPaths.covers.appendingPathComponent("\(c.id).jpg")
            return CSSearchableItem(uniqueIdentifier: "\(prefix)\(c.id)", domainIdentifier: "com.comicarc.library", attributeSet: attrs)
        }
        do {
            try await CSSearchableIndex.default().deleteAllSearchableItems()
            try await CSSearchableIndex.default().indexSearchableItems(items)
            UserDefaults.standard.set(version, forKey: Prefs.spotlightVersion)
        } catch {
            log.error("Spotlight indexing failed: \(error.localizedDescription)")
        }
    }

    static func remove(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map { "\(prefix)\($0)" })
    }

    static func comicID(from activity: NSUserActivity) -> Int64? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, id.hasPrefix(prefix) else { return nil }
        return Int64(id.dropFirst(prefix.count))
    }
}
