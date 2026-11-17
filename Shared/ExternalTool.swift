#if os(macOS)
import Foundation

/// Finds and runs the bundled `unar`/`lsar` tools, for both scanning and reading CBRs.
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
    /// Tracks every running process (scan and reader can run at once), so `terminateActiveProcess`
    /// stops them all.
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    @discardableResult
    func shell(_ executable: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()

        let key = ObjectIdentifier(proc)
        activeProcessLock.lock()
        activeProcesses[key] = proc
        activeProcessLock.unlock()
        defer { activeProcessLock.lock(); activeProcesses.removeValue(forKey: key); activeProcessLock.unlock() }

        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func terminateActiveProcess() {
        activeProcessLock.lock()
        let procs = Array(activeProcesses.values)
        activeProcessLock.unlock()
        for proc in procs where proc.isRunning { proc.terminate() }
    }
}
#endif
