import SwiftUI

struct AllTagsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renamingTag: Tag?
    @State private var renameText = ""
    @State private var pendingDeleteTag: Tag?

    // Reads vm.allTags directly instead of maintaining a separate local copy -- vm already
    // fetches and republishes this exact same (tag, count) list on every reload(), which
    // renameTag/deleteTagGlobally/setTagCategory already trigger, so this view updates live
    // with no extra fetch of its own to keep in sync.
    private var grouped: [(category: String, tags: [(tag: Tag, count: Int)])] {
        let byCategory = Dictionary(grouping: vm.allTags) { $0.tag.category ?? TagCategory.custom.rawValue }
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

            if vm.allTags.isEmpty {
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
                                .accessibilityElement(children: .combine)
                                .accessibilityHint("Double-tap to browse comics tagged \(entry.tag.name)")
                                .contextMenu {
                                    Button("Rename…") {
                                        renameText = entry.tag.name
                                        renamingTag = entry.tag
                                    }
                                    Menu("Change Category") {
                                        ForEach(TagCategory.allCases, id: \.self) { cat in
                                            Button(cat.rawValue) {
                                                vm.setTagCategory(id: entry.tag.id, category: cat)
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Delete Tag", role: .destructive) {
                                        pendingDeleteTag = entry.tag
                                    }
                                }
                                .accessibilityAction(named: "Rename Tag") {
                                    renameText = entry.tag.name
                                    renamingTag = entry.tag
                                }
                                .accessibilityAction(named: "Delete Tag") {
                                    pendingDeleteTag = entry.tag
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 520)
        .alert("Rename Tag", isPresented: Binding(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            TextField("Tag name", text: $renameText)
            Button("Save") {
                if let tag = renamingTag { vm.renameTag(id: tag.id, newName: renameText) }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) { renamingTag = nil }
        } message: {
            Text("Renaming to a name that already exists merges the two tags into one.")
        }
        .confirmationDialog(
            "Delete tag \"\(pendingDeleteTag?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDeleteTag != nil }, set: { if !$0 { pendingDeleteTag = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let tag = pendingDeleteTag { vm.deleteTagGlobally(id: tag.id) }
                pendingDeleteTag = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteTag = nil }
        } message: {
            Text("This removes the tag from every comic that has it. This can't be undone.")
        }
    }
}
