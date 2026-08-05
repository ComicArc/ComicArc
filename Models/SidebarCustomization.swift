import Foundation

enum DiscoverItem: String, CaseIterable, Identifiable, Codable {
    case runs, diary, tierLists, favoriteMoments, stats, history, duplicates, readingOrderManager, metadataConflicts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs:               return "Reading Paths"
        case .diary:               return "Diary"
        case .tierLists:           return "Tier Lists"
        case .favoriteMoments:     return "Highlights"
        case .stats:               return "Statistics"
        case .history:             return "History"
        case .duplicates:          return "Possible Duplicates"
        case .readingOrderManager: return "Reading Order Suggestions"
        case .metadataConflicts:   return "Needs Review"
        }
    }

    var icon: String {
        switch self {
        case .runs:               return "list.bullet.rectangle.portrait.fill"
        case .diary:               return "text.book.closed.fill"
        case .tierLists:           return "square.stack.3d.up.fill"
        case .favoriteMoments:     return "star.circle.fill"
        case .stats:               return "chart.bar.xaxis"
        case .history:             return "clock.fill"
        case .duplicates:          return "doc.on.doc"
        case .readingOrderManager: return "checkmark.seal"
        case .metadataConflicts:   return "exclamationmark.triangle"
        }
    }

    var destination: AppDestination {
        switch self {
        case .runs:               return .runs
        case .diary:               return .diary
        case .tierLists:           return .tierLists
        case .favoriteMoments:     return .favoriteMoments
        case .stats:               return .stats
        case .history:             return .history
        case .duplicates:          return .duplicates
        case .readingOrderManager: return .readingOrderManager
        case .metadataConflicts:   return .metadataConflicts
        }
    }
}

enum SidebarCustomization {
    static let orderKey  = "sidebarDiscoverOrder"
    static let hiddenKey = "sidebarDiscoverHidden"

    static func decodeOrder(_ raw: String) -> [DiscoverItem] {
        let saved = raw.split(separator: ",").compactMap { DiscoverItem(rawValue: String($0)) }
        let missing = DiscoverItem.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    static func decodeHidden(_ raw: String) -> Set<DiscoverItem> {
        Set(raw.split(separator: ",").compactMap { DiscoverItem(rawValue: String($0)) })
    }

    static func encode(_ items: [DiscoverItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }
}
