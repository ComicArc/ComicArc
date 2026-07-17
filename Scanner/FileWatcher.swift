import Foundation

#if os(macOS)
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let supported = LibraryScanner.supportedExtensions
    private var libraryPath: String = ""
    private let onAdded:   (URL)    -> Void
    private let onRemoved: (String) -> Void
    // Called when the watched root becomes inaccessible (e.g. drive eject)
    private let onVolumeUnavailable: (() -> Void)?

    init(onAdded: @escaping (URL) -> Void,
         onRemoved: @escaping (String) -> Void,
         onVolumeUnavailable: (() -> Void)? = nil) {
        self.onAdded              = onAdded
        self.onRemoved            = onRemoved
        self.onVolumeUnavailable  = onVolumeUnavailable
    }

    func start(path: String) {
        stop()
        libraryPath = path
        let paths = [path] as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfPaths = unsafeBitCast(paths, to: NSArray.self)
                let flagsArr = UnsafeBufferPointer(start: flags, count: count)
                for i in 0..<count {
                    guard let p = cfPaths[i] as? String else { continue }
                    let flag = Int(flagsArr[i])

                    // Volume unmount — notify the app so it can show "Library unavailable"
                    let rootChanged = flag & Int(kFSEventStreamEventFlagRootChanged) != 0
                    let unmounted   = flag & Int(kFSEventStreamEventFlagUnmount)     != 0
                    if rootChanged || unmounted {
                        DispatchQueue.main.async { watcher.onVolumeUnavailable?() }
                        continue
                    }

                    let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
                    guard watcher.supported.contains(ext) else { continue }
                    let removed = flag & Int(kFSEventStreamEventFlagItemRemoved) != 0
                    let created = flag & Int(kFSEventStreamEventFlagItemCreated) != 0
                    let renamed = flag & Int(kFSEventStreamEventFlagItemRenamed) != 0
                    if removed && !created {
                        DispatchQueue.main.async { watcher.onRemoved(p) }
                    } else if created || renamed {
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                            if FileManager.default.fileExists(atPath: p) {
                                DispatchQueue.main.async { watcher.onAdded(URL(fileURLWithPath: p)) }
                            }
                        }
                    }
                }
            },
            &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagWatchRoot)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
}

#else

// iOS: file watching via FSEvents is not available. Imports come through UIDocumentPicker.
final class FileWatcher {
    init(onAdded: @escaping (URL) -> Void,
         onRemoved: @escaping (String) -> Void,
         onVolumeUnavailable: (() -> Void)? = nil) {}
    func start(path: String) {}
    func stop() {}
}

#endif
