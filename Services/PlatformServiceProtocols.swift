import Foundation

// MARK: - File service

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
}

// MARK: - Window service

protocol WindowServiceProtocol {
    func toggleFullScreen()
    func enterImmersiveMode()
    func exitImmersiveMode()
    func hideCursorUntilMouseMoves()
    func showCursor()
    func configureMainWindow()
}

// MARK: - No-op implementations (iOS defaults; also used as EnvironmentKey defaults)

struct NoOpFileService: FileServiceProtocol {
    func pickFiles(allowsMultiple: Bool, message: String, prompt: String,
                   completion: @escaping ([URL]) -> Void) { completion([]) }
    func pickFolder(completion: @escaping (URL?) -> Void) { completion(nil) }
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) { completion(nil) }
    func revealInFinder(_ url: URL) {}
}

struct NoOpWindowService: WindowServiceProtocol {
    func toggleFullScreen() {}
    func enterImmersiveMode() {}
    func exitImmersiveMode() {}
    func hideCursorUntilMouseMoves() {}
    func showCursor() {}
    func configureMainWindow() {}
}

// MARK: - Platform factories (called once at app startup in ComicArcApp)

func makePlatformFileService() -> any FileServiceProtocol {
    #if os(macOS)
    MacFileService()
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
