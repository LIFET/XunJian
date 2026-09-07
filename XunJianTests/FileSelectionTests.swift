import AppKit
import SwiftUI
import XCTest
@testable import XunJian

final class FileSelectionTests: XCTestCase {
    private let files = ["a", "b", "c", "d"]

    @MainActor
    func testSizeFilterRejectsUnsafeInputAndRecoversStoredValues() throws {
        let suite = "XunJian.SizeFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9_000_000_000_000.0, forKey: "allFiles.filterMinSizeMB")
        let credentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-unused-credentials-\(UUID().uuidString).plist")
        let model = AppModel(
            credentialStore: LocalCredentialStore(fileURL: credentialsURL),
            aiConfigurationStore: AIConfigurationStore(defaults: defaults),
            filterPreferences: defaults
        )
        defer { model.index.cancelAllTasks(); model.ai.cancelAllTasks() }
        XCTAssertEqual(model.filterMinSizeMB, 0)
        model.filterMinSizeMB = 12.5
        for invalid in [-1.0, .nan, .infinity, -.infinity, 9_000_000_000_000.0] {
            model.filterMinSizeMB = invalid
            XCTAssertEqual(model.filterMinSizeMB, 12.5, "Invalid size: \(invalid)")
            XCTAssertTrue(model.hasInvalidSizeFilterInput)
        }
        model.filterMinSizeMB = 0
        XCTAssertEqual(model.filterMinSizeMB, 0)
        XCTAssertFalse(model.hasInvalidSizeFilterInput)
        model.applyManualFilter(minSizeBytes: .max, minDate: nil)
        XCTAssertGreaterThan(model.minimumFilterSizeBytes, 0)
        XCTAssertNotNil(FileSizeFilter.bytes(fromMegabytes: model.filterMinSizeMB))
        XCTAssertEqual(FileSizeFilter.bytes(fromMegabytes: 12.5), 13_107_200)
        XCTAssertNotNil(FileSizeFilter.bytes(fromMegabytes: FileSizeFilter.maximumMegabytes))
        XCTAssertNil(FileSizeFilter.bytes(fromMegabytes: FileSizeFilter.maximumMegabytes.nextUp))
        XCTAssertEqual(FileSizeFilter.megabytes(fromBytes: -1), 0)
    }

    func testTypeOnlySearchCanBeSavedButEmptySearchCannot() {
        XCTAssertTrue(AllFilesView.canSaveSearch(
            name: "Images", query: "", hasManualFilter: false, kind: .image
        ))
        XCTAssertFalse(AllFilesView.canSaveSearch(
            name: "All", query: "  ", hasManualFilter: false, kind: nil
        ))
        XCTAssertFalse(AllFilesView.canSaveSearch(
            name: " ", query: "", hasManualFilter: false, kind: .image
        ))
        XCTAssertTrue(AllFilesView.canSaveSearch(
            name: "Large", query: "", hasManualFilter: true, kind: nil
        ))
    }

    @MainActor
    func testTypeOnlySavedSearchRoundTripsThroughDatabase() async throws {
        let databaseURL = isolatedSavedSearchDatabaseURL()
        let index = FileIndexCoordinator(isRunningTests: true, databaseURL: databaseURL)
        defer { index.cancelAllTasks() }
        let loaded = expectation(description: "isolated index loaded")
        index.onFilesChanged = { loaded.fulfill() }
        index.start()
        await fulfillment(of: [loaded], timeout: 5)
        let save = try XCTUnwrap(index.saveSearch(name: "Images", query: "", minSizeBytes: 0, minDate: nil, fileKind: .image))
        await save.value
        let reader = try FileIndexDatabase(databaseURL: databaseURL)
        let stored = try await reader.fetchSavedSearches()
        let persisted = try XCTUnwrap(stored.first)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(index.savedSearches, stored)
        XCTAssertEqual(persisted.fileKind, .image)

        let suite = "XunJian.TypeFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-unused-credentials-\(UUID().uuidString).plist")
        let model = AppModel(
            credentialStore: LocalCredentialStore(fileURL: credentialsURL),
            aiConfigurationStore: AIConfigurationStore(defaults: defaults),
            filterPreferences: defaults
        )
        defer { model.index.cancelAllTasks(); model.ai.cancelAllTasks() }
        for _ in 0..<200 where !model.index.isDatabaseAvailable {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.index.isDatabaseAvailable)
        model.selectedKind = .audio
        model.filterMinSizeMB = 100
        model.applySavedSearch(persisted)
        XCTAssertEqual(model.selectedKind, .image)
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.minimumFilterSizeBytes, 0)
        model.filterMinSizeMB = 9_000_000_000_000
        let ids = await model.allFilteredSearchResultIDs()
        XCTAssertEqual(ids, [])
    }

    @MainActor
    func testSavedSearchMutationSurvivesOlderStartupReload() async throws {
        let gate = SavedSearchSnapshotGate()
        gate.blocksNext = true
        let index = FileIndexCoordinator(isRunningTests: true, databaseURL: isolatedSavedSearchDatabaseURL(),
                                         savedSearchSnapshotLoader: { try await gate.load($0) })
        defer { gate.release(); index.cancelAllTasks() }
        let loaded = expectation(description: "older startup snapshot published")
        index.onFilesChanged = { loaded.fulfill() }
        index.start()
        await fulfillment(of: [gate.captured], timeout: 5)
        XCTAssertEqual(gate.heldSnapshot, [])
        let save = try XCTUnwrap(index.saveSearch(name: "Images", query: "", minSizeBytes: 0, minDate: nil, fileKind: .image))
        await save.value
        XCTAssertEqual(index.savedSearches.map(\.name), ["Images"])
        gate.release()
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(index.savedSearches.map(\.name), ["Images"], "旧索引快照不能覆盖已成功保存的搜索")
    }

    @MainActor
    func testSavedSearchNewerMutationWinsOverOlderFetch() async throws {
        let gate = SavedSearchSnapshotGate()
        let index = FileIndexCoordinator(isRunningTests: true, databaseURL: isolatedSavedSearchDatabaseURL(),
                                         savedSearchSnapshotLoader: { try await gate.load($0) })
        defer { gate.release(); index.cancelAllTasks() }
        let loaded = expectation(description: "index loaded")
        index.onFilesChanged = { loaded.fulfill() }
        index.start()
        await fulfillment(of: [loaded], timeout: 5)
        gate.blocksNext = true
        let first = try XCTUnwrap(index.saveSearch(name: "First", query: "", minSizeBytes: 0, minDate: nil))
        await fulfillment(of: [gate.captured], timeout: 5)
        let second = try XCTUnwrap(index.saveSearch(name: "Second", query: "", minSizeBytes: 0, minDate: nil))
        await second.value
        XCTAssertEqual(Set(index.savedSearches.map(\.name)), ["First", "Second"])
        gate.release()
        await first.value
        XCTAssertEqual(Set(index.savedSearches.map(\.name)), ["First", "Second"], "较早fetch不能丢弃后一次保存")
    }

    @MainActor
    func testSavedSearchDeletionWinsOverOlderSaveFetch() async throws {
        let gate = SavedSearchSnapshotGate()
        let databaseURL = isolatedSavedSearchDatabaseURL()
        let index = FileIndexCoordinator(isRunningTests: true, databaseURL: databaseURL,
                                         savedSearchSnapshotLoader: { try await gate.load($0) })
        defer { gate.release(); index.cancelAllTasks() }
        let loaded = expectation(description: "index loaded")
        index.onFilesChanged = { loaded.fulfill() }
        index.start()
        await fulfillment(of: [loaded], timeout: 5)
        gate.blocksNext = true
        let id = UUID()
        let save = try XCTUnwrap(index.saveSearch(name: "Remove me", query: "", minSizeBytes: 0, minDate: nil, id: id))
        await fulfillment(of: [gate.captured], timeout: 5)
        let deletion = try XCTUnwrap(index.deleteSearch(id: id))
        await deletion.value
        XCTAssertTrue(index.savedSearches.isEmpty)
        gate.release()
        await save.value
        XCTAssertTrue(index.savedSearches.isEmpty, "旧保存fetch不能复活已删除的搜索")
        let reader = try FileIndexDatabase(databaseURL: databaseURL)
        let stored = try await reader.fetchSavedSearches()
        XCTAssertTrue(stored.isEmpty)
    }

    @MainActor
    func testSavedSearchFetchFailureKeepsPublishedList() async throws {
        let gate = SavedSearchSnapshotGate()
        let index = FileIndexCoordinator(isRunningTests: true, databaseURL: isolatedSavedSearchDatabaseURL(),
                                         savedSearchSnapshotLoader: { try await gate.load($0) })
        defer { gate.release(); index.cancelAllTasks() }
        let loaded = expectation(description: "index loaded")
        index.onFilesChanged = { loaded.fulfill() }
        index.start()
        await fulfillment(of: [loaded], timeout: 5)
        let save = try XCTUnwrap(index.saveSearch(name: "Keep", query: "", minSizeBytes: 0, minDate: nil))
        await save.value
        let previous = index.savedSearches
        var errors = 0
        index.onError = { _ in errors += 1 }
        gate.failsNext = true
        let failingSave = try XCTUnwrap(index.saveSearch(name: "Unread", query: "", minSizeBytes: 0, minDate: nil))
        await failingSave.value
        XCTAssertEqual(index.savedSearches, previous)
        XCTAssertEqual(errors, 1)
        gate.failsNext = true
        let failingDelete = try XCTUnwrap(index.deleteSearch(id: try XCTUnwrap(previous.first).id))
        await failingDelete.value
        XCTAssertEqual(index.savedSearches, previous)
        XCTAssertEqual(errors, 2)
    }

    @MainActor
    func testSavedSearchCancellationPreventsSuspendedMutationPublication() async throws {
        for deletesSearch in [false, true] {
            for failsAfterRelease in [false, true] {
                let gate = SavedSearchSnapshotGate()
                let databaseURL = isolatedSavedSearchDatabaseURL()
                let index = FileIndexCoordinator(isRunningTests: true, databaseURL: databaseURL,
                                                 savedSearchSnapshotLoader: { try await gate.load($0) })
                defer { gate.release(); index.cancelAllTasks() }
                let loaded = expectation(description: "index loaded before cancellation regression")
                index.onFilesChanged = { loaded.fulfill() }
                index.start()
                await fulfillment(of: [loaded], timeout: 5)
                let originalID = UUID()
                let original = try XCTUnwrap(index.saveSearch(name: "Keep", query: "", minSizeBytes: 0, minDate: nil, id: originalID))
                await original.value
                let previous = index.savedSearches
                var errors = 0
                index.onError = { _ in errors += 1 }
                gate.blocksNext = true
                gate.failsAfterRelease = failsAfterRelease
                let mutation = try XCTUnwrap(deletesSearch
                    ? index.deleteSearch(id: originalID)
                    : index.saveSearch(name: "Committed", query: "", minSizeBytes: 0, minDate: nil))
                await fulfillment(of: [gate.captured], timeout: 5)
                index.cancelAllTasks()
                gate.release()
                await mutation.value
                XCTAssertEqual(index.savedSearches, previous, "取消后的旧保存/删除任务不能发布列表")
                XCTAssertEqual(errors, 0, "取消后的旧任务不能再向界面报告错误")
                let reader = try FileIndexDatabase(databaseURL: databaseURL)
                let stored = try await reader.fetchSavedSearches()
                XCTAssertEqual(stored.count, deletesSearch ? 0 : 2, "取消不撤销已提交的数据库操作")
            }
        }
    }

    @MainActor
    func testSavedSearchSnapshotGateReleaseBeforeCaptureDoesNotSuspend() async throws {
        let gate = SavedSearchSnapshotGate()
        let database = try FileIndexDatabase(databaseURL: isolatedSavedSearchDatabaseURL())
        gate.blocksNext = true
        gate.release()
        let completed = expectation(description: "pre-released snapshot gate returns without suspension")
        let load = Task {
            let snapshot = try await gate.load(database)
            completed.fulfill()
            return snapshot
        }
        await fulfillment(of: [gate.captured], timeout: 5)
        await fulfillment(of: [completed], timeout: 0.2)
        // Also release after a RED timeout so the regression itself never leaks
        // the continuation it has just proven would otherwise remain suspended.
        gate.release()
        let snapshot = try await load.value
        XCTAssertEqual(snapshot, [])
    }

    private func isolatedSavedSearchDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-SavedSearchTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite3")
    }

    @MainActor
    private final class SavedSearchSnapshotGate {
        var blocksNext = false
        var failsNext = false
        var failsAfterRelease = false
        let captured = XCTestExpectation(description: "saved search snapshot captured before publication")
        private(set) var heldSnapshot: [SavedSearch] = []
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func load(_ database: FileIndexDatabase) async throws -> [SavedSearch] {
            let shouldBlock = blocksNext
            blocksNext = false
            if failsNext {
                failsNext = false
                throw FileIndexError.database("Injected saved-search fetch failure")
            }
            let snapshot = try await database.fetchSavedSearches()
            if shouldBlock {
                heldSnapshot = snapshot
                await withCheckedContinuation { continuation in
                    // release() may precede completion of the database fetch.
                    // Remember that terminal state instead of registering a
                    // continuation that no future caller will resume.
                    if isReleased { continuation.resume() }
                    else { self.continuation = continuation }
                    captured.fulfill()
                }
                if failsAfterRelease {
                    throw FileIndexError.database("Injected saved-search failure after release")
                }
            }
            return snapshot
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

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
        XCTAssertFalse(guardState.shouldApplyExternalSelection(["a"]))
        XCTAssertFalse(guardState.shouldApplyExternalSelection([]))
        XCTAssertFalse(guardState.shouldApplyExternalSelection(["b"]))
        XCTAssertTrue(guardState.shouldApplyExternalSelection(["c"]))
    }

    func testNativeSelectionEchoGuardDefersModelNormalizationUntilNativeEcho() {
        var guardState = NativeSelectionEchoGuard()
        guardState.nativeSelectionDidChange(to: ["a", "b"])
        guardState.nativeSelectionPublicationDidComplete()

        XCTAssertFalse(guardState.shouldApplyExternalSelection(["b"]))
        XCTAssertFalse(guardState.shouldApplyExternalSelection(["a", "b"]))
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

        func event(
            row: Int,
            modifiers: NSEvent.ModifierFlags = []
        ) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(
                        x: 80,
                        y: tableView.rect(ofRow: row).midY
                    ),
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
            .mouseDown(with: event(row: 1))
        XCTAssertEqual(tableView.selectedRowIndexes, [1])
        XCTAssertEqual(dataSource.selectionChangeCount, 1)

        let rowThreeCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 3, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        rowThreeCell.layoutSubtreeIfNeeded()
        try XCTUnwrap(rowThreeCell.imageView)
            .mouseDown(with: event(row: 3, modifiers: .command))
        XCTAssertEqual(tableView.selectedRowIndexes, [1, 3])
        XCTAssertEqual(dataSource.selectionChangeCount, 2)

        let rowZeroCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        rowZeroCell.mouseDown(with: try event(row: 0, modifiers: .shift))
        XCTAssertEqual(tableView.selectedRowIndexes, [0, 1, 2, 3])
        XCTAssertEqual(dataSource.selectionChangeCount, 3)
    }

    @MainActor
    func testMountedLargeTableNameHitSelectsFirstRowOnFirstClick() throws {
        let dataSource = NativeTableTestDataSource(rowCount: 2)
        let tableView = LargeFileNSTableView(
            frame: NSRect(x: 0, y: 0, width: 340, height: 100)
        )
        let column = NSTableColumn(identifier: LargeFileTableColumn.name.identifier)
        column.width = 340
        tableView.addTableColumn(column)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.allowsEmptySelection = true
        tableView.reloadData()

        let scrollView = NSScrollView(frame: tableView.frame)
        scrollView.documentView = tableView
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()

        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        cell.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(cell.textField)
        let clipView = try XCTUnwrap(tableView.superview)
        let hitPoint = label.convert(
            NSPoint(x: label.bounds.midX, y: label.bounds.midY),
            to: clipView
        )
        let hitView = try XCTUnwrap(tableView.hitTest(hitPoint))
        XCTAssertTrue(hitView === tableView)
        XCTAssertEqual(tableView.row(for: cell), 0)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 80, y: tableView.rect(ofRow: 0).midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        hitView.mouseDown(with: event)
        hitView.mouseUp(with: try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: event.locationInWindow,
                modifierFlags: [],
                timestamp: 0.01,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        ))

        XCTAssertEqual(tableView.selectedRowIndexes, [0])
        XCTAssertEqual(dataSource.selectionChangeCount, 1)
    }

    @MainActor
    func testMountedLargeTableNameClickPublishesOnlyFinalB() async throws {
        let sourceID = UUID()
        let indexedFiles = ["a", "b"].map { id in
            IndexedFile(
                id: id,
                sourceID: sourceID,
                name: "\(id).txt",
                path: "/tmp/\(id).txt",
                fileExtension: "txt",
                kind: .document,
                size: 1,
                createdAt: nil,
                modifiedAt: nil,
                indexedAt: .distantPast
            )
        }
        var selection: Set<String> = ["a"]
        var publicationHistory: [Set<String>] = []
        let publishedB = expectation(description: "Publishes only final native row B")
        let binding = Binding<Set<String>>(
            get: { selection },
            set: { newValue in
                selection = newValue
                publicationHistory.append(newValue)
                if newValue == ["b"] {
                    publishedB.fulfill()
                }
            }
        )
        func parent() -> LargeFileTableView {
            LargeFileTableView(
                files: indexedFiles,
                idIndex: ["a": 0, "b": 1],
                contentVersion: 1,
                selection: binding,
                categoryText: { _ in "" },
                onSelectionLeadChange: { _ in },
                onDoubleClick: { _ in },
                onQuickLook: { _ in },
                onDelete: {}
            )
        }

        let tableView = LargeFileNSTableView(
            frame: NSRect(x: 0, y: 0, width: 340, height: 100)
        )
        tableView.addTableColumn(
            NSTableColumn(identifier: LargeFileTableColumn.name.identifier)
        )
        tableView.allowsEmptySelection = true
        let coordinator = parent().makeCoordinator()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        let scrollView = NSScrollView(frame: tableView.frame)
        scrollView.documentView = tableView
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        coordinator.replaceSnapshot(with: parent(), in: tableView, force: true)
        publicationHistory.removeAll()
        XCTAssertEqual(tableView.selectedRowIndexes, [0])

        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        cell.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(cell.textField)
        let imageView = try XCTUnwrap(cell.imageView)
        let cellSuperview = try XCTUnwrap(cell.superview)
        let clipView = try XCTUnwrap(tableView.superview)

        let labelCenter = NSPoint(x: label.bounds.midX, y: label.bounds.midY)
        let imageCenter = NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        let blankPoint = NSPoint(x: cell.bounds.maxX - 4, y: cell.bounds.midY)
        XCTAssertTrue(
            label.hitTest(label.convert(labelCenter, to: cell)) === cell
        )
        XCTAssertTrue(
            imageView.hitTest(imageView.convert(imageCenter, to: cell)) === cell
        )
        XCTAssertTrue(
            cell.hitTest(cell.convert(blankPoint, to: cellSuperview)) === cell
        )

        let labelHitPoint = label.convert(labelCenter, to: clipView)
        let imageHitPoint = imageView.convert(imageCenter, to: clipView)
        let blankHitPoint = cell.convert(blankPoint, to: clipView)
        XCTAssertTrue(tableView.hitTest(imageHitPoint) === tableView)
        XCTAssertTrue(tableView.hitTest(blankHitPoint) === tableView)
        let hitView = try XCTUnwrap(tableView.hitTest(labelHitPoint))
        XCTAssertTrue(hitView === tableView)
        XCTAssertEqual(tableView.row(for: cell), 1)
        let locationInTable = label.convert(labelCenter, to: tableView)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: locationInTable,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        hitView.mouseDown(with: event)
        hitView.mouseUp(with: try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: event.locationInWindow,
                modifierFlags: [],
                timestamp: 0.01,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        ))
        XCTAssertEqual(tableView.selectedRowIndexes, [1])
        XCTAssertTrue(publicationHistory.isEmpty)

        // The binding still says A until next-turn publication. An unrelated
        // representable update in this window must not restore the old row.
        coordinator.replaceSnapshot(with: parent(), in: tableView, force: false)
        XCTAssertEqual(tableView.selectedRowIndexes, [1])

        await fulfillment(of: [publishedB], timeout: 1)

        XCTAssertEqual(tableView.selectedRowIndexes, [1])
        XCTAssertEqual(selection, ["b"])
        XCTAssertEqual(publicationHistory, [["b"]])

        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(tableView.selectedRowIndexes, [1])
        XCTAssertEqual(selection, ["b"])
        XCTAssertEqual(publicationHistory, [["b"]])
    }

    @MainActor
    func testLargeTableNameCellDoesNotCreateNestedAccessibilityElement() throws {
        let sourceID = UUID()
        let indexedFiles = ["a", "b"].map { id in
            IndexedFile(
                id: id,
                sourceID: sourceID,
                name: "\(id).txt",
                path: "/tmp/\(id).txt",
                fileExtension: "txt",
                kind: .document,
                size: 1,
                createdAt: nil,
                modifiedAt: nil,
                indexedAt: .distantPast
            )
        }
        let parent = LargeFileTableView(
            files: indexedFiles,
            idIndex: ["a": 0, "b": 1],
            contentVersion: 1,
            selection: .constant([]),
            categoryText: { _ in "" },
            onSelectionLeadChange: { _ in },
            onDoubleClick: { _ in },
            onQuickLook: { _ in },
            onDelete: {}
        )
        let tableView = LargeFileNSTableView(
            frame: NSRect(x: 0, y: 0, width: 340, height: 100)
        )
        tableView.addTableColumn(
            NSTableColumn(identifier: LargeFileTableColumn.name.identifier)
        )
        let coordinator = parent.makeCoordinator()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        let scrollView = NSScrollView(frame: tableView.frame)
        scrollView.documentView = tableView
        coordinator.replaceSnapshot(with: parent, in: tableView, force: true)

        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? LargeFileNameCellView
        )
        cell.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(cell.textField)
        let imageView = try XCTUnwrap(cell.imageView)
        XCTAssertFalse(cell.isAccessibilityElement())
        XCTAssertFalse(label.isAccessibilityElement())
        XCTAssertFalse(imageView.isAccessibilityElement())
        XCTAssertEqual(cell.accessibilityChildren()?.count, 0)

        func accessibilityChildren(of element: AnyObject) -> [AnyObject] {
            let selector = NSSelectorFromString("accessibilityChildren")
            guard let object = element as? NSObject,
                  object.responds(to: selector),
                  let rawChildren = object.perform(selector)?
                      .takeUnretainedValue() as? NSArray else {
                return []
            }
            return rawChildren.map { $0 as AnyObject }
        }

        // Use Objective-C arrays here: AppKit returns private `NSTableRow`
        // objects that the Swift accessibilityRows overlay can miscast.
        let rawRows = try XCTUnwrap(
            tableView.perform(
                NSSelectorFromString("accessibilityRows")
            )?.takeUnretainedValue() as? NSArray
        )
        let rows = rawRows.map { $0 as AnyObject }
        XCTAssertFalse(rows.isEmpty)
        let outerCells = rows.flatMap(accessibilityChildren(of:))
        let nestedChildren = outerCells.flatMap(accessibilityChildren(of:))
        XCTAssertFalse(
            (rows + outerCells + nestedChildren).contains {
                $0 === cell
            }
        )
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

    @MainActor
    func testNativeGridSingleClickPublishesOnlyTheFinalSelectionOnce() throws {
        let dataSource = NativeGridTestDataSource(itemCount: 3)
        let collectionView = LargeFileNSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 250)
        )
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        collectionView.dataSource = dataSource
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.reloadData()
        collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        collectionView.leadItem = 0
        collectionView.selectionAnchorItem = 0

        var publications: [Set<IndexPath>] = []
        collectionView.selectionLeadHandler = { _ in
            publications.append(collectionView.selectionIndexPaths)
        }
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

        collectionView.handleItemMouseDown(item: 1, event: event)

        let expected = Set([IndexPath(item: 1, section: 0)])
        XCTAssertEqual(collectionView.selectionIndexPaths, expected)
        XCTAssertEqual(publications, [expected])
        XCTAssertEqual(collectionView.leadItem, 1)
        XCTAssertEqual(collectionView.selectionAnchorItem, 1)
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
