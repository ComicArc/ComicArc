import SwiftUI

@main
struct ComicArcIPadApp: App {
    @StateObject private var vm = LibraryViewModel.shared
    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    var body: some Scene {
        WindowGroup {
            SharedAppRootContent(vm: vm, fileService: fileService, windowService: windowService)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            LibraryMenuCommands(vm: vm, includeRenameFiles: true)
            NavigateMenuCommands(vm: vm)
        }
    }
}
