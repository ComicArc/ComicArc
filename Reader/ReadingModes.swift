import Foundation

/// Previously defined identically in both `Views/Reader/ReaderView.swift` (Mac) and
/// `iPad/iPadReaderView.swift` -- one shared definition now that both platforms read it from
/// `ReaderSession`.
enum FitMode: String, CaseIterable {
    case fitPage    = "fitPage"
    case fitWidth   = "fitWidth"
    case fitHeight  = "fitHeight"
    case original   = "original"

    var label: String {
        switch self {
        case .fitPage:   return "Fit Page"
        case .fitWidth:  return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .original:  return "Original Size"
        }
    }
    var icon: String {
        switch self {
        case .fitPage:   return "arrow.up.left.and.arrow.down.right"
        case .fitWidth:  return "arrow.left.and.right"
        case .fitHeight: return "arrow.up.and.down"
        case .original:  return "1.circle"
        }
    }
}

enum ColorFilter: String, CaseIterable {
    case none, night, sepia, grayscale
    var label: String {
        switch self {
        case .none:      return "Normal"
        case .night:     return "Night"
        case .sepia:     return "Sepia"
        case .grayscale: return "Grayscale"
        }
    }
    var icon: String {
        switch self {
        case .none:      return "circle.lefthalf.filled"
        case .night:     return "moon.fill"
        case .sepia:     return "photo.artframe"
        case .grayscale: return "circle.fill"
        }
    }
}
