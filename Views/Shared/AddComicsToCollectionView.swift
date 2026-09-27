import SwiftUI

/// The comic picker sheet for adding comics to a Reading Path. The caller supplies which comics
/// are already in it (`alreadyInCollection`) and what adding does (`onAdd`).
struct AddComicsToCollectionView: View {
    let title: String
    let alreadyInCollection: () -> Set<Int64>
    let onAdd: ([Int64]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allComics: [(comic: Comic, searchKey: String)] = []
    @State private var existingIds: Set<Int64> = []
    @State private var selected = Set<Int64>()
    @State private var search = ""

    private var filtered: [Comic] {
        let candidates = allComics.filter { !existingIds.contains($0.comic.id) }
        guard !search.isEmpty else { return candidates.map(\.comic) }
        let q = search.lowercased()
        return candidates.filter { $0.searchKey.contains(q) }.map(\.comic)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to \"\(title)\"").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selected.isEmpty ? "" : "(\(selected.count))")") {
                    // Order by the picker's own list order, not Set iteration order (which is
                    // unspecified) -- otherwise multi-selecting several comics lands them in the
                    // collection in an arbitrary order unrelated to anything the user saw or chose.
                    let orderedIds = allComics.map(\.comic.id).filter { selected.contains($0) }
                    onAdd(orderedIds)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding()

            Divider()

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal).padding(.vertical, 8)

            List(filtered, selection: $selected) { comic in
                HStack(spacing: 10) {
                    PublisherBadge(publisher: comic.publisher)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comic.title).font(.body)
                        Text(comic.series).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(comic.id)
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 520)
        .task {
            // `alreadyInCollection()` reads state the caller already has in memory (cheap,
            // main-actor-isolated) -- only the full-library fetch needs to be off-main. Calling
            // the closure from inside `Task.detached` was the actual cause of the "main
            // actor-isolated property accessed from outside the actor" warning, since
            // `alreadyInCollection` itself is bound to this main-actor-isolated view.
            let existing = alreadyInCollection()
            let comics = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.allComics()
            }.value
            allComics   = comics.map { (comic: $0, searchKey: "\($0.title) \($0.series)".lowercased()) }
            existingIds = existing
        }
    }
}
