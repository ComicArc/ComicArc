import Foundation

/// A user-named snapshot of the library's current sort/filter/search state -- deliberately just a
/// "pin what I'm looking at right now" button, not a query-builder UI. Smart Filters (a fuller
/// query-builder) was tried and reverted earlier in this project's history for being more UI than
/// the feature was worth; this covers the same underlying need (a one-tap way back to a specific
/// view) without that complexity.
struct SavedLibraryView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var publisher: String?
    var tag: String?
    var sortOrder: DatabaseManager.SortOrder
    var unreadOnly: Bool
    var minRatingFilter: Int
    var searchText: String

    init(id: UUID = UUID(), name: String, publisher: String?, tag: String?,
         sortOrder: DatabaseManager.SortOrder, unreadOnly: Bool, minRatingFilter: Int, searchText: String) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.tag = tag
        self.sortOrder = sortOrder
        self.unreadOnly = unreadOnly
        self.minRatingFilter = minRatingFilter
        self.searchText = searchText
    }

    var destination: AppDestination {
        if let tag { return .tag(tag) }
        if let publisher { return .publisher(publisher) }
        return .library
    }

    var icon: String {
        if tag != nil { return "tag" }
        if publisher != nil { return "building.columns" }
        return "line.3.horizontal.decrease.circle"
    }
}

/// Same JSON-in-UserDefaults pattern as `LibraryFolders` -- a small, device-local list that
/// doesn't need to live in the SQLite library database.
enum SavedLibraryViews {
    static let key = "savedLibraryViewsJSON"

    static func read(defaults: UserDefaults = .standard) -> [SavedLibraryView] {
        guard let data = defaults.string(forKey: key)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedLibraryView].self, from: data) else { return [] }
        return decoded
    }

    static func write(_ views: [SavedLibraryView], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(views),
              let string = String(data: data, encoding: .utf8) else { return }
        defaults.set(string, forKey: key)
    }
}
