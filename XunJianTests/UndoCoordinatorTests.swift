import XCTest
@testable import XunJian

@MainActor
final class UndoCoordinatorTests: XCTestCase {
    func testUndoRunsMostRecentActionFirst() async throws {
        let coordinator = UndoCoordinator()
        var reverted: [String] = []

        coordinator.record(title: "first") { reverted.append("first") }
        coordinator.record(title: "second") { reverted.append("second") }

        try await coordinator.undoLast()
        try await coordinator.undoLast()

        XCTAssertEqual(reverted, ["second", "first"])
        XCTAssertFalse(coordinator.canUndo)
    }

    func testNextTitleDescribesPendingAction() {
        let coordinator = UndoCoordinator()
        XCTAssertNil(coordinator.nextTitle)
        XCTAssertFalse(coordinator.canUndo)

        coordinator.record(title: "rename") {}
        coordinator.record(title: "move") {}

        XCTAssertTrue(coordinator.canUndo)
        XCTAssertEqual(coordinator.nextTitle, "move")
    }

    func testUndoOnEmptyStackDoesNothing() async throws {
        let coordinator = UndoCoordinator()
        try await coordinator.undoLast()
        XCTAssertFalse(coordinator.canUndo)
    }

    /// A revert that throws must still be popped: the captured state is stale,
    /// so retrying it would keep failing and block everything beneath it.
    func testFailedRevertIsRemovedFromStack() async {
        struct RevertFailure: Error {}
        let coordinator = UndoCoordinator()
        coordinator.record(title: "beneath") {}
        coordinator.record(title: "failing") { throw RevertFailure() }

        do {
            try await coordinator.undoLast()
            XCTFail("Expected the revert to throw")
        } catch {
            // Expected.
        }

        XCTAssertEqual(coordinator.nextTitle, "beneath")
        XCTAssertTrue(coordinator.canUndo)
    }

    func testStackIsBoundedToMaximumDepth() async throws {
        let coordinator = UndoCoordinator()
        let overflow = UndoCoordinator.maximumDepth + 5
        for index in 0..<overflow {
            coordinator.record(title: "action-\(index)") {}
        }

        XCTAssertEqual(coordinator.entries.count, UndoCoordinator.maximumDepth)
        // The newest entry survives and the oldest ones are dropped.
        XCTAssertEqual(coordinator.nextTitle, "action-\(overflow - 1)")
        XCTAssertFalse(coordinator.entries.contains { $0.title == "action-0" })
    }

    func testClearDropsEveryEntry() {
        let coordinator = UndoCoordinator()
        coordinator.record(title: "rename") {}
        coordinator.record(title: "move") {}

        coordinator.clear()

        XCTAssertFalse(coordinator.canUndo)
        XCTAssertNil(coordinator.nextTitle)
    }
}
