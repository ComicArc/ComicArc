import SwiftUI

struct SeriesLinkPickerView: View {
    let childSeries: String
    let childPublisher: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel

    private struct SeriesVolumeCandidate: Identifiable, Hashable {
        let publisher: String; let series: String; let volume: String?
        var id: String { "\(publisher):\(series):\(volume ?? "")" }
    }

    @State private var allVolumes: [SeriesVolumeCandidate] = []
    @State private var chain: [DatabaseManager.SeriesLink] = []
    @State private var childVolumes: [String?] = []
    @State private var selectedChildVolume: String? = nil
    @State private var searchText = ""
    @State private var isWorking = false
    @State private var linkError: String?

    private func normalize(_ volume: String?) -> String? { volume?.isEmpty == false ? volume : nil }
    private func volumesEqual(_ a: String?, _ b: String?) -> Bool { normalize(a) == normalize(b) }

    private var currentLink: DatabaseManager.SeriesLink? {
        chain.first {
            $0.childPublisher == childPublisher && $0.childSeries == childSeries &&
            volumesEqual($0.childVolume, selectedChildVolume)
        }
    }

    private var filteredCandidates: [SeriesVolumeCandidate] {
        allVolumes.filter {
            !($0.series == childSeries && $0.publisher == childPublisher && volumesEqual($0.volume, selectedChildVolume))
        }.filter {
            searchText.isEmpty || $0.series.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Whether a candidate's series name is ambiguous without its volume -- i.e. more than one
    /// volume of that (publisher, series) exists in the library, so the picker needs to show the
    /// volume alongside it or two different runs (e.g. Amazing Spider-Man Vol. 1 and Vol. 2)
    /// would look identical in the list.
    private func hasMultipleVolumes(_ candidate: SeriesVolumeCandidate) -> Bool {
        allVolumes.filter { $0.publisher == candidate.publisher && $0.series == candidate.series }.count > 1
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

            if childVolumes.count > 1 {
                Picker("Volume Being Linked", selection: $selectedChildVolume) {
                    ForEach(childVolumes, id: \.self) { vol in
                        Text(vol.map { "Volume \($0)" } ?? "No Volume").tag(vol)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if let link = currentLink {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Currently linked as a continuation of:").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label {
                            Text(link.parentVolume.map { "\(link.parentSeries) (Volume \($0))" } ?? link.parentSeries)
                        } icon: {
                            Image(systemName: "arrow.turn.up.left")
                        }
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

                    List(filteredCandidates.prefix(50)) { candidate in
                        Button {
                            link(to: candidate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.series).font(.subheadline.weight(.medium))
                                    HStack(spacing: 4) {
                                        Text(candidate.publisher)
                                        if hasMultipleVolumes(candidate) {
                                            Text("·")
                                            Text(candidate.volume.map { "Volume \($0)" } ?? "No Volume")
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
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
        .errorAlert("Couldn't Link Series", message: $linkError)
    }

    private func load() async {
        let (volumes, links) = await Task.detached(priority: .userInitiated) {
            (DatabaseManager.shared.allSeriesVolumes(), DatabaseManager.shared.seriesLinks())
        }.value
        allVolumes = volumes.map { SeriesVolumeCandidate(publisher: $0.publisher, series: $0.series, volume: $0.volume) }
        chain = links

        let distinctChildVolumes = Set(allVolumes
            .filter { $0.publisher == childPublisher && $0.series == childSeries }
            .map { normalize($0.volume) })
        childVolumes = distinctChildVolumes.sorted { ($0 ?? "") < ($1 ?? "") }
        if !childVolumes.contains(where: { volumesEqual($0, selectedChildVolume) }) {
            selectedChildVolume = childVolumes.first ?? nil
        }
    }

    private func link(to parent: SeriesVolumeCandidate) {
        isWorking = true
        let childVolume = selectedChildVolume
        Task.detached(priority: .userInitiated) {
            let ok = DatabaseManager.shared.addSeriesLink(
                parentPublisher: parent.publisher, parentSeries: parent.series, parentVolume: parent.volume,
                childPublisher: childPublisher, childSeries: childSeries, childVolume: childVolume
            )
            if ok {
                let keys: Set<String> = [
                    "\(parent.publisher):\(parent.series)", "\(childPublisher):\(childSeries)"
                ]
                DatabaseManager.shared.recomputeReadingOrder(affectedGroupKeys: keys)
            }
            await MainActor.run {
                isWorking = false
                if !ok {
                    linkError = "That link couldn't be created -- it would create a cycle or conflicts with an existing link."
                }
                vm.reload()
            }
            await load()
        }
    }

    private func unlink() {
        isWorking = true
        let childVolume = selectedChildVolume
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.removeSeriesLink(childPublisher: childPublisher, childSeries: childSeries, childVolume: childVolume)
            DatabaseManager.shared.recomputeReadingOrder()
            await MainActor.run {
                isWorking = false
                vm.reload()
            }
            await load()
        }
    }
}
