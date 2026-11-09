import Foundation
import CoreServices

/// Watches the library's root folders with FSEvents and reports changes (debounced).
///
/// Only the roots are watched — FSEvents is recursive, so subfolders are covered.
/// Nothing is watched when the library is empty.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var watched: [String] = []

    private let queue = DispatchQueue(label: "com.galleria.fsevents", qos: .utility)
    private let debounceInterval: TimeInterval = 1.5

    /// Called on an arbitrary queue after a burst of file changes settles.
    var onChange: (() -> Void)?

    var isRunning: Bool { stream != nil }

    func start(paths: [String]) {
        let live = paths.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard live != watched || stream == nil else { return }

        stop()
        watched = live
        guard !live.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            live as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watched = []
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange?()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    deinit { stop() }
}
