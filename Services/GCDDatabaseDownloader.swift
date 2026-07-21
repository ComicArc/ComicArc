import Foundation

/// Downloads the one-time offline comics database (see OfflineMetadataStore) from wherever it's
/// hosted. This is the ONLY network call anywhere in this feature — everything after a
/// successful download runs entirely offline, forever, with no server dependency and no
/// per-request cost regardless of how many people use the app.
///
enum GCDDatabaseDownloader {
    static let hostedURL = URL(string: "https://github.com/ComicArc/ComicArc/releases/download/gcd-v1/gcd_lookup.sqlite")!

    enum State: Equatable {
        case idle, downloading(progress: Double), success, failure(String)

        var isDownloading: Bool { if case .downloading = self { return true }; return false }
    }

    @MainActor
    static func download(onProgress: @escaping (State) -> Void) {
        onProgress(.downloading(progress: 0))
        let destination = OfflineMetadataStore.fileURL
        let tmpDestination = destination.appendingPathExtension("download")

        let task = URLSession.shared.downloadTask(with: hostedURL) { tempURL, response, error in
            Task { @MainActor in
                if let error {
                    onProgress(.failure(error.localizedDescription))
                    return
                }
                guard let tempURL, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    onProgress(.failure("The comics database couldn't be downloaded. Check your internet connection and try again later."))
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                              withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: tmpDestination)
                    try FileManager.default.moveItem(at: tempURL, to: tmpDestination)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tmpDestination, to: destination)
                    OfflineMetadataStore.shared.reopen()
                    onProgress(.success)
                } catch {
                    onProgress(.failure("Couldn't save the downloaded database: \(error.localizedDescription)"))
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in onProgress(.downloading(progress: progress.fractionCompleted)) }
        }
        progressObservations.append(observation)
        task.resume()
    }

    // Kept alive for the duration of the download; KVO observations are removed automatically
    // when replaced, so a growing array here is fine — downloads are a rare, one-off action.
    private static var progressObservations: [NSKeyValueObservation] = []
}
