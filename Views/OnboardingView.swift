import SwiftUI

enum OnboardingStep {
    case welcome, cbrSetup, chooseLibrary, scanning, comicsDatabase, complete
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
    @State private var unarInstalled: Bool = false
    @State private var installingUnar: Bool = false
    @State private var gcdDownloadState: GCDDatabaseDownloader.State = .idle
    @State private var isMatchingAfterDownload = false

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
        .task { unarInstalled = checkUnar() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "diamond.fill")
                .foregroundStyle(Design.brandGold)
                .font(.system(size: 14, weight: .black))
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
        case .cbrSetup:      cbrSetupStep
        case .chooseLibrary: chooseLibraryStep
        case .scanning:      scanningStep
        case .comicsDatabase: comicsDatabaseStep
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
                Image(systemName: "diamond.fill")
                    .font(.system(size: 56, weight: .black))
                    .foregroundStyle(Design.goldGradient)
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
                featureBullet(icon: "books.vertical.fill",   label: "Organize",   sub: "CBZ, CBR & PDF")
                featureBullet(icon: "chart.bar.fill",        label: "Track",      sub: "Reading stats")
                featureBullet(icon: "list.bullet.rectangle", label: "Reading Paths", sub: "Cross-series orders")
            }

            Button("Get Started") {
                withAnimation(.easeInOut) {
                    #if os(macOS)
                    step = .cbrSetup
                    #else
                    step = .chooseLibrary
                    #endif
                }
            }
                .goldButton()
                .shadow(color: Design.brandGold.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
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

    private var cbrSetupStep: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Image(systemName: unarInstalled ? "checkmark.seal.fill" : "archivebox.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(unarInstalled ? Color.green : Design.brandGold)

                Text("CBR Support")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)

                Text("ComicArc supports CBZ, PDF, and CBR files.\nCBR format requires a small tool called **unar**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: unarInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(unarInstalled ? .green : .red)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(unarInstalled ? "unar is installed" : "unar not found")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Design.textPrimary)
                        Text(unarInstalled
                             ? "CBR files will open correctly."
                             : "CBR files won't open without it. Install via Homebrew.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !unarInstalled {
                        if installingUnar {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7).tint(Design.brandGold)
                                Text("Installing…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Install via Homebrew") { installUnar() }
                                .buttonStyle(.borderedProminent)
                                .tint(Design.brandBlue)
                        }
                    }
                }
                .padding(20)
                .background(Design.surfaceBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(unarInstalled ? Color.green.opacity(0.3) : Color.red.opacity(0.2)))
            }
            .frame(maxWidth: 560)

            if !unarInstalled {
                Text("Homebrew must be installed at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`.\nYou can also skip this and install unar later.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 16) {
                Button("Back") { withAnimation { step = .welcome } }
                    .foregroundStyle(.secondary).buttonStyle(.plain)

                Button(unarInstalled ? "Continue" : "Skip for Now") {
                    withAnimation { step = .chooseLibrary }
                }
                .goldButton()
            }
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
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
                Button("Back") {
                    withAnimation {
                        #if os(macOS)
                        step = .cbrSetup
                        #else
                        step = .welcome
                        #endif
                    }
                }
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
                        Button("Continue Anyway") { withAnimation { step = .comicsDatabase } }
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

    private var comicsDatabaseStep: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Design.goldGradient)

                Text("Smarter Reading Order (Optional)")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Design.textPrimary)

                Text("Download a free, one-time comics database so annuals and specials get placed\ncorrectly on their own. This downloads once and works offline forever after —\nno ongoing internet needed, no account, no cost.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            VStack(spacing: 12) {
                switch gcdDownloadState {
                case .idle:
                    Button("Download Comics Database") {
                        GCDDatabaseDownloader.download { gcdDownloadState = $0 }
                    }
                    .goldButton()
                case .downloading(let progress):
                    ProgressView(value: progress).frame(maxWidth: 320).tint(Design.brandGold)
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                case .success:
                    if isMatchingAfterDownload {
                        ProgressView().controlSize(.small)
                        Text("Matching your library against it…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Comics database ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .failure(let message):
                    Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480)
                    Button("Try Again") { GCDDatabaseDownloader.download { gcdDownloadState = $0 } }
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 16) {
                if case .downloading = gcdDownloadState {} else if !isMatchingAfterDownload {
                    Button(gcdDownloadState == .success ? "Continue" : "Skip for Now") {
                        withAnimation { step = .complete }
                    }
                    .goldButton()
                }
            }
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        .onChange(of: gcdDownloadState) { _, newValue in
            guard newValue == .success else { return }
            isMatchingAfterDownload = true
            Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.recomputeGCDMatches()
                DatabaseManager.shared.autoPopulateSeriesLinksFromGCD()
                DatabaseManager.shared.recomputeReadingOrder()
                await MainActor.run {
                    isMatchingAfterDownload = false
                    LibraryViewModel.shared.reload()
                }
            }
        }
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

            Button("Open ComicArc") { onComplete() }
                .goldButton()
                .shadow(color: Design.brandGold.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .padding(48)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
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
        case .cbrSetup:      return 1
        case .chooseLibrary: return 2
        case .scanning:      return 3
        case .comicsDatabase: return 4
        case .complete:      return 5
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
                withAnimation { step = .comicsDatabase }
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

    private func checkUnar() -> Bool {

        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("unar").path,
           FileManager.default.fileExists(atPath: bundled) { return true }
        let paths = ["/opt/homebrew/bin/unar", "/usr/local/bin/unar", "/usr/bin/unar"]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func installUnar() {
#if os(macOS)
        let brew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : "/usr/local/bin/brew"
        guard FileManager.default.fileExists(atPath: brew) else {
            scanError = "Homebrew not found. Install it from brew.sh, then run: brew install unar"
            return
        }
        installingUnar = true
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brew)
            proc.arguments = ["install", "unar"]
            do {
                try proc.run()
                // Only safe to wait on a process that actually launched -- calling
                // waitUntilExit() after a failed run() has no defined behavior.
                proc.waitUntilExit()
                DispatchQueue.main.async {
                    installingUnar = false
                    unarInstalled  = checkUnar()
                }
            } catch {
                DispatchQueue.main.async {
                    installingUnar = false
                    scanError = "Couldn't launch Homebrew: \(error.localizedDescription)"
                }
            }
        }
#endif
    }
}
