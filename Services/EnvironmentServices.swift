import SwiftUI

private struct FileServiceKey: EnvironmentKey {
    static let defaultValue: any FileServiceProtocol = NoOpFileService()
}

private struct WindowServiceKey: EnvironmentKey {
    static let defaultValue: any WindowServiceProtocol = NoOpWindowService()
}

extension EnvironmentValues {
    var fileService: any FileServiceProtocol {
        get { self[FileServiceKey.self] }
        set { self[FileServiceKey.self] = newValue }
    }

    var windowService: any WindowServiceProtocol {
        get { self[WindowServiceKey.self] }
        set { self[WindowServiceKey.self] = newValue }
    }
}
