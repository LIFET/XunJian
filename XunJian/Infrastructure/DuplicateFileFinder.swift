import CryptoKit
import Foundation

/// A set of files with identical content (N13).
struct DuplicateGroup: Identifiable, Sendable {
    var id: String { hash }
    let hash: String
    let size: Int64
    var files: [IndexedFile]
}

/// Content-hash duplicate detection, approved for use (the "no content
/// hashing" boundary was lifted for this feature).
///
/// Cost control: files are first grouped by size so hashing only runs inside
/// groups that can actually match, and files above `maximumHashedBytes` are
/// skipped (their duplicates would rarely be worth the I/O anyway).
enum DuplicateFileFinder {
    static let maximumHashedBytes: Int64 = 128 * 1_024 * 1_024

    typealias ProgressHandler = @Sendable (_ hashed: Int, _ total: Int) -> Void

    static func find(
        in files: [IndexedFile],
        progress: ProgressHandler = { _, _ in }
    ) async -> [DuplicateGroup] {
        let candidates = files.filter { $0.size > 0 && $0.size <= maximumHashedBytes }
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
                guard !Task.isCancelled else { return [] }
                if let digest = hash(fileAt: file.url) {
                    byHash[digest, default: []].append(file)
                }
                hashedCount += 1
                progress(hashedCount, totalToHash)
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
    private static func hash(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
