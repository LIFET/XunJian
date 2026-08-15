import CryptoKit
import Darwin
import Foundation

/// A set of files with identical content (N13).
struct DuplicateGroup: Identifiable, Sendable {
    var id: String { hash }
    let hash: String
    let size: Int64
    var files: [IndexedFile]
}

/// Chooses which duplicate to keep when the user asks to trash the rest.
enum DuplicateCleanup {
    static func fileToKeep(in files: [IndexedFile]) -> IndexedFile? {
        files.max { lhs, rhs in
            let left = lhs.modifiedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.modifiedAt ?? rhs.createdAt ?? .distantPast
            if left != right {
                return left < right
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
        }
    }

    static func filesToTrash(keepingNewestIn files: [IndexedFile]) -> [IndexedFile] {
        guard let keeper = fileToKeep(in: files) else { return files }
        return files.filter { $0.id != keeper.id }
    }
}

/// Content-hash duplicate detection, approved for use (the "no content
/// hashing" boundary was lifted for this feature).
///
/// Cost control: files are first grouped by size so hashing only runs inside
/// groups that can actually match. Hashing is streamed, so large files do not
/// need to be loaded into memory and are not silently omitted. Unreadable
/// files (document packages, missing paths) are counted and skipped so one
/// failure cannot abort the whole scan.
enum DuplicateFileFinder {
    typealias ProgressHandler = @Sendable (_ hashed: Int, _ total: Int) -> Void

    struct Result: Sendable {
        var groups: [DuplicateGroup]
        var unreadCount: Int
    }

    struct Fingerprint: Equatable, Sendable {
        let digest: String
        let version: FileSystemObjectVersion
    }

    static func find(
        in files: [IndexedFile],
        progress: ProgressHandler = { _, _ in }
    ) async throws -> Result {
        let candidates = files.filter { $0.size > 0 }
        var bySize: [Int64: [IndexedFile]] = [:]
        for file in candidates {
            bySize[file.size, default: []].append(file)
        }

        var totalToHash = 0
        var hashedCount = 0
        var unreadCount = 0
        let groupsToHash = bySize.values.filter { $0.count > 1 }
        for group in groupsToHash {
            totalToHash += group.count
        }

        var byHash: [String: [IndexedFile]] = [:]
        for group in groupsToHash {
            try await withThrowingTaskGroup(
                of: (file: IndexedFile, digest: String?).self
            ) { taskGroup in
                var iterator = group.makeIterator()
                func addNext() {
                    guard let file = iterator.next() else { return }
                    taskGroup.addTask {
                        do {
                            guard canHashFile(at: file.url) else { return (file, nil) }
                            return (file, try await hash(fileAt: file.url))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (file, nil)
                        }
                    }
                }
                for _ in 0..<min(Self.maximumConcurrentHashes, group.count) {
                    addNext()
                }
                while let completed = try await taskGroup.next() {
                    if let digest = completed.digest {
                        byHash[digest, default: []].append(completed.file)
                    } else {
                        unreadCount += 1
                    }
                    hashedCount += 1
                    let progressStride = max(totalToHash / 100, 1)
                    if hashedCount == totalToHash || hashedCount.isMultiple(of: progressStride) {
                        progress(hashedCount, totalToHash)
                    }
                    addNext()
                }
            }
        }

        let groups = byHash.compactMap { digest, files -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            return DuplicateGroup(
                hash: digest,
                size: files[0].size,
                files: files.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
            )
        }
        .sorted { $0.size > $1.size }
        return Result(groups: groups, unreadCount: unreadCount)
    }

    /// Re-hashes the exact candidates immediately before cleanup. Indexed size
    /// and modification dates are only hints; the current bytes are authoritative.
    static func stillMatches(_ group: DuplicateGroup) async throws -> Bool {
        let result = try await find(in: group.files)
        guard result.unreadCount == 0,
              result.groups.count == 1,
              let verified = result.groups.first,
              verified.hash == group.hash else {
            return false
        }
        return Set(verified.files.map(\.id)) == Set(group.files.map(\.id))
    }

    /// Directories (including document packages) cannot be hashed as a single
    /// file handle, so they are reported as unread instead of failing the scan.
    static func canHashFile(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFREG
    }

    /// Streams the file in 1MB chunks so multi-hundred-MB files don't get
    /// loaded into memory at once. The read loop is blocking I/O, so it runs
    /// on a detached task instead of occupying a cooperative pool thread.
    static func hash(fileAt url: URL) async throws -> String {
        try await fingerprint(fileAt: url).digest
    }

    /// Reads from one descriptor and requires metadata to remain identical for
    /// the whole hash, so a concurrent writer cannot produce a mixed digest.
    static func fingerprint(fileAt url: URL) async throws -> Fingerprint {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = open(
                url.path,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw FileOperationError.fileNotFound
            }
            var shouldCloseDescriptor = true
            defer {
                if shouldCloseDescriptor {
                    close(descriptor)
                }
            }

            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  before.st_mode & S_IFMT == S_IFREG else {
                throw FileOperationError.fileNotFound
            }
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            )
            shouldCloseDescriptor = false
            defer { try? handle.close() }
            let beforeVersion = FileSystemObjectVersion(metadata: before)

            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
            var after = stat()
            guard fstat(handle.fileDescriptor, &after) == 0 else {
                throw FileOperationError.fileNotFound
            }
            guard beforeVersion == FileSystemObjectVersion(metadata: after) else {
                throw FileOperationError.fileIdentityChanged
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return Fingerprint(digest: digest, version: beforeVersion)
        }.value
    }

    /// Hashing runs with bounded concurrency per size group: duplicate-size
    /// groups on large libraries previously hashed one file at a time.
    private static let maximumConcurrentHashes = 4
}
