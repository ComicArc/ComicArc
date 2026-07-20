import SwiftUI

// MARK: - Data

private enum TStep: Int, CaseIterable {
    case welcome, library, browse, openComic, reader, runs, settings, done
}

private struct TStepInfo {
    let icon:     String
    let title:    String
    let body:     String
    let spot:     SpotRegion?   // nil = no spotlight, show centered card
    let above:    Bool          // callout above spotlight (true) or below (false)
}

// Spotlight regions use a mix of fixed pixel values (for the nav bar, which is 47px)
// and fractional width so they work at any window size.
// Resolved in resolved(_:in:) which interprets x/width as fractions of window width,
// y/height as pixel values when navH is used directly.
private let navH: CGFloat = 48   // nav bar + 1px divider

private let steps: [TStepInfo] = [
    TStepInfo(icon: "diamond.fill",
              title: "Welcome to ComicArc",
              body: "Let's take a quick tour of the major features. You can skip this at any time and return to it from Settings → Show Tutorial.",
              spot: nil, above: true),

    TStepInfo(icon: "books.vertical.fill",
              title: "Your Library",
              body: "Comics are organized by Publisher → Character → Series. Click any group card to drill in. Double-click an issue to open it in the reader.",
              spot: .content, above: false),

    TStepInfo(icon: "filemenu.and.selection",
              title: "Navigation Tabs",
              body: "Switch between Library, Reading Runs, Stats, History, and Settings using the tabs in the top bar.",
              spot: .navCenter, above: false),

    TStepInfo(icon: "sidebar.right",
              title: "Issue Detail",
              body: "Click any comic to open its detail panel. Edit metadata, add tags, write a review, rate it, or tap Open in Reader to start reading.",
              spot: .content, above: false),

    TStepInfo(icon: "book.fill",
              title: "The Reader",
              body: "The reader lives inside the app — no separate window. Move your mouse to the top or bottom edge to reveal controls. Use ← → or swipe to turn pages.",
              spot: .content, above: false),

    TStepInfo(icon: "list.bullet.rectangle.portrait.fill",
              title: "Reading Runs",
              body: "A Run is an ordered reading list that can span multiple series — like a crossover event or a character's entire history. Build one from the Runs tab.",
              spot: .navRuns, above: false),

    TStepInfo(icon: "gearshape.fill",
              title: "Settings",
              body: "Change your library folder, adjust reading modes, pick a progress format, export a backup, or re-run this tutorial at any time.",
              spot: .navSettings, above: false),

    TStepInfo(icon: "checkmark.circle.fill",
              title: "You're All Set",
              body: "Press ? anytime in the reader to see all keyboard shortcuts. Enjoy your library!",
              spot: nil, above: true),
]

private enum SpotRegion {
    case content        // everything below the nav bar
    case navCenter      // middle portion of nav bar (tabs)
    case navRuns        // Runs tab button area
    case navSettings    // Settings tab button area

    func rect(in size: CGSize) -> CGRect {
        switch self {
        case .content:
            return CGRect(x: 0, y: navH, width: size.width, height: size.height - navH)
        case .navCenter:
            let w = size.width * 0.56
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: navH)
        case .navRuns:
            // Runs is the 2nd tab; tabs are centered. Approximate 1/6 of width from center-left.
            let tabW: CGFloat = size.width * 0.10
            let startX = size.width * 0.335
            return CGRect(x: startX, y: 0, width: tabW, height: navH)
        case .navSettings:
            // Settings is the last tab (rightmost of the centered tabs)
            let tabW: CGFloat = size.width * 0.10
            let startX = size.width * 0.62
            return CGRect(x: startX, y: 0, width: tabW, height: navH)
        }
    }
}

// MARK: - TutorialView

struct TutorialView: View {
    let onDismiss: () -> Void

    @State private var currentStep: TStep = .welcome
    @State private var transitioning = false

    private var info: TStepInfo { steps[currentStep.rawValue] }
    private var isFirst: Bool { currentStep == .welcome }
    private var isLast:  Bool { currentStep == .done }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Spotlight overlay
                spotlightLayer(geo: geo)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Animated callout
                if info.spot != nil {
                    calloutPopup(geo: geo)
                } else {
                    centeredCard(geo: geo)
                }

                // Skip always top-right
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
        .preferredColorScheme(AppTheme.current.isLight ? .light : .dark)
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    // MARK: - Spotlight canvas

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

    // MARK: - Callout (for spotlight steps)

    private func calloutPopup(geo: GeometryProxy) -> some View {
        let size = geo.size
        guard let region = info.spot else { return AnyView(EmptyView()) }
        let spotRect = region.rect(in: size)

        let cardW: CGFloat = min(420, size.width * 0.44)
        let cardH: CGFloat = 220.0
        let padding: CGFloat = 16

        let yPos: CGFloat = info.above
            ? spotRect.minY - cardH - padding
            : spotRect.maxY + padding
        let clampedY = max(8, min(size.height - cardH - 8, yPos))
        let xPos = max(8, min(size.width - cardW - 8, (size.width - cardW) / 2))

        return AnyView(
            calloutCard
                .frame(width: cardW)
                .position(x: xPos + cardW / 2, y: clampedY + cardH / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: currentStep.rawValue)
        )
    }

    // MARK: - Centered card (for welcome/done steps)

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

    // MARK: - Shared card content

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
                // Progress dots
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

    // MARK: - Helpers

    private func advance(by delta: Int) {
        let next = currentStep.rawValue + delta
        guard let s = TStep(rawValue: next) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { currentStep = s }
    }

}
