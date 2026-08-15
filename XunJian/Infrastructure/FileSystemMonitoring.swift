import CoreServices
import Foundation

struct FileSystemChangeKinds: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let created = Self(rawValue: 1 << 0)
    static let removed = Self(rawValue: 1 << 1)
    static let modified = Self(rawValue: 1 << 2)
    static let renamed = Self(rawValue: 1 << 3)
    static let metadata = Self(rawValue: 1 << 4)
    /// Name, content, or location changed. iCloud xattr / Finder-info ticks
    /// are `.metadata` only and must not start an index scan.
    static let structural: Self = [.created, .removed, .modified, .renamed]
}

struct FileSystemChangeEvent: Hashable, Sendable {
    let path: String
    let kinds: FileSystemChangeKinds
    let isDirectory: Bool
    let requiresFullRescan: Bool

    init(
        path: String,
        kinds: FileSystemChangeKinds,
        isDirectory: Bool,
        requiresFullRescan: Bool = false
    ) {
        self.path = Self.canonicalPath(path)
        self.kinds = kinds
        self.isDirectory = isDirectory
        self.requiresFullRescan = requiresFullRescan
    }

    init(path: String, flags: FSEventStreamEventFlags) {
        self.path = Self.canonicalPath(path)

        func contains(_ flag: Int) -> Bool {
            flags & FSEventStreamEventFlags(flag) != 0
        }

        var kinds: FileSystemChangeKinds = []
        if contains(kFSEventStreamEventFlagItemCreated) { kinds.insert(.created) }
        if contains(kFSEventStreamEventFlagItemRemoved) { kinds.insert(.removed) }
        if contains(kFSEventStreamEventFlagItemModified) { kinds.insert(.modified) }
        if contains(kFSEventStreamEventFlagItemRenamed) { kinds.insert(.renamed) }
        let metadataFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
                | kFSEventStreamEventFlagItemXattrMod
        )
        if flags & metadataFlags != 0 {
            kinds.insert(.metadata)
        }
        if kinds.isEmpty && !contains(kFSEventStreamEventFlagHistoryDone) {
            kinds.insert(.modified)
        }
        self.kinds = kinds
        isDirectory = contains(kFSEventStreamEventFlagItemIsDir)
        let recoveryFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        requiresFullRescan = flags & recoveryFlags != 0
    }

    /// Created / removed / modified / renamed, or a stream-recovery flag.
    var requiresIndexScan: Bool {
        requiresFullRescan || !kinds.isDisjoint(with: .structural)
    }

    /// Finder tags, owner, or iCloud download xattrs. The file the table
    /// shows did not change.
    var isMetadataOnly: Bool {
        !requiresFullRescan && kinds == .metadata
    }

    private static func canonicalPath(_ path: String) -> String {
        FilePathCanonicalizer.path(path)
    }
}

struct MonitoredSource: Equatable, Sendable {
    let sourceID: UUID
    let rootPath: String
}

struct FileIndexScope: Hashable, Sendable {
    let path: String
    let includesDescendants: Bool
}

struct IncrementalScanSnapshot: Sendable {
    let scopes: [FileIndexScope]
    let failedScopes: [FileIndexScope]
    let files: [IndexedFile]
}

final class FileSystemChangeMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable (UUID, [FileSystemChangeEvent]) -> Void
    typealias FailureHandler = @Sendable (UUID, String) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let sourceID: UUID
        private let lock = NSLock()
        private var handler: EventHandler

        init(sourceID: UUID, handler: @escaping EventHandler) {
            self.sourceID = sourceID
            self.handler = handler
        }

        func updateHandler(_ handler: @escaping EventHandler) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func emit(_ events: [FileSystemChangeEvent]) {
            lock.lock()
            let handler = handler
            lock.unlock()
            handler(sourceID, events)
        }
    }

    private final class Registration {
        let rootPath: String
        let stream: FSEventStreamRef
        let callbackBox: CallbackBox

        init(rootPath: String, stream: FSEventStreamRef, callbackBox: CallbackBox) {
            self.rootPath = rootPath
            self.stream = stream
            self.callbackBox = callbackBox
        }

        func stop() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private let queue = DispatchQueue(label: "com.xingmingbo.XunJian.fsevents", qos: .utility)
    private let latency: CFTimeInterval
    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]

    init(latency: CFTimeInterval = 0.25) {
        self.latency = latency
    }

    deinit {
        stopAll()
    }

    func update(
        sources: [MonitoredSource],
        handler: @escaping EventHandler,
        onFailure: FailureHandler? = nil
    ) {
        let desired = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        var registrationsToStop: [Registration] = []

        lock.lock()
        for (sourceID, registration) in Array(registrations) {
            guard let source = desired[sourceID],
                  canonicalPath(source.rootPath) == registration.rootPath else {
                registrations.removeValue(forKey: sourceID)
                registrationsToStop.append(registration)
                continue
            }
            registration.callbackBox.updateHandler(handler)
        }
        let existingSourceIDs = Set(registrations.keys)
        lock.unlock()

        registrationsToStop.forEach { $0.stop() }

        for source in sources where !existingSourceIDs.contains(source.sourceID) {
            guard let registration = makeRegistration(for: source, handler: handler) else {
                onFailure?(source.sourceID, source.rootPath)
                continue
            }
            lock.lock()
            if registrations[source.sourceID] == nil {
                registrations[source.sourceID] = registration
                lock.unlock()
            } else {
                lock.unlock()
                registration.stop()
            }
        }
    }

    func stopAll() {
        lock.lock()
        let registrationsToStop = Array(registrations.values)
        registrations.removeAll()
        lock.unlock()
        registrationsToStop.forEach { $0.stop() }
    }

    private func makeRegistration(
        for source: MonitoredSource,
        handler: @escaping EventHandler
    ) -> Registration? {
        let rootPath = canonicalPath(source.rootPath)
        let callbackBox = CallbackBox(sourceID: source.sourceID, handler: handler)
        // The context retains the box on copy and releases it when the
        // stream is torn down, so a callback already executing on the
        // monitor queue can never race the box's deallocation in `stop()`.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<CallbackBox>.fromOpaque(info).retain().toOpaque()
                )
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let callbackBox = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var events: [FileSystemChangeEvent] = []
            events.reserveCapacity(eventCount)

            for index in 0..<eventCount {
                guard let path = paths[index] else { continue }
                let event = FileSystemChangeEvent(
                    path: String(cString: path),
                    flags: eventFlags[index]
                )
                if !event.kinds.isEmpty || event.requiresFullRescan {
                    events.append(event)
                }
            }

            if !events.isEmpty {
                callbackBox.emit(events)
            }
        }
        // No `NoDefer`: that flag makes FSEvents deliver events immediately
        // and ignores the latency window, defeating kernel-side batching and
        // multiplying callback hops. The coordinator's own 350ms coalescing
        // still applies on top of the 250ms latency here.
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            createFlags
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        return Registration(rootPath: rootPath, stream: stream, callbackBox: callbackBox)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
    }
}
