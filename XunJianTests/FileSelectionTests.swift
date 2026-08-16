import AppKit
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

        XCTAssertEqual(selection.leadID, "a")
        XCTAssertEqual(selection.anchorID, selection.leadID)
        XCTAssertNotEqual(selection.leadID, "c")
    }

    func testCommandRemovingLeadChoosesTheNearestPreviousVisibleSelection() {
        var selection = FileSelection(
            ids: Set(files),
            leadID: "d",
            anchorID: "d"
        )

        selection.select("d", in: files, command: true, shift: false)

        XCTAssertEqual(selection.ids, ["a", "b", "c"])
        XCTAssertEqual(selection.leadID, "c")
        XCTAssertEqual(selection.anchorID, "c")
        XCTAssertEqual(selection.primaryID, "c")
    }

    func testNativeTableSingleSelectionMovesLeadAndAnchor() {
        var selection = FileSelection(ids: ["a", "c"], leadID: "c", anchorID: "a")

        selection.applyNativeTableSelection(["b"], orderedIDs: files)

        XCTAssertEqual(selection.ids, ["b"])
        XCTAssertEqual(selection.leadID, "b")
        XCTAssertEqual(selection.anchorID, "b")
    }

    func testNativeTableCommandAdditionMovesLeadAndAnchor() {
        var selection = FileSelection(ids: ["b"], leadID: "b", anchorID: "b")

        selection.applyNativeTableSelection(
            ["b", "d"],
            orderedIDs: files,
            command: true
        )

        XCTAssertEqual(selection.ids, ["b", "d"])
        XCTAssertEqual(selection.leadID, "d")
        XCTAssertEqual(selection.anchorID, "d")
    }

    func testNativeTableRangeInfersEndpointFarthestFromAnchor() {
        var selection = FileSelection(ids: ["c"], leadID: "c", anchorID: "c")

        selection.applyNativeTableSelection(
            ["a", "b", "c"],
            orderedIDs: files,
            idIndex: ["a": 0, "b": 1, "c": 2, "d": 3],
            shift: true
        )

        XCTAssertEqual(selection.leadID, "a")
        XCTAssertEqual(selection.anchorID, "c")
    }

    func testNativeSelectionEchoGuardRejectsStaleExternalSelectionBeforePublication() {
        var guardState = NativeSelectionEchoGuard()
        guardState.nativeSelectionDidChange(to: ["b"])

        XCTAssertFalse(guardState.shouldApplyExternalSelection(["a"]))
        guardState.nativeSelectionPublicationDidComplete()
        XCTAssertFalse(guardState.shouldApplyExternalSelection(["b"]))
        XCTAssertTrue(guardState.shouldApplyExternalSelection(["c"]))
    }

    func testNativeSelectionEchoGuardAcceptsModelNormalizationAfterPublication() {
        var guardState = NativeSelectionEchoGuard()
        guardState.nativeSelectionDidChange(to: ["a", "b"])
        guardState.nativeSelectionPublicationDidComplete()

        XCTAssertTrue(guardState.shouldApplyExternalSelection(["b"]))
    }

    func testLargeTableColumnDefaultsHideOptionalColumnsAndKeepNameVisible() {
        XCTAssertEqual(
            LargeFileTableColumnVisibility.hiddenIDs(stored: nil),
            ["created", "tags", "location"]
        )
        XCTAssertFalse(
            LargeFileTableColumnVisibility.hiddenIDs(stored: ["name", "kind"])
                .contains("name")
        )
        XCTAssertTrue(
            LargeFileTableColumnVisibility.hiddenIDs(stored: []).isEmpty,
            "An explicit v3 empty array means the user chose to show every column"
        )
        XCTAssertEqual(
            LargeFileTableColumnVisibility.storageKey(
                autosaveName: "XunJian.AllFiles.LargeTable"
            ),
            "LargeFileTableView.XunJian.AllFiles.LargeTable.hiddenColumns.v4"
        )
        XCTAssertEqual(
            LargeFileTableColumnVisibility.persistedIDsAfterRestoration(stored: nil),
            ["created", "location", "tags"]
        )
        XCTAssertEqual(
            LargeFileTableColumnVisibility.persistedIDsAfterRestoration(stored: []),
            [],
            "A deliberate v4 empty preference must remain all-visible"
        )
    }

    func testLargeTableColumnVisibilityCanHideAndRestoreAColumn() {
        let hidden = LargeFileTableColumnVisibility.toggledHiddenIDs(
            current: [],
            column: .kind
        )
        XCTAssertEqual(hidden, ["kind"])

        let restored = LargeFileTableColumnVisibility.toggledHiddenIDs(
            current: hidden,
            column: .kind
        )
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(
            LargeFileTableColumnVisibility.toggledHiddenIDs(
                current: ["kind"],
                column: .name
            ).contains("kind")
        )
    }

    func testLargeTableColumnVisibilityNormalizesNativeAutosaveIdentifiers() {
        let defaultHidden = LargeFileTableColumnVisibility.hiddenIDs(stored: nil)
        XCTAssertTrue(
            LargeFileTableColumnVisibility.isHidden(
                tableColumnIdentifier: LargeFileTableColumn.created.identifier.rawValue,
                hiddenIDs: defaultHidden
            )
        )
        XCTAssertTrue(
            LargeFileTableColumnVisibility.isHidden(
                tableColumnIdentifier: LargeFileTableColumn.location.identifier.rawValue,
                hiddenIDs: defaultHidden
            )
        )
        XCTAssertTrue(
            LargeFileTableColumnVisibility.isHidden(
                tableColumnIdentifier: LargeFileTableColumn.tags.identifier.rawValue,
                hiddenIDs: defaultHidden
            )
        )
        XCTAssertFalse(
            LargeFileTableColumnVisibility.isHidden(
                tableColumnIdentifier: LargeFileTableColumn.created.identifier.rawValue,
                hiddenIDs: []
            ),
            "An explicit empty v4 preference must override autosaved hidden state"
        )
        XCTAssertEqual(
            LargeFileTableColumnVisibility.persistedHiddenIDs(
                columnStates: [
                    (LargeFileTableColumn.created.identifier.rawValue, true),
                    (LargeFileTableColumn.location.identifier.rawValue, true),
                    (LargeFileTableColumn.tags.identifier.rawValue, true),
                    (LargeFileTableColumn.kind.identifier.rawValue, false)
                ]
            ),
            ["created", "location", "tags"],
            "Native prefixed identifiers must persist in the v4 plain-ID namespace"
        )
    }

    func testNativeGridSelectionAppearanceMovesFromExistingItemToClickedItem() {
        let initial = Set([IndexPath(item: 0, section: 0)])
        XCTAssertTrue(NativeGridSelectionAppearance.isSelected(item: 0, selection: initial))
        XCTAssertFalse(NativeGridSelectionAppearance.isSelected(item: 1, selection: initial))

        let afterClick = Set([IndexPath(item: 1, section: 0)])
        XCTAssertFalse(NativeGridSelectionAppearance.isSelected(item: 0, selection: afterClick))
        XCTAssertTrue(NativeGridSelectionAppearance.isSelected(item: 1, selection: afterClick))
    }

    @MainActor
    func testLargeTableNameCellVisualsPublishPlainCommandAndShiftSelection() throws {
        let dataSource = NativeTableTestDataSource(rowCount: 4)
        let tableView = LargeFileNSTableView(
            frame: NSRect(x: 0, y: 0, width: 340, height: 160)
        )
        let column = NSTableColumn(identifier: LargeFileTableColumn.name.identifier)
        column.width = 340
        tableView.addTableColumn(column)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.allowsMultipleSelection = true
        tableView.reloadData()

        func event(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        let rowOneCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        rowOneCell.layoutSubtreeIfNeeded()
        try XCTUnwrap(rowOneCell.textField)
            .mouseDown(with: event())
        XCTAssertEqual(tableView.selectedRowIndexes, [1])

        let rowThreeCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 3, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        rowThreeCell.layoutSubtreeIfNeeded()
        try XCTUnwrap(rowThreeCell.imageView)
            .mouseDown(with: event(modifiers: .command))
        XCTAssertEqual(tableView.selectedRowIndexes, [1, 3])

        let rowZeroCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        rowZeroCell.mouseDown(with: try event(modifiers: .shift))
        XCTAssertEqual(tableView.selectedRowIndexes, [0, 1, 2, 3])
        XCTAssertGreaterThanOrEqual(dataSource.selectionChangeCount, 3)
    }

    func testInactiveNativeRendererCannotClearSelectionDuringViewSwitch() {
        XCTAssertTrue(
            FileBrowseSelection.shouldAcceptNativeSelectionPublication(
                from: .list,
                currentMode: .list
            )
        )
        XCTAssertFalse(
            FileBrowseSelection.shouldAcceptNativeSelectionPublication(
                from: .list,
                currentMode: .grid
            )
        )
        XCTAssertFalse(
            FileBrowseSelection.shouldAcceptNativeSelectionPublication(
                from: .grid,
                currentMode: .list
            )
        )
    }

    @MainActor
    func testNativeGridItemRoutesAllVisualHitsThroughTheWholeCard() throws {
        let card = LargeFileGridItemView(
            frame: NSRect(x: 0, y: 0, width: 132, height: 148)
        )
        card.layoutSubtreeIfNeeded()
        var routedClicks = 0
        card.mouseDownHandler = { _ in routedClicks += 1 }
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        for subview in card.subviews {
            let visualCenter = card.convert(
                NSPoint(x: subview.bounds.midX, y: subview.bounds.midY),
                from: subview
            )
            let hitView = card.hitTest(visualCenter)
            XCTAssertTrue(hitView === card)
            hitView?.mouseDown(with: event)
        }

        XCTAssertEqual(routedClicks, card.subviews.count)
    }

    @MainActor
    func testNativeGridCollectionAppliesPlainCommandAndShiftSelection() {
        let dataSource = NativeGridTestDataSource(itemCount: 4)
        let collectionView = LargeFileNSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 300)
        )
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        collectionView.dataSource = dataSource
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.reloadData()

        collectionView.applyItemSelectionGesture(item: 1, modifiers: [])
        XCTAssertEqual(collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        XCTAssertEqual(collectionView.leadItem, 1)
        XCTAssertEqual(collectionView.selectionAnchorItem, 1)

        collectionView.applyItemSelectionGesture(item: 3, modifiers: .command)
        XCTAssertEqual(
            collectionView.selectionIndexPaths,
            [IndexPath(item: 1, section: 0), IndexPath(item: 3, section: 0)]
        )
        XCTAssertEqual(collectionView.leadItem, 3)
        XCTAssertEqual(collectionView.selectionAnchorItem, 3)

        collectionView.applyItemSelectionGesture(item: 0, modifiers: .shift)
        XCTAssertEqual(
            Set(collectionView.selectionIndexPaths.map(\.item)),
            [0, 1, 2, 3]
        )
        XCTAssertEqual(collectionView.leadItem, 0)
        XCTAssertEqual(collectionView.selectionAnchorItem, 3)
    }
}

@MainActor
private final class NativeGridTestDataSource: NSObject, NSCollectionViewDataSource {
    let itemCount: Int

    init(itemCount: Int) {
        self.itemCount = itemCount
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        itemCount
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}

@MainActor
private final class NativeTableTestDataSource: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate {
    let rowCount: Int
    private(set) var selectionChangeCount = 0

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let cell = LargeFileNameCellView(
            identifier: NSUserInterfaceItemIdentifier("LargeFileTable.NameCell.Test")
        )
        cell.textField?.stringValue = "row-\(row)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChangeCount += 1
    }
}
