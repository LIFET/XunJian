import Combine
import Foundation

/// Search UI state with a deliberately narrow observation boundary.
///
/// Typing updates only the search field subtree. Completed result pages are
/// replaced as one coherent value so consumers never observe a new result
/// array paired with the previous total count or revision.
@MainActor
final class BrowseSearchStore: ObservableObject {
    struct ResultState {
        let results: [IndexedFile]?
        let totalCount: Int?
        let isSearching: Bool
        let revision: UInt64

        static let empty = ResultState(
            results: nil,
            totalCount: nil,
            isSearching: false,
            revision: 0
        )
    }

    @Published private(set) var query = ""
    @Published private(set) var resultState = ResultState.empty
    /// Preview highlighting is presentation-only state. Keeping it beside the
    /// narrow search store avoids invalidating AppModel and the full window
    /// when a query begins, progresses, or completes.
    @Published private(set) var highlightQuery = ""

    var results: [IndexedFile]? { resultState.results }
    var totalCount: Int? { resultState.totalCount }
    var isSearching: Bool { resultState.isSearching }
    var revision: UInt64 { resultState.revision }

    func setQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
    }

    func setHighlightQuery(_ query: String) {
        guard highlightQuery != query else { return }
        highlightQuery = query
    }

    func beginSearch(query: String) {
        setQuery(query)
        guard !resultState.isSearching else { return }
        resultState = ResultState(
            results: resultState.results,
            totalCount: resultState.totalCount,
            isSearching: true,
            revision: resultState.revision
        )
    }

    func finishSearchWithoutReplacingResults() {
        guard resultState.isSearching else { return }
        resultState = ResultState(
            results: resultState.results,
            totalCount: resultState.totalCount,
            isSearching: false,
            revision: resultState.revision
        )
    }

    func publishResults(_ results: [IndexedFile]?, totalCount: Int?) {
        resultState = ResultState(
            results: results,
            totalCount: totalCount,
            isSearching: false,
            revision: resultState.revision &+ 1
        )
    }
}
