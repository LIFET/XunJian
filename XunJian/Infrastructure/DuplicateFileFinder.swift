import CryptoKit
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
/// need to be loaded into memory and are not silently omitted.
enum DuplicateFileFinder {
    typealias ProgressHandler = @Sendable (_ hashed: Int, _ total: Int) -> Void

    static func find(
        in files: [IndexedFile],
        progress: ProgressHandler = { _, _ in }
    ) async throws -> [DuplicateGroup] {
        let candidates = files.filter { $0.size > 0 }
        var bySize: [Int64: [IndexedFile]] = [:]
        for file in candidates {
            bySize[file.size, default: []].append(file)
        }

        var totalToHash = 0
        var hashedCount = 0
        let groupsToHash = bySize.values.filter { $0.count > 1 }
        for group in groupsToHash {
            totalToHash += group.count
        }

        var byHash: [String: [IndexedFile]] = [:]
        for group in groupsToHash {
            for file in group {
                try Task.checkCancellation()
                let digest = try await hash(fileAt: file.url)
                byHash[digest, default: []].append(file)
                hashedCount += 1
                let progressStride = max(totalToHash / 100, 1)
                if hashedCount == totalToHash || hashedCount.isMultiple(of: progressStride) {
                    progress(hashedCount, totalToHash)
                }
            }
        }

        return byHash.compactMap { digest, files -> DuplicateGroup? in
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
    }

    /// Streams the file in 1MB chunks so multi-hundred-MB files don't get
    /// loaded into memory at once.
    static func hash(fileAt url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
