import SwiftUI

struct ImportWizardView: View {
    let report: LibraryHealthReport
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel
    @State private var isRepositioning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library Health Check")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text("\(report.totalCount) thing\(report.totalCount == 1 ? "" : "s") worth a look after this scan")
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
                    if !report.needsSpecialReposition.isEmpty {
                        section(
                            title: "Annuals/specials with no anchor to place against",
                            icon: "arrow.up.arrow.down.circle.fill",
                            detail: "\(report.needsSpecialReposition.reduce(0) { $0 + $1.count }) issue(s) across \(report.needsSpecialReposition.count) series are estimated with the lowest confidence — this repositions them using publication date and story arc where available."
                        ) {
                            Button(isRepositioning ? "Repositioning…" : "Reposition Now") { repositionSpecials() }
                                .buttonStyle(.borderedProminent).tint(Design.brandGold)
                                .disabled(isRepositioning)
                        }
                    }
                    if report.duplicateGroupCount > 0 {
                        section(
                            title: "Duplicate issues",
                            icon: "doc.on.doc.fill",
                            detail: "\(report.duplicateGroupCount) group(s) of possible duplicates found."
                        ) {
                            Button("Review Duplicates") {
                                vm.destination = .duplicates
                                dismiss()
                            }.buttonStyle(.bordered)
                        }
                    }
                    if !report.multipleFirstIssues.isEmpty {
                        seriesListSection(
                            title: "Multiple issue #1s in one series",
                            icon: "1.circle.fill",
                            detail: "Could be a relaunch, a reprint, or a numbering mix-up — worth a manual look since only you know which is which.",
                            items: report.multipleFirstIssues
                        )
                    }
                    if !report.missingComicInfo.isEmpty {
                        seriesListSection(
                            title: "No embedded ComicInfo.xml",
                            icon: "doc.text.magnifyingglass",
                            detail: "These comics only have filename-derived metadata, so Intelligent Reading Order and ComicInfo Order mode can't do as much for them. Nothing to fix automatically — ComicArc never writes files.",
                            items: report.missingComicInfo,
                            actionable: false
                        )
                    }
                    if !report.unparseableNumbering.isEmpty {
                        section(
                            title: "Unparseable issue numbers",
                            icon: "questionmark.circle.fill",
                            detail: "\(report.unparseableNumbering.count) comic(s) have no usable issue number and aren't a recognized special type."
                        ) {
                            EmptyView()
                        }
                    }
                    if report.isEmpty {
                        Text("Nothing to report.").foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .background(Design.appBackground)
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
    private func seriesListSection(title: String, icon: String, detail: String, items: [LibraryHealthReport.SeriesIssue], actionable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            ForEach(items.prefix(8)) { item in
                HStack {
                    Text("\(item.series)").font(.caption.weight(.semibold))
                    Text("· \(item.count) issue(s)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if actionable {
                        Button("Review") {
                            vm.destination = .publisher(item.publisher)
                            vm.selectedSeries = item.series
                            vm.showSeriesManager = true
                            dismiss()
                        }.buttonStyle(.borderless).font(.caption)
                    }
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

    private func repositionSpecials() {
        isRepositioning = true
        let keys = Set(report.needsSpecialReposition.map { "\($0.publisher):\($0.series)" })
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.positionSpecialsChronologically()
            DatabaseManager.shared.recomputeReadingOrder(affectedGroupKeys: keys)
            await MainActor.run {
                isRepositioning = false
                vm.reload()
                vm.refreshLibraryHealth()
            }
        }
    }
}
