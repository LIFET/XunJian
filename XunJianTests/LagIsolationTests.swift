import Combine
import QuickLookThumbnailing
import XCTest
@testable import XunJian

@MainActor
final class LagIsolationTests: XCTestCase {
    func testSearchTypingPublishesOnlyTheNarrowStore() {
        let model = AppModel()
        var appModelPublications = 0
        var queryPublications = 0
        let appObservation = model.objectWillChange.sink { appModelPublications += 1 }
        let queryObservation = model.browseSearchStore.$query
            .dropFirst()
            .sink { _ in queryPublications += 1 }

        model.searchText = "r"
        model.searchText = "re"
        model.searchText = "report"

        XCTAssertEqual(model.searchText, "report")
        XCTAssertEqual(queryPublications, 3)
        XCTAssertEqual(appModelPublications, 0)
        _ = (appObservation, queryObservation)
    }

    func testSearchLifecyclePublishesOnlyTheNarrowStore() {
        let model = AppModel()
        let result = makeFile(name: "report.pdf", path: "/docs/report.pdf")
        var appModelPublications = 0
        var publishedStates: [BrowseSearchStore.ResultState] = []
        let appObservation = model.objectWillChange.sink { appModelPublications += 1 }
        let stateObservation = model.browseSearchStore.$resultState
            .dropFirst()
            .sink { publishedStates.append($0) }

        model.browseSearchStore.beginSearch(query: "report")
        XCTAssertEqual(appModelPublications, 0)

        model.browseSearchStore.publishResults([result], totalCount: 7)

        XCTAssertEqual(appModelPublications, 0)
        XCTAssertEqual(model.searchResults?.map(\.id), [result.id])
        XCTAssertEqual(model.searchResultTotalCount, 7)
        XCTAssertEqual(model.searchResultsRevision, 1)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(publishedStates.count, 2)
        XCTAssertTrue(publishedStates[0].isSearching)
        XCTAssertEqual(publishedStates[1].results?.map(\.id), [result.id])
        XCTAssertEqual(publishedStates[1].totalCount, 7)
        XCTAssertEqual(publishedStates[1].revision, 1)
        XCTAssertFalse(publishedStates[1].isSearching)

        model.browseSearchStore.beginSearch(query: "report")
        model.browseSearchStore.finishSearchWithoutReplacingResults()
        XCTAssertEqual(appModelPublications, 0)
        _ = (appObservation, stateObservation)
    }

    func testPreviewHighlightQueryPublishesOnlyTheNarrowStore() {
        let model = AppModel()
        var appModelPublications = 0
        var highlightQueries: [String] = []
        let appObservation = model.objectWillChange.sink { appModelPublications += 1 }
        let highlightObservation = model.browseSearchStore.$highlightQuery
            .dropFirst()
            .sink { highlightQueries.append($0) }

        model.highlightQuery = "report"
        model.highlightQuery = "report"
        model.highlightQuery = "invoice"

        XCTAssertEqual(model.highlightQuery, "invoice")
        XCTAssertEqual(highlightQueries, ["report", "invoice"])
        XCTAssertEqual(appModelPublications, 0)
        _ = (appObservation, highlightObservation)
    }

    func testSchedulingANonEmptyQueryKeepsPreviousSearchResults() {
        let previous = [makeFile(name: "report.pdf", path: "/docs/report.pdf")]

        XCTAssertEqual(
            FileIndexCoordinator.retainedSearchResults(
                forQuery: "repo",
                previous: previous
            )?.map(\.id),
            previous.map(\.id)
        )
        XCTAssertNil(
            FileIndexCoordinator.retainedSearchResults(
                forQuery: "",
                previous: previous
            )
        )
        XCTAssertNil(
            FileIndexCoordinator.retainedSearchResults(
                forQuery: "   ",
                previous: previous
            )
        )
    }

    func testDisplayedFilesRefreshKeyIgnoresTypingAndSearchingFlag() {
        let idle = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: true
        )
        let typed = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: true
        )

        XCTAssertEqual(idle.signature, typed.signature)
    }

    func testDisplayedFilesRefreshKeyChangesWhenSearchResultsRevisionChanges() {
        let before = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: true
        )
        let after = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 9,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: true
        )

        XCTAssertNotEqual(before.signature, after.signature)
    }

    func testDisplayedFilesRefreshKeyRestartsForVisibilityWithoutInvalidatingCache() {
        let visible = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: true
        )
        let hidden = DisplayedFilesRefreshKey(
            filesRevision: 3,
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil,
            isVisible: false
        )

        XCTAssertNotEqual(visible, hidden)
        XCTAssertEqual(visible.signature, hidden.signature)
    }

    func testDisplayedFilesUserKeyIgnoresIndexChurnButNotSearchResults() {
        let browsing = DisplayedFilesUserKey(
            query: "",
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil
        )
        let sameInputs = DisplayedFilesUserKey(
            query: "",
            searchResultsRevision: 8,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil
        )
        let searchFinished = DisplayedFilesUserKey(
            query: "",
            searchResultsRevision: 9,
            aiSearchResultCount: nil,
            aiSearchRevision: 0,
            selectedKind: nil,
            sortOrder: .modifiedAt,
            sortAscending: false,
            minSizeBytes: 0,
            minDate: nil
        )

        XCTAssertEqual(browsing.signature, sameInputs.signature)
        XCTAssertNotEqual(browsing.signature, searchFinished.signature)
        XCTAssertTrue(
            DisplayedFilesRefreshPolicy.shouldSettleRevisionDrivenRefresh(
                previousUserSignature: browsing.signature,
                currentUserSignature: sameInputs.signature
            )
        )
        XCTAssertFalse(
            DisplayedFilesRefreshPolicy.shouldSettleRevisionDrivenRefresh(
                previousUserSignature: browsing.signature,
                currentUserSignature: searchFinished.signature
            )
        )
        XCTAssertFalse(
            DisplayedFilesRefreshPolicy.shouldSettleRevisionDrivenRefresh(
                previousUserSignature: nil,
                currentUserSignature: browsing.signature
            )
        )
    }

    func testTableThumbnailsRequestFinderLikePreviews() {
        XCTAssertEqual(FileThumbnail.representationTypes(for: 24), .thumbnail)
        XCTAssertEqual(FileThumbnail.representationTypes(for: 32), .thumbnail)
        XCTAssertEqual(FileThumbnail.representationTypes(for: 72), .thumbnail)
        XCTAssertEqual(FileThumbnail.representationTypes(for: 150), .thumbnail)
    }

    func testNativeFinderTagRefreshTargetsOnlyChangedVisibleRows() {
        let idIndex = Dictionary(
            uniqueKeysWithValues: (0..<100_000).map { ("file-\($0)", $0) }
        )
        let visibleRows = IndexSet(integersIn: 40_000..<40_024)

        let affectedRows = NativeFinderTagReloadPolicy.affectedVisibleRows(
            changedFileIDs: ["file-2", "file-40005", "file-40019", "missing"],
            idIndex: idIndex,
            visibleRows: visibleRows
        )

        XCTAssertEqual(affectedRows, IndexSet([40_005, 40_019]))
        XCTAssertEqual(affectedRows.count, 2)
    }

    func testNativeFinderTagRefreshDoesNothingForOffscreenChanges() {
        let affectedRows = NativeFinderTagReloadPolicy.affectedVisibleRows(
            changedFileIDs: ["file-a", "file-b"],
            idIndex: ["file-a": 3, "file-b": 99],
            visibleRows: IndexSet(integersIn: 10..<20)
        )

        XCTAssertTrue(affectedRows.isEmpty)
    }

    func testSixFigureListDisablesContinuousScrollTrackingAndWholeTableAnimation() {
        XCTAssertTrue(FileBrowsePerformancePolicy.tracksLiveListScrollPosition(fileCount: 20_000))
        XCTAssertFalse(FileBrowsePerformancePolicy.tracksLiveListScrollPosition(fileCount: 20_001))
        XCTAssertTrue(FileBrowsePerformancePolicy.tracksLiveGridScrollPosition(fileCount: 20_000))
        XCTAssertFalse(FileBrowsePerformancePolicy.tracksLiveGridScrollPosition(fileCount: 20_001))
        XCTAssertFalse(FileBrowsePerformancePolicy.usesNativeTable(fileCount: 20_000))
        XCTAssertTrue(FileBrowsePerformancePolicy.usesNativeTable(fileCount: 20_001))
        XCTAssertFalse(FileBrowsePerformancePolicy.usesNativeGrid(fileCount: 20_000))
        XCTAssertTrue(FileBrowsePerformancePolicy.usesNativeGrid(fileCount: 20_001))
        XCTAssertTrue(FileBrowsePerformancePolicy.usesNativeBrowser(fileCount: 20_001))
        XCTAssertTrue(FileBrowsePerformancePolicy.animatesModeChange(fileCount: 5_000))
        XCTAssertFalse(FileBrowsePerformancePolicy.animatesModeChange(fileCount: 5_001))
        XCTAssertFalse(FileBrowsePerformancePolicy.tracksLiveListScrollPosition(fileCount: 96_019))
        XCTAssertFalse(FileBrowsePerformancePolicy.tracksLiveGridScrollPosition(fileCount: 96_019))
        XCTAssertTrue(FileBrowsePerformancePolicy.usesNativeTable(fileCount: 96_019))
        XCTAssertTrue(FileBrowsePerformancePolicy.usesNativeGrid(fileCount: 96_019))
        XCTAssertFalse(FileBrowsePerformancePolicy.animatesModeChange(fileCount: 96_019))
    }

    func testToolbarBuildsOneStableLayoutForEachWidthBand() {
        let full = FileToolbarLayoutPolicy.configuration(for: 1_120)
        XCTAssertTrue(full.showsFileType)
        XCTAssertTrue(full.showsSort)
        XCTAssertTrue(full.showsSortDirection)
        XCTAssertTrue(full.showsViewMode)

        let medium = FileToolbarLayoutPolicy.configuration(for: 800)
        XCTAssertTrue(medium.compactAI)
        XCTAssertTrue(medium.showsFileType)
        XCTAssertTrue(medium.showsSort)
        XCTAssertFalse(medium.showsSortDirection)
        XCTAssertFalse(medium.showsViewMode)

        let narrow = FileToolbarLayoutPolicy.configuration(for: 500)
        XCTAssertTrue(narrow.compactAI)
        XCTAssertFalse(narrow.showsFileType)
        XCTAssertFalse(narrow.showsSort)
        XCTAssertFalse(narrow.showsSortDirection)
        XCTAssertFalse(narrow.showsViewMode)
    }

    func testNativeGridLayoutKeepsSixFigureFramesUniqueAcrossWidthsAndScrollOffsets() throws {
        let itemCount = 96_148
        let widths = Set(
            stride(from: 280, through: 1_600, by: 17).map(CGFloat.init)
                + [320, 500, 800, 1_122, 1_440]
        ).sorted()

        for width in widths {
            let layout = NativeGridLayoutPolicy(
                itemCount: itemCount,
                containerWidth: width
            )
            let maximumOffset = max(layout.contentSize.height - 750, 0)
            let offsets = [
                CGFloat.zero,
                147,
                10_000,
                maximumOffset / 2,
                maximumOffset
            ]

            for offset in offsets {
                let visibleRects = [
                    CGRect(x: 0, y: offset, width: width, height: 750),
                    CGRect(
                        x: width * 0.17,
                        y: offset + 37,
                        width: width * 0.61,
                        height: 413
                    )
                ]
                for visibleRect in visibleRects {
                    let visibleFrames = layout.itemFrames(intersecting: visibleRect)
                    let itemIndices = visibleFrames.map(\.item)

                    XCTAssertEqual(
                        Set(itemIndices).count,
                        itemIndices.count,
                        "Duplicate item at width \(width), offset \(offset)"
                    )
                    XCTAssertLessThanOrEqual(
                        visibleFrames.count,
                        (Int(ceil(visibleRect.height / layout.rowStride)) + 2) * layout.columns
                    )
                    for (index, lhs) in visibleFrames.enumerated() {
                        XCTAssertTrue(lhs.frame.intersects(visibleRect))
                        for rhs in visibleFrames.dropFirst(index + 1) {
                            XCTAssertFalse(
                                lhs.frame.intersects(rhs.frame),
                                "Items \(lhs.item) and \(rhs.item) overlap at width \(width)"
                            )
                        }
                    }
                }
            }

            let lastFrame = try XCTUnwrap(layout.frame(forItem: itemCount - 1))
            XCTAssertLessThanOrEqual(lastFrame.maxX, layout.contentSize.width)
            XCTAssertLessThanOrEqual(lastFrame.maxY, layout.contentSize.height)
            XCTAssertTrue(
                layout.itemFrames(
                    intersecting: CGRect(
                        x: 0,
                        y: layout.contentSize.height + 1,
                        width: width,
                        height: 750
                    )
                ).isEmpty
            )
        }
    }

    func testNativeGridLayoutProducesStableFramesForOnePreparedWidth() throws {
        let layout = NativeGridLayoutPolicy(itemCount: 96_148, containerWidth: 1_122)
        let sampleItems = [0, 1, layout.columns - 1, layout.columns, 48_073, 96_147]
        let frames = try sampleItems.map { try XCTUnwrap(layout.frame(forItem: $0)) }

        XCTAssertEqual(Set(frames.map { NSValue(rect: $0) }).count, frames.count)
        XCTAssertEqual(frames[0].minY, frames[1].minY)
        XCTAssertGreaterThan(frames[3].minY, frames[0].maxY)
        XCTAssertNil(layout.frame(forItem: -1))
        XCTAssertNil(layout.frame(forItem: 96_148))
    }

    func testNativeGridLeadFollowsKeyboardSelectionDelta() {
        XCTAssertEqual(
            NativeGridSelectionLead.updatedLead(
                previousLead: 10,
                previousSelection: [10],
                newSelection: [10, 11, 12, 13, 14, 15]
            ),
            15
        )
        XCTAssertEqual(
            NativeGridSelectionLead.updatedLead(
                previousLead: 15,
                previousSelection: [15],
                newSelection: [10, 11, 12, 13, 14, 15]
            ),
            10
        )
        XCTAssertEqual(
            NativeGridSelectionLead.updatedLead(
                previousLead: 15,
                previousSelection: [10, 11, 12, 13, 14, 15],
                newSelection: [10]
            ),
            10
        )
        XCTAssertEqual(
            NativeGridSelectionLead.updatedLead(
                previousLead: 10,
                previousSelection: [10],
                newSelection: [4, 10]
            ),
            4
        )
        XCTAssertEqual(
            NativeGridSelectionLead.updatedLead(
                previousLead: 10,
                previousSelection: [3, 10, 18],
                newSelection: [3, 18]
            ),
            3
        )
        XCTAssertNil(
            NativeGridSelectionLead.updatedLead(
                previousLead: 10,
                previousSelection: [10],
                newSelection: []
            )
        )
    }

    func testInteractiveSortMatchesExistingOrderAndStopsWhenCancelled() {
        let files = (0..<2_000).map { index in
            makeFile(
                id: "file-\(index)",
                name: "file-\(2_000 - index).pdf",
                path: "/docs/file-\(index).pdf"
            )
        }
        for order in FileSortOrder.allCases {
            let expected = order.sorted(files, ascending: false).map(\.id)
            let actual = order.sortedCancellable(
                files,
                ascending: false,
                isCancelled: { false }
            )?.map(\.id)
            XCTAssertEqual(actual, expected, "Sort mismatch for \(order.rawValue)")
        }

        XCTAssertNil(
            FileSortOrder.name.sortedCancellable(
                files,
                ascending: true,
                isCancelled: { true }
            )
        )
    }

    func testCommandTargetStatePublishesOncePerReplacement() {
        let model = AppModel()
        let file = makeFile(name: "report.pdf", path: "/docs/report.pdf")
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }

        model.updateCommandTargetFiles(
            [file],
            usesGlobalSearchPagination: true,
            signature: 42
        )

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.commandTargetFiles.map(\.id), [file.id])
        XCTAssertTrue(model.commandTargetUsesGlobalSearchPagination)
        _ = observation
    }

    func testCategoryIndexStoreTogglesOneFileWithoutReplacingTheLibrary() {
        let work = FileCategory(id: UUID(), name: "Work", symbolName: "briefcase")
        let files = (0..<50).map { index in
            makeFile(name: "file-\(index).pdf", path: "/docs/file-\(index).pdf")
        }
        let store = CategoryIndexStore()
        store.replaceAll(
            categories: [work],
            links: [:],
            categoriesByFileID: [:],
            fileCountsByCategoryID: [:],
            filesByCategoryID: [:]
        )

        store.applyAssignment(assigned: true, file: files[7], category: work)
        XCTAssertEqual(store.fileCount(in: work.id), 1)
        XCTAssertEqual(store.files(in: work.id).map(\.id), [files[7].id])
        XCTAssertTrue(store.isAssigned(work.id, to: files[7].id))

        store.applyAssignment(assigned: false, file: files[7], category: work)
        XCTAssertEqual(store.fileCount(in: work.id), 0)
        XCTAssertTrue(store.files(in: work.id).isEmpty)
        XCTAssertFalse(store.isAssigned(work.id, to: files[7].id))
    }

    func testCategoryIndexStoreAppliesBatchWithOneRevision() {
        let work = FileCategory(id: UUID(), name: "Work", symbolName: "briefcase")
        let files = (0..<50).map { index in
            makeFile(name: "file-\(index).pdf", path: "/docs/file-\(index).pdf")
        }
        let store = CategoryIndexStore()
        store.replaceAll(
            categories: [work],
            links: [:],
            categoriesByFileID: [:],
            fileCountsByCategoryID: [:],
            filesByCategoryID: [:]
        )
        let initialRevision = store.revision

        store.applyAssignments(assigned: true, files: files, category: work)

        XCTAssertEqual(store.revision, initialRevision + 1)
        XCTAssertEqual(store.fileCount(in: work.id), files.count)
        XCTAssertEqual(Set(store.files(in: work.id).map(\.id)), Set(files.map(\.id)))
    }

    func testFileExportProgressStoreDoesNotReplaceIdenticalProgress() {
        let store = FileExportProgressStore()
        XCTAssertNil(store.progress)

        store.update(FileExportProgress(completed: 2, total: 10))
        let first = store.progress
        store.update(FileExportProgress(completed: 2, total: 10))
        XCTAssertEqual(store.progress, first)

        store.update(FileExportProgress(completed: 3, total: 10))
        XCTAssertEqual(store.progress?.completed, 3)

        store.update(nil)
        XCTAssertNil(store.progress)
    }

    func testTrashUndoStoreDoesNotPublishOnTheIndexCoordinator() {
        let coordinator = FileIndexCoordinator(isRunningTests: true)
        var indexChanges = 0
        let observation = coordinator.objectWillChange.sink { indexChanges += 1 }

        coordinator.trashUndoStore.update(
            FileIndexCoordinator.TrashUndo(
                items: [
                    FileIndexCoordinator.TrashUndo.Item(
                        trashURL: URL(fileURLWithPath: "/tmp/Trash/a.pdf"),
                        originalURL: URL(fileURLWithPath: "/docs/a.pdf"),
                        identity: FileSystemObjectIdentity(
                            device: 1,
                            inode: 2,
                            fileType: 0
                        ),
                        originalParentIdentity: FileSystemObjectIdentity(
                            device: 3,
                            inode: 4,
                            fileType: 0
                        ),
                        originalFileID: "file-a",
                        sourceID: UUID(),
                        categoryIDs: []
                    )
                ],
                undoEntryID: nil
            )
        )

        XCTAssertEqual(indexChanges, 0)
        XCTAssertEqual(coordinator.trashUndoStore.undo?.fileCount, 1)
        _ = observation
    }

    func testPausedOrUnavailableSourcesAreNeverEligibleForScanning() {
        let available = makeSource(enabled: true, accessState: .available)
        let paused = makeSource(enabled: false, accessState: .available)
        let unavailable = makeSource(enabled: true, accessState: .needsAuthorization)

        XCTAssertTrue(FileIndexCoordinator.isSourceEligibleForScanning(available))
        XCTAssertFalse(FileIndexCoordinator.isSourceEligibleForScanning(paused))
        XCTAssertFalse(FileIndexCoordinator.isSourceEligibleForScanning(unavailable))
    }

    func testIncrementalRefreshSkipsPublishWhenOnlyIndexedAtChanges() {
        let sourceID = UUID()
        let current = makeFile(
            id: "stable",
            sourceID: sourceID,
            name: "notes.md",
            path: "/docs/notes.md"
        )
        let rescanned = IndexedFile(
            id: current.id,
            sourceID: current.sourceID,
            name: current.name,
            path: current.path,
            fileExtension: current.fileExtension,
            kind: current.kind,
            size: current.size,
            createdAt: current.createdAt,
            modifiedAt: current.modifiedAt,
            indexedAt: current.indexedAt.addingTimeInterval(30)
        )

        XCTAssertFalse(
            FileIndexCoordinator.shouldPublishIncrementalRefresh(
                currentFiles: [current],
                updatedFiles: [rescanned],
                currentLinks: [:],
                updatedLinks: [:]
            )
        )
        XCTAssertTrue(current.hasVisibleIndexChange(comparedTo: makeFile(
            id: "stable",
            sourceID: sourceID,
            name: "renamed.md",
            path: "/docs/renamed.md"
        )))
        XCTAssertTrue(
            FileIndexCoordinator.shouldPublishIncrementalRefresh(
                currentFiles: [current],
                updatedFiles: [current],
                currentLinks: [:],
                updatedLinks: [current.id: [UUID()]]
            )
        )
    }

    func testIncrementalMergeDropsVisibleFileRenamedToDotPrefix() {
        let sourceID = UUID()
        let visible = makeFile(
            id: "stable-id",
            sourceID: sourceID,
            name: "notes.md",
            path: "/docs/notes.md"
        )
        let hidden = makeFile(
            id: "stable-id",
            sourceID: sourceID,
            name: ".notes.md",
            path: "/docs/.notes.md"
        )

        let merged = FileIndexCoordinator.mergeIncrementalFiles(
            current: [visible],
            fetched: [hidden],
            removedIDs: [],
            includesHiddenFiles: false
        )

        XCTAssertTrue(merged.isEmpty)
    }

    func testEqualRankSearchPaginationIsStableAcrossEveryPage() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-StablePaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "分页稳定性",
            path: container.path,
            bookmark: Data([1])
        )
        let files = (0..<1_200).map { index in
            makeFile(
                id: "same-rank-\(index)",
                sourceID: source.id,
                name: "文档-\(index).txt",
                path: container.appendingPathComponent("文档-\(index).txt").path,
                textContent: "完全相同分页词"
            )
        }
        try await database.replaceFiles(for: source.id, with: files)

        var collected: [String] = []
        for offset in stride(from: 0, to: files.count, by: 200) {
            let page = try await database.searchFilesPage(
                matching: "完全相同分页词",
                limit: 200,
                offset: offset,
                fetchesTotalCount: false
            )
            collected.append(contentsOf: page.files.map(\.id))
        }

        XCTAssertEqual(collected.count, 1_200)
        XCTAssertEqual(Set(collected).count, 1_200)
    }

    private func makeSource(
        enabled: Bool,
        accessState: SourceAccessState
    ) -> FileSource {
        FileSource(
            id: UUID(),
            displayName: "Documents",
            path: "/docs",
            bookmark: Data(),
            enabled: enabled,
            createdAt: Date(),
            accessState: accessState
        )
    }

    private func makeFile(
        id: String? = nil,
        sourceID: UUID = UUID(),
        name: String,
        path: String,
        textContent: String? = nil
    ) -> IndexedFile {
        IndexedFile(
            id: id ?? path,
            sourceID: sourceID,
            name: name,
            path: path,
            fileExtension: "pdf",
            kind: .document,
            size: 1,
            createdAt: nil,
            modifiedAt: Date(),
            indexedAt: Date(),
            textContent: textContent
        )
    }
}
