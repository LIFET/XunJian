import XCTest
@testable import XunJian

final class FileSelectionTests: XCTestCase {
    private let files = ["a", "b", "c", "d"]

    func testPlainClickReplacesSelectionAndMovesAnchor() {
        var selection = FileSelection()
        selection.select("b", in: files, command: false, shift: false)
        selection.select("d", in: files, command: false, shift: false)

        XCTAssertEqual(selection.ids, ["d"])
        XCTAssertEqual(selection.leadID, "d")
        XCTAssertEqual(selection.anchorID, "d")
        XCTAssertEqual(selection.primaryID, "d")
    }

    func testCommandClickTogglesWithoutClearingTheRest() {
        var selection = FileSelection()
        selection.select("a", in: files, command: false, shift: false)
        selection.select("c", in: files, command: true, shift: false)
        selection.select("a", in: files, command: true, shift: false)

        XCTAssertEqual(selection.ids, ["c"])
        XCTAssertEqual(selection.leadID, "c")
        XCTAssertEqual(selection.anchorID, "c")
    }

    func testShiftClickSelectsInclusiveRangeFromAnchor() {
        var selection = FileSelection()
        selection.select("a", in: files, command: false, shift: false)
        selection.select("c", in: files, command: false, shift: true)

        XCTAssertEqual(selection.ids, ["a", "b", "c"])
        XCTAssertEqual(selection.leadID, "c")
        XCTAssertEqual(selection.anchorID, "a")
    }

    func testShiftClickKeepsAnchorWhenTheLeadMovesAgain() {
        var selection = FileSelection()
        selection.select("b", in: files, command: false, shift: false)
        selection.select("d", in: files, command: false, shift: true)
        selection.select("a", in: files, command: false, shift: true)

        XCTAssertEqual(selection.ids, ["a", "b"])
        XCTAssertEqual(selection.leadID, "a")
        XCTAssertEqual(selection.anchorID, "b")
    }

    func testArrowMovesLeadAndReplacesSelection() {
        var selection = FileSelection()
        selection.select("a", in: files, command: false, shift: false)
        selection.moveLead(by: 2, in: files, extending: false)

        XCTAssertEqual(selection.ids, ["c"])
        XCTAssertEqual(selection.leadID, "c")
        XCTAssertEqual(selection.anchorID, "c")
    }

    func testShiftArrowExtendsFromStickyAnchor() {
        var selection = FileSelection()
        selection.select("b", in: files, command: false, shift: false)
        selection.moveLead(by: 1, in: files, extending: true)
        selection.moveLead(by: 1, in: files, extending: true)

        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        XCTAssertEqual(selection.leadID, "d")
        XCTAssertEqual(selection.anchorID, "b")
    }

    func testArrowClampsAtBothEnds() {
        var selection = FileSelection()
        selection.select("a", in: files, command: false, shift: false)
        selection.moveLead(by: -3, in: files, extending: false)
        XCTAssertEqual(selection.leadID, "a")

        selection.moveLead(by: 20, in: files, extending: false)
        XCTAssertEqual(selection.ids, ["d"])
        XCTAssertEqual(selection.leadID, "d")
    }

    func testResolveIdentityKeepsTheRestOfAMultiSelection() {
        var selection = FileSelection()
        selection.select("a", in: files, command: false, shift: false)
        selection.select("c", in: files, command: true, shift: false)
        selection.resolveIdentity(from: "c", to: "c-renamed")

        XCTAssertEqual(selection.ids, ["a", "c-renamed"])
        XCTAssertEqual(selection.leadID, "c-renamed")
        XCTAssertEqual(selection.anchorID, "c-renamed")
    }

    func testSelectAllUsesTheFirstVisibleFileAsLead() {
        var selection = FileSelection()
        selection.selectAll(orderedIDs: files)

        XCTAssertEqual(selection.ids, Set(files))
        XCTAssertEqual(selection.leadID, "a")
        XCTAssertEqual(selection.anchorID, "a")
    }

    func testReconcileDropsStaleLeadAfterExternalAssignment() {
        var selection = FileSelection()
        selection.select("c", in: files, command: false, shift: false)
        selection.ids = ["a", "b"]
        selection.reconcileMetadata()

        XCTAssertEqual(selection.leadID, selection.ids.first)
        XCTAssertEqual(selection.anchorID, selection.leadID)
        XCTAssertNotEqual(selection.leadID, "c")
    }
}
