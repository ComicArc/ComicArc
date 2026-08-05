import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showMergeConfirm = false
    @State private var showOnlyFlagged  = false
    @State private var showSeriesLinkPicker = false
    @State private var pagePickerIssue: Comic? = nil
    @State private var exportErrorMessage: String? = nil
    // Bumped whenever a custom cover is set for a row -- IssueThumbnail's `.task` only runs once
    // per view identity, so merely refetching `issues` (same comic ids, same ForEach identity)
    // would never make an already-appeared row re-query ThumbnailCache and pick up the new image.
    @State private var thumbnailRefreshToken = 0

    private var flaggedCount: Int { issues.filter { ($0.readingOrderConfidence ?? 100) < 85 }.count }
    private var visibleIssues: [Comic] {
        showOnlyFlagged ? issues.filter { ($0.readingOrderConfidence ?? 100) < 85 } : issues
    }

    init(series: String, publisher: String?) {
        self.series    = series
        self.publisher = publisher
        _newName       = State(initialValue: series)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Series")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text(series)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Link as Continuation of Another Series…") { showSeriesLinkPicker = true }
                    Button("Export Series as CSV…") {
                        BackupService.exportCSV(
                            comics: issues, fileService: fileService, filename: "\(series).csv"
                        ) { exportErrorMessage = $0 }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).frame(width: 28)
                .help("Advanced: chain this series to another series' numbering (e.g. a relaunch)")
                Button("Done") { dismiss() }
                    .goldButton()
            }
            .padding(24)
            .background(Design.navBackground)
            .sheet(isPresented: $showSeriesLinkPicker) {
                SeriesLinkPickerView(childSeries: series, childPublisher: publisher ?? "Unknown")
                    .environmentObject(vm)
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "")
            }

            Rectangle().fill(Design.borderColor).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    renameSection

                    sectionDivider

                    issuesSection
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 700)
        .background(Design.appBackground)
        .task { await loadIssues() }
        .onChange(of: coverComicId) { _, _ in vm.reload() }
        .sheet(item: $pagePickerIssue) { issue in
            ComicPageCoverPicker(comic: issue) { image in
                ThumbnailCache.shared.setCustomCover(comicId: issue.id, image: image)
                thumbnailRefreshToken += 1
                Task { await loadIssues() }
            }
        }
    }

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
                .confirmationDialog(
                    "A series named “\(newName.trimmingCharacters(in: .whitespaces))” already exists.",
                    isPresented: $showMergeConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Merge Series", role: .destructive) { performRename() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Renaming will combine all issues from both series into one. This can't be undone automatically.")
                }
            }

            Text("Renaming updates all \(issues.count) issues in this series.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
    }

    private var issuesSection: some View {
        // Hoisted so each filter over `issues` runs once per render instead of once per
        // reference below -- both are computed properties re-derived on every access.
        let flagged = flaggedCount
        let visible = visibleIssues
        return VStack(alignment: .leading, spacing: 14) {
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
                Text("\(visible.count) issues · drag, ⌘↑/⌘↓, or use Move Near… to reorder")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if flagged > 0 {
                Toggle(isOn: $showOnlyFlagged) {
                    Label("Show only possibly misplaced (\(flagged))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .toggleStyle(.switch).controlSize(.mini)
            }

            List(selection: $selectedIssueId) {
                ForEach(visible) { issue in
                    issueRow(issue)
                        .listRowBackground(Design.surfaceBg)
                        .listRowSeparatorTint(Design.borderColor)
                        .tag(issue.id)
                }
                .onMove { from, to in
                    guard !showOnlyFlagged else { return }
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
                .id("\(issue.id)-\(thumbnailRefreshToken)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(issue.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let confidence = issue.readingOrderConfidence, confidence < 85 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .help(issue.readingOrderReason ?? "Position estimated with low confidence — worth checking")
                    }
                }
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
                Menu {
                    ForEach(issues.filter { $0.id != issue.id }) { target in
                        Button(target.title) { moveIssue(issue, afterId: target.id) }
                    }
                } label: {
                    Image(systemName: "arrow.right.to.line")
                }
                .menuStyle(.borderlessButton).controlSize(.mini)
                .frame(width: 22)
                .help("Move next to another issue")
                .accessibilityLabel("Move \(issue.title) near another issue")

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

                Menu("Custom…") {
                    Button("Choose a Page From This Issue…") { pagePickerIssue = issue }
                    Button("Choose Image File…") { changeCover(for: issue) }
                }
                .menuStyle(.borderlessButton).controlSize(.mini).fixedSize()
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

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
        if vm.seriesNameCollides(oldName: series, publisher: publisher, newName: trimmed) {
            showMergeConfirm = true
            return
        }
        performRename()
    }

    private func performRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        vm.renameSeries(oldName: series, publisher: publisher, newName: trimmed)
        dismiss()
    }

    private func saveOrder() {
        let ids = issues.map(\.id)
        vm.reorderComics(orderedIds: ids)
        vm.reload()
    }

    private func moveIssue(_ issue: Comic, afterId targetId: Int64) {
        guard let fromIdx = issues.firstIndex(where: { $0.id == issue.id }),
              let targetIdx = issues.firstIndex(where: { $0.id == targetId }) else { return }
        issues.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: targetIdx + 1)
        saveOrder()
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
            prompt: "Set Cover",
            contentTypes: [.image]
        ) { urls in
            guard let url = urls.first else { return }
            ThumbnailCache.shared.setCustomCover(comicId: issue.id, imageURL: url)
            thumbnailRefreshToken += 1
        }
    }
}

private struct IssueThumbnail: View {
    let comic: Comic
    @State private var img: PlatformImage?

    var body: some View {
        Group {
            if let img {
                Image(platformImage: img).comicCoverStyle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
