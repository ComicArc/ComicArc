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

struct Tag: Identifiable, Hashable {
    let id: Int64
    let name: String
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
