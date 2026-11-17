import Foundation

struct Comic: Identifiable, Equatable, Hashable {
    let id: Int64
    var title: String
    var filePath: String
    var publisher: String
    var character: String?
    var series: String
    var issueNumber: String?
    var pageCount: Int
    var writer: String?
    var penciller: String?
    var year: Int?
    var volume: String?
    var format: String?
    var storyArc: String?
    var languageIso: String?
    var notes: String?
    var addedAt: String
    var position: Int
    var fileHash: String?

    var progress: Int = 0
    var isFavorite: Bool = false
    var inReadingList: Bool = false

    /// Why the comic is soft-deleted: "user" or "missing" (nil is treated as "user").
    var deletedReason: String? = nil
    var finishedAt: String? = nil
    /// The folder between the Character and Series folders, e.g. "Classic".
    var folderGroup: String? = nil

    var fileExtension: String { URL(fileURLWithPath: filePath).pathExtension.lowercased() }
    var isStarted: Bool { progress > 0 }
    /// Driven by the sticky `finished_at`, not the page position.
    var isFinished: Bool { finishedAt != nil }
    var progressPercent: Double { pageCount > 0 ? Double(progress) / Double(pageCount) : 0 }

    static func == (lhs: Comic, rhs: Comic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Run: Identifiable, Equatable, Hashable {
    let id: Int64
    var title: String
    var description: String
    var buyLink: String?
    var comicCount: Int = 0
    var readCount:  Int = 0
    var coverImagePath: String? = nil

    // Id-only equality, so an edited path still matches its selection.
    static func == (lhs: Run, rhs: Run) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RunItem: Identifiable {
    let id: Int64
    var comic: Comic
    var position: Int
    var notes: String

    var isFinished: Bool { comic.isFinished }
}

enum TagCategory: String, CaseIterable {
    case genre = "Genre", format = "Format", mood = "Mood", custom = "Custom"
}

struct Tag: Identifiable, Hashable {
    let id: Int64
    let name: String
    var category: String? = nil
}

struct PublisherStat { let publisher: String; let count: Int }
struct SeriesStat     { let series: String; let publisher: String; let count: Int }
struct GrowthPoint: Identifiable { let id = UUID(); let label: String; let count: Int }

struct Bookmark: Identifiable {
    let id: Int64
    let comicId: Int64
    let page: Int
    let label: String
    var isFavorite: Bool = false
}

/// A bookmark flagged as a favorite moment, shown in Highlights.
struct FavoriteMoment: Identifiable {
    let bookmark: Bookmark
    let comic: Comic
    var id: Int64 { bookmark.id }
}

struct HistoryEntry: Identifiable {
    let id: Int64
    let comicId: Int64
    let title: String
    let publisher: String
    let series: String
    let pageStart: Int
    let pageEnd: Int
    let readAt: String
    var pagesRead: Int { max(0, pageEnd - pageStart) }
}

struct LibraryStats {
    let totalComics: Int
    let pagesRead: Int
    let favorites: Int
    let inProgress: Int
    let finished: Int
    let unread: Int
    let runsCount: Int
    let readingStreak: Int
    let activityMap: [String: Int]
    let publisherBreakdown: [PublisherStat]
    let topSeries: [SeriesStat]
    let recentlyRead: [Comic]
    let collectionGrowth: [GrowthPoint]
}

/// An imported comic's series/publisher/issue number disagreeing with its ComicInfo.xml, held for
/// review.
struct MetadataConflict: Identifiable, Equatable {
    let id: Int64
    let field: String            // "series" | "publisher" | "issue_number"
    let currentValue: String?
    let proposedValue: String?
    let proposedSource: String   // e.g. "ComicInfo.xml"
}

struct MetadataConflictRow: Identifiable, Equatable {
    let conflict: MetadataConflict
    let comic: Comic
    var id: Int64 { conflict.id }
}
