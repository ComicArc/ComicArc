import SwiftUI

/// A comic cover loaded asynchronously from `CoverStore`. Shows the whole cover (never cropped),
/// with a quiet placeholder while it loads.
struct CoverImage: View {
    let comicID: Int64
    let path: String
    var customPath: String? = nil
    @State private var image: CGImage?

    init(comicID: Int64, path: String, customPath: String? = nil) {
        self.comicID = comicID
        self.path = path
        self.customPath = customPath
        _image = State(initialValue: customPath.flatMap { CoverStore.shared.cachedFile($0) } ?? CoverStore.shared.cached(comicID))
    }

    init(_ comic: Comic) { self.init(comicID: comic.id, path: comic.filePath) }

    var body: some View {
        ZStack {
            Theme.raised
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "book.closed").font(.title2).foregroundStyle(Theme.textTertiary)
            }
        }
        .task(id: "\(comicID)|\(customPath ?? "")") {
            if let customPath, let custom = await CoverStore.shared.image(atPath: customPath) { image = custom; return }
            if image == nil || customPath == nil { image = await CoverStore.shared.cover(id: comicID, path: path) }
        }
    }
}

/// Kerned all-caps section title.
struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased()).font(.signage(13)).kerning(1.4).foregroundStyle(Theme.textPrimary)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.textTertiary) }
            Spacer()
        }
    }
}

struct ProgressLine: View {
    let value: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textPrimary.opacity(0.14))
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 3)
    }
}

struct PublisherBadge: View {
    let publisher: String
    var body: some View {
        Text(publisher.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .rounded)).kerning(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.publisherColor(publisher), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent.opacity(0.8))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message).font(.callout).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let action { Button(action.label, action: action.run).buttonStyle(AccentButtonStyle()).padding(.top, 4) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.accentGradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
            .contentShape(Capsule())
    }
}

/// Lifts a card slightly on hover (no spring, so a grid never wobbles).
struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }

    func coverFrame(width: CGFloat) -> some View {
        frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).stroke(Theme.border))
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
    }

    /// Shows an alert while `message` is set.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message.wrappedValue ?? "") }
    }
}

/// Simple flowing layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}
