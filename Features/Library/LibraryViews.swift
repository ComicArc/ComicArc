import SwiftUI

// MARK: - Home

struct LibraryHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var inProgress: [Comic] = []
    @State private var upNext: [Comic] = []
    @State private var groups: [CharacterGroup] = []
    @State private var recent: [Comic] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if let current = inProgress.first { NowReadingHero(comic: current) }
                if inProgress.count > 1 { Shelf(title: "Continue Reading", comics: Array(inProgress.dropFirst())) }
                if !upNext.isEmpty { Shelf(title: "Up Next", comics: upNext, caption: "The next issue of series you're reading") }
                if !groups.isEmpty { SurpriseBanner() }
                if !recent.isEmpty { Shelf(title: "Recently Added", comics: recent) }
                ForEach(groupedByPublisher, id: \.0) { publisher, items in
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: publisher, trailing: "\(items.count) \(items.count == 1 ? "character" : "characters")")
                        GroupGrid(groups: items)
                    }
                }
                if loaded && groups.isEmpty {
                    EmptyState(icon: "books.vertical", title: "Your library is empty",
                               message: "Scan your library folder, or drop comic files anywhere in this window.",
                               action: ("Scan Now", { model.rescan() }))
                }
            }
            .padding(Theme.gutter)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task(id: model.revision) {
            async let a = Database.shared.comics(ComicFilter(inProgressOnly: true, limit: 12))
            async let b = Database.shared.upNext()
            async let c = Database.shared.characterGroups(publisher: nil)
            async let d = Database.shared.recentlyAdded()
            recent = (try? await d) ?? []
            inProgress = (try? await a) ?? []
            upNext = (try? await b) ?? []
            groups = (try? await c) ?? []
            loaded = true
        }
    }

    private var groupedByPublisher: [(String, [CharacterGroup])] {
        var order: [String] = []
        var map: [String: [CharacterGroup]] = [:]
        for g in groups {
            if map[g.publisher] == nil { order.append(g.publisher) }
            map[g.publisher, default: []].append(g)
        }
        return order.map { ($0, map[$0]!) }
    }
}

/// The comic you're reading right now, large, over a blurred copy of its cover.
struct NowReadingHero: View {
    let comic: Comic
    @Environment(AppModel.self) private var model
    @State private var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            CoverImage(comic).coverFrame(width: 168)
                .shadow(color: tint.opacity(0.45), radius: 22, y: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("NOW READING").font(.signage(12)).kerning(1.8).foregroundStyle(Theme.accent)
                Text(comic.title).font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(comic.series).font(.headline).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressLine(value: comic.progress, color: tint).frame(maxWidth: 280)
                    Text("Page \(comic.currentPage + 1) of \(comic.pageCount)").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 4)
                HStack(spacing: 10) {
                    Button { model.open(comic) } label: { Label("Continue Reading", systemImage: "book.fill") }
                        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    Button("Details") { model.path.append(.comic(comic.id)) }.buttonStyle(QuietButtonStyle())
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                CoverImage(comic).scaledToFill().blur(radius: 50).opacity(0.55)
                LinearGradient(colors: [Theme.background.opacity(0.4), Theme.background.opacity(0.95)], startPoint: .leading, endPoint: .trailing)
            }
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        .task(id: comic.id) {
            if let c = await CoverStore.shared.accentColor(id: comic.id, path: comic.filePath) { tint = Color(nsColor: c) }
        }
    }
}

/// Picks the first issue of a series you haven't started, for when you can't decide.
struct SurpriseBanner: View {
    @Environment(AppModel.self) private var model
    @State private var pick: Comic?
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 18) {
            if let pick {
                CoverImage(pick).coverFrame(width: 74).id(pick.id).transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "dice.fill").font(.system(size: 34)).foregroundStyle(Theme.accentGradient).frame(width: 74)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("CAN'T DECIDE?").font(.signage(11)).kerning(1.6).foregroundStyle(Theme.accent)
                Text(pick.map { "Try \($0.series)" } ?? "Start a series you haven't read yet")
                    .font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(pick.map { "\($0.publisher) · starts with \($0.shortLabel)" } ?? "ComicArc picks the first issue of a random series you haven't started.")
                    .font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { roll() } label: { Label(pick == nil ? "Surprise Me" : "Another", systemImage: "dice") }
                .buttonStyle(QuietButtonStyle())
            if let pick {
                Button { model.open(pick) } label: { Label("Read It", systemImage: "book.fill") }.buttonStyle(AccentButtonStyle())
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }

    private func roll() {
        Task {
            let next = try? await Database.shared.surprise()
            withAnimation(.easeOut(duration: 0.25)) { pick = next }
        }
    }
}

struct Shelf: View {
    let title: String
    let comics: [Comic]
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title, trailing: caption)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(comics) { ComicCard(comic: $0, width: 120, showSeries: true) }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Groups

struct GroupGrid: View {
    let groups: [CharacterGroup]
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 22)], alignment: .leading, spacing: 26) {
            ForEach(groups) { g in
                GroupCard(title: g.name, subtitle: "\(g.count) issue\(g.count == 1 ? "" : "s")",
                          coverID: g.coverComicID, customCover: g.customCoverPath, finished: g.finished, total: g.count)
                    .onTapGesture { model.path.append(.group(g)) }
                    .contextMenu {
                        Button("Choose Cover Image…") { pickCover(for: g) }
                        if g.customCoverPath != nil {
                            Button("Use Default Cover") {
                                model.perform { try await $0.setCharacterCover(group: g.name, publisher: g.publisher, imagePath: nil) }
                            }
                        }
                    }
            }
        }
    }

    private func pickCover(for g: CharacterGroup) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = "chargroup_\(g.publisher)_\(g.name)".replacingOccurrences(of: "/", with: "-")
        guard let path = CoverStore.shared.importCustomImage(from: url, name: name) else {
            model.showToast("That image couldn't be read.", isError: true); return
        }
        Task { await CoverStore.shared.invalidateFile(path) }
        model.perform { try await $0.setCharacterCover(group: g.name, publisher: g.publisher, imagePath: path) }
    }
}

/// A cover with a name, issue count and how much of it you've read.
struct GroupCard: View {
    let title: String
    let subtitle: String
    let coverID: Int64
    let customCover: String?
    let finished: Int
    let total: Int
    var width: CGFloat = 150
    @State private var path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if let path { CoverImage(comicID: coverID, path: path, customPath: customCover) } else { Theme.raised }
            }
            .coverFrame(width: width)
            .overlay(alignment: .bottom) {
                if finished > 0 && total > 0 { ProgressLine(value: Double(finished) / Double(total), color: Theme.finished).padding(6) }
            }
            .hoverLift()
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Text(finished > 0 ? "\(subtitle) · \(finished) read" : subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: coverID) {
            path = try? await Database.shared.read { db in try db.scalarString("SELECT file_path FROM comics WHERE id = ?", [coverID]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct PublisherView: View {
    let publisher: String
    @Environment(AppModel.self) private var model
    @State private var groups: [CharacterGroup] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: publisher, subtitle: "\(groups.reduce(0) { $0 + $1.count }) issues")
                GroupGrid(groups: groups)
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .task(id: "\(publisher)-\(model.revision)") { groups = (try? await Database.shared.characterGroups(publisher: publisher)) ?? [] }
    }
}

struct SeriesGridView: View {
    let group: CharacterGroup
    @Environment(AppModel.self) private var model
    @State private var series: [SeriesGroup] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: group.name, subtitle: "\(group.publisher) · \(series.count) series · \(series.reduce(0) { $0 + $1.count }) issues")
                ForEach(sections, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 14) {
                        if sections.count > 1 { SectionTitle(text: title, trailing: "\(items.count) series") }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 22)], alignment: .leading, spacing: 26) {
                            ForEach(items) { s in
                                GroupCard(title: s.series, subtitle: "\(s.count) issue\(s.count == 1 ? "" : "s")", coverID: s.coverComicID,
                                          customCover: s.customCoverPath, finished: s.finished, total: s.count)
                                    .onTapGesture { model.path.append(.series(s)) }
                                    .contextMenu { SeriesMenu(series: s) }
                            }
                        }
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle(group.name)
        .task(id: model.revision) { series = (try? await Database.shared.seriesGroups(group: group.name, publisher: group.publisher)) ?? [] }
    }

    /// Series grouped by the folder between character and series (e.g. Classic / Modern).
    private var sections: [(String, [SeriesGroup])] {
        let groups = Dictionary(grouping: series) { $0.folderGroup ?? "" }
        guard groups.count > 1 else { return [("", series)] }
        return groups.keys.sorted { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }.map { ($0.isEmpty ? "Other" : $0, groups[$0]!) }
    }
}

struct SeriesMenu: View {
    let series: SeriesGroup
    @Environment(AppModel.self) private var model
    var body: some View {
        Button("Read from the Beginning") {
            Task { if let first = try? await Database.shared.comics(ComicFilter(publisher: series.publisher, series: series.series, limit: 1)).first { model.open(first) } }
        }
        Button("Mark Series as Read") {
            Task { if let all = try? await Database.shared.comics(ComicFilter(publisher: series.publisher, series: series.series)) { model.markRead(all) } }
        }
        Menu("Add Series to Reading Path") {
            ForEach(model.readingPaths.filter { !$0.isReadingList }) { p in
                Button(p.title) { addAll { model.addToPath($0, pathID: p.id, title: p.title) } }
            }
            Divider()
            Button("New Reading Path…") {
                NewPathPrompt.ask(initial: series.series) { title in addAll { model.addToNewPath($0, title: title) } }
            }
        }
    }
    private func addAll(_ action: @escaping ([Comic]) -> Void) {
        Task { if let all = try? await Database.shared.comics(ComicFilter(publisher: series.publisher, series: series.series)) { action(all) } }
    }
}

// MARK: - Issues

struct IssueListView: View {
    let series: SeriesGroup
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.sortOrder) private var sortRaw = SortOrder.issue.rawValue
    @AppStorage(Prefs.hideFinished) private var hideFinished = false
    @State private var comics: [Comic] = []
    @State private var missing: [Int] = []
    @State private var managing = false

    private var resume: Comic? {
        comics.first(where: \.isInProgress) ?? comics.first(where: { !$0.isFinished }) ?? comics.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    ScreenHeader(title: series.series, subtitle: subtitle)
                    Spacer()
                    if let resume {
                        Button { model.open(resume) } label: {
                            Label(resume.isInProgress ? "Continue \(resume.shortLabel)" : (comics.contains(where: \.isFinished) ? "Read \(resume.shortLabel)" : "Start Reading"),
                                  systemImage: "book.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                    }
                    Button("Manage Series") { managing = true }.buttonStyle(QuietButtonStyle())
                }
                if !missing.isEmpty {
                    Label("Missing from your library: " + missing.prefix(8).map { "#\($0)" }.joined(separator: ", ") + (missing.count > 8 ? "…" : ""),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                GridControls(sortRaw: $sortRaw, hideFinished: $hideFinished)
                ComicGrid(comics: comics)
                if comics.isEmpty && hideFinished {
                    EmptyState(icon: "checkmark.circle", title: "You've read every issue", message: "Turn off Hide Read to see them.")
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, model.selecting ? 80 : 0)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { if model.selecting { SelectionBar(visible: comics).padding(.bottom, 16) } }
        .navigationTitle(series.series)
        .sheet(isPresented: $managing) { SeriesManagerView(series: series) }
        .task(id: "\(sortRaw)-\(hideFinished)-\(model.revision)") {
            comics = (try? await Database.shared.comics(ComicFilter(publisher: series.publisher, series: series.series, unreadOnly: hideFinished,
                                                                    sort: SortOrder(rawValue: sortRaw) ?? .issue))) ?? []
            missing = (try? await Database.shared.missingIssues(series: series.series, publisher: series.publisher)) ?? []
        }
    }

    private var subtitle: String {
        let read = comics.filter(\.isFinished).count
        return "\(series.publisher) · \(series.count) issues" + (read > 0 ? " · \(read) read" : "")
    }
}

struct GridControls: View {
    @Binding var sortRaw: String
    @Binding var hideFinished: Bool
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.gridDensity) private var densityRaw = GridDensity.regular.rawValue

    var body: some View {
        HStack(spacing: 14) {
            Picker("Sort", selection: $sortRaw) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .fixedSize()
            Toggle("Hide Read", isOn: $hideFinished).toggleStyle(.checkbox)
            Spacer()
            Picker("Size", selection: $densityRaw) {
                Image(systemName: "square.grid.3x3").tag(GridDensity.compact.rawValue)
                Image(systemName: "square.grid.2x2").tag(GridDensity.regular.rawValue)
                Image(systemName: "rectangle.grid.1x2").tag(GridDensity.large.rawValue)
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            .help("Cover size")
            Button(model.selecting ? "Done" : "Select") { model.selecting ? model.endSelection() : (model.selecting = true) }
                .buttonStyle(QuietButtonStyle())
        }
        .font(.callout)
    }
}

struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary) }
        }
    }
}

/// Continue Reading, Favorites and tag screens.
struct ComicListScreen: View {
    let title: String
    let filter: ComicFilter
    let empty: (icon: String, title: String, message: String?)
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.sortOrder) private var sortRaw = SortOrder.issue.rawValue
    @AppStorage(Prefs.hideFinished) private var hideFinished = false
    @State private var comics: [Comic] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: title, subtitle: loaded ? "\(comics.count) comic\(comics.count == 1 ? "" : "s")" : nil)
                if !filter.inProgressOnly { GridControls(sortRaw: $sortRaw, hideFinished: $hideFinished) }
                if loaded && comics.isEmpty {
                    EmptyState(icon: empty.icon, title: empty.title, message: empty.message).frame(minHeight: 360)
                } else {
                    ComicGrid(comics: comics, showSeries: true)
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, model.selecting ? 80 : 0)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { if model.selecting { SelectionBar(visible: comics).padding(.bottom, 16) } }
        .task(id: "\(filter.hashValue)-\(sortRaw)-\(hideFinished)-\(model.revision)") {
            var f = filter
            if !f.inProgressOnly { f.sort = SortOrder(rawValue: sortRaw) ?? .issue; f.unreadOnly = hideFinished }
            comics = (try? await Database.shared.comics(f)) ?? []
            loaded = true
        }
    }
}

struct SearchResultsView: View {
    let query: String
    let publisher: String?
    @Environment(AppModel.self) private var model
    @State private var comics: [Comic] = []
    @State private var groups: [CharacterGroup] = []
    @State private var series: [SeriesGroup] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Results for “\(query)”", subtitle: loaded ? "\(comics.count) comic\(comics.count == 1 ? "" : "s") in \(series.count) series" : "Searching…")
                if !series.isEmpty && series.count <= 12 {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: "Series")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(series) { s in
                                    GroupCard(title: s.series, subtitle: "\(s.count) issue\(s.count == 1 ? "" : "s")", coverID: s.coverComicID,
                                              customCover: nil, finished: 0, total: s.count, width: 120)
                                        .onTapGesture {
                                            model.searchText = ""
                                            model.path = [.group(CharacterGroup(name: s.groupName, character: nil, publisher: s.publisher, count: 0,
                                                                                coverComicID: s.coverComicID, customCoverPath: nil, started: 0, finished: 0)),
                                                          .series(s)]
                                        }
                                }
                            }
                        }
                    }
                }
                if !groups.isEmpty && groups.count <= 12 {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: "Characters")
                        GroupGrid(groups: groups)
                    }
                }
                if !comics.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: "Comics", trailing: comics.count >= 500 ? "First 500 shown — add more words to narrow it down" : nil)
                        ComicGrid(comics: comics, showSeries: true)
                    }
                }
                if loaded && comics.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "No matches",
                               message: "Search looks at titles, series, characters, publishers, folders such as “Classic”, issue numbers, years, credits and tags. Every word must match.")
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, model.selecting ? 80 : 0)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { if model.selecting { SelectionBar(visible: comics).padding(.bottom, 16) } }
        .task(id: "\(query)-\(publisher ?? "")-\(model.revision)") {
            try? await Task.sleep(for: .milliseconds(180))   // debounce typing
            guard !Task.isCancelled else { return }
            async let c = Database.shared.comics(ComicFilter(publisher: publisher, search: query, limit: 500))
            async let g = Database.shared.characterGroups(publisher: publisher, search: query)
            async let s = Database.shared.seriesMatching(query)
            series = ((try? await s) ?? []).filter { publisher == nil || $0.publisher == publisher }
            comics = (try? await c) ?? []
            groups = (try? await g) ?? []
            loaded = true
        }
    }
}
