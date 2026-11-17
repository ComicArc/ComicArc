import SwiftUI

struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ReaderModel
    @State private var showTop = false
    @State private var showBottom = false
    @State private var filmstrip = false
    @State private var help = false
    @State private var bookmarksOpen = false
    @State private var pageField = ""
    @State private var showCounter = false
    @State private var counterTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(launch: ReaderLaunch) { _model = State(initialValue: ReaderModel(launch: launch)) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                content(geo.size)
                VStack(spacing: 0) {
                    if showTop || model.loading && model.images.isEmpty { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer()
                    if filmstrip { Filmstrip(model: model).transition(.move(edge: .bottom).combined(with: .opacity)) }
                    if showBottom || filmstrip { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                if model.autoplay {
                    VStack { Spacer(); ProgressLine(value: model.autoplayProgress).frame(height: 3) }.allowsHitTesting(false)
                } else if !showBottom && !filmstrip && model.pageCount > 1 {
                    // Where you are in the issue, without any controls on screen.
                    VStack {
                        Spacer()
                        ProgressLine(value: Double(model.page + 1) / Double(model.pageCount), color: Theme.accent.opacity(0.55))
                            .frame(height: 2)
                    }
                    .allowsHitTesting(false)
                }
                if showCounter && !showBottom {
                    VStack {
                        Spacer()
                        Text("\(model.page + 1) / \(model.pageCount)")
                            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 14)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if let notice = model.notice { NoticePill(text: notice) }
                if model.justFinished { FinishedCard(model: model) }
            }
            .onContinuousHover { phase in
                var top = false, bottom = false
                if case .active(let p) = phase { top = p.y < 80; bottom = p.y > geo.size.height - 120 }
                if top != showTop || bottom != showBottom {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showTop = top; showBottom = bottom }
                }
            }
            .onChange(of: geo.size, initial: true) { _, size in
                model.setViewport(size, scale: NSScreen.main?.backingScaleFactor ?? 2)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            focused = true
            model.onOpenComic = { comic in app.reader = ReaderLaunch(comic: comic, page: nil, pathID: model.pathID) }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        .task { await model.open() }
        .onDisappear { Task { await model.close() } }
        .onReceive(NotificationCenter.default.publisher(for: .showReaderHelp)) { _ in help = true }
        .onChange(of: model.page) {
            // A brief page counter after each turn; the cursor hides until the mouse moves.
            NSCursor.setHiddenUntilMouseMoves(true)
            withAnimation(.easeOut(duration: 0.12)) { showCounter = true }
            counterTask?.cancel()
            counterTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.3)) { showCounter = false } }
            }
        }
        .sheet(isPresented: $help) { ReaderHelp() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func content(_ size: CGSize) -> some View {
        if model.failed {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(model.pageCount == 0 ? "This comic couldn't be opened." : "Page \(model.page + 1) couldn't be loaded.")
                    .foregroundStyle(.white)
                HStack {
                    if model.pageCount > 0 { Button("Try Again") { model.retry() } }
                    Button("Close") { close() }
                }
            }
        } else if model.scrollMode, let renderer = model.renderer {
            ScrollPages(model: model, renderer: renderer, width: size.width)
        } else if !model.images.isEmpty {
            PageCanvas(images: displayed, fitMode: model.fitMode, filter: model.colorFilter, zoom: $model.zoom,
                       forward: model.movedForward != model.rightToLeft,
                       onSwipe: { towardNext in towardNext != model.rightToLeft ? model.next() : model.previous() },
                       onSideClick: { right in right != model.rightToLeft ? model.next() : model.previous() },
                       onZoomEnd: { model.zoomChanged($0) })
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    /// Right-to-left spreads show the later page on the left.
    private var displayed: [CGImage] { model.rightToLeft ? model.images.reversed() : model.images }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 14) {
            iconButton("xmark", "Close (Esc)") { close() }
            Divider().frame(height: 18)
            iconButton("chevron.left.2", model.previousIssue.map { "Previous: \($0.title)" } ?? "No previous issue") {
                if let p = model.previousIssue { app.reader = ReaderLaunch(comic: p, page: nil, pathID: model.pathID) }
            }
            .disabled(model.previousIssue == nil)
            VStack(spacing: 1) {
                Text(model.comic.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(model.comic.series).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: 460)
            iconButton("chevron.right.2", model.nextIssue.map { "Next: \($0.title)" } ?? "No next issue") {
                if let n = model.nextIssue { app.reader = ReaderLaunch(comic: n, page: nil, pathID: model.pathID) }
            }
            .disabled(model.nextIssue == nil)
            Spacer()
            iconButton(model.isBookmarked ? "bookmark.fill" : "bookmark", "Bookmark page (B)", active: model.isBookmarked) { model.toggleBookmark() }
            iconButton(model.isHighlighted ? "star.fill" : "star", "Add page to Highlights (H)", active: model.isHighlighted) { model.toggleHighlight() }
            Button { bookmarksOpen.toggle() } label: { Image(systemName: "list.bullet").font(.title3) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(model.bookmarks.isEmpty ? 0.4 : 0.9))
                .help("Bookmarks")
                .popover(isPresented: $bookmarksOpen) { BookmarksPopover(model: model) }
            settingsMenu
            iconButton(model.autoplay ? "pause.fill" : "play.fill", "Autoplay (A)", active: model.autoplay) { model.toggleAutoplay() }
                .disabled(model.scrollMode)
            iconButton("questionmark.circle", "Keyboard shortcuts (?)") { help = true }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Fit", selection: $model.fitMode) {
                ForEach(FitMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            Toggle("Two-Page Spreads (D)", isOn: $model.doublePage).disabled(model.scrollMode)
            Toggle("Continuous Scroll", isOn: $model.scrollMode)
            Toggle("Right to Left (R)", isOn: $model.rightToLeft)
            Picker("Color", selection: $model.colorFilter) {
                ForEach(ColorFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Autoplay Speed", selection: $model.autoplaySeconds) {
                ForEach([3.0, 5, 6, 8, 10, 15], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
        } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.white.opacity(0.9))
        .help("Reading settings")
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            iconButton(model.rightToLeft ? "chevron.right" : "chevron.left", "Previous page") { model.rightToLeft ? model.next() : model.previous() }
            if model.pageCount > 1 {
                Slider(value: Binding(get: { Double(model.page) }, set: { model.jump(to: Int($0.rounded())) }),
                       in: 0...Double(max(1, model.pageCount - 1)))
                    .tint(Theme.accent)
                    .environment(\.layoutDirection, model.rightToLeft ? .rightToLeft : .leftToRight)
                    .accessibilityLabel("Page")
                    .accessibilityValue("\(model.page + 1) of \(model.pageCount)")
            }
            TextField("", text: $pageField)
                .textFieldStyle(.plain).multilineTextAlignment(.center).font(.callout.monospacedDigit())
                .frame(width: 44).padding(.vertical, 3)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                .onSubmit { if let n = Int(pageField) { model.jump(to: n - 1) }; focused = true }
                .onChange(of: model.page, initial: true) { _, p in pageField = "\(p + 1)" }
                .help("Type a page number and press Return")
            Text("of \(model.pageCount)").font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            Text(model.pagesLeft == 0 ? "Last page" : "\(model.pagesLeft) left")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45)).frame(minWidth: 52, alignment: .leading)
            iconButton("square.grid.3x3", "Page thumbnails (G)", active: filmstrip) {
                withAnimation(.easeOut(duration: 0.15)) { filmstrip.toggle() }
            }
            iconButton(model.rightToLeft ? "chevron.left" : "chevron.right", "Next page") { model.rightToLeft ? model.previous() : model.next() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func iconButton(_ icon: String, _ help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3).frame(width: 26, height: 26) }
            .buttonStyle(.plain)
            .foregroundStyle(active ? Theme.accent : .white.opacity(0.9))
            .help(help)
            .accessibilityLabel(help)
    }

    // MARK: - Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let forward = { model.next() }, backward = { model.previous() }
        switch press.key {
        case .rightArrow: model.rightToLeft ? backward() : forward()
        case .leftArrow: model.rightToLeft ? forward() : backward()
        case .downArrow, .pageDown: forward()
        case .upArrow, .pageUp: backward()
        case .space: press.modifiers.contains(.shift) ? backward() : forward()
        case .home: model.jump(to: 0)
        case .end: model.jump(to: model.pageCount - 1)
        case .escape:
            if model.autoplay { model.autoplay = false } else if filmstrip { filmstrip = false } else { close() }
        default:
            switch press.characters.lowercased() {
            case "a": model.toggleAutoplay()
            case "b": model.toggleBookmark()
            case "h": model.toggleHighlight()
            case "d": if !model.scrollMode { model.doublePage.toggle() }
            case "r": model.rightToLeft.toggle()
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "g": withAnimation(.easeOut(duration: 0.15)) { filmstrip.toggle() }
            case "=", "+": model.zoom = min(5, model.zoom * 1.25); model.zoomChanged(model.zoom)
            case "-": model.zoom = max(1, model.zoom / 1.25)
            case "0": model.zoom = 1
            case "w": close()
            case "?", "/": help = true
            default: return .ignored
            }
        }
        return .handled
    }

    private func close() {
        Task { await model.close() }
        app.closeReader()
    }
}

// MARK: - Pieces

private struct NoticePill: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.callout.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 90)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct FinishedCard: View {
    let model: ReaderModel
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.finished)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finished “\(model.comic.title)”").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    if let next = model.nextIssue { Text("Up next: \(next.title)").font(.caption).foregroundStyle(.white.opacity(0.65)) }
                }
                if let next = model.nextIssue {
                    Button("Read Next") { app.reader = ReaderLaunch(comic: next, page: nil, pathID: model.pathID) }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 90)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct Filmstrip: View {
    let model: ReaderModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(0..<model.pageCount, id: \.self) { p in
                        if let renderer = model.renderer {
                            PageThumb(renderer: renderer, page: p, width: 58)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: p == model.page ? 2 : 0).padding(.bottom, 18))
                                .onTapGesture { model.jump(to: p) }
                                .id(p)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(height: 128)
            .background(.ultraThinMaterial)
            .onAppear { proxy.scrollTo(model.page, anchor: .center) }
            .onChange(of: model.page) { _, p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
    }
}

private struct BookmarksPopover: View {
    let model: ReaderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bookmarks").font(.headline).padding(12)
            Divider()
            if model.bookmarks.isEmpty {
                Text("Press B to bookmark a page, or H to add it to Highlights.")
                    .font(.callout).foregroundStyle(.secondary).padding(14).frame(width: 260)
            } else {
                List(model.bookmarks) { b in
                    HStack {
                        Image(systemName: b.isHighlight ? "star.fill" : "bookmark.fill").foregroundStyle(Theme.accent)
                        Button("Page \(b.page + 1)\(b.label.isEmpty ? "" : " · \(b.label)")") { model.jump(to: b.page) }.buttonStyle(.plain)
                        Spacer()
                        Button { model.deleteBookmark(b) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 280, height: min(320, CGFloat(model.bookmarks.count) * 32 + 20))
            }
        }
    }
}

/// Continuous vertical scrolling, pages decoded at the window width.
private struct ScrollPages: View {
    let model: ReaderModel
    let renderer: PageRenderer
    let width: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(0..<model.pageCount, id: \.self) { p in
                        ScrollPage(renderer: renderer, page: p, width: min(width, 1100), filter: model.colorFilter)
                            .id(p)
                            .onAppear { model.scrolledTo(p) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(model.page, anchor: .top) }
        }
    }
}

private struct ScrollPage: View {
    let renderer: PageRenderer
    let page: Int
    let width: CGFloat
    let filter: ColorFilter
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.04).aspectRatio(0.66, contentMode: .fit).overlay(ProgressView())
            }
        }
        .frame(width: width)
        .saturation(filter == .grayscale ? 0 : 1)
        .colorMultiply(filter == .sepia ? Color(hex: 0xF2D7A8) : filter == .night ? Color(hex: 0x9E805C) : .white)
        .task(id: page) {
            let pixels = Int(width * (NSScreen.main?.backingScaleFactor ?? 2))
            image = await renderer.image(page, maxPixel: pixels)
        }
    }
}

struct ReaderHelp: View {
    @Environment(\.dismiss) private var dismiss
    private let keys: [(String, String)] = [
        ("→ ← / Space", "Next / previous page (⇧Space goes back)"),
        ("↑ ↓ / Page Up, Page Down", "Previous / next page"),
        ("Home / End", "First / last page"),
        ("Click left / right side", "Turn the page"),
        ("Swipe left or right", "Turn the page"),
        ("Pinch, + / − / 0", "Zoom in, out, reset"),
        ("Double-click", "Zoom to 2× / back"),
        ("B / H", "Bookmark / add to Highlights"),
        ("D", "Two-page spreads"),
        ("R", "Right-to-left reading"),
        ("A", "Autoplay"),
        ("G", "Page thumbnails"),
        ("F", "Full screen"),
        ("Esc / W", "Close"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reader Shortcuts").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                ForEach(keys, id: \.0) { k in
                    GridRow {
                        Text(k.0).font(.system(.callout, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(k.1).font(.callout)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 470)
    }
}
