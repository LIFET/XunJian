import CoreServices
import Darwin
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
    /// Last host-wide FSEvents cursor committed for this exact monitored root.
    /// A whole-Mac source owns multiple streams, so sharing one cursor across
    /// roots could let a faster stream hide events from a slower one.
    let sinceEventID: FSEventStreamEventId?

    init(
        sourceID: UUID,
        rootPath: String,
        sinceEventID: FSEventStreamEventId? = nil
    ) {
        self.sourceID = sourceID
        self.rootPath = rootPath
        self.sinceEventID = sinceEventID
    }
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
    typealias EventHandler = @Sendable (
        UUID,
        String,
        [FileSystemChangeEvent],
        FSEventStreamEventId
    ) -> Void
    typealias FailureHandler = @Sendable (UUID, String) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let sourceID: UUID
        let rootPath: String
        private let lock = NSLock()
        private var handler: EventHandler

        init(sourceID: UUID, rootPath: String, handler: @escaping EventHandler) {
            self.sourceID = sourceID
            self.rootPath = rootPath
            self.handler = handler
        }

        func updateHandler(_ handler: @escaping EventHandler) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func emit(_ events: [FileSystemChangeEvent], lastEventID: FSEventStreamEventId) {
            lock.lock()
            let handler = handler
            lock.unlock()
            handler(sourceID, rootPath, events, lastEventID)
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

    private struct RegistrationKey: Hashable {
        let sourceID: UUID
        let rootPath: String
    }

    private let queue = DispatchQueue(label: "com.xingmingbo.XunJian.fsevents", qos: .utility)
    private let latency: CFTimeInterval
    private let lock = NSLock()
    private var registrations: [RegistrationKey: Registration] = [:]

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
        let desired = Dictionary(
            sources.map {
                let rootPath = canonicalPath($0.rootPath)
                return (
                    RegistrationKey(sourceID: $0.sourceID, rootPath: rootPath),
                    MonitoredSource(sourceID: $0.sourceID, rootPath: rootPath)
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        var registrationsToStop: [Registration] = []

        lock.lock()
        for (key, registration) in Array(registrations) {
            guard let source = desired[key],
                  canonicalPath(source.rootPath) == registration.rootPath else {
                registrations.removeValue(forKey: key)
                registrationsToStop.append(registration)
                continue
            }
            registration.callbackBox.updateHandler(handler)
        }
        let existingKeys = Set(registrations.keys)
        lock.unlock()

        registrationsToStop.forEach { $0.stop() }

        for source in sources {
            let key = RegistrationKey(
                sourceID: source.sourceID,
                rootPath: canonicalPath(source.rootPath)
            )
            guard !existingKeys.contains(key) else { continue }
            guard let registration = makeRegistration(for: source, handler: handler) else {
                onFailure?(source.sourceID, source.rootPath)
                continue
            }
            lock.lock()
            if registrations[key] == nil {
                registrations[key] = registration
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
        let callbackBox = CallbackBox(
            sourceID: source.sourceID,
            rootPath: rootPath,
            handler: handler
        )
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
        let callback: FSEventStreamCallback = {
            _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let callbackBox = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var events: [FileSystemChangeEvent] = []
            events.reserveCapacity(eventCount)
            var lastEventID: FSEventStreamEventId = 0

            for index in 0..<eventCount {
                lastEventID = max(lastEventID, eventIDs[index])
                guard let path = paths[index] else { continue }
                let event = FileSystemChangeEvent(
                    path: String(cString: path),
                    flags: eventFlags[index]
                )
                if !event.kinds.isEmpty || event.requiresFullRescan {
                    events.append(event)
                }
            }

            if lastEventID > 0 {
                callbackBox.emit(events, lastEventID: lastEventID)
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
        let startEventID = source.sinceEventID ?? FSEventsGetCurrentEventId()
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootPath] as CFArray,
            startEventID,
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
        // Persist the exact boundary used for a source that has never had a
        // cursor. Future launches can then replay every event after it.
        if source.sinceEventID == nil {
            callbackBox.emit([], lastEventID: startEventID)
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

/// Shallow vnode monitoring for Whole-Mac topology and home-level files.
///
/// FSEvents is recursive, so registering the user's home as a second stream
/// duplicated every event already delivered by the per-scope streams. A vnode
/// source reports changes only for the watched directory or file, which is
/// exactly what is needed to discover new top-level entries, update direct
/// home files, and notice a late iCloud Drive mount.
final class DirectoryTopologyMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable () -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    private final class Registration {
        let path: String
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject

        init(path: String, descriptor: Int32, source: DispatchSourceFileSystemObject) {
            self.path = path
            self.descriptor = descriptor
            self.source = source
        }

        func stop() {
            source.cancel()
        }
    }

    private let queue = DispatchQueue(
        label: "com.xingmingbo.XunJian.directory-topology",
        qos: .utility
    )
    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]

    deinit { stopAll() }

    func update(
        paths: [String],
        handler: @escaping EventHandler,
        onFailure: FailureHandler? = nil
    ) {
        let desiredPaths = Set(paths.map(Self.canonicalPath))
        var registrationsToStop: [Registration] = []

        lock.lock()
        for (path, registration) in Array(registrations) where !desiredPaths.contains(path) {
            registrations.removeValue(forKey: path)
            registrationsToStop.append(registration)
        }
        let existingPaths = Set(registrations.keys)
        lock.unlock()

        registrationsToStop.forEach { $0.stop() }

        for path in desiredPaths.subtracting(existingPaths) {
            guard let registration = makeRegistration(path: path, handler: handler) else {
                onFailure?(path)
                continue
            }
            lock.lock()
            if registrations[path] == nil {
                registrations[path] = registration
                lock.unlock()
                registration.source.resume()
            } else {
                lock.unlock()
                registration.source.resume()
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
        path: String,
        handler: @escaping EventHandler
    ) -> Registration? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        return Registration(path: path, descriptor: descriptor, source: source)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
    }
}
