import SwiftUI

struct ImportWizardView: View {
    // @State (seeded from the initializer) instead of `let` so the sheet's own sections/counts
    // can be refreshed after a "Fix Automatically" action -- otherwise the button just flashes
    // "Fixing..." and reverts with no way to tell whether anything actually changed.
    @State private var report: LibraryHealthReport
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showRenameFiles = false

    init(report: LibraryHealthReport) {
        _report = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library Check")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text("A few things worth a look after this scan")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.goldButton()
            }
            .padding(24)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if report.duplicateGroupCount > 0 {
                        section(
                            title: "Possible duplicate issues",
                            icon: "doc.on.doc.fill",
                            detail: "\(report.duplicateGroupCount) group(s) of comics with the same file name or cover."
                        ) {
                            Button("Review Duplicates") {
                                vm.destination = .duplicates
                                dismiss()
                            }.buttonStyle(.bordered)
                        }
                    }
                    if !report.multipleFirstIssues.isEmpty {
                        seriesListSection(
                            title: "More than one issue #1 in a series",
                            icon: "1.circle.fill",
                            detail: "Could be a relaunch, a reprint, or a numbering mix-up — take a quick look and decide which is which.",
                            items: report.multipleFirstIssues
                        )
                    }
                    if !report.numberingGaps.isEmpty {
                        seriesListSection(
                            title: "Missing issues",
                            icon: "questionmark.circle.fill",
                            detail: "These series have a gap in their numbering — could be an issue you don't own, or one that hasn't been imported yet.",
                            items: report.numberingGaps
                        )
                    }
                    if !report.multipleVolumes.isEmpty {
                        seriesListSection(
                            title: "Multiple volumes under one series name",
                            icon: "square.stack.fill",
                            detail: "These series have more than one distinct volume filed together.",
                            items: report.multipleVolumes
                        )
                    }
                    if !report.numberingMismatches.isEmpty {
                        seriesListSection(
                            title: "Possible numbering mismatches",
                            icon: "number",
                            detail: "Issue numbers that are the same value but written differently (like #1 and #01) — could be a real duplicate, or just inconsistent naming.",
                            items: report.numberingMismatches
                        )
                    }
                    if report.missingComicInfoCount > 0 {
                        section(
                            title: "Missing ComicInfo.xml",
                            icon: "doc.questionmark",
                            detail: "\(report.missingComicInfoCount) comic(s) scanned with no ComicInfo.xml metadata found. ComicArc still works from the filename and folder structure, but embedded metadata (writer, cover date, story arc) won't be available."
                        ) { EmptyView() }
                    }
                    if report.corruptArchiveCount > 0 {
                        section(
                            title: "Corrupt or unreadable archives",
                            icon: "exclamationmark.triangle.fill",
                            detail: "\(report.corruptArchiveCount) comic(s) have no readable pages. Resyncing gives them a fresh attempt in case the earlier failure was temporary."
                        ) {
                            Button("Resync Library") { vm.resyncLibrary() }
                                .buttonStyle(.bordered)
                        }
                    }
                    if report.isEmpty {
                        Text("Nothing to report — your library looks good.").foregroundStyle(.secondary).padding(24)
                    }

                    section(
                        title: "Messy filenames?",
                        icon: "textformat",
                        detail: "Automatically rename files to match your library's naming convention. Nothing outside ComicArc changes except the filename."
                    ) {
                        Button("Rename Files…") { showRenameFiles = true }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(Design.appBackground)
        .sheet(isPresented: $showRenameFiles) { RenameFilesView().environmentObject(vm) }
    }

    @ViewBuilder
    private func section<Action: View>(title: String, icon: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            action()
        }
        .padding(16)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func seriesListSection(title: String, icon: String, detail: String, items: [LibraryHealthReport.SeriesIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            ForEach(items.prefix(8)) { item in
                HStack {
                    Text("\(item.series)").font(.caption.weight(.semibold))
                    Text("· \(item.count) issue(s)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Review") {
                        vm.destination = .publisher(item.publisher)
                        vm.selectedSeries = item.series
                        vm.showSeriesManager = true
                        dismiss()
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel("Review \(item.series), \(item.count) issue\(item.count == 1 ? "" : "s")")
                }
            }
            if items.count > 8 {
                Text("+ \(items.count - 8) more").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }


}
