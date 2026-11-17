import SwiftUI
import Foundation

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
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", title: "No reading history yet.",
                                message: "Open a comic in the reader to start tracking.")
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matching history.")
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
                                SignageLabel(text: formattedGroupDate(group.date), size: 11, kerning: 1.5)
                                    .padding(.horizontal, 24).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Design.appBackground)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 14) {
            MiniComicCard(comic: Comic(
                id: entry.comicId, title: entry.title, filePath: "",
                publisher: entry.publisher, character: nil, series: entry.series,
                issueNumber: nil, pageCount: 0, writer: nil, penciller: nil,
                year: nil, storyArc: nil, languageIso: nil, notes: nil,
                addedAt: "", position: 0, fileHash: nil
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

/// Groups UTC timestamps by the user's local day, so evening sessions don't split across UTC
/// midnight.
enum DayGroupingFormatters {
    // Used from background tasks; a configured DateFormatter is thread-safe.
    static let utcParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let localDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let localTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func localDayKey(from iso: String) -> String {
        guard let d = utcParser.date(from: iso) else { return String(iso.prefix(10)) }
        return localDayKeyFormatter.string(from: d)
    }

    static func formattedGroupDate(_ iso: String) -> String {
        guard let d = localDayKeyFormatter.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .full
        return out.string(from: d).uppercased()
    }

    static func shortTime(_ iso: String) -> String {
        guard let d = utcParser.date(from: iso) else { return "" }
        return localTimeFormatter.string(from: d)
    }
}
