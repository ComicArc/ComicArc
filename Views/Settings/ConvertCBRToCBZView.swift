import SwiftUI

/// A batch tool to re-encode CBR (RAR) comics as CBZ (zip) in place -- macOS-only, mirroring the
/// existing CBR-support gating everywhere else in the app, since it depends on the same bundled
/// `unar`. Reduces how much of the library still depends on `unar`/`lsar` being present to be
/// read at all.
#if os(macOS)
struct ConvertCBRToCBZView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [Comic] = []
    @State private var isLoading = true
    @State private var isConverting = false
    @State private var progressDone = 0
    @State private var result: (successCount: Int, failures: [(path: String, error: LibraryScanner.CBRConversionError)])?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                ProgressView("Checking your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                resultsView(result)
            } else if candidates.isEmpty {
                emptyState
            } else {
                list
                Divider()
                footer
            }
        }
        .frame(width: 640, height: 520)
        .task { load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Convert CBR to CBZ").font(.title3.bold())
                Text("Re-encodes RAR-based comics as ZIP-based CBZ files in place, so they no longer depend on unar being installed to read. The original .cbr is removed once the .cbz is verified.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No CBR Files Found").font(.headline).foregroundStyle(.secondary)
            Text("Every comic in your library is already CBZ, PDF, or a plain image.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(candidates) { comic in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comic.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text((comic.filePath as NSString).lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 7)
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if isConverting {
                ProgressView(value: Double(progressDone), total: Double(candidates.count))
                    .frame(width: 160)
                Text("\(progressDone)/\(candidates.count)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(candidates.count) CBR file\(candidates.count == 1 ? "" : "s") found")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Convert All…") { convert() }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.brandGold)
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func resultsView(_ result: (successCount: Int, failures: [(path: String, error: LibraryScanner.CBRConversionError)])) -> some View {
        VStack(spacing: 16) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.failures.isEmpty ? Design.brandGold : .orange)
            Text("\(result.successCount) Converted").font(.headline)
            if !result.failures.isEmpty {
                Text("\(result.failures.count) couldn't be converted and were left as-is.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.failures, id: \.path) { failure in
                            Text((failure.path as NSString).lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.cbrComics()
            await MainActor.run { candidates = comics; isLoading = false }
        }
    }

    private func convert() {
        isConverting = true
        progressDone = 0
        let items = candidates.map { (id: $0.id, path: $0.filePath) }
        LibraryScanner.shared.convertAllCBRToCBZ(items) { done, total in
            progressDone = done
        } completion: { successCount, failures in
            isConverting = false
            result = (successCount, failures)
            LibraryViewModel.shared.reload()
        }
    }
}
#endif
