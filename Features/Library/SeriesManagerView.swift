import SwiftUI

/// Rename a series, set its cover, and put its issues in your own order.
struct SeriesManagerView: View {
    let series: SeriesGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [Comic] = []
    @State private var name = ""
    @State private var error: String?
    @State private var orderChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manage Series").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            HStack(spacing: 10) {
                TextField("Series name", text: $name).textFieldStyle(.roundedBorder)
                Button("Rename") { rename() }.disabled(name.trimmed.isEmpty || name.trimmed == series.series)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            HStack {
                Text("Drag issues to set your own reading order. It's kept when the library is rescanned.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Reset to Issue Order") { reset() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.bottom, 8)
            List {
                ForEach(issues) { c in
                    HStack(spacing: 12) {
                        CoverImage(c).frame(width: 32, height: 48).clipShape(RoundedRectangle(cornerRadius: 3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1)
                            Text(c.type == .regular ? (c.issueNumber.map { "#\($0)" } ?? "No number") : c.type.rawValue.capitalized)
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Menu {
                            Button("Use as Series Cover") {
                                model.perform("Series cover updated") { try await $0.setSeriesCover(series: series.series, publisher: series.publisher, comicID: c.id, imagePath: nil) }
                            }
                            Button("Move to Top") { move(c, to: 0) }
                            Button("Move to Bottom") { move(c, to: issues.count) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                .onMove { from, to in
                    issues.move(fromOffsets: from, toOffset: to)
                    save()
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 620)
        .errorAlert("Can't Rename", message: $error)
        .task { await load() }
        .onAppear { name = series.series }
    }

    private func load() async {
        issues = (try? await Database.shared.comics(ComicFilter(publisher: series.publisher, series: series.series))) ?? []
    }

    private func move(_ c: Comic, to index: Int) {
        guard let from = issues.firstIndex(of: c) else { return }
        issues.move(fromOffsets: IndexSet(integer: from), toOffset: index)
        save()
    }

    private func save() {
        let ids = issues.map(\.id)
        model.perform { try await $0.reorderIssues(ids) }
    }

    private func reset() {
        model.perform("Back to issue-number order") { try await $0.resetIssueOrder(series: series.series, publisher: series.publisher) }
        Task { try? await Task.sleep(for: .milliseconds(150)); await load() }
    }

    private func rename() {
        let new = name.trimmed
        Task {
            if (try? await Database.shared.seriesExists(new, publisher: series.publisher)) == true {
                error = "There's already a series called “\(new)”. Choose another name, or use Move to Series to merge issues."
                return
            }
            do {
                try await Database.shared.renameSeries(series.series, to: new, publisher: series.publisher)
                model.libraryDidChange()
                model.path.removeLast()
                dismiss()
                model.showToast("Renamed to “\(new)”")
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TagManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            if model.tags.isEmpty {
                EmptyState(icon: "tag", title: "No tags yet", message: "Add tags from any comic's page.")
            } else {
                List(model.tags) { t in
                    HStack {
                        Text("#\(t.name)")
                        Spacer()
                        Text("\(t.count)").foregroundStyle(Theme.textTertiary)
                        Button("Rename") {
                            NewPathPrompt.ask(title: "Rename Tag", placeholder: "Tag", initial: t.name) { name in
                                model.perform { try await $0.renameTag(t.id, to: name) }
                            }
                        }
                        .controlSize(.small)
                        Button("Delete", role: .destructive) { model.perform("Deleted #\(t.name)") { try await $0.deleteTag(t.id) } }
                            .controlSize(.small)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 440, height: 480)
    }
}
