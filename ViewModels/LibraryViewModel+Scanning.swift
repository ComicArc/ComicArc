import Foundation
import Combine
import CoreSpotlight
import UserNotifications
import os

extension LibraryViewModel {
    func resyncLibrary() {
        let paths = libraryPaths
        guard !paths.isEmpty, !isBusy else { return }
        isResyncing = true
        LibraryScanner.shared.scan(libraryPaths: paths) { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanState  = state
                self.isScanning = state.running
                guard !state.running else { return }
                if !state.removedIds.isEmpty { self.removeFromSpotlight(state.removedIds) }
                DispatchQueue.global(qos: .utility).async {
                    LibraryScanner.shared.reparseAllMeta(libraryRoots: paths)
                    DispatchQueue.main.async {
                        self.reload()
                        self.indexSpotlight()
                        self.refreshDuplicates()
                        self.refreshRenameCandidates()
                        self.isResyncing = false
                    }
                }
            }
        }
    }

    func scan() {
        let paths = libraryPaths
        guard !paths.isEmpty, !isBusy else { return }
        isScanning = true
        scanState = .init()
        LibraryScanner.shared.scan(libraryPaths: paths) { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanState  = state
                self.isScanning = state.running
                if !state.running {
                    self.reload()
                    self.indexSpotlight()
                    if !state.removedIds.isEmpty { self.removeFromSpotlight(state.removedIds) }
                    self.notifyScanComplete(added: state.added)
                    self.refreshDuplicates()
                    self.presentScanReport(state)
                    self.refreshLibraryHealth()
                    self.refreshRenameCandidates()
                    self.refreshRecommendations()
                    // The corruption-recovery safety net (DatabaseManager.recoverIfCorrupted)
                    // previously only had a backup from launch time -- a scan is exactly the kind
                    // of session that adds a lot of new, otherwise-unbacked-up data.
                    if state.added > 0 { Task.detached(priority: .utility) { self.db.refreshBackup() } }
                }
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        let roots = libraryPaths
        importProgress = ImportProgress(done: 0, total: urls.count)
        Task.detached(priority: .utility) { [weak self] in
            var added = 0, skipped = 0
            var failures: [(name: String, reason: String)] = []
            for (i, url) in urls.enumerated() {
                switch LibraryScanner.shared.addSingle(url: url, libraryRoots: roots) {
                case .added:
                    added += 1
                case .movedOrRenamed, .alreadyInLibrary:
                    skipped += 1
                case .fileNotFound:
                    failures.append((url.lastPathComponent, "File no longer exists"))
                case .unsupportedFormat:
                    failures.append((url.lastPathComponent, "Unsupported file type"))
                }
                let done = i + 1
                await MainActor.run { self?.importProgress = ImportProgress(done: done, total: urls.count) }
            }
            await self?.reload()
            await self?.refreshDuplicates()

            let paths = urls.map(\.path)
            let newComics = DatabaseManager.shared.comics(withPaths: paths)
            if !newComics.isEmpty { ThumbnailCache.shared.prewarm(comics: newComics) }

            await MainActor.run {
                self?.importProgress = nil
                // A single successful, ordinary import with nothing to flag isn't worth
                // interrupting the user over -- only surface the summary when there's something
                // to report (any failure) or the batch was large enough that silent completion
                // would leave real doubt about whether it actually worked.
                if !failures.isEmpty || urls.count > 1 {
                    self?.lastImportSummary = ImportSummary(added: added, skipped: skipped, failures: failures)
                }
            }
        }
    }

    private func presentScanReport(_ state: LibraryScanner.ScanState) {
        guard state.error == nil, !state.cancelled else { return }
        guard state.added > 0 || state.removed > 0 || state.recovered > 0 || state.stillCorrupted > 0 else { return }
        scanReportDismissTask?.cancel()
        showScanReport = true
        let task = DispatchWorkItem { [weak self] in self?.showScanReport = false }
        scanReportDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func dismissScanReport() {
        scanReportDismissTask?.cancel()
        showScanReport = false
    }

    func notifyScanComplete(added: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted, added > 0 else { return }
            let content          = UNMutableNotificationContent()
            content.title        = "Library Updated"
            content.body         = "Added \(added) new comic\(added == 1 ? "" : "s") to your library."
            content.sound        = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}
