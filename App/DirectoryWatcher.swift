import CoreServices
import Foundation

/// Watches transcript directories recursively and fires when a transcript changes.
///
/// FSEvents rather than a poll loop. Agents append to a transcript on every
/// message, and the 30-second coalescing latency turns a busy session's write
/// storm into one rescan per window. Events for anything but a `.jsonl` file
/// are ignored, since tool output and subagent artifacts churn beside the
/// transcripts.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.ericbriscoe.tokenwidget.fsevents")
    private let onChange: () -> Void

    init?(paths: [URL], latency: CFTimeInterval = 30, onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return nil }
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
                flags[index] & dropped != 0 || changed[index].hasSuffix(".jsonl")
            }
            if needsScan { watcher.onChange() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
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
        // The callback holds an unretained pointer; let one already running finish.
        queue.sync {}
    }
}
