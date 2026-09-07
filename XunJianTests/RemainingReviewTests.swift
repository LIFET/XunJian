import AppKit
import Combine
import Darwin
import XCTest
@testable import XunJian

final class RemainingReviewTests: XCTestCase {
    @MainActor
    func testDuplicateCleanupPartialFailureAndUndoUseIsolatedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XunJian-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("files", isDirectory: true)
        let trash = root.appendingPathComponent("test-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        for name in ["a.txt", "b.txt", "c.txt"] {
            let url = folder.appendingPathComponent(name)
            try Data("identical test contents".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        }
        let databaseURL = root.appendingPathComponent("index.sqlite3")
        let database = try FileIndexDatabase(databaseURL: databaseURL)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let source = try await database.upsertSource(displayName: "Fixture", path: folder.path, bookmark: bookmark)
        let files = try await FileScanner().scan(sourceID: source.id, rootURL: folder)
        try await database.replaceFiles(for: source.id, with: files)
        let manager = IsolatedDuplicateTrashManager(root: folder, trash: trash)
        let suite = "XunJian.Cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = FileIndexCoordinator(isRunningTests: true, fileSystemEventDefaults: defaults, databaseURL: databaseURL, fileOperations: FileOperationService(fileManager: manager))
        let undo = UndoCoordinator()
        index.undoCoordinator = undo
        defer { index.cancelAllTasks() }
        index.start()
        for _ in 0..<500 where !index.isDatabaseAvailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(index.isDatabaseAvailable)
        let result = try await DuplicateFileFinder.find(in: files)
        let group = try XCTUnwrap(result.groups.first)
        let keeper = try XCTUnwrap(DuplicateCleanup.fileToKeep(in: group.files))
        index.refreshAllSources()
        XCTAssertTrue(index.isScanning)
        do {
            try await index.confirmDuplicateTrash(group)
            XCTFail("Injected second-file failure must be reported")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        try await undo.undoLast()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        for file in files { XCTAssertEqual(try Data(contentsOf: file.url), Data("identical test contents".utf8)) }
        for _ in 0..<500 where index.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(index.isScanning)
        let restoredFiles = try await database.fetchFiles()
        XCTAssertEqual(Set(restoredFiles.map(\.path)), Set(files.map(\.path)))
    }

    func testDuplicateSearchOwnershipRejectsCancelledRunAfterRestart() {
        let oldRun = UUID()
        let invalidated = UUID()
        XCTAssertFalse(StorageInsightsView.acceptsDuplicateSearchUpdate(oldRun, current: invalidated))
        let newRun = UUID()
        var isFindingNewRun = true
        var newProgress = 1
        // Delivery order: A cancelled, B starts, A's progress and completion arrive.
        if StorageInsightsView.acceptsDuplicateSearchUpdate(oldRun, current: newRun) {
            newProgress = 100
            isFindingNewRun = false
        }
        XCTAssertEqual(newProgress, 1)
        XCTAssertTrue(isFindingNewRun)
        XCTAssertTrue(StorageInsightsView.acceptsDuplicateSearchUpdate(newRun, current: newRun))
    }

    func testBackgroundExportCancellationReachesWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xunjian-background-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("files.csv")
        try Data("original".utf8).write(to: destination)
        let files = (0..<500).map { makeFile(name: "\($0).pdf", path: "/synthetic/\($0).pdf") }
        let reachedFirstBatch = expectation(description: "writer reached first batch")
        let releaseWriter = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await FileListExport.writeInBackground(files: files, format: .csv, categoryNames: [:], to: destination) { count in
                if count == 250 {
                    reachedFirstBatch.fulfill()
                    _ = releaseWriter.wait(timeout: .now() + 5)
                }
            }
        }
        await fulfillment(of: [reachedFirstBatch], timeout: 3)
        task.cancel()
        releaseWriter.signal()
        do {
            try await task.value
            XCTFail("Cancelling the export owner must cancel the detached writer")
        } catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["files.csv"])
    }

    func testCancelledFinalExportProgressPreservesExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xunjian-cancel-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [makeFile(name: "new.pdf", path: "/synthetic/new.pdf")]
        for format in FileListExport.Format.allCases {
            let destination = root.appendingPathComponent("files.\(format.fileExtension)")
            try Data("original".utf8).write(to: destination)
            let task = Task.detached {
                try FileListExport.write(files: files, format: format, categoryNames: [:], to: destination) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do {
                try await task.value
                XCTFail("Cancelled export must not install its temporary file")
            } catch is CancellationError { }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".xunjian-export-") })
    }

    func testCancelledFinalPagedExportProgressPreservesExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xunjian-cancel-page-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [makeFile(name: "new.pdf", path: "/synthetic/new.pdf")]
        for format in FileListExport.Format.allCases {
            let destination = root.appendingPathComponent("files.\(format.fileExtension)")
            try Data("original".utf8).write(to: destination)
            let task = Task.detached {
                try await FileListExport.writePaged(orderedIDs: files.map(\.id), format: format, to: destination, progress: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }) { _ in FileExportPage(files: files, categoryNames: [:]) }
            }
            do {
                try await task.value
                XCTFail("Cancelled paged export must not install its temporary file")
            } catch is CancellationError { }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".xunjian-export-") })
    }

    func testCancelledDuplicateFingerprintDoesNotReadFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xunjian-cancel-hash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.txt")
        try Data("synthetic".utf8).write(to: url)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DuplicateFileFinder.fingerprint(fileAt: url)
        }
        do {
            _ = try await task.value
            XCTFail("Fingerprint must inherit cancellation before reading")
        } catch is CancellationError { }
    }

    func testDuplicateFindCancellationFromProgressStopsDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xunjian-cancel-find-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try (0..<12).map { index in
            let url = root.appendingPathComponent("\(index).txt")
            try Data("same".utf8).write(to: url)
            return makeFile(name: url.lastPathComponent, path: url.path, size: 4)
        }
        let task = Task.detached {
            try await DuplicateFileFinder.find(in: files) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Detection must stop rather than return a complete result after cancellation")
        } catch is CancellationError { }
    }

    func testPreviewMatchingStopsWhenTaskIsCancelled() async {
        let chunks = TextPreviewView.chunk(String(repeating: "中文", count: 1_000))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return TextPreviewView.matchesWithRanges(for: "中", in: chunks)
        }
        let result = await task.value
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.rangesByChunk.isEmpty)
    }

    func testPreviewHighFrequencyMatchingScalesToTextLimit() {
        let start = ContinuousClock.now
        let baseline = TextPreviewView.matchesWithRanges(for: "中", in: TextPreviewView.chunk(String(repeating: "中", count: 16_000)))
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(baseline.matches.count, 16_000)
        XCTAssertLessThan(elapsed, .seconds(2), "High-frequency matching must avoid quadratic full-text walks")
        guard elapsed < .seconds(2) else { return }
        let largeStart = ContinuousClock.now
        let large = TextPreviewView.matchesWithRanges(for: "中", in: TextPreviewView.chunk(String(repeating: "中", count: 200_000)))
        XCTAssertEqual(large.matches.count, 200_000)
        XCTAssertEqual(large.rangesByChunk.values.reduce(0) { $0 + $1.count }, 200_000)
        XCTAssertLessThan(largeStart.duration(to: .now), .seconds(8))
    }

    func testPreviewUnicodeCrossChunkRangesAndEmptyQuery() {
        let text = "🙂Cafe\u{301}中文CAFÉ👨‍👩‍👧‍👦"
        let chunks = TextPreviewView.chunk(text, maximumChunkLength: 3)
        let result = TextPreviewView.matchesWithRanges(for: "cafe", in: chunks)
        XCTAssertEqual(result.matches.count, 2)
        for match in result.matches {
            let reconstructed = match.segments.map { segment in
                String(chunks.first { $0.id == segment.chunkID }!.text[segment.range])
            }.joined()
            XCTAssertEqual(reconstructed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), "cafe")
        }
        XCTAssertTrue(TextPreviewView.matchesWithRanges(for: "", in: chunks).matches.isEmpty)
        XCTAssertTrue(TextPreviewView.matchesWithRanges(for: "absent", in: chunks).matches.isEmpty)
    }

    @MainActor
    func testDatabaseDoesNotAdvertiseReadyBeforeInitialSnapshot() async {
        let coordinator = FileIndexCoordinator(isRunningTests: true)
        defer { coordinator.cancelAllTasks() }
        var publishedSnapshot = false
        coordinator.onFilesChanged = { publishedSnapshot = true }
        let ready = expectation(description: "ready after initial snapshot")
        let observation = coordinator.$databaseState
            .filter { $0 == .available }.prefix(1)
            .sink { _ in
                XCTAssertTrue(publishedSnapshot, "数据库打开不代表文件已载入；不能提前显示空库和授权入口")
                ready.fulfill()
            }
        coordinator.start()
        await fulfillment(of: [ready], timeout: 5)
        withExtendedLifetime(observation) {}
        publishedSnapshot = false
        let retryReady = expectation(description: "retry ready after snapshot")
        let retryObservation = coordinator.$databaseState.dropFirst()
            .filter { $0 == .available }.prefix(1)
            .sink { _ in
                XCTAssertTrue(publishedSnapshot, "重试也必须等待文件快照")
                retryReady.fulfill()
            }
        await coordinator.retryDatabase()
        await fulfillment(of: [retryReady], timeout: 5)
        withExtendedLifetime(retryObservation) {}
    }

    @MainActor
    func testDatabaseStartsInOpeningStateAndOnlyFailureShowsRetryUI() async throws {
        let coordinator = FileIndexCoordinator(isRunningTests: true)

        XCTAssertEqual(coordinator.databaseState, .opening)
        XCTAssertFalse(coordinator.isDatabaseAvailable)
        XCTAssertFalse(coordinator.databaseState.showsFailure)

        coordinator.start()
        for _ in 0..<100 where coordinator.databaseState != .available {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.databaseState, .available)
        XCTAssertTrue(coordinator.isDatabaseAvailable)
        XCTAssertFalse(coordinator.databaseState.showsFailure)
        XCTAssertTrue(FileIndexDatabaseState.failed.showsFailure)
        coordinator.cancelAllTasks()
    }

    @MainActor
    func testMenuBarDefaultsObserversHopToMainRunLoopBeforeReadingPreferences() async {
        let center = NotificationCenter()
        let delivered = expectation(description: "UserDefaults notification delivered")
        var deliveredOnMainThread = false
        let observation = XunJianAppDelegate.userDefaultsDidChangePublisher(center: center)
            .sink { _ in
                deliveredOnMainThread = Thread.isMainThread
                delivered.fulfill()
            }

        Task.detached {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertTrue(deliveredOnMainThread)
        _ = observation
    }

    @MainActor
    func testDatabaseBootstrapActuallyRunsOffMainThread() async throws {
        let openedOnMainThread = try await FileIndexCoordinator.performDatabaseBootstrap {
            Thread.isMainThread
        }

        XCTAssertFalse(openedOnMainThread)
    }

    @MainActor
    func testGlobalScrollbarStyleKeepsNativeScrollersThin() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiSource = try String(
            contentsOf: repositoryRoot
                .appending(path: "XunJian/Views/Components/XunJianUI.swift"),
            encoding: .utf8
        )
        let shellSource = try String(
            contentsOf: repositoryRoot
                .appending(path: "XunJian/Views/AppShellView.swift"),
            encoding: .utf8
        )
        let menuBarSource = try String(
            contentsOf: repositoryRoot
                .appending(path: "XunJian/Views/MenuBarSearchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(uiSource.contains("scrollView.scrollerStyle = .overlay"))
        XCTAssertTrue(uiSource.contains("scroller.controlSize = .small"))
        XCTAssertTrue(shellSource.contains(".xunjianThinScrollers()"))
        XCTAssertTrue(menuBarSource.contains(".xunjianThinScrollers()"))

        let rootView = NSView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller?.controlSize = .regular
        rootView.addSubview(scrollView)

        XunJianScrollAppearance.applyRecursively(in: rootView)

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
    }

    @MainActor
    func testThinScrollerHostAppliesOnExplicitRefreshButNotEveryLayoutPass() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let rootView = try XCTUnwrap(window.contentView)
        let hostView = XunJianThinScrollerHostView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        rootView.addSubview(hostView)
        rootView.addSubview(scrollView)

        hostView.scheduleApply()
        for _ in 0..<200 where scrollView.scrollerStyle != .overlay
            || scrollView.verticalScroller?.controlSize != .small {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)

        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller?.controlSize = .regular
        hostView.needsLayout = true
        hostView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(scrollView.scrollerStyle, .legacy)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .regular)

        hostView.scheduleApply()
        for _ in 0..<200 where scrollView.scrollerStyle != .overlay
            || scrollView.verticalScroller?.controlSize != .small {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
    }

    func testPaginatedSelectAllContextIgnoresResultPublicationButTracksFilters() {
        let original = PaginatedSelectAllContext(
            query: "report",
            kind: .document,
            minimumSizeMB: 2,
            minimumDate: 100,
            aiSearchRevision: 7
        )
        let afterSearchResultPublication = PaginatedSelectAllContext(
            query: "report",
            kind: .document,
            minimumSizeMB: 2,
            minimumDate: 100,
            aiSearchRevision: 7
        )
        let changedFilter = PaginatedSelectAllContext(
            query: "report",
            kind: .document,
            minimumSizeMB: 4,
            minimumDate: 100,
            aiSearchRevision: 7
        )

        XCTAssertEqual(original, afterSearchResultPublication)
        XCTAssertNotEqual(original, changedFilter)
    }

    func testFinderTagRefreshPreservesExistingContentForSameFile() throws {
        XCTAssertFalse(FinderTagRefreshPolicy.shouldClearExistingTags(
            loadedFileID: "file-a",
            currentFileID: "file-a"
        ))
        XCTAssertTrue(FinderTagRefreshPolicy.shouldClearExistingTags(
            loadedFileID: "file-a",
            currentFileID: "file-b"
        ))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "XunJian/Views/Components/FileInspectorEmptyView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(#".task(id: "\(previewCacheKey)-\(previewRetry)")"#))
        XCTAssertFalse(source.contains(#"previewRetry)-\(finderTagRefreshRevision)"#))
    }

    func testBrowseFilterCombinesAIKeywordKindSizeAndDate() {
        let oldDocument = makeFile(
            name: "old.pdf",
            path: "/docs/old.pdf",
            modifiedAt: Date(timeIntervalSince1970: 100),
            size: 20
        )
        let currentDocument = makeFile(
            name: "current.pdf",
            path: "/docs/current.pdf",
            modifiedAt: Date(timeIntervalSince1970: 300),
            size: 200
        )
        let code = IndexedFile(
            id: "code",
            sourceID: UUID(),
            name: "main.swift",
            path: "/docs/main.swift",
            fileExtension: "swift",
            kind: .code,
            size: 300,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 300),
            indexedAt: Date()
        )

        let result = AppModel.filesMatchingBrowseFilters(
            indexedFiles: [oldDocument, currentDocument, code],
            aiSearchResults: [oldDocument, currentDocument, code],
            searchResults: [currentDocument, code],
            query: "current",
            kind: .document,
            minimumSize: 100,
            minimumDate: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(result.map(\.id), [currentDocument.id])
    }

    func testBatchActionsUseOnlySelectedFilesPublishedByCurrentPage() {
        let visible = makeFile(name: "visible.pdf", path: "/docs/visible.pdf")
        let hidden = makeFile(name: "hidden.pdf", path: "/other/hidden.pdf")

        let result = AppModel.filesForBatchAction(
            selectedIDs: [visible.id, hidden.id],
            commandTargetFiles: [visible]
        )

        XCTAssertEqual(result.map(\.id), [visible.id])
    }

    @MainActor
    func testClearingCommandTargetDuringRefreshKeepsPaginationOwnership() {
        let model = AppModel()
        let file = makeFile(name: "page.pdf", path: "/docs/page.pdf")
        model.updateCommandTargetFiles(
            [file],
            usesGlobalSearchPagination: true
        )

        model.clearCommandTargetFilesKeepingPagination()

        XCTAssertTrue(model.hasPublishedCommandTarget)
        XCTAssertTrue(model.commandTargetUsesGlobalSearchPagination)
        XCTAssertTrue(model.commandTargetFiles.isEmpty)
    }

    func testModifiedDateLowerBoundExcludesFilesWithoutModifiedDate() {
        let missingDate = makeFile(
            name: "unknown.pdf",
            path: "/docs/unknown.pdf",
            modifiedAt: nil
        )
        let current = makeFile(
            name: "current.pdf",
            path: "/docs/current.pdf",
            modifiedAt: Date(timeIntervalSince1970: 300)
        )

        let result = AppModel.filesMatchingBrowseFilters(
            indexedFiles: [missingDate, current],
            aiSearchResults: nil,
            searchResults: nil,
            query: "",
            kind: nil,
            minimumSize: 0,
            minimumDate: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(result.map(\.id), [current.id])
    }

    func testExportCategoryNamesUsesOnlyRequestedFilesAndStableOrdering() {
        let first = makeFile(name: "first.pdf", path: "/docs/first.pdf")
        let second = makeFile(name: "second.pdf", path: "/docs/second.pdf")
        let finance = UUID()
        let work = UUID()

        let result = FileListExport.categoryNames(
            for: [first],
            links: [
                first.id: [work, finance],
                second.id: [work]
            ],
            namesByID: [finance: "Finance", work: "Work"],
            orderByID: [finance: 0, work: 1]
        )

        XCTAssertEqual(result, [first.id: ["Finance", "Work"]])
    }

    func testCSVFieldsNeutralizeSpreadsheetFormulas() {
        XCTAssertEqual(FileListExport.csvField("=1+1"), "'=1+1")
        XCTAssertEqual(FileListExport.csvField("+SUM(A1:A2)"), "'+SUM(A1:A2)")
        XCTAssertEqual(FileListExport.csvField("@command"), "'@command")
        XCTAssertEqual(FileListExport.csvField("  =1+1"), "'  =1+1")
        XCTAssertEqual(FileListExport.csvField("normal.txt"), "normal.txt")
    }

    func testStreamingCSVExportMatchesInMemoryContractAndReplacesDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("files.csv")
        try Data("stale".utf8).write(to: destination)
        let files = [
            makeFile(name: "=formula.pdf", path: "/docs/=formula.pdf", size: 42),
            makeFile(name: "report.pdf", path: "/docs/report.pdf", size: 84)
        ]
        let categoryNames = [files[0].id: ["Finance"], files[1].id: ["Work"]]

        try FileListExport.write(
            files: files,
            format: .csv,
            categoryNames: categoryNames,
            to: destination
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(
            exported,
            FileListExport.contents(
                for: files,
                format: .csv,
                categoryNames: categoryNames
            )
        )
        XCTAssertTrue(exported.contains("'=formula.pdf"))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".xunjian-export-") }
        )
    }

    @MainActor
    func testPagedCSVExportResolvesOnlyBoundedMetadataBatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-paged-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("files.csv")
        let files = (0..<1_001).map { index in
            makeFile(
                name: "file-\(index).pdf",
                path: "/docs/file-\(index).pdf",
                size: Int64(index)
            )
        }
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let orderedIDs = files.map(\.id)
        let probe = ExportPageProbe()

        try await FileListExport.writePaged(
            orderedIDs: orderedIDs,
            format: .csv,
            to: destination
        ) { ids in
            await probe.record(pageSize: ids.count)
            return FileExportPage(
                files: ids.compactMap { filesByID[$0] },
                categoryNames: [:]
            )
        }

        let exported = try String(contentsOf: destination, encoding: .utf8)
        let pageSizes = await probe.pageSizes()
        XCTAssertEqual(exported.split(separator: "\n").count, files.count + 1)
        XCTAssertEqual(pageSizes, [500, 500, 1])
    }

    func testUnboundedSearchIDsApplySourceHiddenAndMetadataFilters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-search-ids-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "Documents", path: root.path, bookmark: Data([1])
        )
        let otherSource = try await database.upsertSource(
            displayName: "Other", path: "/other", bookmark: Data([2])
        )
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let matching = IndexedFile(
            id: "matching", sourceID: source.id, name: "current.txt",
            path: root.appendingPathComponent("current.txt").path,
            fileExtension: "txt", kind: .document, size: 2_048,
            createdAt: nil, modifiedAt: cutoff.addingTimeInterval(1), indexedAt: Date(),
            textContent: "共同检索词"
        )
        let hidden = IndexedFile(
            id: "hidden", sourceID: source.id, name: ".secret.txt",
            path: root.appendingPathComponent(".secret.txt").path,
            fileExtension: "txt", kind: .document, size: 2_048,
            createdAt: nil, modifiedAt: cutoff.addingTimeInterval(1), indexedAt: Date(),
            textContent: "共同检索词"
        )
        let wrongKind = IndexedFile(
            id: "image", sourceID: source.id, name: "current.png",
            path: root.appendingPathComponent("current.png").path,
            fileExtension: "png", kind: .image, size: 2_048,
            createdAt: nil, modifiedAt: cutoff.addingTimeInterval(1), indexedAt: Date(),
            textContent: "共同检索词"
        )
        let other = IndexedFile(
            id: "other", sourceID: otherSource.id, name: "other.txt", path: "/other/other.txt",
            fileExtension: "txt", kind: .document, size: 2_048,
            createdAt: nil, modifiedAt: cutoff.addingTimeInterval(1), indexedAt: Date(),
            textContent: "共同检索词"
        )
        try await database.replaceFiles(for: source.id, with: [matching, hidden, wrongKind])
        try await database.replaceFiles(for: otherSource.id, with: [other])

        let ids = try await database.searchFileIDs(
            matching: "共同检索词",
            includesHiddenFiles: false,
            sourceIDs: [source.id],
            kind: .document,
            minimumSize: 1_024,
            minimumDate: cutoff
        )

        XCTAssertEqual(ids, [matching.id])
    }

    func testStorageInsightsKeepsOnlyCorrectTopTenFiles() {
        let sourceID = UUID()
        let files = (0..<25).map { index in
            IndexedFile(
                id: "file-\(index)",
                sourceID: sourceID,
                name: "file-\(index).pdf",
                path: "/docs/file-\(index).pdf",
                fileExtension: "pdf",
                kind: .document,
                size: Int64(index),
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                indexedAt: Date()
            )
        }

        let snapshot = StorageInsightsSnapshot.make(files: files, sources: [])

        XCTAssertEqual(snapshot.largestFiles.map(\.size), Array((15..<25).reversed()).map(Int64.init))
        XCTAssertEqual(snapshot.oldestFiles.map(\.id), (0..<10).map { "file-\($0)" })
    }

    func testDuplicateHashReadsTheCompleteFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-duplicate-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("abc".utf8).write(to: file)

        let digest = try await DuplicateFileFinder.hash(fileAt: file)
        XCTAssertEqual(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDuplicateHashRejectsLinksFIFOsAndDevicesWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-special-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let regular = root.appendingPathComponent("regular.bin")
        try Data("safe".utf8).write(to: regular)
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        for url in [link, fifo, URL(fileURLWithPath: "/dev/null")] {
            XCTAssertFalse(DuplicateFileFinder.canHashFile(at: url), url.path)
            do {
                _ = try await DuplicateFileFinder.fingerprint(fileAt: url)
                XCTFail("Expected special file to be rejected: \(url.path)")
            } catch {
                // Rejection is the contract; the exact filesystem errno is
                // intentionally not exposed to the UI.
            }
        }
    }

    func testQuickSearchMatchesNameAndPath() {
        let file = makeFile(
            name: "invoice.pdf",
            path: "/Users/me/Documents/Finance/invoice.pdf"
        )

        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "invoice"))
        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "Finance"))
        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "DOCUMENTS"))
        XCTAssertFalse(QuickSearchMatching.matches(file: file, query: "taxes"))
    }

    func testQuickSearchReportsPathOnlyHits() {
        let file = makeFile(
            name: "invoice.pdf",
            path: "/Users/me/Documents/Finance/invoice.pdf"
        )

        XCTAssertTrue(QuickSearchMatching.matchedPathOnly(file: file, query: "Finance"))
        XCTAssertFalse(QuickSearchMatching.matchedPathOnly(file: file, query: "invoice"))
        XCTAssertFalse(QuickSearchMatching.matchedPathOnly(file: file, query: "taxes"))
    }

    func testSavedSearchSummaryIncludesQuerySizeAndDate() {
        let search = SavedSearch(
            id: UUID(),
            name: "Contracts",
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let english = search.conditionSummary(usesEnglish: true)
        XCTAssertTrue(english.contains("合同"))
        XCTAssertTrue(english.contains("10"))
        XCTAssertFalse(english.isEmpty)

        let chinese = search.conditionSummary(usesEnglish: false)
        XCTAssertTrue(chinese.contains("合同"))
        XCTAssertTrue(chinese.contains("10"))
    }

    func testSavedSearchSummaryForUnconstrainedSearch() {
        let search = SavedSearch(
            id: UUID(),
            name: "Everything",
            query: "  ",
            minSizeBytes: 0,
            minDate: nil,
            createdAt: Date()
        )

        XCTAssertEqual(search.conditionSummary(usesEnglish: true), "Any name")
        XCTAssertEqual(search.conditionSummary(usesEnglish: false), "不限名称")
    }

    func testDuplicateCleanupKeepsTheNewestFile() {
        let older = makeFile(name: "a.pdf", path: "/a.pdf", modifiedAt: Date(timeIntervalSince1970: 1))
        let newest = makeFile(name: "b.pdf", path: "/b.pdf", modifiedAt: Date(timeIntervalSince1970: 9))
        let middle = makeFile(name: "c.pdf", path: "/c.pdf", modifiedAt: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(DuplicateCleanup.fileToKeep(in: [older, newest, middle])?.id, newest.id)
        XCTAssertEqual(
            DuplicateCleanup.filesToTrash(keepingNewestIn: [older, newest, middle]).map(\.id),
            [older.id, middle.id]
        )
    }

    func testDuplicateCleanupFallsBackToPathWhenDatesMatch() {
        let date = Date(timeIntervalSince1970: 42)
        let left = makeFile(name: "copy.pdf", path: "/z/copy.pdf", modifiedAt: date)
        let right = makeFile(name: "copy.pdf", path: "/a/copy.pdf", modifiedAt: date)

        XCTAssertEqual(DuplicateCleanup.fileToKeep(in: [left, right])?.path, "/a/copy.pdf")
        XCTAssertEqual(DuplicateCleanup.filesToTrash(keepingNewestIn: [left, right]).map(\.path), ["/z/copy.pdf"])
    }

    @MainActor
    func testFileTableKeepsStableIdentityAcrossInspectorWidthChanges() {
        XCTAssertEqual(
            FileTableLayout.snapshotLayoutToken(contentWidth: 360, viewMode: .list),
            FileTableLayout.snapshotLayoutToken(contentWidth: 1_200, viewMode: .list)
        )
        XCTAssertNotEqual(
            FileTableLayout.snapshotLayoutToken(contentWidth: 360, viewMode: .grid),
            FileTableLayout.snapshotLayoutToken(contentWidth: 1_200, viewMode: .grid)
        )
    }

    func testSavedSearchMatchesCurrentFilters() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let search = SavedSearch(
            id: UUID(),
            name: "Contracts",
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            createdAt: Date()
        )

        XCTAssertTrue(search.matches(
            query: " 合同 ",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 0,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "发票",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: nil
        ))
        XCTAssertTrue(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            fileKind: nil
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            fileKind: .document
        ))
    }

    func testSavedSearchIncludesKindInCurrentMatch() {
        let search = SavedSearch(
            id: UUID(),
            name: "PDFs",
            query: "合同",
            minSizeBytes: 0,
            minDate: nil,
            createdAt: Date(),
            fileKind: .document
        )
        XCTAssertTrue(search.matches(query: "合同", minSizeBytes: 0, minDate: nil, fileKind: .document))
        XCTAssertFalse(search.matches(query: "合同", minSizeBytes: 0, minDate: nil, fileKind: nil))
        XCTAssertTrue(search.conditionSummary(usesEnglish: false).contains("文档"))
        XCTAssertTrue(search.conditionSummary(usesEnglish: true).contains("Document"))
    }

    func testQuickSearchPrefixCountsRemainingMatches() {
        let files = [
            makeFile(name: "a.pdf", path: "/docs/a.pdf"),
            makeFile(name: "b.pdf", path: "/docs/b.pdf"),
            makeFile(name: "notes.txt", path: "/docs/notes.txt"),
            makeFile(name: "c.pdf", path: "/other/c.pdf")
        ]
        let result = QuickSearchMatching.prefixMatches(
            in: files,
            query: "pdf",
            limit: 2
        )
        XCTAssertEqual(result.files.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertEqual(result.remainingCount, 1)
    }

    func testDuplicateFindSkipsUnreadablePackagesWithoutFailing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-dup-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let left = root.appendingPathComponent("a.txt")
        let right = root.appendingPathComponent("b.txt")
        let package = root.appendingPathComponent("pack.pages", isDirectory: true)
        try Data("abc".utf8).write(to: left)
        try Data("abc".utf8).write(to: right)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("internal".utf8).write(to: package.appendingPathComponent("index.xml"))

        let files = [
            makeFile(name: "a.txt", path: left.path, size: 3),
            makeFile(name: "b.txt", path: right.path, size: 3),
            makeFile(name: "pack.pages", path: package.path, size: 3)
        ]
        let result = try await DuplicateFileFinder.find(in: files)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.name)), ["a.txt", "b.txt"])
        XCTAssertEqual(result.unreadCount, 1)
    }

    func testDuplicateCleanupRevalidatesCurrentBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-dup-revalidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("a.txt")
        let right = root.appendingPathComponent("b.txt")
        try Data("abc".utf8).write(to: left)
        try Data("abc".utf8).write(to: right)
        let files = [
            makeFile(name: "a.txt", path: left.path, size: 3),
            makeFile(name: "b.txt", path: right.path, size: 3)
        ]
        let initialResult = try await DuplicateFileFinder.find(in: files)
        let group = try XCTUnwrap(initialResult.groups.first)
        let initiallyMatches = try await DuplicateFileFinder.stillMatches(group)
        XCTAssertTrue(initiallyMatches)

        try Data("xyz".utf8).write(to: right)
        let matchesAfterMutation = try await DuplicateFileFinder.stillMatches(group)
        XCTAssertFalse(matchesAfterMutation)
    }

    func testDuplicateCoordinatedDeleteRejectsContentChangedAfterHash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-dup-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let keeperURL = root.appendingPathComponent("keeper.txt")
        let candidateURL = root.appendingPathComponent("candidate.txt")
        try Data("same".utf8).write(to: keeperURL)
        try Data("same".utf8).write(to: candidateURL)
        let sourceID = UUID()
        let scanned = try await FileScanner().scan(sourceID: sourceID, rootURL: root)
        let candidate = try XCTUnwrap(scanned.first { $0.url == candidateURL })
        let keeperFingerprint = try await DuplicateFileFinder.fingerprint(fileAt: keeperURL)
        let candidateFingerprint = try await DuplicateFileFinder.fingerprint(fileAt: candidateURL)

        try Data("changed".utf8).write(to: candidateURL)

        do {
            _ = try await FileOperationService().moveDuplicateToTrash(
                indexedFile: candidate,
                expectedVersion: candidateFingerprint.version,
                matching: keeperURL,
                expectedReferenceVersion: keeperFingerprint.version
            )
            XCTFail("Expected changed candidate to be rejected")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .fileIdentityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeperURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testExcludedRescanPreservesFileAndCategoryRelationship() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-preserved-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(databaseURL: root.appendingPathComponent("index.sqlite3"))
        let source = try await database.upsertSource(
            displayName: "Documents",
            path: root.path,
            bookmark: Data([1])
        )
        let visible = IndexedFile(
            id: "visible", sourceID: source.id, name: "visible.txt",
            path: root.appendingPathComponent("visible.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        let excluded = IndexedFile(
            id: "excluded", sourceID: source.id, name: "secret.txt",
            path: root.appendingPathComponent("Private/secret.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [visible, excluded])
        let category = try await database.createCategory(name: "保留", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: excluded.id)

        try await database.replaceFiles(
            for: source.id,
            with: [visible],
            preservedUnscannedFileIDs: [excluded.id]
        )

        let persistedIDs = Set(try await database.fetchFiles().map(\.id))
        let persistedCategoryIDs = try await database.fetchCategoryIDs(forFile: excluded.id)
        XCTAssertEqual(persistedIDs, [visible.id, excluded.id])
        XCTAssertEqual(persistedCategoryIDs, [category.id])
    }

    func testMetadataRefreshPreservesStoredTextInFTS() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-preserved-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(databaseURL: root.appendingPathComponent("index.sqlite3"))
        let source = try await database.upsertSource(
            displayName: "Documents", path: root.path, bookmark: Data([1])
        )
        let file = IndexedFile(
            id: "document", sourceID: source.id, name: "notes.txt",
            path: root.appendingPathComponent("notes.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [file])
        try await database.updateTextContents([
            FileTextContentUpdate(fileID: file.id, textContent: "persistent sentinel phrase")
        ])

        try await database.replaceFiles(
            for: source.id,
            with: [file],
            preservesExistingText: true
        )

        let persistedText = try await database.fetchTextContent(forFileID: file.id)
        let matchingIDs = try await database.searchFiles(matching: "sentinel").map(\.id)
        XCTAssertEqual(persistedText, "persistent sentinel phrase")
        XCTAssertEqual(matchingIDs, [file.id])
    }

    func testStagedTextContentsCommitAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-staged-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(databaseURL: root.appendingPathComponent("index.sqlite3"))
        let source = try await database.upsertSource(
            displayName: "Documents", path: root.path, bookmark: Data([1])
        )
        let file = IndexedFile(
            id: "document", sourceID: source.id, name: "notes.txt",
            path: root.appendingPathComponent("notes.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [file])
        try await database.updateTextContents([
            FileTextContentUpdate(fileID: file.id, textContent: "old complete phrase")
        ])
        let scanID = UUID()
        try await database.stageTextContents([
            FileTextContentUpdate(fileID: file.id, textContent: "new complete phrase")
        ], scanID: scanID)

        let oldBeforeCommit = try await database.searchFiles(matching: "old").map(\.id)
        let newBeforeCommit = try await database.searchFiles(matching: "new").map(\.id)
        XCTAssertEqual(oldBeforeCommit, [file.id])
        XCTAssertTrue(newBeforeCommit.isEmpty)

        try await database.commitStagedTextContents(scanID: scanID, sourceID: source.id)

        let oldAfterCommit = try await database.searchFiles(matching: "old").map(\.id)
        let newAfterCommit = try await database.searchFiles(matching: "new").map(\.id)
        XCTAssertTrue(oldAfterCommit.isEmpty)
        XCTAssertEqual(newAfterCommit, [file.id])
    }

    func testStagedTextCommitPreservesUnscannedFileTextAndFTS() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-staged-preserved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(databaseURL: root.appendingPathComponent("index.sqlite3"))
        let source = try await database.upsertSource(
            displayName: "Documents", path: root.path, bookmark: Data([1])
        )
        let visible = IndexedFile(
            id: "visible", sourceID: source.id, name: "visible.txt",
            path: root.appendingPathComponent("visible.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        let preserved = IndexedFile(
            id: "preserved", sourceID: source.id, name: ".preserved.txt",
            path: root.appendingPathComponent(".preserved.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [visible, preserved])
        try await database.updateTextContents([
            FileTextContentUpdate(fileID: visible.id, textContent: "old visible phrase"),
            FileTextContentUpdate(fileID: preserved.id, textContent: "preserved sentinel phrase")
        ])
        try await database.replaceFiles(
            for: source.id,
            with: [visible],
            preservesExistingText: true,
            preservedUnscannedFileIDs: [preserved.id]
        )
        let scanID = UUID()
        try await database.stageTextContents([
            FileTextContentUpdate(fileID: visible.id, textContent: "new visible phrase")
        ], scanID: scanID)

        try await database.commitStagedTextContents(
            scanID: scanID,
            sourceID: source.id,
            preservedUnscannedFileIDs: [preserved.id]
        )

        let preservedText = try await database.fetchTextContent(forFileID: preserved.id)
        let sentinelIDs = try await database.searchFiles(matching: "sentinel").map(\.id)
        let newIDs = try await database.searchFiles(matching: "new").map(\.id)
        let oldIDs = try await database.searchFiles(matching: "old").map(\.id)
        XCTAssertEqual(preservedText, "preserved sentinel phrase")
        XCTAssertEqual(sentinelIDs, [preserved.id])
        XCTAssertEqual(newIDs, [visible.id])
        XCTAssertTrue(oldIDs.isEmpty)
    }

    func testDocumentPackageIsIndexedAsOneFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-package-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Report.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("internal".utf8).write(to: package.appendingPathComponent("index.xml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try await FileScanner().scan(sourceID: UUID(), rootURL: root)

        XCTAssertEqual(files.map(\.name), ["Report.pages"])
        XCTAssertEqual(files.first?.kind, .document)
    }

    func testDestructiveOperationRejectsFileReplacedAtIndexedPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.txt")
        try Data("first".utf8).write(to: url)
        let scanner = FileScanner()
        let scanned = try await scanner.scan(sourceID: UUID(), rootURL: root)
        let indexed = try XCTUnwrap(scanned.first)
        let service = FileOperationService()
        try await service.requireIndexedIdentity(indexed)

        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)

        do {
            _ = try await service.rename(indexedFile: indexed, to: "renamed.txt")
            XCTFail("Expected replacement to be rejected")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .fileIdentityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("renamed.txt").path
            )
        )
    }

    func testTextExtractionStreamsBoundedBatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-text-batches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try Data("text \(index)".utf8).write(
                to: root.appendingPathComponent("file-\(index).txt")
            )
        }
        let scanner = FileScanner()
        let files = try await scanner.scan(
            sourceID: UUID(),
            rootURL: root,
            extractsText: false
        )
        let recorder = TextExtractionBatchRecorder()

        try await scanner.extractTextContents(
            in: files,
            batchSize: 2,
            consume: { updates in await recorder.record(updates) }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.sizes, [2, 2, 1])
        XCTAssertEqual(snapshot.fileIDs.count, 5)
        XCTAssertEqual(Set(snapshot.fileIDs), Set(files.map(\.id)))
    }

    func testContentIndexCanBeEnrichedAndClearedWithoutRemovingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-content-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "Documents",
            path: root.path,
            bookmark: Data([1])
        )
        let file = IndexedFile(
            id: "content-file",
            sourceID: source.id,
            name: "notes.md",
            path: root.appendingPathComponent("notes.md").path,
            fileExtension: "md",
            kind: .document,
            size: 12,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [file])
        try await database.updateTextContents([
            FileTextContentUpdate(fileID: file.id, textContent: "private searchable phrase")
        ])
        let storedText = try await database.fetchTextContent(forFileID: file.id)
        let matchingBeforeClear = try await database.searchFiles(matching: "searchable")
        XCTAssertEqual(storedText, "private searchable phrase")
        XCTAssertEqual(matchingBeforeClear.map(\.id), [file.id])

        try await database.clearTextContents()

        let clearedText = try await database.fetchTextContent(forFileID: file.id)
        let matchingAfterClear = try await database.searchFiles(matching: "searchable")
        let remainingFiles = try await database.fetchFiles()
        XCTAssertNil(clearedText)
        XCTAssertTrue(matchingAfterClear.isEmpty)
        XCTAssertEqual(remainingFiles.map(\.id), [file.id])
    }

    private func makeFile(
        name: String,
        path: String,
        modifiedAt: Date? = Date(),
        size: Int64 = 1
    ) -> IndexedFile {
        IndexedFile(
            id: path,
            sourceID: UUID(),
            name: name,
            path: path,
            fileExtension: "pdf",
            kind: .document,
            size: size,
            createdAt: nil,
            modifiedAt: modifiedAt,
            indexedAt: Date()
        )
    }
}

private final class IsolatedDuplicateTrashManager: FileManager, @unchecked Sendable {
    let root: URL
    let trash: URL
    private var calls = 0
    init(root: URL, trash: URL) { self.root = root; self.trash = trash; super.init() }
    override func trashItem(at url: URL, resultingItemURL result: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        calls += 1
        if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
        let destination = trash.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: destination)
        result?.pointee = destination as NSURL
    }
}

private actor TextExtractionBatchRecorder {
    private var sizes: [Int] = []
    private var fileIDs: [String] = []

    func record(_ updates: [FileTextContentUpdate]) {
        sizes.append(updates.count)
        fileIDs.append(contentsOf: updates.map(\.fileID))
    }

    func snapshot() -> (sizes: [Int], fileIDs: [String]) {
        (sizes, fileIDs)
    }
}

private actor ExportPageProbe {
    private var sizes: [Int] = []

    func record(pageSize: Int) {
        sizes.append(pageSize)
    }

    func pageSizes() -> [Int] {
        sizes
    }
}
