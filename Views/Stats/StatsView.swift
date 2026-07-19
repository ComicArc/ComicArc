import SwiftUI

struct StatsView: View {
    @State private var stats:    LibraryStats? = nil
    @State private var goalYear: Int = Calendar.current.component(.year, from: Date())
    @State private var goalCount: Int = 52
    @State private var issuesReadThisYear: Int = 0
    @State private var editingGoal = false
    @State private var goalDraft   = ""

    var body: some View {
        Group {
            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heading
                        statCards(stats)
                        sectionDivider
                        readingGoalSection
                        sectionDivider
                        HStack(alignment: .top, spacing: 40) {
                            publisherSection(stats)
                            Divider()
                            topSeriesSection(stats)
                        }
                        .padding(.horizontal, 24)
                        sectionDivider
                        yearInReviewSection(stats)
                        sectionDivider
                        recentlyReadSection(stats)
                        if !stats.activityMap.isEmpty {
                            sectionDivider
                            heatmapSection(stats)
                        }
                        Spacer(minLength: 40)
                    }
                }
            } else {
                ProgressView("Loading Stats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Design.appBackground)
        .task { await loadStats() }
    }

    // MARK: - Reading Goal section

    private var readingGoalSection: some View {
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
            VStack(alignment: .leading, spacing: 8) {
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
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR STATS")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(Design.brandGold)
                .kerning(2)
            Text("Everything you've read, rated, and collected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Design.borderColor).frame(height: 1)
            .padding(.horizontal, 24).padding(.vertical, 20)
    }

    // MARK: - Stat cards

    private func statCards(_ s: LibraryStats) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 220))],
            spacing: 12
        ) {
            statCard("COMICS IN LIBRARY", value: "\(s.totalComics)")
            statCard("COMPLETED",         value: "\(s.finished)")
            statCard("IN PROGRESS",       value: "\(s.inProgress)")
            statCard("PAGES READ",        value: "\(s.pagesRead)")
            statCard("FAVORITES",         value: "\(s.favorites)")
            statCard("NARRATIVE RUNS",    value: "\(s.runsCount)")
            if s.readingStreak > 0 {
                statCard("DAY STREAK 🔥",  value: "\(s.readingStreak)")
            }
        }
        .padding(.horizontal, 24)
    }

    private func statCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 38, weight: .black))
                .foregroundStyle(Design.brandGold)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.lowercased().replacingOccurrences(of: " 🔥", with: "")): \(value)")
    }

    // MARK: - By Publisher (colored badge + horizontal bar, matches Python)

    private func publisherSection(_ s: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("BY PUBLISHER")

            let maxCount = s.publisherBreakdown.first?.count ?? 1
            ForEach(s.publisherBreakdown.prefix(8), id: \.publisher) { item in
                HStack(spacing: 12) {
                    PublisherBadge(publisher: item.publisher)
                        .frame(width: 56, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Design.surfaceBg)
                                .frame(height: 10)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(
                                    colors: [Design.brandGold, Color(red: 0.976, green: 0.863, blue: 0.384)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(
                                    width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(maxCount)),
                                    height: 10
                                )
                        }
                    }
                    .frame(height: 10)
                    .accessibilityHidden(true)

                    Text("\(item.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.publisher): \(item.count) comics")
            }
        }
    }

    // MARK: - Top Series

    private func topSeriesSection(_ s: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("TOP SERIES").padding(.bottom, 14)

            ForEach(s.topSeries.prefix(8), id: \.series) { item in
                HStack(spacing: 10) {
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
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.series) by \(item.publisher): \(item.count) issues")

                Rectangle().fill(Design.borderColor).frame(height: 1).accessibilityHidden(true)
            }
        }
    }

    // MARK: - Recently Read

    private func recentlyReadSection(_ s: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("RECENTLY READ").padding(.bottom, 14)

            ForEach(s.recentlyRead) { comic in
                HStack(spacing: 12) {
                    MiniComicCard(comic: comic)
                        .frame(width: 46, height: 66)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(comic.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        PublisherBadge(publisher: comic.publisher)

                        if comic.isFinished {
                            Text("Read")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if comic.progress > 0 {
                            Text("p. \(comic.progress + 1)/\(comic.pageCount)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let lr = comic.lastRead {
                        Text(String(lr.prefix(10)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)

                Rectangle().fill(Design.borderColor).frame(height: 1)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Reading Activity heatmap

    private func heatmapSection(_ s: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("READING ACTIVITY")
            HeatmapView(activityMap: s.activityMap, days: 365)
                .frame(height: 7 * (12 + 2))
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(.secondary)
            .kerning(1.5)
    }

    // MARK: - Year in Review

    @ViewBuilder
    private func yearInReviewSection(_ s: LibraryStats) -> some View {
        let yr = Calendar.current.component(.year, from: Date())
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("\(yr) IN REVIEW")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180))], spacing: 10) {
                statCard("READ THIS YEAR", value: "\(issuesReadThisYear)")
                if let topPub = s.publisherBreakdown.first {
                    statCard("TOP PUBLISHER", value: topPub.publisher.uppercased())
                }
                if let topSeries = s.topSeries.first {
                    statCard("TOP SERIES", value: topSeries.series)
                }
                if s.readingStreak > 0 {
                    statCard("BEST STREAK", value: "\(s.readingStreak) days")
                }
            }
        }
        .padding(.horizontal, 24)
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

// MARK: - Heatmap (GitHub-style)

struct HeatmapView: View {
    let activityMap: [String: Int]
    let days: Int

    var body: some View {
        let cellSize: CGFloat = 12
        let gap:      CGFloat = 2
        let weeks     = 53
        let allCells  = paddedCells(weeks: weeks)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cellSize), spacing: gap), count: weeks),
            spacing: gap
        ) {
            ForEach(Array(allCells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 2)
                    .fill(cell.date.isEmpty ? Color.clear : cellColor(cell.count))
                    .frame(width: cellSize, height: cellSize)
                    .help(cell.count > 0 ? "\(cell.date): \(cell.count) sessions" : "")
            }
        }
    }

    private func paddedCells(weeks: Int) -> [(date: String, count: Int)] {
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let today   = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let startOffset = -((weeks - 1) * 7 + weekday - 1)

        var grid: [(date: String, count: Int)] = []
        grid.reserveCapacity(weeks * 7)
        for row in 0..<7 {
            for col in 0..<weeks {
                let offset = startOffset + col * 7 + row
                if let d = cal.date(byAdding: .day, value: offset, to: today), d <= today {
                    let key = fmt.string(from: d)
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

