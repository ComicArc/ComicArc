import Foundation
import Combine
import CoreSpotlight
import os

extension LibraryViewModel {
    func refreshOnThisDay() {
        Task.detached(priority: .utility) { [db] in
            let entries = db.onThisDayEntries()
            await MainActor.run { self.onThisDayEntries = entries }
        }
    }

    func refreshRecommendations() {
        Task.detached(priority: .utility) { [db] in
            let recs = Self.computeRecommendations(db: db)
            await MainActor.run { self.recommendations = recs }
        }
    }

    /// Pure, no-network, no-ML recommendation heuristic: weight tags/publisher/writer by how
    /// often they appear among comics rated >= 4, then score every unread comic from a DIFFERENT
    /// series by how much overlap it has with that taste profile. A tag match counts for more
    /// than a shared publisher, since "publisher" is a weak signal on its own (most libraries are
    /// dominated by 1-2 publishers) while a shared tag is a deliberate, user-chosen signal.
    nonisolated static func computeRecommendations(db: DatabaseManager, limit: Int = 12) -> [Comic] {
        let likedComics = db.allComics(minRating: 4)
        guard !likedComics.isEmpty else { return [] }
        let likedIds = Set(likedComics.map(\.id))
        let likedSeriesKeys = Set(likedComics.map { "\($0.publisher)|\($0.series)" })

        let likedTagsByComic = db.tagIdsByComic(likedComics.map(\.id))
        var tagWeights: [Int64: Int] = [:]
        for (_, tagIds) in likedTagsByComic {
            for t in tagIds { tagWeights[t, default: 0] += 1 }
        }

        var publisherWeights: [String: Int] = [:]
        var writerWeights: [String: Int] = [:]
        for c in likedComics {
            publisherWeights[c.publisher, default: 0] += 1
            if let w = c.writer, !w.isEmpty { writerWeights[w, default: 0] += 1 }
        }

        let candidates = db.allComics(unreadOnly: true).filter {
            !likedIds.contains($0.id) && !likedSeriesKeys.contains("\($0.publisher)|\($0.series)")
        }
        guard !candidates.isEmpty else { return [] }
        let candidateTagsByComic = db.tagIdsByComic(candidates.map(\.id))

        let scored: [(comic: Comic, score: Int)] = candidates.compactMap { c in
            var score = 0
            for t in candidateTagsByComic[c.id] ?? [] { score += (tagWeights[t] ?? 0) * 3 }
            score += publisherWeights[c.publisher] ?? 0
            if let w = c.writer, let ww = writerWeights[w] { score += ww * 2 }
            return score > 0 ? (c, score) : nil
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.comic)
    }

}
