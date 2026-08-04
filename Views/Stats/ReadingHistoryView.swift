import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var history: [HistoryEntry] = []
    @State private var isLoading = true

    private func filteredHistory(_ source: [HistoryEntry]) -> [HistoryEntry] {
        guard !vm.searchText.isEmpty else { return source }
        let q = vm.searchText.lowercased()
        return source.filter {
            $0.title.lowercased().contains(q) ||
            $0.series.lowercased().contains(q) ||
            $0.publisher.lowercased().contains(q)
        }
    }

    private func grouped(_ entries: [HistoryEntry]) -> [(date: String, entries: [HistoryEntry])] {
        Dictionary(grouping: entries) { DayGroupingFormatters.localDayKey(from: $0.readAt) }
            .sorted { $0.key > $1.key }
            .map { (date: $0.key, entries: $0.value) }
    }

    var body: some View {
        let filtered = filteredHistory(history)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("READING HISTORY")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(1.5)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("No reading history yet.")
                        .foregroundStyle(.secondary)
                    Text("Open a comic in the reader to start tracking.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("No matching history.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped(filtered), id: \.date) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    historyRow(entry)
                                    Rectangle().fill(Design.borderColor).frame(height: 1)
                                        .padding(.leading, 24)
                                }
                            } header: {
                                Text(formattedGroupDate(group.date))
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.secondary)
                                    .kerning(1.5)
                                    .padding(.horizontal, 24).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Design.appBackground)
                            }
                        }
                    }
                }
            }
        }
        .background(Design.appBackground)
        .task { await load() }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 14) {
            MiniComicCard(comic: Comic(
                id: entry.comicId, title: entry.title, filePath: "",
                publisher: entry.publisher, character: nil, series: entry.series,
                issueNumber: nil, pageCount: 0, writer: nil, penciller: nil,
                year: nil, storyArc: nil, languageIso: nil, notes: nil,
                addedAt: "", deletedAt: nil, position: 0, fileHash: nil
            ))
            .frame(width: 36, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    PublisherBadge(publisher: entry.publisher)
                    Text(entry.series)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Text("\(entry.pagesRead) page\(entry.pagesRead == 1 ? "" : "s") read (p.\(entry.pageStart + 1)–\(entry.pageEnd + 1))")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            Text(shortTime(entry.readAt))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title), \(entry.series)")
        .accessibilityValue("\(entry.pagesRead) page\(entry.pagesRead == 1 ? "" : "s") read, pages \(entry.pageStart + 1) to \(entry.pageEnd + 1)")
    }

    private func load() async {
        isLoading = true
        history = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.readingHistory(limit: 500)
        }.value
        isLoading = false
    }

    private func formattedGroupDate(_ iso: String) -> String {
        DayGroupingFormatters.formattedGroupDate(iso)
    }

    private func shortTime(_ iso: String) -> String {
        DayGroupingFormatters.shortTime(iso)
    }
}
