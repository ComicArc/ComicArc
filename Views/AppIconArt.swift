import SwiftUI

/// Source-of-truth art for the app icon -- ComicArc's permanent visual identity -- rendered to
/// every required PNG size via the `#if DEBUG` export action in `SettingsView`, reusing the exact
/// `ImageRenderer` pipeline `Services/ShareCardRenderer.swift` already proves works in this app.
/// A tilted comic book -- a second cover peeking out behind it says "a collection," not just one
/// issue -- with `ComicBurstShape` as the front cover's own splash accent, tying the icon straight
/// back to the in-app wordmark instead of inventing a third visual language.
///
/// Corner radius (224 of 1024, ~21.9%) approximates Apple's Big Sur+ "squircle" icon convention by
/// eye -- this app has no access to Apple's official icon template grid, so treat this as a close
/// approximation, not an exact HIG match. Two shapes plus one accent, kept deliberately simple so
/// the silhouette still reads at 16x16.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.075, green: 0.078, blue: 0.094),
                                 Color(red: 0.035, green: 0.037, blue: 0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Back cover -- just an edge peeking out, the "you own more than one" cue.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.2, green: 0.16, blue: 0.06))
                .frame(width: 380, height: 520)
                .rotationEffect(.degrees(16))
                .offset(x: 100, y: 50)

            // Front cover.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.98, green: 0.75, blue: 0.12),
                                             Color(red: 0.855, green: 0.58, blue: 0.047)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 5)
                )
                .frame(width: 400, height: 560)
                .rotationEffect(.degrees(-9))
                .offset(x: -40, y: -10)
                .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 24)

            // Cover splash burst -- dark-on-gold so it reads as ink on the cover, not another
            // light source.
            ComicBurstShape(points: 10, innerRatio: 0.5)
                .fill(Color(red: 0.11, green: 0.09, blue: 0.02))
                .frame(width: 170, height: 170)
                .rotationEffect(.degrees(-9))
                .offset(x: 36, y: -80)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: 224, style: .continuous))
    }
}

#Preview("App Icon") {
    AppIconArt()
        .frame(width: 256, height: 256)
}
