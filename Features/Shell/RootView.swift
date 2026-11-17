import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
                } detail: {
                    NavigationStack(path: $model.path) {
                        SectionView(item: model.sidebar)
                            .navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) { Breadcrumbs() }
                    .background(Theme.background)
                }
                .modifier(LibrarySearch())
                .toolbar { MainToolbar() }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
                .overlay { if dropTargeted { DropHighlight() } }
            }

            if model.quickOpen && model.reader == nil {
                QuickOpen().transition(.opacity).zIndex(5)
            }

            if let launch = model.reader {
                ReaderView(launch: launch)
                    .id(launch.id)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 28) }
        .animation(.easeOut(duration: 0.2), value: model.reader)
        .animation(.easeOut(duration: 0.12), value: model.quickOpen)
        .preferredColorScheme(model.reader == nil ? Theme.scheme : .dark)
        .onChange(of: model.reader) { _, launch in columns = launch == nil ? .all : .detailOnly }
        .onChange(of: model.searchText) { _, text in
            if !text.isEmpty, model.reader == nil { model.path = [] }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let fileURL = URL(dataRepresentation: url, relativeTo: nil) { urls.append(fileURL) }
            }
            model.importFiles(urls)
        }
        return true
    }
}

/// The root screen for a sidebar item.
struct SectionView: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty,
               item == .home || { if case .publisher = item { return true }; return false }() {
                SearchResultsView(query: model.searchText, publisher: { if case .publisher(let p) = item { return p }; return nil }())
            } else {
                switch item {
                case .home: LibraryHomeView()
                case .publisher(let p): PublisherView(publisher: p)
                case .continueReading: ComicListScreen(title: "Continue Reading", filter: ComicFilter(inProgressOnly: true),
                                                       empty: ("book", "Nothing in progress", "Comics you've started show up here."))
                case .favorites: ComicListScreen(title: "Favorites", filter: ComicFilter(favoritesOnly: true),
                                                 empty: ("heart", "No favorites yet", "Right-click any comic and choose Favorite."))
                case .tag(let t): ComicListScreen(title: "#\(t)", filter: ComicFilter(tag: t),
                                                  empty: ("tag", "Nothing tagged #\(t)", nil))
                case .era(let e): ComicListScreen(title: e, filter: ComicFilter(era: e),
                                                  empty: ("tag", "No \(e) comics", nil))
                case .paths: ReadingPathsView()
                case .highlights: HighlightsView()
                case .stats: StatsView()
                case .health: HealthView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationTitle(item.title)
    }
}

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .group(let g): SeriesGridView(group: g)
        case .series(let s): IssueListView(series: s)
        case .comic(let id): IssueDetailView(comicID: id)
        case .path(let id): PathDetailView(pathID: id)
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .help("Back (⌘[)").disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .help("Forward (⌘])").disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.scan.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.scan.total > 0 ? "\(model.scan.done) / \(model.scan.total)" : (model.scan.message ?? "Scanning…"))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    Button("Stop") { model.cancelScan() }.controlSize(.small)
                }
            } else {
                Button { model.rescan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .help("Scan your library folders for new comics (⇧⌘R)")
                    .disabled(model.folders.isEmpty)
            }
            Button { ImportPanel.run(model) } label: { Label("Import", systemImage: "plus") }
                .help("Import comic files (⌘O)")
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 14) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Theme.danger : Theme.accent)
                Text(toast.message).font(.callout).foregroundStyle(.white).lineLimit(2)
                if toast.undo != nil {
                    Button("Undo") { model.undoToast() }.buttonStyle(.plain).font(.callout.bold()).foregroundStyle(Theme.accent)
                }
                Button { model.toast = nil } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Theme.accent.opacity(0.06))
            .overlay(Label("Drop comics to add them", systemImage: "plus.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.accent))
            .padding(12)
            .allowsHitTesting(false)
    }
}


/// "Library › Batman › Batman (1940)": where you are, with every level clickable.
struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model
    @State private var comicTitles: [Int64: String] = [:]

    var body: some View {
        if !model.path.isEmpty {
            HStack(spacing: 6) {
                crumb(model.sidebar.title, depth: 0)
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, route in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    crumb(title(route), depth: index + 1, current: index == model.path.count - 1)
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8)
            .background(Theme.background.opacity(0.92))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .task(id: model.path) {
                for case .comic(let id) in model.path where comicTitles[id] == nil {
                    comicTitles[id] = (try? await Database.shared.comic(id: id))?.title
                }
            }
        }
    }

    private func crumb(_ text: String, depth: Int, current: Bool = false) -> some View {
        Button(text) { model.pop(to: depth) }
            .buttonStyle(.plain)
            .foregroundStyle(current ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .disabled(current)
    }

    private func title(_ route: Route) -> String {
        switch route {
        case .group(let g): g.name
        case .series(let s): s.series
        case .comic(let id): comicTitles[id] ?? "Issue"
        case .path(let id): model.readingPaths.first { $0.id == id }?.title ?? "Reading Path"
        }
    }
}

/// The toolbar search field: filters the library as you type, suggests recent searches, eras,
/// publishers, series and characters, and remembers what you searched for.
struct LibrarySearch: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage("recentSearches") private var recentJSON = "[]"
    @State private var suggestions: [String] = []
    @State private var focused = false

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentJSON.utf8))) ?? [] }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search comics, series, eras…")
            .searchSuggestions {
                let query = model.searchText.trimmed
                if query.isEmpty {
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent, id: \.self) { r in Label(r, systemImage: "clock.arrow.circlepath").searchCompletion(r) }
                        }
                    }
                    if !model.eras.isEmpty {
                        Section("Eras") {
                            ForEach(model.eras, id: \.name) { e in Label("\(e.name)  ·  \(e.count)", systemImage: "tag").searchCompletion(e.name) }
                        }
                    }
                    Section("Publishers") {
                        ForEach(model.publishers, id: \.self) { p in Label(p, systemImage: "building.2").searchCompletion(p) }
                    }
                } else {
                    ForEach(suggestions, id: \.self) { s in Label(s, systemImage: "books.vertical").searchCompletion(s) }
                }
            }
            .onSubmit(of: .search) { remember(model.searchText) }
            .task(id: model.searchText) {
                let q = model.searchText.trimmed
                guard !q.isEmpty else { suggestions = []; return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                let series = (try? await Database.shared.seriesMatching(q)) ?? []
                var names: [String] = []
                for s in series where !names.contains(s.series) && s.series.lowercased() != q.lowercased() { names.append(s.series) }
                for s in series where !names.contains(s.groupName) && s.groupName != s.series && s.groupName.lowercased() != q.lowercased() { names.append(s.groupName) }
                suggestions = Array(names.prefix(8))
                // Remember searches you stay on, not every keystroke.
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { remember(q) }
            }
    }

    private func remember(_ query: String) {
        let q = query.trimmed
        guard q.count >= 2 else { return }
        var list = recent.filter { $0.lowercased() != q.lowercased() }
        list.insert(q, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(6))) { recentJSON = String(decoding: data, as: UTF8.self) }
    }
}