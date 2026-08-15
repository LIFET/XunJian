import XCTest
@testable import XunJian

@MainActor
final class ScanProgressStoreTests: XCTestCase {
    func testUpdatePublishesANewValue() {
        let store = ScanProgressStore()
        XCTAssertNil(store.progress)
        XCTAssertFalse(store.isActive)

        store.update(ScanProgress(discoveredCount: 100, currentPath: "/tmp"))
        XCTAssertEqual(store.progress?.discoveredCount, 100)
        XCTAssertTrue(store.isActive)

        store.update(nil)
        XCTAssertNil(store.progress)
        XCTAssertFalse(store.isActive)
    }

    func testIdenticalProgressDoesNotReplaceTheValue() {
        let store = ScanProgressStore()
        let progress = ScanProgress(discoveredCount: 200, currentPath: "/tmp")
        store.update(progress)
        let first = store.progress
        store.update(progress)
        XCTAssertTrue(store.progress == first)
    }
}
