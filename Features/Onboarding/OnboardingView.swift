import SwiftUI

/// The welcome flow: what ComicArc is, choosing the comics folder, the first scan, a theme, and the
/// handful of shortcuts worth knowing. Also available any time from Help › Welcome Tour.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var scanStarted = false
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if step > 0 && !model.scan.running {
                    Button { go(step - 1) } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.accent : Theme.textTertiary.opacity(0.5))
                            .frame(width: i == step ? 22 : 7, height: 7)
                    }
                }
                Spacer()
                if model.libraryCount > 0 && step < steps - 1 {
                    Button("Skip") { model.finishOnboarding() }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 30).padding(.top, 44)

            Spacer(minLength: 20)
            Group {
                switch step {
                case 0: welcome
                case 1: folder
                case 2: scanning
                case 3: look
                default: tips
                }
            }
            .frame(maxWidth: 760)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onChange(of: model.scan.running) { _, running in if !running && step == 2 { scanStarted = true } }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.13)).frame(width: 140, height: 140)
                Image(systemName: "books.vertical.fill").font(.system(size: 60)).foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 10) {
                Text("Welcome to ComicArc").font(.system(size: 40, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("A comic library and reader built around the folders you already have.\nNothing is uploaded, moved or renamed.")
                    .font(.title3).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                feature("folder.fill", "Your folders", "Publishers, characters, eras and series come straight from how you've organized your files.")
                feature("book.fill", "Instant reader", "Pages are prepared ahead of time, so turning a page never waits.")
                feature("point.topleft.down.to.point.bottomright.curvepath.fill", "Reading Paths", "Build your own reading order across series, like a playlist.")
            }
            Button { go(1) } label: { Text("Get Started").padding(.horizontal, 24) }
                .buttonStyle(AccentButtonStyle()).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    private var folder: some View {
        VStack(spacing: 26) {
            header("Where are your comics?", "Choose the folder that holds them. ComicArc reads its structure and keeps watching it for new comics.")
            VStack(alignment: .leading, spacing: 7) {
                path(0, "Comics", "folder", "your library folder")
                path(1, "DC", "building.2", "publisher")
                path(2, "Batman", "person.fill", "character")
                path(3, "Classic", "tag.fill", "era — becomes the #Classic tag")
                path(4, "Batman (1940)", "books.vertical.fill", "series")
                path(5, "Batman (1940) #497.cbz", "doc.fill", "issue")
            }
            .padding(20)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            if model.folders.isEmpty {
                Button { choose() } label: { Label("Choose Comics Folder", systemImage: "folder.badge.plus").padding(.horizontal, 10) }
                    .buttonStyle(AccentButtonStyle()).controlSize(.large).keyboardShortcut(.defaultAction)
                Text("CBZ, CBR, PDF and image files. Every level is optional; any layout works.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.folders, id: \.self) { f in
                        Label(f, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Add Another Folder…") { choose() }.buttonStyle(QuietButtonStyle())
                        Button { go(2) } label: { Text("Continue").padding(.horizontal, 16) }
                            .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private var scanning: some View {
        VStack(spacing: 24) {
            if model.scan.running {
                header("Building your library…", "Reading each file once. Covers fill in as you browse.")
                ProgressView(value: Double(model.scan.done), total: Double(max(1, model.scan.total))).tint(Theme.accent).frame(width: 380)
                Text(model.scan.total > 0 ? "\(model.scan.done) of \(model.scan.total) comics" : "Looking for comics…")
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            } else if let warning = model.scan.warning {
                header("Your folder isn't available", warning)
                Button("Choose a Different Folder") { go(1) }.buttonStyle(QuietButtonStyle())
            } else {
                header(model.libraryCount > 0 ? "Your library is ready" : "No comics found yet",
                       model.libraryCount > 0 ? "Here's what ComicArc found in your folders." : "Add CBZ, CBR or PDF files to your folder, or choose another one.")
                if model.libraryCount > 0 {
                    HStack(spacing: 14) {
                        stat("\(model.libraryCount)", "comics")
                        stat("\(model.publishers.count)", model.publishers.count == 1 ? "publisher" : "publishers")
                        stat("\(model.eras.count)", model.eras.count == 1 ? "era tag" : "era tags")
                        stat("\(model.readingPaths.count)", "Reading Paths")
                    }
                }
                Button { go(model.libraryCount > 0 ? 3 : 1) } label: { Text(model.libraryCount > 0 ? "Continue" : "Back").padding(.horizontal, 16) }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .task {
            if !model.scan.running && !scanStarted && model.libraryCount == 0 { await model.runScan() }
            scanStarted = true
        }
    }

    private var look: some View {
        VStack(spacing: 26) {
            header("Pick a look", "Change it any time in Settings. The reader always stays dark so pages stand out.")
            HStack(spacing: 14) {
                ForEach(AppTheme.allCases) { theme in ThemeSwatch(theme: theme) }
            }
            Button { go(4) } label: { Text("Continue").padding(.horizontal, 16) }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private var tips: some View {
        VStack(spacing: 24) {
            header("A few things worth knowing", nil)
            VStack(alignment: .leading, spacing: 14) {
                tip("command", "⌘K", "Jump to any series, comic or Reading Path by typing a few letters.")
                tip("hand.tap", "Click a page's side", "Turn pages with a click, the arrow keys, Space or a two-finger swipe.")
                tip("star", "H while reading", "Save a page to Highlights. B bookmarks it.")
                tip("chevron.left.chevron.right", "⌘[ and ⌘]", "Go back and forward, or click the trail at the top of any page.")
                tip("point.topleft.down.to.point.bottomright.curvepath", "Reading Paths", "Right-click any comic or series to add it to your own reading order.")
            }
            .padding(22)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            Button { model.finishOnboarding() } label: { Label("Start Reading", systemImage: "book.fill").padding(.horizontal, 16) }
                .buttonStyle(AccentButtonStyle()).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Pieces

    private func go(_ next: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { step = next }
    }

    private func choose() {
        guard let url = ImportPanel.chooseFolder(message: "Choose the folder that contains your comics") else { return }
        model.setFolders(model.folders + [url.standardizedFileURL.path])
        scanStarted = false
        go(2)
        Task { await model.runScan() }
    }

    private func header(_ title: String, _ subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle).font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(text).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func path(_ depth: Int, _ name: String, _ icon: String, _ meaning: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(depth == 3 ? Theme.accent : Theme.textSecondary).frame(width: 18)
            Text(name).font(.system(.callout, design: .monospaced).weight(.medium)).foregroundStyle(Theme.textPrimary)
            Text("— \(meaning)").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(.leading, CGFloat(depth) * 20)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 130).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func tip(_ icon: String, _ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(key).font(.callout.weight(.bold)).foregroundStyle(Theme.textPrimary).frame(width: 150, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// A clickable preview of a theme; selecting it applies it immediately.
struct ThemeSwatch: View {
    let theme: AppTheme
    @State private var store = ThemeStore.shared

    var body: some View {
        let p = theme.palette
        let selected = store.theme == theme
        Button { store.theme = theme } label: {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    p.sidebar.frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(p.accent).frame(width: 34, height: 6)
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(p.raised).frame(width: 16, height: 24) }
                        }
                        Capsule().fill(p.ink.opacity(0.4)).frame(width: 44, height: 4)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.background)
                }
                .frame(width: 112, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 3 : 1))
                Text(theme.name).font(.callout.weight(selected ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
