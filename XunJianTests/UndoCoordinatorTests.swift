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

    func testRemovingOneSourceKeepsUnrelatedUndoEntries() {
        let coordinator = UndoCoordinator()
        let removedSource = UUID()
        let retainedSource = UUID()
        coordinator.record(title: "removed", affectedSourceIDs: [removedSource]) {}
        coordinator.record(title: "retained", affectedSourceIDs: [retainedSource]) {}
        coordinator.record(title: "global") {}

        coordinator.removeEntries(affecting: removedSource)

        XCTAssertEqual(coordinator.entries.map(\.title), ["retained", "global"])
    }

    func testConcurrentUndoDoesNotConsumeTheNextEntry() async throws {
        let coordinator = UndoCoordinator()
        let gate = UndoTestGate()
        var reverted: [String] = []
        coordinator.record(title: "first") { reverted.append("first") }
        coordinator.record(title: "second") {
            await gate.wait()
            reverted.append("second")
        }

        let runningUndo = Task { try await coordinator.undoLast() }
        await gate.waitUntilBlocked()
        XCTAssertTrue(coordinator.isUndoing)
        XCTAssertFalse(coordinator.canUndo)

        try await coordinator.undoLast()
        XCTAssertEqual(coordinator.nextTitle, "first")

        await gate.open()
        try await runningUndo.value
        XCTAssertEqual(reverted, ["second"])
        XCTAssertEqual(coordinator.nextTitle, "first")
    }
}

private actor UndoTestGate {
    private var isBlocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func open() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
