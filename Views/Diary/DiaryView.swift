import SwiftUI

struct DiaryView: View {
    @State private var entries: [DiaryEntry] = []
    @State private var grouped: [(date: String, entries: [DiaryEntry])] = []
    @State private var isLoading = true
    @State private var openedComic: Comic?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DIARY")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(1.5)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "star.bubble")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("No diary entries yet.")
                        .foregroundStyle(.secondary)
                    Text("Rate or review a comic to start your diary.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.date) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    diaryRow(entry)
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
        .sheet(item: $openedComic) { comic in
            IssueDetailPage(comic: comic, onBack: { openedComic = nil })
        }
    }

    private func diaryRow(_ entry: DiaryEntry) -> some View {
        HStack(spacing: 14) {
            MiniComicCard(comic: entry.comic)
                .frame(width: 36, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.comic.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if entry.isReread {
                        Text("REREAD")
                            .font(.system(size: 9, weight: .black))
                            .kerning(0.5)
                            .foregroundStyle(Design.brandBlue)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Design.brandBlue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 6) {
                    PublisherBadge(publisher: entry.comic.publisher)
                    Text(entry.comic.series)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                readOnlyStars(entry.rating)

                if let review = entry.review, !review.isEmpty {
                    Text(review)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(shortTime(entry.loggedAt))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { openedComic = entry.comic }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.comic.title), \(entry.comic.series), \(entry.rating) star\(entry.rating == 1 ? "" : "s")\(entry.isReread ? ", reread" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private func readOnlyStars(_ rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(star <= rating ? Design.brandGold : Design.secondaryLabel)
            }
        }
        .accessibilityHidden(true)
    }

    private func load() async {
        isLoading = true
        let (e, g) = await Task.detached(priority: .userInitiated) {
            let rows = DatabaseManager.shared.diaryEntries(limit: 500)
            // loggedAt is stored as CURRENT_TIMESTAMP (UTC) -- grouping by its raw date substring
            // splits/merges entries on a UTC midnight boundary that has nothing to do with the
            // user's actual calendar day (e.g. a US-timezone reading session in the evening can
            // straddle UTC midnight and get split across two day headers).
            let grp  = Dictionary(grouping: rows) { Self.localDayKey(from: $0.loggedAt) }
                .sorted { $0.key > $1.key }
                .map { (date: $0.key, entries: $0.value) }
            return (rows, grp)
        }.value
        entries = e; grouped = g; isLoading = false
    }

    private static let utcParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let localDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let localTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func localDayKey(from iso: String) -> String {
        guard let d = utcParser.date(from: iso) else { return String(iso.prefix(10)) }
        return localDayKeyFormatter.string(from: d)
    }

    private func formattedGroupDate(_ iso: String) -> String {
        guard let d = Self.localDayKeyFormatter.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .full
        return out.string(from: d).uppercased()
    }

    private func shortTime(_ iso: String) -> String {
        guard let d = Self.utcParser.date(from: iso) else { return "" }
        return Self.localTimeFormatter.string(from: d)
    }
}
