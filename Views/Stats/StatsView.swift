import SwiftUI
import Charts

struct StatsView: View {
    @State private var stats:    LibraryStats? = nil
    @State private var goalYear: Int = Calendar.current.component(.year, from: Date())
    @State private var goalCount: Int = 52
    @State private var issuesReadThisYear: Int = 0
    @State private var editingGoal = false
    @State private var goalDraft   = ""
    @State private var showGoalInputError = false
    @State private var showYearInReview = false

    private let gridColumns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 20, alignment: .top)]

    var body: some View {
        Group {
            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        heading
                        heroRow(stats)
                        readingGoalCard

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            publisherCard(stats)
                            topSeriesCard(stats)
                            growthCard(stats)
                            if !stats.activityMap.isEmpty { activityCard(stats) }
                        }
                        .padding(.horizontal, 24)

                        if !stats.recentlyRead.isEmpty { recentlyReadSection(stats) }
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 24)
                }
            } else {
                ProgressView("Loading Stats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Design.appBackground)
        .task { await loadStats() }
        .sheet(isPresented: $showYearInReview) { YearInReviewView() }
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                SignageLabel(text: "Your Stats", size: 30, kerning: 2, tint: Design.brandGold)
                Text("Everything you've read, rated, and collected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Year in Review") { showYearInReview = true }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
    }

    private func heroRow(_ s: LibraryStats) -> some View {
        HStack(alignment: .top, spacing: 20) {
            completionRingCard(s)
                .frame(maxWidth: .infinity)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metricTile("PAGES READ", value: "\(s.pagesRead)", icon: "book.pages", tint: Design.brandBlue)
                metricTile("FAVORITES", value: "\(s.favorites)", icon: "heart.fill", tint: .red)
                metricTile("READING PATHS", value: "\(s.runsCount)", icon: "list.bullet.rectangle.portrait.fill", tint: Design.brandGold)
                metricTile("DAY STREAK", value: "\(s.readingStreak)", icon: "flame.fill", tint: .orange)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
    }

    private func completionRingCard(_ s: LibraryStats) -> some View {
        DashboardCard {
            VStack(spacing: 16) {
                sectionHeader("COLLECTION STATUS")

                ZStack {
                    Chart {
                        SectorMark(angle: .value("Finished", max(s.finished, 0)), innerRadius: .ratio(0.68), angularInset: 1.5)
                            .foregroundStyle(Design.brandGold)
                            .cornerRadius(3)
                        SectorMark(angle: .value("In Progress", max(s.inProgress, 0)), innerRadius: .ratio(0.68), angularInset: 1.5)
                            .foregroundStyle(Design.brandBlue)
                            .cornerRadius(3)
                        SectorMark(angle: .value("Unread", max(s.unread, 0)), innerRadius: .ratio(0.68), angularInset: 1.5)
                            .foregroundStyle(Design.surfaceBg)
                            .cornerRadius(3)
                    }
                    .frame(height: 180)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(s.finished) finished, \(s.inProgress) in progress, \(s.unread) unread, of \(s.totalComics) total")

                    VStack(spacing: 2) {
                        Text("\(s.totalComics)").font(.system(size: 30, weight: .black)).foregroundStyle(.primary)
                        Text("COMICS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
                    }
                }

                HStack(spacing: 16) {
                    legendDot("Finished", Design.brandGold, s.finished)
                    legendDot("In Progress", Design.brandBlue, s.inProgress)
                    legendDot("Unread", Design.secondaryLabel, s.unread)
                }
            }
        }
    }

    private func legendDot(_ label: String, _ color: Color, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) · \(count)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metricTile(_ label: String, value: String, icon: String, tint: Color) -> some View {
        DashboardCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.lowercased()): \(value)")
    }

    private var readingGoalCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionHeader("READING GOAL \(goalYear)")
                    Spacer()
                    Button("Change Goal") { goalDraft = "\(goalCount)"; editingGoal = true }
                        .font(.caption).foregroundStyle(Design.brandGold).buttonStyle(.plain)
                        .accessibilityLabel("Change reading goal")
                        .help("Set your annual reading target")
                }

                let pct = goalCount > 0 ? min(1.0, Double(issuesReadThisYear) / Double(goalCount)) : 0
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(issuesReadThisYear)")
                        .font(.system(size: 36, weight: .black)).foregroundStyle(Design.brandGold)
                    Text("of \(goalCount) issues read")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(pct * 100))%")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(pct >= 1 ? .green : .secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Design.surfaceBg).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Design.brandGold, Color(red: 0.976, green: 0.863, blue: 0.384)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * pct, height: 12)
                    }
                }
                .frame(height: 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reading goal progress: \(Int(pct * 100))%")

                if pct >= 1 {
                    Label("Goal achieved! 🎉", systemImage: "star.fill")
                        .foregroundStyle(.green).font(.subheadline)
                } else {
                    Text("\(goalCount - issuesReadThisYear) issues to go")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 24)
        .alert("Set Reading Goal for \(goalYear)", isPresented: $editingGoal) {
            TextField("Number of issues", text: $goalDraft)
            Button("Save") {
                if let n = Int(goalDraft), n > 0 {
                    goalCount = n
                    LibraryViewModel.shared.setReadingGoal(year: goalYear, count: n)
                } else {
                    showGoalInputError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Invalid Goal", isPresented: $showGoalInputError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a whole number greater than 0.")
        }
    }

    private func publisherCard(_ s: LibraryStats) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("BY PUBLISHER")
                Chart(s.publisherBreakdown.prefix(6), id: \.publisher) { item in
                    BarMark(
                        x: .value("Comics", item.count),
                        y: .value("Publisher", item.publisher)
                    )
                    .foregroundStyle(Design.publisherColor(item.publisher))
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text("\(item.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { value in
                    AxisValueLabel {
                        if let pub = value.as(String.self) {
                            Text(pub).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } }
                .frame(height: CGFloat(min(s.publisherBreakdown.count, 6)) * 34 + 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.publisherBreakdown.prefix(6).map { "\($0.publisher): \($0.count)" }.joined(separator: ", "))
            }
        }
    }

    private func topSeriesCard(_ s: LibraryStats) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("TOP SERIES").padding(.bottom, 10)

                ForEach(Array(s.topSeries.prefix(5).enumerated()), id: \.element.series) { idx, item in
                    HStack(spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Design.brandGold)
                            .frame(width: 18)
                        PublisherBadge(publisher: item.publisher)
                        Text(item.series)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.series) by \(item.publisher): \(item.count) issues")

                    if idx < min(s.topSeries.count, 5) - 1 {
                        Rectangle().fill(Design.borderColor).frame(height: 1).accessibilityHidden(true)
                    }
                }

                if s.topSeries.isEmpty {
                    Text("No series yet — import some comics to see this fill in.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func growthCard(_ s: LibraryStats) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("COLLECTION GROWTH")
                Text("Comics added, last 6 months")
                    .font(.caption2).foregroundStyle(.tertiary)

                Chart(s.collectionGrowth) { point in
                    BarMark(
                        x: .value("Month", point.label),
                        y: .value("Added", point.count)
                    )
                    .foregroundStyle(Design.brandBlue.gradient)
                    .cornerRadius(4)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.collectionGrowth.map { "\($0.label): \($0.count) added" }.joined(separator: ", "))
            }
        }
    }

    private func activityCard(_ s: LibraryStats) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("READING ACTIVITY")
                HeatmapView(activityMap: s.activityMap, days: 365)
                    .frame(height: 7 * (12 + 2))
            }
        }
    }

    private func recentlyReadSection(_ s: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("RECENTLY READ").padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(s.recentlyRead) { comic in
                        VStack(alignment: .leading, spacing: 6) {
                            MiniComicCard(comic: comic)
                                .frame(width: 100, height: 144)

                            Text(comic.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .frame(width: 100, alignment: .leading)

                            if comic.isFinished {
                                Text("Read").font(.caption2).foregroundStyle(.secondary)
                            } else if comic.progress > 0 {
                                Text("p. \(comic.progress + 1)/\(comic.pageCount)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 100)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        SignageLabel(text: title, size: 12, kerning: 1.2)
    }

    private func loadStats() async {
        let (s, goal, read) = await Task.detached(priority: .utility) {
            let s    = DatabaseManager.shared.loadStats()
            let yr   = Calendar.current.component(.year, from: Date())
            let goal = DatabaseManager.shared.readingGoal(year: yr)
            let read = DatabaseManager.shared.issuesReadThisYear()
            return (s, goal, read)
        }.value
        stats               = s
        goalCount           = goal
        issuesReadThisYear  = read
    }
}

private struct DashboardCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content.dashboardCardStyle(padding: padding)
    }
}

struct HeatmapView: View {
    let activityMap: [String: Int]
    let days: Int

    // Computed once and cached in @State instead of being rebuilt (including a fresh
    // Calendar/DateFormatter) on every single body evaluation -- SwiftUI re-evaluates body far
    // more often than activityMap actually changes.
    @State private var cells: [(date: String, count: Int)] = []

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        let cellSize: CGFloat = 12
        let gap:      CGFloat = 2
        let weeks     = 53
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cellSize), spacing: gap), count: weeks),
            spacing: gap
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 2)
                    .fill(cell.date.isEmpty ? Color.clear : cellColor(cell.count))
                    .frame(width: cellSize, height: cellSize)
                    .help(cell.count > 0 ? "\(cell.date): \(cell.count) sessions" : "")
                    .accessibilityLabel(cell.date.isEmpty ? "" :
                        "\(cell.date): \(cell.count) session\(cell.count == 1 ? "" : "s")")
            }
        }
        .onAppear { recomputeCells() }
        .onChange(of: activityMap) { _, _ in recomputeCells() }
    }

    private func recomputeCells() {
        cells = Self.paddedCells(weeks: 53, activityMap: activityMap)
    }

    private static func paddedCells(weeks: Int, activityMap: [String: Int]) -> [(date: String, count: Int)] {
        let cal = Calendar(identifier: .gregorian)

        let today   = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let startOffset = -((weeks - 1) * 7 + weekday - 1)

        var grid: [(date: String, count: Int)] = []
        grid.reserveCapacity(weeks * 7)
        for row in 0..<7 {
            for col in 0..<weeks {
                let offset = startOffset + col * 7 + row
                if let d = cal.date(byAdding: .day, value: offset, to: today), d <= today {
                    let key = dayKeyFormatter.string(from: d)
                    grid.append((key, activityMap[key] ?? 0))
                } else {
                    grid.append(("", 0))
                }
            }
        }
        return grid
    }

    private func cellColor(_ count: Int) -> Color {
        switch count {
        case 0:   return Color.primary.opacity(0.06)
        case 1:   return Color.green.opacity(0.4)
        case 2:   return Color.green.opacity(0.65)
        case 3:   return Color.green.opacity(0.85)
        default:  return Color.green
        }
    }
}
