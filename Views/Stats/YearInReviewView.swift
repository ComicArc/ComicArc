import SwiftUI

/// A "wrapped"-style recap of one calendar year's reading, built entirely from data ComicArc
/// already tracks day-to-day (reading sessions, diary ratings/rereads) -- no new instrumentation,
/// just a year-scoped aggregation and a dedicated presentation for it.
struct YearInReviewView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var availableYears: [Int] = []
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var stats: DatabaseManager.YearInReviewStats?
    @State private var isLoading = true

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
                            statTile("PAGES READ", value: "\(stats.pagesRead)", icon: "book.pages", tint: Design.brandBlue)
                            statTile("DAY STREAK", value: "\(stats.longestStreakDays)", icon: "flame.fill", tint: .orange)
                            statTile("REREADS", value: "\(stats.rereadCount)", icon: "arrow.counterclockwise", tint: Design.brandGold)
                            statTile("RATED", value: stats.averageRating.map { String(format: "%.1f★", $0) } ?? "—",
                                     icon: "star.fill", tint: .yellow)
                        }

                        if let top = stats.topSeries {
                            highlightRow(icon: "books.vertical.fill", label: "Most-Read Series",
                                         value: top.name, detail: "\(top.count) issue\(top.count == 1 ? "" : "s")")
                        }
                        if let pub = stats.topPublisher {
                            highlightRow(icon: "building.columns.fill", label: "Most-Read Publisher",
                                         value: pub.name, detail: "\(pub.count) issue\(pub.count == 1 ? "" : "s")")
                        }
                        if let month = stats.busiestMonthLabel {
                            highlightRow(icon: "calendar", label: "Busiest Month", value: month, detail: nil)
                        }

                        if !stats.topRated.isEmpty {
                            topRatedSection(stats.topRated)
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
            Button("Done") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private func heroCard(_ stats: DatabaseManager.YearInReviewStats) -> some View {
        VStack(spacing: 8) {
            Text("\(stats.issuesRead)")
                .font(.system(size: 64, weight: .black, design: .rounded))
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

    private func statTile(_ label: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 24, weight: .black)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    private func highlightRow(icon: String, label: String, value: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Design.brandGold).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    private func topRatedSection(_ topRated: [(title: String, rating: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOP RATED").font(.system(size: 12, weight: .black)).foregroundStyle(.secondary).kerning(1.2)
            VStack(spacing: 0) {
                ForEach(Array(topRated.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        HStack(spacing: 1) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= entry.rating ? "star.fill" : "star")
                                    .font(.system(size: 9)).foregroundStyle(Design.brandGold)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.title), \(entry.rating) star\(entry.rating == 1 ? "" : "s")")
                    if entry.title != topRated.last?.title { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(Design.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 48)).foregroundStyle(.quaternary)
            Text("No Reading Activity Yet").font(.headline).foregroundStyle(.secondary)
            Text("Read a few issues and come back -- your recap builds itself from there.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDataForYearState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 48)).foregroundStyle(.quaternary)
            Text("No Reading Activity in \(String(selectedYear))").font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        stats = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.yearInReview(year: year)
        }.value
    }
}
