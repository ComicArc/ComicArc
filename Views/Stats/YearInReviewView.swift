import SwiftUI

/// A "wrapped"-style recap of one calendar year's reading, built entirely from data ComicArc
/// already tracks day-to-day (reading sessions and finished issues) -- no new instrumentation,
/// just a year-scoped aggregation and a dedicated presentation for it.
struct YearInReviewView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var availableYears: [Int] = []
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var stats: DatabaseManager.YearInReviewStats?
    @State private var isLoading = true
    @State private var shareCardURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if availableYears.isEmpty {
                emptyState
            } else if let stats, stats.issuesRead > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heroCard(stats)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            RecapStatTile(label: "PAGES READ", value: "\(stats.pagesRead)", icon: "book.pages", tint: Design.brandBlue)
                            RecapStatTile(label: "DAY STREAK", value: "\(stats.longestStreakDays)", icon: "flame.fill", tint: .orange)
                        }

                        if let top = stats.topSeries {
                            RecapHighlightRow(icon: "books.vertical.fill", label: "Most-Read Series",
                                               value: top.name, detail: "\(top.count) issue\(top.count == 1 ? "" : "s")",
                                               tint: Design.brandGold)
                        }
                        if let pub = stats.topPublisher {
                            RecapHighlightRow(icon: "building.columns.fill", label: "Most-Read Publisher",
                                               value: pub.name, detail: "\(pub.count) issue\(pub.count == 1 ? "" : "s")",
                                               tint: Design.brandGold)
                        }
                        if let month = stats.busiestMonthLabel {
                            RecapHighlightRow(icon: "calendar", label: "Busiest Month", value: month, detail: nil,
                                               tint: Design.brandGold)
                        }
                    }
                    .padding(24)
                }
            } else {
                noDataForYearState
            }
        }
        .frame(width: 520, height: 640)
        .background(Design.appBackground)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Year in Review").font(.title3.bold())
                if availableYears.count > 1 {
                    Picker("Year", selection: $selectedYear) {
                        ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selectedYear) { _, _ in Task { await loadStats() } }
                } else if let year = availableYears.first {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let shareCardURL {
                ShareLink(item: shareCardURL, preview: SharePreview("\(selectedYear) in Review")) {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Share as Image")
                .padding(.trailing, 4)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private func heroCard(_ stats: DatabaseManager.YearInReviewStats) -> some View {
        VStack(spacing: 8) {
            Text("\(stats.issuesRead)")
                .font(Design.Typography.heroNumber)
                .foregroundStyle(Design.brandGold)
            Text("issues read in \(stats.year)")
                .font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "calendar.badge.clock",
            title: "No Reading Activity Yet",
            message: "Read a few issues and come back -- your recap builds itself from there.",
            iconFont: .system(size: 48),
            messageWidth: 320
        )
    }

    private var noDataForYearState: some View {
        EmptyStateView(
            icon: "calendar.badge.clock",
            title: "No Reading Activity in \(String(selectedYear))",
            iconFont: .system(size: 48)
        )
    }

    private func load() async {
        isLoading = true
        let years = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.availableReadingYears()
        }.value
        availableYears = years
        if let mostRecent = years.first { selectedYear = mostRecent }
        await loadStats()
        isLoading = false
    }

    private func loadStats() async {
        let year = selectedYear
        shareCardURL = nil
        let result = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.yearInReview(year: year)
        }.value
        stats = result
        guard selectedYear == year else { return }
        let card = ShareCardView(
            title: "\(year) in Review",
            subtitle: "\(result.issuesRead) issue\(result.issuesRead == 1 ? "" : "s") read",
            covers: [],
            stats: [
                ("Pages", "\(result.pagesRead)"),
                ("Streak", "\(result.longestStreakDays)d")
            ]
        )
        shareCardURL = ShareCardRenderer.renderToTempPNG(card, filename: "YearInReview-\(year).png")
    }
}
