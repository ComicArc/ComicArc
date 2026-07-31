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
    var deletedAt: String?
    var position: Int
    var fileHash: String?

    var progress: Int = 0
    var lastRead: String?
    var rating: Int = 0
    var review: String? = nil
    var isFavorite: Bool = false
    var inReadingList: Bool = false

    var readingOrderPosition: Int? = nil
    var readingOrderConfidence: Int? = nil
    var readingOrderReason: String? = nil
    var gcdMatchConfidence: Int? = nil
    var gcdSeriesName: String? = nil
    var gcdIssueNumber: String? = nil
    /// Why this comic is soft-deleted -- "user" (explicitly deleted) or "missing" (its file
    /// vanished from disk during a scan). Nil for pre-existing soft-deletes, treated as "user".
    /// Only meaningful when `deletedAt` is set; irrelevant otherwise.
    var deletedReason: String? = nil

    var fileExtension: String { URL(fileURLWithPath: filePath).pathExtension.lowercased() }
    var isStarted: Bool { progress > 0 }
    var isFinished: Bool { pageCount > 1 && progress >= pageCount - 1 }
    var progressPercent: Double { pageCount > 0 ? Double(progress) / Double(pageCount) : 0 }

    static func == (lhs: Comic, rhs: Comic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Run: Identifiable, Equatable, Hashable {
    let id: Int64
    var title: String
    var description: String
    var rating: Int?
    var review: String?
    var buyLink: String?
    var createdAt: String
    var comicCount: Int = 0
    var readCount:  Int = 0
    var coverImagePath: String? = nil

    // Explicit id-only equality (matching Comic's override above): editing a Run's title/rating
    // elsewhere and then reloading the sidebar's `runs` array must still recognize the edited
    // row as "the same Run" for staleness checks like `if !runs.contains(selectedRun)` --
    // synthesized field-wise Equatable would call the freshly-edited row "different" from the
    // stale selection and silently clear the selection even though the Run still exists.
    static func == (lhs: Run, rhs: Run) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RunItem: Identifiable {
    let id: Int64
    var comic: Comic
    var position: Int
    var notes: String

    var isFinished: Bool { comic.isFinished }
    var isStarted: Bool { comic.isStarted }
}

/// The fixed set of tier buckets a Tier List sorts comics into, in display order (best first).
/// Fixed rather than user-customizable to keep the feature to the classic tier-list shape --
/// still a real ranking tool without needing a whole tier-management UI.
enum ComicTier: String, CaseIterable, Identifiable {
    case s = "S", a = "A", b = "B", c = "C", d = "D", f = "F"
    var id: String { rawValue }
}

struct TierList: Identifiable, Equatable, Hashable {
    let id: Int64
    var title: String
    var description: String
    var createdAt: String
    var comicCount: Int = 0
    var rating: Int? = nil
    var review: String? = nil
    var coverImagePath: String? = nil

    // Explicit id-only equality -- see Run for why.
    static func == (lhs: TierList, rhs: TierList) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TierListItem: Identifiable {
    let id: Int64
    var comic: Comic
    var tier: String
    var position: Int
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
struct GrowthPoint: Identifiable { let id = UUID(); let month: String; let label: String; let count: Int }

struct Bookmark: Identifiable {
    let id: Int64
    let comicId: Int64
    let page: Int
    let label: String
    let createdAt: String
    var isFavorite: Bool = false
}

/// A bookmark flagged as a "favorite moment" -- worth revisiting on its own, browsable across the
/// whole library rather than only from within that one comic's own bookmark list.
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

struct DiaryEntry: Identifiable {
    let id: Int64  // diary_entries row id -- NOT comic.id, since a reread produces a second row for the same comic
    let comic: Comic
    let rating: Int
    let review: String?
    let loggedAt: String
    let isReread: Bool
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
