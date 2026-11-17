import SwiftUI
import AppKit

extension Notification.Name {
    static let showReaderHelp = Notification.Name("showReaderHelp")
}

enum ImportPanel {
    @MainActor static func run(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["cbz", "cbr", "pdf"].compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose comics to add to your library"
        panel.prompt = "Import"
        if panel.runModal() == .OK { model.importFiles(panel.urls) }
    }

    @MainActor static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
