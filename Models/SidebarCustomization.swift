import Foundation

enum DiscoverItem: String, CaseIterable, Identifiable, Codable {
    case favoriteMoments, stats, libraryHealth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favoriteMoments:     return "Highlights"
        case .stats:               return "Stats"
        case .libraryHealth:       return "Library Health"
        }
    }

    var icon: String {
        switch self {
        case .favoriteMoments:     return "star.circle.fill"
        case .stats:               return "chart.bar.xaxis"
        case .libraryHealth:       return "stethoscope"
        }
    }

    var destination: AppDestination {
        switch self {
        case .favoriteMoments:     return .favoriteMoments
        case .stats:               return .stats
        case .libraryHealth:       return .libraryHealth
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

    static func visibleItems(orderRaw: String, hiddenRaw: String) -> [DiscoverItem] {
        let hidden = decodeHidden(hiddenRaw)
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
