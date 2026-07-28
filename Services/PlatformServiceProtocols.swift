import Foundation
import UniformTypeIdentifiers

// Both protocols are UI-facing (AppKit/UIKit) in every concrete implementation, but neither was
// actor-isolated -- a hypothetical caller invoking these from a background Task would get no
// compile-time guardrail against off-main UI access. It only worked because every actual call
// site (e.g. BackupService.import) happens to already be on the main actor.
@MainActor
protocol FileServiceProtocol {
    func pickFiles(
        allowsMultiple: Bool,
        message: String,
        prompt: String,
        contentTypes: [UTType],
        completion: @escaping ([URL]) -> Void
    )
    func pickFolder(completion: @escaping (URL?) -> Void)
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void)
    func revealInFinder(_ url: URL)

    func shareFile(_ url: URL)
}

@MainActor
protocol WindowServiceProtocol {
    func toggleFullScreen()
    func enterImmersiveMode()
    func exitImmersiveMode()
    func hideCursorUntilMouseMoves()
    func showCursor()
    func configureMainWindow()
}

struct NoOpFileService: FileServiceProtocol {
    // Explicitly `nonisolated`: these no-op types have no state and don't need MainActor to
    // construct, but EnvironmentServices.swift's EnvironmentKey.defaultValue evaluates in a
    // nonisolated static context -- without this the (otherwise MainActor-inferred, via
    // protocol conformance) implicit init would make that defaultValue uncallable there.
    nonisolated init() {}
    func pickFiles(allowsMultiple: Bool, message: String, prompt: String, contentTypes: [UTType],
                   completion: @escaping ([URL]) -> Void) { completion([]) }
    func pickFolder(completion: @escaping (URL?) -> Void) { completion(nil) }
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) { completion(nil) }
    func revealInFinder(_ url: URL) {}
    func shareFile(_ url: URL) {}
}

struct NoOpWindowService: WindowServiceProtocol {
    nonisolated init() {}
    func toggleFullScreen() {}
    func enterImmersiveMode() {}
    func exitImmersiveMode() {}
    func hideCursorUntilMouseMoves() {}
    func showCursor() {}
    func configureMainWindow() {}
}

@MainActor
func makePlatformFileService() -> any FileServiceProtocol {
    #if os(macOS)
    MacFileService()
    #elseif os(iOS)
    IOSFileService()
    #else
    NoOpFileService()
    #endif
}

@MainActor
func makePlatformWindowService() -> any WindowServiceProtocol {
    #if os(macOS)
    MacWindowService()
    #else
    NoOpWindowService()
    #endif
}
