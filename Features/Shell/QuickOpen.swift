import SwiftUI

/// ⌘K: type a few letters and jump straight to a series, comic, Reading Path or screen.
struct QuickOpen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Result] = []
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Result: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let comic: Comic?
        let action: @MainActor (AppModel) -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Jump to a series, comic, path or screen…", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused)
                        .onSubmit { run(selected) }
                    Text("esc").font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                                    row(r, highlighted: i == selected)
                                        .id(i)
                                        .onTapGesture { run(i) }
                                        .onHover { if $0 { selected = i } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: selected) { _, i in proxy.scrollTo(i) }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .frame(width: 620)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            results = await search(query)
            selected = 0
        }
    }

    private func row(_ r: Result, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            if let comic = r.comic {
                CoverImage(comic).frame(width: 26, height: 39).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: r.icon).frame(width: 26).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(r.subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if highlighted { Image(systemName: "return").font(.caption).foregroundStyle(Theme.textTertiary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func run(_ index: Int) {
        guard results.indices.contains(index) else { return }
        let action = results[index].action
        close()
        action(model)
    }

    private func close() { model.quickOpen = false }

    private func search(_ text: String) async -> [Result] {
        let q = text.trimmed
        let screens: [(SidebarItem, String)] = [(.home, "books.vertical"), (.continueReading, "book"), (.favorites, "heart"),
                                                (.paths, "point.topleft.down.to.point.bottomright.curvepath"),
                                                (.highlights, "star"), (.stats, "chart.bar"), (.health, "stethoscope")]
        let screenResults = screens.filter { q.isEmpty || $0.0.title.localizedCaseInsensitiveContains(q) }.map { item, icon in
            Result(id: "s-\(item.title)", title: item.title, subtitle: "Screen", icon: icon, comic: nil) { $0.sidebar = item }
        }
        guard !q.isEmpty else {
            let recent = (try? await Database.shared.comics(ComicFilter(sort: .recentlyRead, limit: 6))) ?? []
            return recent.filter { $0.lastRead != nil }.map(comicResult) + screenResults
        }
        let series = (try? await Database.shared.seriesMatching(q)) ?? []
        let comics = (try? await Database.shared.comics(ComicFilter(search: q, limit: 12))) ?? []
        let paths = model.readingPaths.filter { $0.title.localizedCaseInsensitiveContains(q) }
        return series.prefix(6).map { s in
            Result(id: "r-\(s.id)", title: s.series, subtitle: "Series · \(s.publisher) · \(s.count) issues", icon: "books.vertical", comic: nil) { m in
                m.sidebar = .home
                m.path = [.group(CharacterGroup(name: s.groupName, character: nil, publisher: s.publisher, count: 0,
                                                coverComicID: s.coverComicID, customCoverPath: nil, started: 0, finished: 0)), .series(s)]
            }
        }
        + paths.map { p in
            Result(id: "p-\(p.id)", title: p.title, subtitle: "Reading Path · \(p.count) comics", icon: "point.topleft.down.to.point.bottomright.curvepath", comic: nil) { m in
                m.sidebar = .paths; m.path = [.path(p.id)]
            }
        }
        + comics.map(comicResult) + screenResults
    }

    private func comicResult(_ c: Comic) -> Result {
        Result(id: "c-\(c.id)", title: c.title, subtitle: c.isInProgress ? "Continue · page \(c.currentPage + 1) of \(c.pageCount)" : c.series,
               icon: "book", comic: c) { $0.open(c) }
    }
}

extension Database {
    /// Series whose name (or publisher/character/era) matches every word of `query`.
    func seriesMatching(_ query: String) async throws -> [SeriesGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return try await read { db in
            var conds = ["c.deleted_at IS NULL"]
            var args: [SQLBindable?] = []
            for w in words {
                conds.append("(c.series LIKE ? ESCAPE '\\' OR c.publisher LIKE ? ESCAPE '\\' OR c.character LIKE ? ESCAPE '\\' OR c.folder_group LIKE ? ESCAPE '\\')")
                args += Array(repeating: "%\(ComicSQL.likeEscaped(w))%", count: 4)
            }
            return try db.query("""
                SELECT c.series, c.publisher, \(ComicSQL.groupName), COUNT(*), MIN(c.id), MAX(c.folder_group)
                FROM comics c WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.publisher, c.series ORDER BY (c.series LIKE ?) DESC, COUNT(*) DESC LIMIT 12
                """, args + ["\(ComicSQL.likeEscaped(words[0]))%"]) { r in
                SeriesGroup(series: r.string(0) ?? "", publisher: r.string(1) ?? "", groupName: r.string(2) ?? "",
                            count: r.int(3), coverComicID: r.int64(4), customCoverPath: nil, started: 0, finished: 0, folderGroup: r.string(5))
            }
        }
    }
}
