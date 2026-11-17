import SwiftUI

/// Comic picker for adding comics to a Reading Path.
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
                    // Keep the list's order, not the Set's.
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
            // Only the library fetch runs off the main actor.
            let existing = alreadyInCollection()
            let comics = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.allComics()
            }.value
            allComics   = comics.map { (comic: $0, searchKey: "\($0.title) \($0.series)".lowercased()) }
            existingIds = existing
        }
    }
}

/// The Reading Path edit sheet. A nil `buyLink` hides that field.
struct EditCollectionView: View {
    let noun: String
    @Binding var item: Run
    var buyLink: Binding<String>? = nil
    let onSave: (_ title: String, _ description: String, _ buyLink: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var buyLinkText: String

    init(noun: String, item: Binding<Run>, buyLink: Binding<String>? = nil,
         onSave: @escaping (String, String, String?) -> Void) {
        self.noun = noun
        self._item = item
        self.buyLink = buyLink
        self.onSave = onSave
        _title = State(initialValue: item.wrappedValue.title)
        _description = State(initialValue: item.wrappedValue.description)
        _buyLinkText = State(initialValue: buyLink?.wrappedValue ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit \(noun)").font(.title2.bold()).padding(24)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description)
                    if buyLink != nil {
                        TextField("Buy / Info Link (URL)", text: $buyLinkText).autocorrectionDisabled()
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 400)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let d = description.trimmingCharacters(in: .whitespaces)
        let l = buyLink != nil ? buyLinkText.trimmingCharacters(in: .whitespaces) : nil
        onSave(t, d, l?.isEmpty == true ? nil : l)
        dismiss()
    }
}
