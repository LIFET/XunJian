import Foundation

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
    static func prefixMatches(
        in files: [IndexedFile],
        query: String,
        limit: Int
    ) -> (files: [IndexedFile], remainingCount: Int) {
        var matched: [IndexedFile] = []
        var remaining = 0
        matched.reserveCapacity(min(limit, files.count))
        for file in files {
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
