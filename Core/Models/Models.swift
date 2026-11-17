import Foundation

struct Comic: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var filePath: String
    var publisher: String
    var character: String?
    var series: String
    var issueNumber: String?
    var pageCount: Int
    var year: Int?
    var writer: String?
    var penciller: String?
    var storyArc: String?
    var notes: String?
    var volume: String?
    var format: String?
    var languageISO: String?
    var folderGroup: String?
    var addedAt: String
    var position: Int
    var fileHash: String?
    var currentPage: Int
    var lastRead: String?
    var finishedAt: String?
    var isFavorite: Bool
    var inReadingList: Bool
    var deletedReason: String?

    var url: URL { URL(fileURLWithPath: filePath) }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isStarted: Bool { currentPage > 0 }
    var isFinished: Bool { finishedAt != nil }
    var isInProgress: Bool { isStarted && !isFinished }
    var progress: Double { pageCount > 1 ? Double(currentPage) / Double(pageCount - 1) : 0 }
    var type: ComicType { ComicClassifier.classify(issueNumber: issueNumber, title: title, format: format) }

    /// "#12" for regular issues; the title for specials and unnumbered books.
    var shortLabel: String {
        if let n = issueNumber, !n.isEmpty, type == .regular { return "#\(n)" }
        return title
    }
}

/// A character (or a series without one) inside a publisher: the first level of browsing.
struct CharacterGroup: Identifiable, Hashable, Sendable {
    var id: String { "\(publisher)/\(name)" }
    let name: String
    let character: String?
    let publisher: String
    let count: Int
    let coverComicID: Int64
    let customCoverPath: String?
    let started: Int
    let finished: Int
}

struct SeriesGroup: Identifiable, Hashable, Sendable {
    var id: String { "\(publisher)/\(series)" }
    let series: String
    let publisher: String
    let groupName: String
    let count: Int
    let coverComicID: Int64
    let customCoverPath: String?
    let started: Int
    let finished: Int
    let folderGroup: String?
}

struct ReadingPath: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var description: String
    var coverImagePath: String?
    var count: Int
    var finished: Int
    var firstComicID: Int64?

    static let readingListTitle = "Reading List"
    var isReadingList: Bool { title == Self.readingListTitle }
}

struct ReadingPathItem: Identifiable, Hashable, Sendable {
    let id: Int64
    var comic: Comic
    var notes: String
}

struct Tag: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var count: Int
}

struct Bookmark: Identifiable, Hashable, Sendable {
    let id: Int64
    let comicID: Int64
    let page: Int
    var label: String
    var isHighlight: Bool
    let createdAt: String
}

struct Highlight: Identifiable, Hashable, Sendable {
    var id: Int64 { bookmark.id }
    let bookmark: Bookmark
    let comic: Comic
}

struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let comic: Comic
    let pageStart: Int
    let pageEnd: Int
    let readAt: Date
}

struct MetadataConflict: Identifiable, Hashable, Sendable {
    let id: Int64
    let comic: Comic
    let field: String
    let currentValue: String?
    let proposedValue: String?
    let source: String
}

struct SeriesReaderPrefs: Sendable, Hashable {
    var fitMode: FitMode
    var rightToLeft: Bool
    var doublePage: Bool
    var scrollMode: Bool
}

enum FitMode: String, CaseIterable, Sendable {
    case fitPage, fitWidth, fitHeight, original
    var label: String {
        switch self {
        case .fitPage: "Fit Page"
        case .fitWidth: "Fit Width"
        case .fitHeight: "Fit Height"
        case .original: "Original Size"
        }
    }
    var icon: String {
        switch self {
        case .fitPage: "arrow.up.left.and.arrow.down.right"
        case .fitWidth: "arrow.left.and.right"
        case .fitHeight: "arrow.up.and.down"
        case .original: "1.magnifyingglass"
        }
    }
}

enum ColorFilter: String, CaseIterable, Sendable {
    case none, night, sepia, grayscale
    var label: String {
        switch self {
        case .none: "Original"
        case .night: "Night"
        case .sepia: "Sepia"
        case .grayscale: "Grayscale"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case issue = "Issue Order", title = "Title", recentlyAdded = "Recently Added",
         recentlyRead = "Recently Read", year = "Year", pageCount = "Page Count"
    var id: String { rawValue }
}
