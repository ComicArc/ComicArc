import SwiftUI

struct ReadingHistoryView: View {
    @State private var history: [HistoryEntry] = []
    @State private var grouped: [(date: String, entries: [HistoryEntry])] = []
    @State private var isLoading = true

    var body: some View {
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.date) { group in
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
        let (h, g) = await Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.readingHistory(limit: 500)
            let grp  = Dictionary(grouping: rows) { String($0.readAt.prefix(10)) }
                .sorted { $0.key > $1.key }
                .map { (date: $0.key, entries: $0.value) }
            return (rows, grp)
        }.value
        history = h; grouped = g; isLoading = false
    }

    private func formattedGroupDate(_ iso: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let d = fmt.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .full
        return out.string(from: d).uppercased()
    }

    private func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return "" }
        return String(iso.dropFirst(11).prefix(5))
    }
}
