import Foundation

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

        // Holds this download's own observation so `finish` can invalidate and remove exactly
        // it -- without this, `progressObservations` only ever grows across the process
        // lifetime (every retry after a failed download leaks another one).
        var observation: NSKeyValueObservation?
        func finish(_ state: State) {
            if let observation {
                observation.invalidate()
                progressObservations.removeAll { $0 === observation }
            }
            onProgress(state)
        }

        let task = URLSession.shared.downloadTask(with: hostedURL) { tempURL, response, error in
            Task { @MainActor in
                if let error {
                    finish(.failure(error.localizedDescription))
                    return
                }
                guard let tempURL, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    finish(.failure("The comics database couldn't be downloaded. Check your internet connection and try again later."))
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
                    finish(.success)
                } catch {
                    finish(.failure("Couldn't save the downloaded database: \(error.localizedDescription)"))
                }
            }
        }

        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in onProgress(.downloading(progress: progress.fractionCompleted)) }
        }
        if let observation { progressObservations.append(observation) }
        task.resume()
    }

    private static var progressObservations: [NSKeyValueObservation] = []
}
