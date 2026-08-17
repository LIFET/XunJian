import SwiftUI

@MainActor
func consumeAIStreamForDisplay(
    _ stream: AsyncThrowingStream<String, any Error>,
    update: (String) -> Void
) async throws {
    let clock = ContinuousClock()
    var lastUpdate = clock.now
    var rendered = ""
    var pending = ""

    for try await chunk in stream {
        try Task.checkCancellation()
        pending += chunk
        let now = clock.now
        guard lastUpdate.duration(to: now) >= .milliseconds(50) else { continue }
        rendered += pending
        pending.removeAll(keepingCapacity: true)
        update(rendered)
        lastUpdate = now
    }
    if !pending.isEmpty {
        rendered += pending
        update(rendered)
    }
}
enum AITaskSheet: Identifiable {
    case search
    case explain(IndexedFile)
    case ask(IndexedFile)
    case classify

    var id: String {
        switch self {
        case .search: "search"
        case let .explain(file): "explain-\(file.id)"
        case let .ask(file): "ask-\(file.id)"
        case .classify: "classify"
        }
    }
}
