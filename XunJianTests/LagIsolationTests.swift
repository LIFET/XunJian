import Combine
import QuickLookThumbnailing
import XCTest
@testable import XunJian

@MainActor
final class LagIsolationTests: XCTestCase {
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
