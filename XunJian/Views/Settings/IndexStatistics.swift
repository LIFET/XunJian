import Foundation

/// Read-only index figures shown in Settings.
///
/// Computed off the main thread because the database size needs file-system
/// access and the "last indexed" value scans the in-memory file list.
struct IndexStatistics: Equatable, Sendable {
    /// Total bytes on disk, or `nil` when the database has not been created
    /// yet or cannot be read.
    let databaseSizeBytes: Int64?
    let lastIndexedAt: Date?

    static let unknown = IndexStatistics(databaseSizeBytes: nil, lastIndexedAt: nil)

    var databaseSizeText: String {
        guard let databaseSizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: databaseSizeBytes, countStyle: .file)
    }

    var lastIndexedText: String {
        guard let lastIndexedAt else { return "—" }
        return FinderDateFormatting.string(for: lastIndexedAt)
    }

    static func make(files: [IndexedFile]) async -> IndexStatistics {
        let lastIndexedAt = files.map(\.indexedAt).max()
        let size = await Task.detached(priority: .utility) {
            databaseSizeOnDisk()
        }.value
        return IndexStatistics(databaseSizeBytes: size, lastIndexedAt: lastIndexedAt)
    }

    /// SQLite keeps the write-ahead log and shared-memory file alongside the
    /// main database, so all three are counted to reflect real disk usage.
    private static func databaseSizeOnDisk() -> Int64? {
        guard let databaseURL = try? FileIndexDatabase.defaultDatabaseURL() else { return nil }
        let candidates = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]

        var total: Int64 = 0
        var foundAny = false
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { continue }
            total += Int64(size)
            foundAny = true
        }
        return foundAny ? total : nil
    }
}
