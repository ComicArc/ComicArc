import SwiftUI

private enum TStep: Int, CaseIterable {
    case welcome, sidebar, library, openComic, reader, readingPaths, diaryTierListsAndMoments, readingOrder, renameAndCovers, toolbar, done
}

private struct TStepInfo {
    let icon:     String
    let title:    String
    let body:     String
    let spot:     SpotRegion?
    let above:    Bool
}

private extension TStep {
    // An exhaustive switch instead of a positional array indexed by `rawValue` -- a plain
    // `[TStepInfo]` literal has no compiler-enforced link to TStep's cases, so adding or
    // removing a case without updating the array in lockstep would silently show mismatched
    // content for a step (or index out of range). A `switch` with no `default` forces every
    // case to be handled here whenever TStep itself changes.
    var info: TStepInfo {
        switch self {
        case .welcome:
            return TStepInfo(icon: "diamond.fill",
                title: "Welcome to ComicArc",
                body: "Let's take a quick tour of the major features. You can skip this at any time and return to it from Settings → Show Tutorial.",
                spot: nil, above: true)

        case .sidebar:
            return TStepInfo(icon: "sidebar.left",
                title: "The Sidebar",
                body: "Everything lives here: Library, Continue Reading, Favorites, and Reading List at the top; your Publishers and Tags below; and Reading Paths, Statistics, and History under Discover. Tap More for the deeper tracking tools — Diary, Tier Lists, Highlights — plus anything that shows up automatically when there's something to review, like a possible duplicate.",
                spot: .sidebar, above: false)

        case .library:
            return TStepInfo(icon: "books.vertical.fill",
                title: "Your Library",
                body: "Comics are organized by Publisher → Character → Series. Click any group card to drill in. Double-click an issue to open it in the reader.",
                spot: .content, above: false)

        case .openComic:
            return TStepInfo(icon: "rectangle.stack.fill",
                title: "Issue Detail",
                body: "Click any comic to open its detail panel. Edit metadata, add tags, write a review, rate it, or tap Open in Reader to start reading. If the comics database matched it wrong (or not at all), use Fix Match to search and set the correct match yourself.",
                spot: .content, above: false)

        case .reader:
            return TStepInfo(icon: "book.fill",
                title: "The Reader",
                body: "The reader lives inside the app — no separate window. Move your mouse to the top or bottom edge to reveal controls. Use ← → or swipe to turn pages.",
                spot: .content, above: false)

        case .readingPaths:
            return TStepInfo(icon: "list.bullet.rectangle.portrait.fill",
                title: "Reading Paths",
                body: "A Reading Path is an ordered list that can span multiple series — like a crossover event or a character's entire history. Build one from Reading Paths in the sidebar.",
                spot: .sidebar, above: false)

        case .diaryTierListsAndMoments:
            return TStepInfo(icon: "text.book.closed.fill",
                title: "Diary, Tier Lists & Highlights",
                body: "Rate or review any comic and it's automatically logged in your Diary, rereads included. Tier Lists let you rank comics into S/A/B/C/D/F tiers — think \"Best Vertigo Runs.\" Star a bookmark in the reader to save it as a Highlight, browsable later as its own gallery. And Statistics includes a Year in Review recap once you've been reading a while.",
                spot: .sidebar, above: false)

        case .readingOrder:
            return TStepInfo(icon: "arrow.up.arrow.down.circle.fill",
                title: "Fixing Reading Order",
                body: "Annuals and specials sometimes land in the wrong spot. Open a series and tap Manage Series to drag issues into place — no editing files required.",
                spot: nil, above: true)

        case .renameAndCovers:
            return TStepInfo(icon: "photo.on.rectangle.angled",
                title: "Renaming Files & Covers",
                body: "Settings → Fix Filenames can tidy up messy filenames automatically. And you're never stuck with the wrong cover — pick any page from the issue itself, or a custom image, right from its detail view.",
                spot: nil, above: true)

        case .toolbar:
            return TStepInfo(icon: "wrench.and.screwdriver.fill",
                title: "The Toolbar",
                body: "At the top of the window: Scan checks your library folders for new comics, Resync re-scans everything, Import adds files directly, the grid icon changes card size, the arrows sort your library, and the gear opens Settings.",
                spot: nil, above: true)

        case .done:
            return TStepInfo(icon: "checkmark.circle.fill",
                title: "You're All Set",
                body: "Press ? anytime in the reader to see all keyboard shortcuts. Enjoy your library!",
                spot: nil, above: true)
        }
    }
}

private enum SpotRegion {
    case content
    case sidebar

    /// Only the sidebar and content areas are spotlight-able: both are real SwiftUI view
    /// bounds this GeometryReader can measure. The actual toolbar buttons live in macOS's
    /// native title bar, which sits outside the view hierarchy entirely — there's no rect to
    /// draw here that would land on them correctly, so that step describes them in text only.
    func rect(in size: CGSize) -> CGRect {
        let sidebarWidth = min(280, size.width * 0.24)
        switch self {
        case .sidebar:
            return CGRect(x: 0, y: 0, width: sidebarWidth, height: size.height)
        case .content:
            return CGRect(x: sidebarWidth, y: 0, width: size.width - sidebarWidth, height: size.height)
        }
    }
}

struct TutorialView: View {
    let onDismiss: () -> Void

    @State private var currentStep: TStep = .welcome
    @State private var transitioning = false

    private var info: TStepInfo { currentStep.info }
    private var isFirst: Bool { currentStep == .welcome }
    private var isLast:  Bool { currentStep == .done }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                spotlightLayer(geo: geo)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if info.spot != nil {
                    calloutPopup(geo: geo)
                } else {
                    centeredCard(geo: geo)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button("Skip Tutorial") { onDismiss() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(18)
                    }
                    Spacer()
                }
            }
        }
        // Always dark, regardless of the user's app theme: every color in this overlay (the
        // black scrim, white text, gold accents) is fixed, not theme-derived. Following the
        // user's Sepia (light) theme here would put hardcoded white text on a light-tinted
        // .ultraThinMaterial card -- a real contrast/readability bug, not a nice-to-have.
        .preferredColorScheme(.dark)
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private func spotlightLayer(geo: GeometryProxy) -> some View {
        Canvas { ctx, size in
            var path = Path(CGRect(origin: .zero, size: size))
            if let region = info.spot {
                let r = region.rect(in: size)
                path.addRoundedRect(
                    in: r.insetBy(dx: -4, dy: -4),
                    cornerSize: CGSize(width: 10, height: 10)
                )
            }
            ctx.fill(path, with: .color(.black.opacity(info.spot == nil ? 0.82 : 0.76)),
                     style: FillStyle(eoFill: true))
        }
        .animation(.easeInOut(duration: 0.35), value: currentStep.rawValue)
    }

    private func calloutPopup(geo: GeometryProxy) -> some View {
        let size = geo.size
        guard let region = info.spot else { return AnyView(EmptyView()) }
        let spotRect = region.rect(in: size)

        let cardW: CGFloat = min(420, size.width * 0.44)
        let cardH: CGFloat = 220.0
        let padding: CGFloat = 16

        // For the sidebar spot, the card reads better alongside it than above/below a tall
        // narrow strip, so anchor horizontally next to the spot instead of vertically relative
        // to it.
        let xPos: CGFloat
        let yPos: CGFloat
        if case .sidebar = region {
            xPos = spotRect.maxX + padding
            yPos = max(8, min(size.height - cardH - 8, (size.height - cardH) / 2))
        } else {
            yPos = info.above ? spotRect.minY - cardH - padding : spotRect.maxY + padding
            xPos = max(8, min(size.width - cardW - 8, (size.width - cardW) / 2))
        }
        let clampedY = max(8, min(size.height - cardH - 8, yPos))
        let clampedX = max(8, min(size.width - cardW - 8, xPos))

        return AnyView(
            calloutCard
                .frame(width: cardW)
                .position(x: clampedX + cardW / 2, y: clampedY + cardH / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: currentStep.rawValue)
        )
    }

    private func centeredCard(geo: GeometryProxy) -> some View {
        VStack {
            Spacer()
            calloutCard
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: currentStep.rawValue)
            Spacer()
        }
    }

    private var calloutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: info.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Design.goldGradient)
                    .frame(width: 40)

                Text(info.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text(info.body)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(TStep.allCases, id: \.rawValue) { s in
                        let active = s == currentStep
                        RoundedRectangle(cornerRadius: 3)
                            .fill(active ? Design.brandGold : Color.white.opacity(0.25))
                            .frame(width: active ? 18 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: currentStep.rawValue)
                    }
                }

                Spacer()

                if !isFirst {
                    Button("Back") { advance(by: -1) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .buttonStyle(.plain)
                }

                Button(isLast ? "Done" : "Next") {
                    if isLast { onDismiss() } else { advance(by: 1) }
                }
                .buttonStyle(GoldCapsuleStyle())
            }
        }
        .padding(22)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Design.brandGold.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
    }

    private func advance(by delta: Int) {
        let next = currentStep.rawValue + delta
        guard let s = TStep(rawValue: next) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { currentStep = s }
    }

}
