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

    /// Daily-use Discover items that stay always visible in the sidebar; everything else collapses
    /// into "More" so day one doesn't show 9 equally-weighted rows at once. Shared by Mac's
    /// `SidebarView` and iPad's `iPadSidebar`.
    static let coreDiscoverItems: Set<DiscoverItem> = [.stats]

    static func visibleItems(orderRaw: String, hiddenRaw: String) -> [DiscoverItem] {
        let hidden = decodeHidden(hiddenRaw)
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
