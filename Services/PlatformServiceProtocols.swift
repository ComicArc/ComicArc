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

    /// Moves a file to the system Trash (not a permanent delete) and returns the resulting
    /// location within the Trash, if it succeeded -- callers can use that URL to move the file
    /// back as part of an undo. Returns nil if trashing isn't supported or failed.
    func moveToTrash(_ url: URL) -> URL?

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

    /// Opens the system print panel for a single page image. No-op where printing isn't
    /// supported (iOS/iPadOS has no equivalent entry point wired up yet).
    func printImage(_ image: PlatformImage)
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
    func moveToTrash(_ url: URL) -> URL? { nil }
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
    func printImage(_ image: PlatformImage) {}
}

@MainActor
func makePlatformFileService() -> any FileServiceProtocol {
    #if os(macOS)
    MacFileService()
    #elseif os(iOS) || os(visionOS)
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
