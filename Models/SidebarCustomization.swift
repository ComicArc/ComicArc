import Foundation

// MARK: - Sidebar customization (Discover section: Reading Orders / Stats / History / Duplicates)
//
// Publishers and Tags are dynamic, per-library data — reordering those manually wouldn't mean
// much since their membership changes as the library changes. The "Discover" section, though,
// is a fixed small set of destinations, exactly the kind of thing worth letting a user hide or
// reorder to match how they actually use the app (matches Finder's toolbar customization, just
// for the sidebar).
//
// Stored as comma-joined raw-value strings (not an array/set) specifically so both the sidebar
// (main window) and the customization UI (Settings window — a separate SwiftUI scene on macOS)
// can back onto the same values via plain @AppStorage(String) and stay in sync automatically;
// @AppStorage has no built-in support for [String]/Set<String>.
enum DiscoverItem: String, CaseIterable, Identifiable, Codable {
    case runs, stats, history, duplicates, orderHealth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs:        return "Reading Orders"
        case .stats:       return "Statistics"
        case .history:     return "History"
        case .duplicates:  return "Possible Duplicates"
        case .orderHealth: return "Order Health"
        }
    }

    var icon: String {
        switch self {
        case .runs:        return "list.bullet.rectangle.portrait.fill"
        case .stats:       return "chart.bar.xaxis"
        case .history:     return "clock.fill"
        case .duplicates:  return "doc.on.doc"
        case .orderHealth: return "list.number"
        }
    }

    var destination: AppDestination {
        switch self {
        case .runs:        return .runs
        case .stats:       return .stats
        case .history:     return .history
        case .duplicates:  return .duplicates
        case .orderHealth: return .readingOrderManager
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
