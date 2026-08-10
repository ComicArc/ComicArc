import Foundation

/// What `Run` and `TierList` genuinely have in common: a named, ordered, coverable, rateable
/// collection of comics. Their *list* screens, cards, and edit sheets were previously two
/// separately-maintained, nearly line-for-line-identical implementations (`RunsView.swift` /
/// `TierListsView.swift`) -- this protocol is what lets `CollectionListView`/`CollectionCard`/
/// `EditCollectionView` be written once. Their *detail* screens stay separate on purpose: a
/// Run's detail is a single ordered list (drag-reorder within one list), a TierList's is items
/// bucketed into six tiers (drag between tiers) -- a genuinely different interaction model, not
/// worth forcing into one generic view.
protocol NamedCollection: Identifiable, Equatable where ID == Int64 {
    var title: String { get }
    var description: String { get }
    var rating: Int? { get }
    var review: String? { get }
    var coverImagePath: String? { get }
}

extension Run: NamedCollection {}
extension TierList: NamedCollection {}
