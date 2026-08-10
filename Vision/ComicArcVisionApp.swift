import SwiftUI

/// visionOS entry point -- a plain windowed app (no immersive space), reusing the exact same
/// shared Database/Models/Services/Scanner/Views/ViewModels code as ComicArcPad, plus iPadRootView
/// itself directly (via `SharedAppRootContent`, see `Shared/SharedAppRoot.swift`). visionOS's
/// windowed-app SwiftUI surface is close enough to iPadOS's that this needed no new UI of its own
/// for a first version -- the same 3-column NavigationSplitView reader works as a window in the
/// Shared Space. Deliberately not attempting an immersive space or a spatial-specific redesign
/// here; that's a real, separate design exercise, not a mechanical port.
@main
struct ComicArcVisionApp: App {
    @StateObject private var vm = LibraryViewModel.shared
    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    var body: some Scene {
        WindowGroup {
            SharedAppRootContent(vm: vm, fileService: fileService, windowService: windowService)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            LibraryMenuCommands(vm: vm)
            NavigateMenuCommands(vm: vm)
        }
    }
}
