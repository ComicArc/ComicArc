import SwiftUI

struct SeriesLinkPickerView: View {
    let childSeries: String
    let childPublisher: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel

    @State private var allSeries: [(publisher: String, series: String)] = []
    @State private var chain: [DatabaseManager.SeriesLink] = []
    @State private var searchText = ""
    @State private var isWorking = false

    private var currentLink: DatabaseManager.SeriesLink? {
        chain.first { $0.childPublisher == childPublisher && $0.childSeries == childSeries }
    }

    private var filteredCandidates: [(publisher: String, series: String)] {
        allSeries.filter {
            $0.series != childSeries || $0.publisher != childPublisher
        }.filter {
            searchText.isEmpty || $0.series.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link as Continuation").font(.title3.bold())
                    Text(childSeries).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.goldButton()
            }
            .padding(20)

            if let link = currentLink {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Currently linked as a continuation of:").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(link.parentSeries, systemImage: "arrow.turn.up.left")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Unlink", role: .destructive) { unlink() }
                            .buttonStyle(.bordered).disabled(isWorking)
                    }
                }
                .padding(16)
                .background(Design.surfaceBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search for the series this continues…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 20)

                    List(filteredCandidates.prefix(50), id: \.series) { candidate in
                        Button {
                            link(to: candidate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.series).font(.subheadline.weight(.medium))
                                    Text(candidate.publisher).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 480)
        .background(Design.appBackground)
        .task { await load() }
    }

    private func load() async {
        let (series, links) = await Task.detached(priority: .userInitiated) {
            (DatabaseManager.shared.allSeriesNames(), DatabaseManager.shared.seriesLinks())
        }.value
        allSeries = series
        chain = links
    }

    private func link(to parent: (publisher: String, series: String)) {
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let ok = DatabaseManager.shared.addSeriesLink(
                parentPublisher: parent.publisher, parentSeries: parent.series,
                childPublisher: childPublisher, childSeries: childSeries
            )
            if ok {
                let keys: Set<String> = [
                    "\(parent.publisher):\(parent.series)", "\(childPublisher):\(childSeries)"
                ]
                DatabaseManager.shared.recomputeReadingOrder(affectedGroupKeys: keys)
            }
            await MainActor.run {
                isWorking = false
                vm.reload()
            }
            await load()
        }
    }

    private func unlink() {
        isWorking = true
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.removeSeriesLink(childPublisher: childPublisher, childSeries: childSeries)
            DatabaseManager.shared.recomputeReadingOrder()
            await MainActor.run {
                isWorking = false
                vm.reload()
            }
            await load()
        }
    }
}
