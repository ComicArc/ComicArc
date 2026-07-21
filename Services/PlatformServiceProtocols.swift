import Foundation

protocol FileServiceProtocol {
    func pickFiles(
        allowsMultiple: Bool,
        message: String,
        prompt: String,
        completion: @escaping ([URL]) -> Void
    )
    func pickFolder(completion: @escaping (URL?) -> Void)
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void)
    func revealInFinder(_ url: URL)

    func shareFile(_ url: URL)
}

protocol WindowServiceProtocol {
    func toggleFullScreen()
    func enterImmersiveMode()
    func exitImmersiveMode()
    func hideCursorUntilMouseMoves()
    func showCursor()
    func configureMainWindow()
}

struct NoOpFileService: FileServiceProtocol {
    func pickFiles(allowsMultiple: Bool, message: String, prompt: String,
                   completion: @escaping ([URL]) -> Void) { completion([]) }
    func pickFolder(completion: @escaping (URL?) -> Void) { completion(nil) }
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) { completion(nil) }
    func revealInFinder(_ url: URL) {}
    func shareFile(_ url: URL) {}
}

struct NoOpWindowService: WindowServiceProtocol {
    func toggleFullScreen() {}
    func enterImmersiveMode() {}
    func exitImmersiveMode() {}
    func hideCursorUntilMouseMoves() {}
    func showCursor() {}
    func configureMainWindow() {}
}

func makePlatformFileService() -> any FileServiceProtocol {
    #if os(macOS)
    MacFileService()
    #elseif os(iOS)
    IOSFileService()
    #else
    NoOpFileService()
    #endif
}

func makePlatformWindowService() -> any WindowServiceProtocol {
    #if os(macOS)
    MacWindowService()
    #else
    NoOpWindowService()
    #endif
}
