import SwiftUI

struct SeriesManagerView: View {
    let series:    String
    let publisher: String?

    @Environment(\.dismiss)      private var dismiss
    @Environment(\.fileService)  private var fileService
    @EnvironmentObject var vm: LibraryViewModel

    @State private var newName:        String
    @State private var issues:         [Comic]  = []
    @State private var coverComicId:   Int64?   = nil
    @State private var selectedIssueId: Int64?  = nil

    init(series: String, publisher: String?) {
        self.series    = series
        self.publisher = publisher
        _newName       = State(initialValue: series)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Series")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(series)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .goldButton()
            }
            .padding(24)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Rename section
                    renameSection

                    sectionDivider

                    // Issues list with reorder + per-issue actions
                    issuesSection
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 700)
        .background(Design.appBackground)
        .task { await loadIssues() }
        .onChange(of: coverComicId) { _, _ in vm.reload() }
    }

    // MARK: - Rename

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Series Name")

            HStack(spacing: 10) {
                TextField("Series name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .colorScheme(.dark)

                Button("Rename") {
                    renameSeries()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                          newName.trimmingCharacters(in: .whitespaces) == series)
                .tint(Design.brandGold)
            }

            Text("Renaming updates all \(issues.count) issues in this series.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
    }

    // MARK: - Issues list

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Issue Order")
                Spacer()
                if coverComicId != nil {
                    Button("Reset Cover") {
                        vm.clearSeriesCoverByName(series: series, publisher: publisher ?? "")
                        coverComicId = nil
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.red.opacity(0.8))
                }
                Text("\(issues.count) issues · drag or use ⌘↑/⌘↓ to reorder")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            List(selection: $selectedIssueId) {
                ForEach(issues) { issue in
                    issueRow(issue)
                        .listRowBackground(Design.surfaceBg)
                        .listRowSeparatorTint(Design.borderColor)
                        .tag(issue.id)
                }
                .onMove { from, to in
                    issues.move(fromOffsets: from, toOffset: to)
                    saveOrder()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 300)
            .onKeyPress(.upArrow, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                moveSelectedIssue(by: -1); return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                moveSelectedIssue(by: 1); return .handled
            }
        }
        .padding(24)
    }

    private func issueRow(_ issue: Comic) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 14))

            IssueThumbnail(comic: issue)
                .frame(width: 36, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let n = issue.issueNumber {
                        Text("Issue #\(n)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let y = issue.year {
                        Text("·").foregroundStyle(.tertiary).font(.caption)
                        Text("\(y)").font(.caption).foregroundStyle(.tertiary)
                    }
                    if issue.isFinished {
                        Text("·").foregroundStyle(.tertiary).font(.caption)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                // Position controls
                Button {
                    moveIssueToTop(issue)
                } label: {
                    Image(systemName: "arrow.up.to.line")
                }
                .buttonStyle(.borderless).controlSize(.mini)
                .help("Move to top")
                .accessibilityLabel("Move \(issue.title) to top")
                .disabled(issues.first?.id == issue.id)

                Button {
                    moveIssueToBottom(issue)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(.borderless).controlSize(.mini)
                .help("Move to bottom")
                .accessibilityLabel("Move \(issue.title) to bottom")
                .disabled(issues.last?.id == issue.id)

                Divider().frame(height: 14)

                // Cover controls
                if coverComicId == issue.id {
                    Label("Cover", systemImage: "star.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(Design.brandGold)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Design.brandGold.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Button("Set Cover") {
                        vm.setSeriesCoverById(series: series, publisher: publisher ?? "", comicId: issue.id)
                        coverComicId = issue.id
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }

                Button("Custom…") { changeCover(for: issue) }
                    .buttonStyle(.bordered).controlSize(.mini).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.secondary)
            .kerning(1.2)
            .textCase(.uppercase)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Design.borderColor).frame(height: 1)
    }

    // MARK: - Actions

    private func loadIssues() async {
        let ser = series; let pub = publisher ?? ""
        let (sorted, cover) = await Task.detached(priority: .userInitiated) {
            let all = DatabaseManager.shared.allComics(publisher: pub.isEmpty ? nil : pub, series: ser)
                .sorted { $0.position < $1.position }
            let cover = DatabaseManager.shared.currentSeriesCover(series: ser, publisher: pub)
            return (all, cover)
        }.value
        issues = sorted; coverComicId = cover
    }

    private func renameSeries() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != series else { return }
        vm.renameSeries(oldName: series, publisher: publisher, newName: trimmed)
        dismiss()
    }

    private func saveOrder() {
        let ids = issues.map(\.id)
        vm.reorderComics(orderedIds: ids)
        vm.reload()
    }

    private func moveIssueToTop(_ issue: Comic) {
        guard let idx = issues.firstIndex(where: { $0.id == issue.id }), idx > 0 else { return }
        issues.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
        saveOrder()
    }

    private func moveIssueToBottom(_ issue: Comic) {
        guard let idx = issues.firstIndex(where: { $0.id == issue.id }),
              idx < issues.count - 1 else { return }
        issues.move(fromOffsets: IndexSet(integer: idx), toOffset: issues.count)
        saveOrder()
    }

    private func moveSelectedIssue(by delta: Int) {
        guard let id = selectedIssueId,
              let idx = issues.firstIndex(where: { $0.id == id }) else { return }
        let newIdx = max(0, min(issues.count - 1, idx + delta))
        guard newIdx != idx else { return }
        issues.move(fromOffsets: IndexSet(integer: idx),
                    toOffset: delta > 0 ? newIdx + 1 : newIdx)
        saveOrder()
    }

    private func changeCover(for issue: Comic) {
        fileService.pickFiles(
            allowsMultiple: false,
            message: "Choose a cover image for \(issue.title)",
            prompt: "Set Cover"
        ) { urls in
            guard let url = urls.first else { return }
            ThumbnailCache.shared.setCustomCover(comicId: issue.id, imageURL: url)
        }
    }
}

// MARK: - Small thumbnail for the issues list

private struct IssueThumbnail: View {
    let comic: Comic
    @State private var img: PlatformImage?

    var body: some View {
        Group {
            if let img {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Design.cardBg)
                    .overlay(Image(systemName: "book.closed").font(.caption).foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task { ThumbnailCache.shared.thumbnail(for: comic) { img = $0 } }
    }
}
