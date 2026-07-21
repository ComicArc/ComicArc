import SwiftUI

struct ImportWizardView: View {
    let report: LibraryHealthReport
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel
    @State private var isRepositioning = false
    @State private var showRenameFiles = false

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
                    if !report.needsSpecialReposition.isEmpty {
                        section(
                            title: "Some annuals or specials may be in the wrong spot",
                            icon: "arrow.up.arrow.down.circle.fill",
                            detail: "\(report.needsSpecialReposition.reduce(0) { $0 + $1.count }) issue(s) across \(report.needsSpecialReposition.count) series. This tries to place them better using their cover date and story."
                        ) {
                            Button(isRepositioning ? "Fixing…" : "Fix Automatically") { repositionSpecials() }
                                .buttonStyle(.borderedProminent).tint(Design.brandGold)
                                .disabled(isRepositioning)
                        }
                    }
                    if report.duplicateGroupCount > 0 {
                        section(
                            title: "Possible duplicate issues",
                            icon: "doc.on.doc.fill",
                            detail: "\(report.duplicateGroupCount) group(s) of comics that look like the same issue twice."
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
                    }.buttonStyle(.borderless).font(.caption)
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
