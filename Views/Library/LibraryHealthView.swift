import SwiftUI

/// The one home for library maintenance: the health report plus tools, possible duplicates, and
/// ComicInfo.xml conflicts that need a decision -- previously a pop-up sheet, two sidebar
/// sections, and several Settings buttons.
struct LibraryHealthView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", duplicates = "Duplicates", needsReview = "Needs Review" }

    @EnvironmentObject var vm: LibraryViewModel
    @State private var tab: Tab = .overview
    @State private var loadedReport: LibraryHealthReport?
    @State private var showRenameFiles = false
    #if os(macOS)
    @State private var showConvertCBR = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SignageLabel(text: "Library Health", size: 20, kerning: 1.5, tint: Design.textPrimary)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in Text(title(for: t)).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            switch tab {
            case .overview:    overview
            case .duplicates:  DuplicatesView()
            case .needsReview: MetadataConflictsView()
            }
        }
        .background(Design.appBackground)
        .task(id: vm.isBusy) {
            guard !vm.isBusy else { return }
            loadedReport = await Task.detached(priority: .userInitiated) { LibraryHealthAnalyzer.analyze() }.value
        }
        .sheet(isPresented: $showRenameFiles) { RenameFilesView().environmentObject(vm) }
        #if os(macOS)
        .sheet(isPresented: $showConvertCBR) { ConvertCBRToCBZView() }
        #endif
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .overview:    return "Overview"
        case .duplicates:  return vm.duplicateGroups.isEmpty ? "Duplicates" : "Duplicates (\(vm.duplicateGroups.count))"
        case .needsReview: return vm.pendingMetadataConflicts.isEmpty ? "Needs Review" : "Needs Review (\(vm.pendingMetadataConflicts.count))"
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let report = loadedReport {
            overview(report)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overview(_ report: LibraryHealthReport) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if report.duplicateGroupCount > 0 {
                        section(
                            title: "Possible duplicate issues",
                            icon: "doc.on.doc.fill",
                            detail: "\(report.duplicateGroupCount) group(s) of comics with the same file name or cover."
                        ) {
                            Button("Review Duplicates") { tab = .duplicates }
                                .buttonStyle(.bordered)
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
                        title: "Tools",
                        icon: "wrench.and.screwdriver",
                        detail: "Tidy up filenames, convert CBR files to CBZ, or rescan everything from scratch."
                    ) {
                        HStack {
                            Button("Clean Up Filenames…") { showRenameFiles = true }
                            #if os(macOS)
                            Button("Convert CBR to CBZ…") { showConvertCBR = true }
                            #endif
                            Button("Resync Library") { vm.resyncLibrary() }
                                .disabled(vm.isBusy)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(24)
            }
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
