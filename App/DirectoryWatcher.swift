import CoreServices
import Foundation

/// Watches transcript directories recursively and fires when anything changes.
///
/// FSEvents rather than a poll loop: Claude Code appends to a transcript on
/// every assistant message, and the two-second coalescing latency turns a busy
/// session's write storm into one rescan.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.ericbriscoe.tokenwidget.fsevents")
    private let onChange: () -> Void
    private let requestedPaths: [String]

    init?(paths: [URL], latency: CFTimeInterval = 2.0, onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return nil }
        requestedPaths = paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        // Watch an existing ancestor so a provider's first session is noticed.
        let existing = Set(paths.map { requested -> String in
            var ancestor = requested.standardizedFileURL.resolvingSymlinksInPath()
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            return ancestor.path
        })
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let needsScan = (0..<count).contains { index in
                if flags[index] & dropped != 0 { return true }
                let path = URL(fileURLWithPath: changed[index]).resolvingSymlinksInPath().path
                return watcher.requestedPaths.contains { root in
                    path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
                }
            }
            if needsScan { watcher.onChange() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            Array(existing) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
