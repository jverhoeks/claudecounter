import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// One filesystem change observed by the watcher. Mirrors
/// `watcher.Change` in the Go implementation.
public struct FileChange: Equatable, Sendable {
    public enum Kind: Sendable {
        case create
        case modify
        case remove
    }
    public let path: String
    public let kind: Kind
    public init(path: String, kind: Kind) {
        self.path = path; self.kind = kind
    }
}

/// FSEventStream wrapper that emits an `AsyncStream<FileChange>` for
/// every `.jsonl` change beneath a root directory tree. macOS-native
/// equivalent of fsnotify+walk in the Go binary; FSEvents is recursive
/// by design so no per-subdir Add() is needed.
public final class Watcher: @unchecked Sendable {

    public typealias Stream = AsyncStream<FileChange>

    private let root: String
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private var continuation: Stream.Continuation?

    public init(root: String) {
        self.root = root
        self.queue = DispatchQueue(label: "claudecounter.watcher", qos: .utility)
    }

    /// Start watching. Returns the stream of changes. The stream ends
    /// when `stop()` is called.
    public func start() -> Stream {
        let (stream, continuation) = Stream.makeStream(of: FileChange.self)
        self.continuation = continuation
        startFSEvents()
        continuation.onTermination = { @Sendable [weak self] _ in
            self?.stop()
        }
        return stream
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        continuation?.finish()
        continuation = nil
    }

    deinit {
        stop()
    }

    private func startFSEvents() {
        let pathToWatch = root as CFString
        let paths = [pathToWatch] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // UseCFTypes makes eventPaths arrive as a CFArray of CFStrings, which
        // is much friendlier to read in Swift than the default char**.
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, count, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
                let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
                for i in 0..<count {
                    let cfPath = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, i), to: CFString.self)
                    let path = cfPath as String
                    watcher.handle(path: path, flags: eventFlags[i])
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,                  // 50 ms latency — same order of magnitude as fsnotify on macOS
            flags
        ) else {
            continuation?.finish()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            continuation?.finish()
            return
        }
        self.stream = stream
    }

    /// Translate one FSEvents callback record into a `FileChange` and
    /// forward it on the stream — when the path is a `.jsonl` and the
    /// flags map to a kind we care about.
    fileprivate func handle(path: String, flags: FSEventStreamEventFlags) {
        guard path.hasSuffix(".jsonl") else { return }
        guard let kind = mapFlags(flags) else { return }
        continuation?.yield(FileChange(path: path, kind: kind))
    }
}

/// Map FSEvents flags onto a `FileChange.Kind`. Returns nil for events
/// we don't care about (directory ops, history-done sentinels, etc).
/// Order matches the Go watcher: Create > Write > Remove/Rename.
public func mapFlags(_ flags: FSEventStreamEventFlags) -> FileChange.Kind? {
    let f = Int(flags)
    if f & kFSEventStreamEventFlagItemIsDir != 0 { return nil }

    if f & kFSEventStreamEventFlagItemCreated != 0 {
        return .create
    }
    if f & kFSEventStreamEventFlagItemModified != 0 {
        return .modify
    }
    if f & (kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 {
        return .remove
    }
    return nil
}
