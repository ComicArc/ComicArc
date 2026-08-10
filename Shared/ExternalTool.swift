#if os(macOS)
import Foundation

/// Locates and runs the bundled/Homebrew CLI tools (`unar`, `lsar`) CBR support depends on.
/// Shared by `LibraryScanner` (page-count listing at scan time) and `CBRDocument` (page
/// extraction at read time) so there's exactly one place that knows how to find and launch these
/// binaries, instead of two copies drifting apart.
final class ExternalTool: @unchecked Sendable {
    static let shared = ExternalTool()
    private init() {}

    private let whichLock = NSLock()
    private var whichCache: [String: String?] = [:]

    func which(_ name: String) -> String? {
        whichLock.lock()
        if let cached = whichCache[name] { whichLock.unlock(); return cached }
        whichLock.unlock()
        let resolved = resolveWhich(name)
        whichLock.lock(); whichCache[name] = resolved; whichLock.unlock()
        return resolved
    }

    private func resolveWhich(_ name: String) -> String? {
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(name).path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        let brewPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let found = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) { return found }
        let result = shell("/usr/bin/which", args: [name])
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private let activeProcessLock = NSLock()
    private var activeProcess: Process?

    @discardableResult
    func shell(_ executable: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()

        activeProcessLock.lock()
        activeProcess = proc
        activeProcessLock.unlock()
        defer { activeProcessLock.lock(); activeProcess = nil; activeProcessLock.unlock() }

        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func terminateActiveProcess() {
        activeProcessLock.lock()
        let proc = activeProcess
        activeProcessLock.unlock()
        if proc?.isRunning == true { proc?.terminate() }
    }
}
#endif
