import SwiftUI

private struct FileServiceKey: EnvironmentKey {
    static let defaultValue: any FileServiceProtocol = NoOpFileService()
}

private struct WindowServiceKey: EnvironmentKey {
    static let defaultValue: any WindowServiceProtocol = NoOpWindowService()
}

/// Lets a comic's cover (in a grid card or IssueDetailPage, both deep in the browsing hierarchy)
/// and the reader's own hero-cover layer share one `matchedGeometryEffect` namespace without
/// threading it through every intermediate view as an explicit parameter. Optional (nil
/// default) since not every view tree that might read this actually has `ContentView` as an
/// ancestor (e.g. previews) -- `heroGeometry(id:in:isSource:)`'s optional-namespace overload
/// below just no-ops when it's nil, rather than every call site needing its own guard.
private struct ReaderNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
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

    var readerNamespace: Namespace.ID? {
        get { self[ReaderNamespaceKey.self] }
        set { self[ReaderNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Named distinctly from SwiftUI's own `matchedGeometryEffect` (rather than overloading it)
    /// so a nil namespace visibly opts a view out instead of silently shadowing the real API with
    /// a narrower one. `isSource` defaults to `true` for the grid/detail cover call sites, which
    /// are the actual sources of this transition; the reader's own hero-cover layer passes
    /// `isSource: false` explicitly since it's always the destination, never a competing source.
    @ViewBuilder
    func heroGeometry(id: some Hashable, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace {
            self.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}
