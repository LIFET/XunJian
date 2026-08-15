import Foundation

/// Recent search terms shown under the search field (N03).
///
/// Search terms are user content, so they stay in this process's own
/// `UserDefaults`, are never written to the index or any log, and the UI
/// always offers a way to remove them.
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    static let maximumEntryCount = 10
    private static let defaultsKey = "search.recentQueries"

    @Published private(set) var entries: [String] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.sanitized(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Records a committed query. Called when the user presses Return rather
    /// than on every keystroke, so the list holds intentional searches only.
    func record(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        var updated = entries.filter {
            $0.localizedCaseInsensitiveCompare(query) != .orderedSame
        }
        updated.insert(query, at: 0)
        persist(Array(updated.prefix(Self.maximumEntryCount)))
    }

    func remove(_ query: String) {
        persist(entries.filter { $0 != query })
    }

    func clear() {
        persist([])
    }

    private func persist(_ newEntries: [String]) {
        entries = newEntries
        defaults.set(newEntries, forKey: Self.defaultsKey)
    }

    /// Drops blanks and case-insensitive duplicates, keeping the newest first.
    /// Applied on load so a hand-edited or legacy defaults value can't produce
    /// duplicate rows or an unbounded list.
    static func sanitized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                continue
            }
            result.append(trimmed)
            if result.count == maximumEntryCount { break }
        }
        return result
    }
}
