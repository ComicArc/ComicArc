#if os(macOS)
import AppKit

// Backs ComicArc.sdef -- AppleScript/Script Editor support, distinct from the AppIntents surface
// in ComicArcAppIntents.swift (Shortcuts/Siri). Both exist because they're genuinely separate
// automation technologies with no bridge between them; kept to the same conservative, no-
// destructive-actions scope as the AppIntents surface. `@objc(ExactName)` matters here -- it must
// match each command's `<cocoa class="...">` in the sdef exactly, since Swift's default runtime
// name would otherwise be module-qualified and mangled.

@objc(ScanLibraryScriptCommand)
final class ScanLibraryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async { LibraryViewModel.shared.scan() }
        return nil
    }
}

@objc(ResyncLibraryScriptCommand)
final class ResyncLibraryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async { LibraryViewModel.shared.resyncLibrary() }
        return nil
    }
}

@objc(ShowContinueReadingScriptCommand)
final class ShowContinueReadingScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async { LibraryViewModel.shared.select(.continueReading) }
        return nil
    }
}
#endif
