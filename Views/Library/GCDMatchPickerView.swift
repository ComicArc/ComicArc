import SwiftUI

/// Manual override for which offline comics-database (GCD) series/issue a comic is matched to --
/// the picker `MetadataInspectorView`'s "Fix Match" button opens when the automatic match is
/// wrong or missing. Two levels: search for the real series first, then pick the exact issue
/// within it. A pick made here is protected from ever being silently reverted by a later library
/// rescan (see `gcd_match_source` in `DatabaseManager`).
struct GCDMatchPickerView: View {
    let comicId: Int64
    let currentSeries: String
    let currentGCDMatchSource: String
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel

    @State private var searchText = ""
    @State private var results: [GCDSeriesCandidate] = []
    @State private var isSearching = false
    @State private var selectedSeries: GCDSeriesCandidate?
    @State private var issues: [GCDIssueCandidate] = []
    @State private var isLoadingIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if currentGCDMatchSource == "manual" {
                HStack {
                    Label("Manually matched", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                    Spacer()
                    Button("Clear Manual Match", role: .destructive) { clearMatch() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
            }

            if let series = selectedSeries {
                issueListSection(series)
            } else {
                seriesSearchSection
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 520)
        .background(Design.appBackground)
        .task {
            searchText = currentSeries
            search()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSeries == nil ? "Fix GCD Match" : "Choose Issue")
                    .font(.title3.bold())
                Text(selectedSeries?.name ?? currentSeries)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selectedSeries != nil {
                Button("Back") { selectedSeries = nil }
                    .buttonStyle(.bordered)
            }
            Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private var seriesSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search for the real series…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .onChange(of: searchText) { _, _ in search() }

            if isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "Type a series name to search." : "No matching series in the offline database.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { candidate in
                    Button {
                        selectedSeries = candidate
                        loadIssues(candidate)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name).font(.subheadline.weight(.medium))
                                HStack(spacing: 4) {
                                    if let pub = candidate.publisherName { Text(pub) }
                                    Text("·")
                                    Text(yearRange(candidate))
                                    Text("·")
                                    Text("\(candidate.issueCount) issue\(candidate.issueCount == 1 ? "" : "s")")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func issueListSection(_ series: GCDSeriesCandidate) -> some View {
        Group {
            if isLoadingIssues {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                Text("This series has no cataloged issues.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(issues) { issue in
                    Button {
                        apply(series: series, issue: issue)
                    } label: {
                        HStack {
                            Text("#\(issue.number)").font(.subheadline.weight(.medium))
                            Spacer()
                            if let date = issue.keyDate {
                                Text(date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func yearRange(_ candidate: GCDSeriesCandidate) -> String {
        switch (candidate.yearBegan, candidate.yearEnded) {
        case let (b?, e?): return "\(b)–\(e)"
        case let (b?, nil): return "\(b)–present"
        default: return "Year unknown"
        }
    }

    private func search() {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        isSearching = true
        Task.detached(priority: .userInitiated) {
            let found = OfflineMetadataStore.shared.searchSeries(query: query)
            await MainActor.run {
                guard searchText == query else { return }
                results = found
                isSearching = false
            }
        }
    }

    private func loadIssues(_ series: GCDSeriesCandidate) {
        isLoadingIssues = true
        Task.detached(priority: .userInitiated) {
            let found = OfflineMetadataStore.shared.issuesForSeries(seriesId: series.id)
            await MainActor.run {
                issues = found
                isLoadingIssues = false
            }
        }
    }

    private func apply(series: GCDSeriesCandidate, issue: GCDIssueCandidate) {
        vm.setManualGCDMatch(comicId: comicId, gcdIssueId: issue.id, seriesName: series.name,
                              issueNumber: issue.number, coverDate: issue.keyDate, seriesYearBegan: series.yearBegan)
        onApplied()
        dismiss()
    }

    private func clearMatch() {
        vm.clearManualGCDMatch(comicId: comicId)
        onApplied()
        dismiss()
    }
}
