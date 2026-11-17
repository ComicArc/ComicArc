import SwiftUI
import Charts

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var stats = LibraryStats()
    @State private var history: [HistoryEntry] = []
    @State private var showYear = false
    private let year = Calendar.current.component(.year, from: Date())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    ScreenHeader(title: "Stats", subtitle: "\(stats.total) comics in your library")
                    Spacer()
                    Button { showYear = true } label: { Label("Year in Review", systemImage: "sparkles") }.buttonStyle(QuietButtonStyle())
                    Picker("", selection: $tab) { Text("Overview").tag(0); Text("History").tag(1) }
                        .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                if tab == 0 { overview } else { historyList }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .task(id: model.revision) {
            stats = (try? await Database.shared.stats(year: year)) ?? LibraryStats()
            history = (try? await Database.shared.history()) ?? []
        }
        .sheet(isPresented: $showYear) { YearInReviewView() }
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                tile("Read", "\(stats.finished)", "checkmark.circle.fill", Theme.finished)
                tile("In Progress", "\(stats.inProgress)", "book.fill", Theme.accent)
                tile("Unread", "\(stats.unread)", "circle.dashed", Theme.textSecondary)
                tile("Pages Read", stats.pagesRead.formatted(), "doc.plaintext.fill", .cyan)
                tile("Streak", "\(stats.currentStreak) day\(stats.currentStreak == 1 ? "" : "s")", "flame.fill", .orange,
                     caption: "Best: \(stats.longestStreak)")
            }
            HStack(alignment: .top, spacing: 16) {
                card("\(year) Goal") { goal }.frame(width: 280)
                card("Reading Activity") { Heatmap(activity: stats.activity) }
            }
            HStack(alignment: .top, spacing: 16) {
                card("Publishers") {
                    Chart(stats.publishers, id: \.name) { p in
                        BarMark(x: .value("Comics", p.total), y: .value("Publisher", p.name))
                            .foregroundStyle(Theme.publisherColor(p.name).opacity(0.35))
                        BarMark(x: .value("Read", p.finished), y: .value("Publisher", p.name))
                            .foregroundStyle(Theme.publisherColor(p.name))
                    }
                    .chartXAxis { AxisMarks(position: .bottom) }
                    .frame(height: CGFloat(max(1, stats.publishers.count)) * 34 + 30)
                    Text("Solid = read, faded = in your library").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                card("Most-Read Series") {
                    if stats.topSeries.isEmpty {
                        Text("Finish an issue to see your top series.").font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(stats.topSeries, id: \.series) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.series).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\(s.finished)/\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            }
                            ProgressLine(value: Double(s.finished) / Double(max(1, s.total)), color: Theme.publisherColor(s.publisher))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            if stats.growth.count > 1 {
                card("Comics Added") {
                    Chart(stats.growth, id: \.month) { g in
                        BarMark(x: .value("Month", Self.monthLabel(g.month)), y: .value("Added", g.added)).foregroundStyle(Theme.accent)
                    }
                    .frame(height: 160)
                }
            }
        }
    }

    private var goal: some View {
        let pct = Double(stats.finishedThisYear) / Double(max(1, stats.goal))
        return VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.raised, lineWidth: 12)
                Circle().trim(from: 0, to: min(1, pct)).stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(stats.finishedThisYear)").font(.system(size: 34, weight: .black, design: .rounded))
                    Text("of \(stats.goal)").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 130, height: 130)
            Text(pct >= 1 ? "Goal reached!" : "\(stats.goal - stats.finishedThisYear) to go").font(.callout.weight(.medium))
            Button("Change Goal…") {
                NewPathPrompt.ask(title: "Reading Goal for \(year)", placeholder: "Issues", initial: "\(stats.goal)") { text in
                    guard let n = Int(text), n > 0 else { return }
                    model.perform { try await $0.setReadingGoal(n, year: year) }
                }
            }
            .buttonStyle(.link).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - History

    private var historyList: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if history.isEmpty {
                EmptyState(icon: "clock", title: "No reading history yet", message: "Every time you read, it's logged here.")
            }
            ForEach(groupedHistory, id: \.0) { day, entries in
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: day)
                    ForEach(entries) { e in
                        HStack(spacing: 12) {
                            CoverImage(e.comic).frame(width: 30, height: 45).clipShape(RoundedRectangle(cornerRadius: 3))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.comic.title).font(.callout.weight(.medium))
                                Text(e.pageEnd > e.pageStart ? "Pages \(e.pageStart + 1)–\(e.pageEnd + 1)" : "Page \(e.pageEnd + 1)")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text(e.readAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.path.append(.comic(e.comic.id)) }
                    }
                }
            }
        }
    }

    private var groupedHistory: [(String, [HistoryEntry])] {
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in history {
            let key = Calendar.current.isDateInToday(e.readAt) ? "Today"
                : Calendar.current.isDateInYesterday(e.readAt) ? "Yesterday"
                : e.readAt.formatted(.dateTime.weekday(.wide).month(.wide).day())
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }

    // MARK: - Pieces

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary)
            if let caption { Text(caption).font(.caption2).foregroundStyle(Theme.textTertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    static func monthLabel(_ ym: String) -> String {
        SQLDate.day(ym + "-01").map { $0.formatted(.dateTime.month(.abbreviated)) } ?? ym
    }
}

/// A year of reading days, GitHub-style.
struct Heatmap: View {
    let activity: [String: Int]
    private let weeks = 52

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1) - (cal.component(.weekday, from: today) - 1), to: today)!
        let maxCount = max(1, activity.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<weeks + 1, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let count = activity[SQLDate.dayKey(day)] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(day > today ? Color.clear : count == 0 ? Theme.raised : Theme.accent.opacity(0.3 + 0.7 * Double(count) / Double(maxCount)))
                                .frame(width: 10, height: 10)
                                .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(count == 0 ? "no reading" : "\(count) reading \(count == 1 ? "event" : "events")")")
                        }
                    }
                }
            }
            Text("\(activity.count) days with reading in the past year").font(.caption2).foregroundStyle(Theme.textTertiary)
        }
    }
}

struct YearInReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var years: [Int] = []
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var review: YearInReview?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Year in Review").font(.title3.bold())
                Spacer()
                if years.count > 1 {
                    Picker("", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }.fixedSize().labelsHidden()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            if let r = review {
                ScrollView {
                    VStack(spacing: 22) {
                        Text("\(String(r.year)) in Comics").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(Theme.accent)
                        HStack(spacing: 14) {
                            big("\(r.finished)", "issues read")
                            big(r.pages.formatted(), "pages")
                            big("\(r.daysRead)", "days reading")
                            big("\(r.longestStreak)", "day best streak")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if let s = r.topSeries { fact("Most-read series", "\(s.name) · \(s.count) issues") }
                            if let p = r.topPublisher { fact("Favorite publisher", "\(p.name) · \(p.count) issues") }
                            if let m = r.busiestMonth { fact("Busiest month", "\(m.name) · \(m.count) issues") }
                            if let f = r.firstFinished { fact("First finished", f.title) }
                            if let l = r.lastFinished, l.id != r.firstFinished?.id { fact("Most recent", l.title) }
                        }
                        .frame(maxWidth: 460)
                        if r.finished == 0 { Text("No finished issues in \(String(r.year)) yet.").foregroundStyle(Theme.textSecondary) }
                    }
                    .padding(26)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 560)
        .task { years = (try? await Database.shared.activeYears()) ?? []; if let first = years.first, !years.contains(year) { year = first } }
        .task(id: year) { review = try? await Database.shared.yearInReview(year) }
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 28, weight: .black, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).fontWeight(.semibold).lineLimit(1)
        }
        .font(.callout)
    }
}
