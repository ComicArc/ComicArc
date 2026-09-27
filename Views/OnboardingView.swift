import SwiftUI

enum OnboardingStep {
    case welcome, chooseLibrary, scanning, complete
}

struct OnboardingView: View {
    let onComplete: () -> Void

    @Environment(\.fileService) private var fileService

    @State private var step:        OnboardingStep = .welcome
    @State private var libraryPaths: [String] = []
    @State private var scanDone:    Int = 0
    @State private var scanTotal:   Int = 0
    @State private var scanError:   String? = nil
    @State private var scanFinishedEmpty = false

    var body: some View {
        ZStack {
            Design.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                stepContent
                Spacer()
                bottomBar
            }
        }
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 640)
        #endif
        .preferredColorScheme(AppTheme.current.isLight ? .light : .dark)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ComicBurstShape()
                .fill(Design.goldGradient)
                .frame(width: 14, height: 14)
            Text("COMICARC")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(Design.brandGold)
                .kerning(1.5)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Design.navBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Design.borderColor).frame(height: 1)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:       welcomeStep
        case .chooseLibrary: chooseLibraryStep
        case .scanning:      scanningStep
        case .complete:      completeStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 36) {
            ZStack {
                Circle()
                    .fill(Design.goldGradient.opacity(0.12))
                    .frame(width: 130, height: 130)
                Circle()
                    .stroke(Design.brandGold.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 130, height: 130)
                // The app's own mark -- same shape as the real app icon, so
                // this reads as brand consistency, not an extra decoration.
                ComicBurstShape()
                    .fill(Design.goldGradient)
                    .frame(width: 64, height: 64)
            }

            VStack(spacing: 14) {
                Text("Welcome to ComicArc")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(0.5)

                Text("Your personal comic library — organized, tracked, and ready to read.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 40) {
                featureBullet(icon: "books.vertical.fill", label: "Organize", sub: "CBZ, CBR & PDF")
                featureBullet(icon: "book.fill",           label: "Read",     sub: "Built right in")
                featureBullet(icon: "chart.bar.fill",      label: "Track",    sub: "Progress & stats")
            }

            Button("Get Started") {
                withAnimation(.easeInOut) { step = .chooseLibrary }
            }
                .goldButton()
                .shadow(color: Design.brandGold.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }

    private func quickStartRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Design.brandGold).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func featureBullet(icon: String, label: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Design.goldGradient)
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Design.textPrimary)
            Text(sub)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120)
        .padding(22)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.borderColor, lineWidth: 1))
    }

    private var chooseLibraryStep: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 52))
                    .foregroundStyle(Design.goldGradient)

                Text("Choose Your Comics Folders")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)
                    .kerning(0.5)

                Text("Point ComicArc to the folder (or folders) where your comics are stored.\nSubfolders are scanned automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("LIBRARY FOLDERS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .kerning(1.5)

                VStack(spacing: 0) {
                    if libraryPaths.isEmpty {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary).font(.title3)
                            Text("No folder selected").foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(16)
                    } else {
                        ForEach(libraryPaths, id: \.self) { path in
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(Design.brandGold).font(.title3)
                                Text(path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    libraryPaths.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(path)")
                            }
                            .padding(16)
                            if path != libraryPaths.last { Divider() }
                        }
                    }
                }
                .background(Design.surfaceBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(libraryPaths.isEmpty ? Design.borderColor : Design.brandGold.opacity(0.4), lineWidth: 1)
                )

                Button("Add Folder…") { pickFolder() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 560)

            HStack(spacing: 16) {
                Button("Back") { withAnimation { step = .welcome } }
                    .foregroundStyle(.secondary).buttonStyle(.plain)

                Button("Scan Library") {
                    LibraryFolders.write(libraryPaths)
                    withAnimation { step = .scanning }
                    startScan()
                }
                .goldButton()
                .opacity(libraryPaths.isEmpty ? 0.5 : 1)
                .disabled(libraryPaths.isEmpty)
            }
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }

    private var scanningStep: some View {
        VStack(spacing: 36) {
            if let err = scanError {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)
                    Text("Couldn't Read That Folder")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text(err)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 480)
                    Button("Choose a Different Folder") { chooseDifferentFolder() }
                        .goldButton()
                }
            } else if scanFinishedEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "questionmark.folder.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    Text("No Comics Found")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text("This folder (and its subfolders) don't contain any supported comic files (CBZ, CBR, PDF). Choose a different folder, or continue if you'll add comics later.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 480)
                    HStack(spacing: 16) {
                        Button("Choose a Different Folder") { chooseDifferentFolder() }
                            .buttonStyle(.bordered)
                        Button("Continue Anyway") { withAnimation { step = .complete } }
                            .goldButton()
                    }
                }
            } else if scanTotal == 0 {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(Design.brandGold)
                    Text("Discovering comics…")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text(libraryPaths.count == 1 ? libraryPaths[0] : "\(libraryPaths.count) folders")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 480)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Design.goldGradient)
                    Text("Scanning Library")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    VStack(spacing: 8) {
                        ProgressView(value: Double(scanDone), total: Double(max(scanTotal, 1)))
                            .progressViewStyle(.linear)
                            .tint(Design.brandGold)
                            .frame(maxWidth: 480)
                        Text("\(scanDone) of \(scanTotal) comics indexed")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }

    private var completeStep: some View {
        VStack(spacing: 36) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 130, height: 130)
                Circle().stroke(Color.green.opacity(0.3), lineWidth: 1.5).frame(width: 130, height: 130)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 58)).foregroundStyle(.green)
            }

            VStack(spacing: 14) {
                Text("You're All Set!")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)
                Text("\(scanDone) comic\(scanDone == 1 ? "" : "s") indexed and ready to read.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            // The whole quick start -- replaces the separate multi-step tutorial overlay.
            VStack(alignment: .leading, spacing: 12) {
                quickStartRow(icon: "books.vertical.fill", title: "Your Library",
                              text: "Folders become Publisher → Character → Series. Open any comic to start reading.")
                #if os(macOS)
                quickStartRow(icon: "book.fill", title: "The Reader",
                              text: "Arrow keys turn pages. Move the pointer to the top or bottom edge for controls. Pinch or double-click to zoom, then scroll around. Press ? for every shortcut.")
                #else
                quickStartRow(icon: "book.fill", title: "The Reader",
                              text: "Swipe or tap the edges to turn pages. Tap the middle for controls. Pinch to zoom.")
                #endif
                quickStartRow(icon: "list.bullet.rectangle.portrait.fill", title: "Reading Paths",
                              text: "Build your own run from any comics you own — a crossover, a character's history, a personal playlist. Add a comic to one from its menu.")
            }
            .frame(maxWidth: 520)

            Button("Open ComicArc") { onComplete() }
                .goldButton()
                .shadow(color: Design.brandGold.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                let isCurrent = stepIndex == i
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Design.brandGold : Design.borderColor)
                    .frame(width: isCurrent ? 24 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: stepIndex)
            }
        }
        .padding(.bottom, 32)
    }

    private var stepIndex: Int {
        switch step {
        case .welcome:       return 0
        case .chooseLibrary: return 1
        case .scanning:      return 2
        case .complete:      return 3
        }
    }

    private func pickFolder() {
        fileService.pickFolder { url in
            guard let url, !libraryPaths.contains(url.path) else { return }
            libraryPaths.append(url.path)
        }
    }

    private func startScan() {
        scanError = nil
        scanFinishedEmpty = false
        LibraryScanner.shared.scan(libraryPaths: libraryPaths) { state in
            DispatchQueue.main.async {
                scanDone  = state.done
                scanTotal = state.total
                guard !state.running else { return }
                // The scanner already distinguishes "path isn't accessible" (e.g. a file was
                // picked instead of a folder, or permissions were denied) from a genuinely empty
                // folder -- without checking this, both cases used to silently advance straight
                // to "You're All Set! 0 comics indexed," which reads as broken, not empty.
                if let err = state.error {
                    scanError = err
                    return
                }
                LibraryViewModel.shared.reload()
                guard state.total > 0 else {
                    scanFinishedEmpty = true
                    return
                }
                withAnimation { step = .complete }
            }
        }
    }

    /// Resets back to folder selection after a failed or empty scan, so the user can pick a
    /// different folder rather than being stuck on an error screen with no way forward.
    private func chooseDifferentFolder() {
        libraryPaths = []
        UserDefaults.standard.removeObject(forKey: LibraryFolders.key)
        UserDefaults.standard.removeObject(forKey: LibraryFolders.legacySingleKey)
        scanError = nil
        scanFinishedEmpty = false
        scanDone = 0
        scanTotal = 0
        withAnimation { step = .chooseLibrary }
    }
}
