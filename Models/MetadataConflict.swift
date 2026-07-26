import Foundation

/// A detected disagreement between an already-imported comic's current series/publisher/
/// issue_number and what a corrected metadata-priority resolution would now produce. Surfaced for
/// manual review rather than silently applied in either direction.
struct MetadataConflict: Identifiable, Equatable {
    let id: Int64
    let comicId: Int64
    let field: String            // "series" | "publisher" | "issue_number"
    let currentValue: String?
    let proposedValue: String?
    let proposedSource: String   // e.g. "ComicInfo.xml"
    let detectedAt: String
    let status: String           // "pending" | "applied" | "dismissed"
}

/// A conflict paired with the comic it's about -- what the review UI actually displays.
struct MetadataConflictRow: Identifiable, Equatable {
    let conflict: MetadataConflict
    let comic: Comic
    var id: Int64 { conflict.id }
}
