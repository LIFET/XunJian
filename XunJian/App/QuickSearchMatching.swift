import Foundation

/// Tiny thread-safe cancellation flag so a detached full-index scan can be
/// abandoned from outside: the owning task flips it in its cancellation
/// handler and the scan polls it per file.
final class QuickSearchCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Shared substring match for command-palette and menu-bar quick search.
///
/// Matches are case- and diacritic-insensitive. Path is included because
/// people often remember the folder, not the file name.
enum QuickSearchMatching {
    static func matches(_ candidate: String, query: String) -> Bool {
        candidate.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    static func matches(file: IndexedFile, query: String) -> Bool {
        matches(file.name, query: query) || matches(file.path, query: query)
    }

    /// True when the query hit the path but not the file name, so the UI can
    /// label the result as a path match.
    static func matchedPathOnly(file: IndexedFile, query: String) -> Bool {
        !matches(file.name, query: query) && matches(file.path, query: query)
    }

    /// Walks the index once, keeping only `limit` hits and counting the rest
    /// so a "see remaining in All Files" action can be offered without
    /// allocating every match.
    ///
    /// `isCancelled` is polled per file so callers that run this scan inside
    /// a `Task.detached` (whose cancellation cannot be observed) can abandon
    /// stale full-index walks the moment newer input arrives.
    static func prefixMatches(
        in files: [IndexedFile],
        query: String,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> (files: [IndexedFile], remainingCount: Int) {
        var matched: [IndexedFile] = []
        var remaining = 0
        matched.reserveCapacity(min(limit, files.count))
        for file in files {
            guard !isCancelled() else { break }
            guard matches(file: file, query: query) else { continue }
            if matched.count < limit {
                matched.append(file)
            } else {
                remaining += 1
            }
        }
        return (matched, remaining)
    }
}
