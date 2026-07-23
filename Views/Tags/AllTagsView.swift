import SwiftUI

struct AllTagsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var allTags: [(tag: Tag, count: Int)] = []
    @State private var isLoading = true

    private var grouped: [(category: String, tags: [(tag: Tag, count: Int)])] {
        let byCategory = Dictionary(grouping: allTags) { $0.tag.category ?? TagCategory.custom.rawValue }
        let order = TagCategory.allCases.map(\.rawValue)
        return order.compactMap { cat in
            guard let tags = byCategory[cat], !tags.isEmpty else { return nil }
            return (category: cat, tags: tags.sorted { $0.tag.name < $1.tag.name })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("All Tags").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allTags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tag").font(.system(size: 40)).foregroundStyle(.quaternary)
                    Text("No tags yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.category) { group in
                        Section(group.category) {
                            ForEach(group.tags, id: \.tag.id) { entry in
                                Button {
                                    vm.select(.tag(entry.tag.name))
                                    dismiss()
                                } label: {
                                    HStack {
                                        TagChip(name: entry.tag.name, category: entry.tag.category)
                                        Spacer()
                                        Text("\(entry.count)").foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 520)
        .task {
            let t = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.allTags()
            }.value
            allTags = t; isLoading = false
        }
    }
}
