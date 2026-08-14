import AppKit
import CoreServices
import XCTest
@testable import XunJian

final class NavigationModelTests: XCTestCase {
    @MainActor
    func testAISearchRevisionChangesEvenWhenResultCountCanStayTheSame() {
        let model = AppModel()
        let initialRevision = model.aiSearchRevision

        model.clearAISearch()

        XCTAssertGreaterThan(model.aiSearchRevision, initialRevision)
    }

    @MainActor
    func testCollapsedProviderStatusUsesCurrentAPIKeyModeInsteadOfOAuthState() {
        let status = AIProviderCollapsedStatusPresentation.make(
            supportsOAuth: true,
            isCurrentProvider: true,
            activeMode: .apiKey,
            hasAPIKey: true,
            apiKeyState: .verified,
            hasCredentialError: false,
            hasUnsavedConfigurationChanges: false,
            oauthState: .disconnected
        )

        XCTAssertEqual(
            status.title,
            AppLanguage.localized("API Key：已验证", english: "API Key: Verified")
        )
        XCTAssertEqual(status.tone, .green)
    }

    @MainActor
    func testCollapsedProviderStatusUsesCurrentOAuthModeInsteadOfAPIKeyFallback() {
        let status = AIProviderCollapsedStatusPresentation.make(
            supportsOAuth: true,
            isCurrentProvider: true,
            activeMode: .oauth,
            hasAPIKey: true,
            apiKeyState: .failed("API Key failed"),
            hasCredentialError: true,
            hasUnsavedConfigurationChanges: true,
            oauthState: .connected
        )

        XCTAssertEqual(
            status.title,
            AppLanguage.localized(
                "OAuth：\(AIOAuthState.connected.localizedTitle)",
                english: "OAuth: \(AIOAuthState.connected.localizedTitle)"
            )
        )
        XCTAssertEqual(status.tone, .green)
    }

    @MainActor
    func testCollapsedNonCurrentOAuthProviderShowsBothAuthenticationChannels() {
        let status = AIProviderCollapsedStatusPresentation.make(
            supportsOAuth: true,
            isCurrentProvider: false,
            activeMode: .oauth,
            hasAPIKey: true,
            apiKeyState: .saved,
            hasCredentialError: false,
            hasUnsavedConfigurationChanges: false,
            oauthState: .signedInUnverified
        )

        XCTAssertEqual(
            status.title,
            AppLanguage.localized(
                "OAuth：\(AIOAuthState.signedInUnverified.localizedTitle) · API Key：已保存，需验证",
                english: "OAuth: \(AIOAuthState.signedInUnverified.localizedTitle) · API Key: Saved; Verification Required"
            )
        )
        XCTAssertEqual(status.tone, .secondary)
    }

    @MainActor
    func testAddingExactExistingSourceIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(root, against: [makeSource(at: root)])
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("相同来源必须被拒绝，实际为 \(error)")
            }
        }
    }

    @MainActor
    func testAddingChildOfExistingSourceIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("子文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(child, against: [makeSource(at: root)])
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("父来源已存在时必须拒绝子来源，实际为 \(error)")
            }
        }
    }

    @MainActor
    func testAddingParentOfExistingSourceIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("子文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(root, against: [makeSource(at: child)])
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("子来源已存在时必须拒绝父来源，实际为 \(error)")
            }
        }
    }

    @MainActor
    func testAddingSymlinkAliasOfExistingSourceIsRejected() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let target = container.appendingPathComponent("真实来源", isDirectory: true)
        let alias = container.appendingPathComponent("来源别名", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(alias, against: [makeSource(at: target)])
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("指向已有来源的符号链接必须被拒绝，实际为 \(error)")
            }
        }
    }

    @MainActor
    func testAddingUnrelatedSourceIsAllowed() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = container.appendingPathComponent("来源 A", isDirectory: true)
        let second = container.appendingPathComponent("来源 B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)

        XCTAssertNoThrow(
            try AppModel.validateSourceCandidate(second, against: [makeSource(at: first)])
        )
    }

    @MainActor
    func testReauthorizingSourceToItsOwnPathIsAllowed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = makeSource(at: root)

        XCTAssertNoThrow(
            try AppModel.validateSourceCandidate(
                root,
                against: [source],
                excluding: source.id
            )
        )
    }

    @MainActor
    func testReauthorizingMovedSourceToUniquePathIsAllowed() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("原位置", isDirectory: true)
        let moved = container.appendingPathComponent("移动后", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let source = makeSource(at: original)
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertNoThrow(
            try AppModel.validateSourceCandidate(
                moved,
                against: [source],
                excluding: source.id
            )
        )
    }

    @MainActor
    func testReauthorizingSourceToAnotherExactSourceIsRejectedWithoutChangingRecord() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("待恢复", isDirectory: true)
        let existing = container.appendingPathComponent("已有来源", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let source = makeSource(at: original)
        let sources = [source, makeSource(at: existing)]
        let snapshot = sources

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(
                existing,
                against: sources,
                excluding: source.id
            )
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("重新授权到另一相同来源必须被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(sources, snapshot)
    }

    @MainActor
    func testReauthorizingSourceToChildOfAnotherSourceIsRejectedWithoutChangingRecord() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("待恢复", isDirectory: true)
        let existing = container.appendingPathComponent("已有来源", isDirectory: true)
        let child = existing.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let source = makeSource(at: original)
        let sources = [source, makeSource(at: existing)]
        let snapshot = sources

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(
                child,
                against: sources,
                excluding: source.id
            )
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("重新授权到另一来源的子目录必须被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(sources, snapshot)
    }

    @MainActor
    func testReauthorizingSourceToParentOfAnotherSourceIsRejectedWithoutChangingRecord() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("待恢复", isDirectory: true)
        let candidate = container.appendingPathComponent("候选父目录", isDirectory: true)
        let existing = candidate.appendingPathComponent("已有来源", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let source = makeSource(at: original)
        let sources = [source, makeSource(at: existing)]
        let snapshot = sources

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(
                candidate,
                against: sources,
                excluding: source.id
            )
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("重新授权到另一来源的父目录必须被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(sources, snapshot)
    }

    @MainActor
    func testReauthorizingSourceToSymlinkAliasIsRejectedWithoutChangingRecord() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("待恢复", isDirectory: true)
        let existing = container.appendingPathComponent("已有来源", isDirectory: true)
        let alias = container.appendingPathComponent("已有来源别名", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        let source = makeSource(at: original)
        let sources = [source, makeSource(at: existing)]
        let snapshot = sources

        XCTAssertThrowsError(
            try AppModel.validateSourceCandidate(
                alias,
                against: sources,
                excluding: source.id
            )
        ) { error in
            guard case FileIndexError.overlappingSource = error else {
                return XCTFail("重新授权到另一来源的符号链接别名必须被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(sources, snapshot)
    }

    @MainActor
    func testRapidCategoryTogglesPreserveClickParity() {
        var pendingAssignment: Bool?
        pendingAssignment = AppModel.categoryAssignmentAfterToggle(
            persistedAssignment: false,
            pendingAssignment: pendingAssignment
        )
        pendingAssignment = AppModel.categoryAssignmentAfterToggle(
            persistedAssignment: false,
            pendingAssignment: pendingAssignment
        )
        XCTAssertEqual(pendingAssignment, false, "Two clicks should return to the initial state")

        pendingAssignment = AppModel.categoryAssignmentAfterToggle(
            persistedAssignment: false,
            pendingAssignment: pendingAssignment
        )
        XCTAssertEqual(pendingAssignment, true, "Three clicks should end in the toggled state")
    }

    func testDefaultCategoriesAreUniqueAndNamed() {
        let categories = FileCategory.defaults

        XCTAssertEqual(categories.count, 8)
        XCTAssertEqual(Set(categories.map(\.id)).count, categories.count)
        XCTAssertTrue(categories.allSatisfy { !$0.name.isEmpty && !$0.symbolName.isEmpty })
    }

    func testCategoryDestinationUsesMatchingCategoryTitle() throws {
        let category = try XCTUnwrap(FileCategory.defaults.first)
        let destination = NavigationDestination.category(category.id)

        XCTAssertEqual(destination.title(categories: FileCategory.defaults), category.name)
    }

    func testEveryFileKindHasVisibleMetadata() {
        XCTAssertTrue(FileKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
    }

    @MainActor
    func testDeletedCurrentCategoryReturnsToCategoryOverview() {
        let categoryID = UUID()
        XCTAssertEqual(
            AppShellView.selectionAfterCategoryReload(
                .category(categoryID),
                availableCategoryIDs: []
            ),
            .categories
        )
        XCTAssertEqual(
            AppShellView.selectionAfterCategoryReload(
                .category(categoryID),
                availableCategoryIDs: [categoryID]
            ),
            .category(categoryID)
        )
        XCTAssertEqual(
            AppShellView.selectionAfterCategoryReload(
                .allFiles,
                availableCategoryIDs: []
            ),
            .allFiles
        )
    }

    @MainActor
    func testRelevanceSortOnlyAppearsDuringSearch() {
        XCTAssertFalse(AllFilesView.availableSortOrders(hasActiveSearch: false).contains(.relevance))
        XCTAssertTrue(AllFilesView.availableSortOrders(hasActiveSearch: true).contains(.relevance))
        XCTAssertEqual(
            AllFilesView.normalizedSortOrder(.relevance, hasActiveSearch: false),
            .modifiedAt
        )
        XCTAssertEqual(
            AllFilesView.normalizedSortOrder(.relevance, hasActiveSearch: true),
            .relevance
        )
        XCTAssertEqual(
            AllFilesView.normalizedSortOrder(.name, hasActiveSearch: false),
            .name
        )
    }

    @MainActor
    func testSearchAndBrowseSortContextsRemainIndependent() {
        XCTAssertEqual(
            AllFilesView.selectedSortOrder(
                hasActiveSearch: false,
                browse: .createdAt,
                search: .relevance
            ),
            .createdAt
        )
        XCTAssertEqual(
            AllFilesView.selectedSortOrder(
                hasActiveSearch: true,
                browse: .createdAt,
                search: .relevance
            ),
            .relevance
        )
    }

    @MainActor
    func testRetestingCurrentAPIKeyDeactivatesOnlyMatchingAPISelection() {
        XCTAssertTrue(AppModel.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: .deepSeek,
            activeMode: .apiKey,
            testedKind: .deepSeek
        ))
        XCTAssertFalse(AppModel.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: .deepSeek,
            activeMode: .oauth,
            testedKind: .deepSeek
        ))
        XCTAssertFalse(AppModel.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: .qwen,
            activeMode: .apiKey,
            testedKind: .deepSeek
        ))
    }

    @MainActor
    func testLateScanCleanupCannotOwnNewScanState() {
        let oldGeneration = UUID()
        let newGeneration = UUID()
        XCTAssertFalse(
            AppModel.scanCleanupOwnsState(
                currentGeneration: newGeneration,
                finishingGeneration: oldGeneration
            )
        )
        XCTAssertTrue(
            AppModel.scanCleanupOwnsState(
                currentGeneration: newGeneration,
                finishingGeneration: newGeneration
            )
        )
    }

    @MainActor
    func testMissingFileSweepIsSkippedWhenAnyIncrementalScopeFailed() {
        XCTAssertTrue(AppModel.shouldRemoveMissingFiles(
            failedScopeCount: 0,
            hasRemovalEvents: true
        ))
        XCTAssertFalse(AppModel.shouldRemoveMissingFiles(
            failedScopeCount: 1,
            hasRemovalEvents: true
        ))
        XCTAssertFalse(AppModel.shouldRemoveMissingFiles(
            failedScopeCount: 0,
            hasRemovalEvents: false
        ))
    }

    @MainActor
    func testRecoveryFullRescanQueuesWhileAnotherScanOwnsTheState() {
        XCTAssertTrue(AppModel.shouldQueueFullRescan(isScanning: true))
        XCTAssertFalse(AppModel.shouldQueueFullRescan(isScanning: false))
    }
}

private func makeSource(at url: URL) -> FileSource {
    FileSource(
        id: UUID(),
        displayName: url.lastPathComponent,
        path: url.path,
        bookmark: Data(),
        enabled: true,
        createdAt: Date()
    )
}

final class BookmarkManagerTests: XCTestCase {
    func testBookmarkRoundTripRestoresSelectedDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = BookmarkManager()
        let bookmark = try manager.createBookmark(for: directory)
        let restored = try manager.resolveBookmark(bookmark)

        XCTAssertEqual(restored.url.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertFalse(restored.isStale)
    }

    func testBookmarkTracksDirectoryAfterItMoves() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("原目录", isDirectory: true)
        let moved = container.appendingPathComponent("移动后的目录", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

        let manager = BookmarkManager()
        let bookmark = try manager.createBookmark(for: original)
        try FileManager.default.moveItem(at: original, to: moved)

        let restored = try manager.resolveBookmark(bookmark)

        XCTAssertEqual(restored.url.standardizedFileURL, moved.standardizedFileURL)
    }

    func testInvalidBookmarkRequiresAuthorizationAgain() {
        XCTAssertThrowsError(try BookmarkManager().resolveBookmark(Data([0, 1, 2]))) { error in
            guard case FileIndexError.bookmarkResolution = error else {
                return XCTFail("无效 Bookmark 应映射为 bookmarkResolution，实际为 \(error)")
            }
        }
    }
}

final class FileScannerTests: XCTestCase {
    func testSkippedDirectoryMakesSnapshotIncomplete() {
        XCTAssertTrue(FileScanner.isComplete(skippedPaths: []))
        XCTAssertFalse(FileScanner.isComplete(skippedPaths: ["/private/unreadable"]))
    }

    func testScannerIndexesRegularFilesAndSkipsExcludedDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("资料", isDirectory: true)
        let excluded = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("说明.md"))
        try Data("emoji".utf8).write(to: nested.appendingPathComponent("计划🧭.txt"))
        try Data("skip".utf8).write(to: excluded.appendingPathComponent("ignored.js"))

        let sourceID = UUID()
        let files = try await FileScanner().scan(sourceID: sourceID, rootURL: root)

        XCTAssertEqual(Set(files.map(\.name)), ["说明.md", "计划🧭.txt"])
        XCTAssertTrue(files.allSatisfy { $0.sourceID == sourceID })
        XCTAssertTrue(files.allSatisfy { $0.size > 0 })
        XCTAssertEqual(files.first(where: { $0.name == "说明.md" })?.textContent, "hello")
    }

    func testScannerReturnsEmptyResultForEmptyDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try await FileScanner().scan(sourceID: UUID(), rootURL: root)

        XCTAssertTrue(files.isEmpty)
    }

    func testScannerSkipsDotPrefixedFilesByDefaultAndCanIncludeThem() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<1_000 {
            try Data("\(index)".utf8).write(
                to: root.appendingPathComponent("文件-\(index).txt")
            )
        }
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".保留.txt"))
        let longName = String(repeating: "长", count: 70) + ".md"
        try Data("long".utf8).write(to: root.appendingPathComponent(longName))

        let hiddenDirectory = root.appendingPathComponent(".私密", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hiddenDirectory,
            withIntermediateDirectories: true
        )
        try Data("nested hidden".utf8).write(
            to: hiddenDirectory.appendingPathComponent("嵌套.txt")
        )

        let files = try await FileScanner().scan(sourceID: UUID(), rootURL: root)
        let filesIncludingHidden = try await FileScanner().scan(
            sourceID: UUID(),
            rootURL: root,
            includesHiddenFiles: true
        )

        XCTAssertEqual(files.count, 1_001)
        XCTAssertFalse(files.contains(where: { $0.name == ".保留.txt" }))
        XCTAssertFalse(files.contains(where: { $0.name == "嵌套.txt" }))
        XCTAssertTrue(files.contains(where: { $0.name == longName }))
        XCTAssertEqual(filesIncludingHidden.count, 1_003)
        XCTAssertTrue(filesIncludingHidden.contains(where: { $0.name == ".保留.txt" }))
        XCTAssertTrue(filesIncludingHidden.contains(where: { $0.name == "嵌套.txt" }))
    }

    func testIncrementalScanKeepsIdentityAcrossRenameAndScopesDeletedPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let originalURL = root.appendingPathComponent("原文件.md")
        let renamedURL = root.appendingPathComponent("已重命名.md")
        try Data("identity".utf8).write(to: originalURL)
        let scanner = FileScanner()
        let originalFiles = try await scanner.scan(sourceID: sourceID, rootURL: root)
        let original = try XCTUnwrap(originalFiles.first)

        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let snapshot = try await scanner.scanChanges(
            sourceID: sourceID,
            rootURL: root,
            events: [
                FileSystemChangeEvent(
                    path: originalURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile
                    )
                ),
                FileSystemChangeEvent(
                    path: renamedURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile
                    )
                )
            ]
        )

        XCTAssertEqual(snapshot.files.map(\.id), [original.id])
        XCTAssertEqual(snapshot.files.map(\.path), [renamedURL.path])
        XCTAssertEqual(Set(snapshot.scopes.map(\.path)), [originalURL.path, renamedURL.path])
        XCTAssertTrue(snapshot.failedScopes.isEmpty)
    }

    func testFullScanFailsClosedWhenAnyFileMetadataCannotBeRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let readableURL = root.appendingPathComponent("可读.txt")
        let unreadableURL = root.appendingPathComponent("不可读.txt")
        try Data("readable".utf8).write(to: readableURL)
        try Data("unreadable".utf8).write(to: unreadableURL)

        let unreadablePath = unreadableURL.resolvingSymlinksInPath().standardizedFileURL.path
        let scanner = FileScanner(resourceValuesLoader: { url, keys in
            if url.resolvingSymlinksInPath().standardizedFileURL.path == unreadablePath {
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: keys)
        })

        do {
            _ = try await scanner.scan(sourceID: UUID(), rootURL: root)
            XCTFail("读取任一应扫描文件失败时，不得返回会触发全量替换的残缺快照")
        } catch let error as FileIndexError {
            guard case .unreadableFolder = error else {
                return XCTFail("应以不可读来源失败关闭，实际为 \(error)")
            }
        }
    }

    func testIncrementalScanExcludesFailedScopeFromReconciliationAndPreservesCategory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let goodURL = root.appendingPathComponent("成功.txt")
        let failedURL = root.appendingPathComponent("失败.txt")
        try Data("old-good".utf8).write(to: goodURL)
        try Data("old-failed".utf8).write(to: failedURL)

        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "增量失败范围",
            path: root.path,
            bookmark: Data([1, 2, 3])
        )
        let initialFiles = try await FileScanner().scan(sourceID: source.id, rootURL: root)
        try await database.replaceFiles(for: source.id, with: initialFiles)
        let failedFile = try XCTUnwrap(initialFiles.first(where: { $0.name == failedURL.lastPathComponent }))
        let category = try await database.createCategory(name: "必须保留", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: failedFile.id)

        try Data("new-good-content".utf8).write(to: goodURL)
        try Data("new-failed-content".utf8).write(to: failedURL)
        let failedPath = failedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let scanner = FileScanner(resourceValuesLoader: { url, keys in
            if url.resolvingSymlinksInPath().standardizedFileURL.path == failedPath {
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: keys)
        })
        let snapshot = try await scanner.scanChanges(
            sourceID: source.id,
            rootURL: root,
            events: [
                FileSystemChangeEvent(path: goodURL.path, kinds: [.modified], isDirectory: false),
                FileSystemChangeEvent(path: failedURL.path, kinds: [.modified], isDirectory: false)
            ]
        )

        XCTAssertEqual(
            snapshot.scopes.map(\.path),
            [goodURL.resolvingSymlinksInPath().standardizedFileURL.path]
        )
        XCTAssertEqual(snapshot.failedScopes.map(\.path), [failedPath])
        try await database.reconcileFiles(
            for: source.id,
            scopes: snapshot.scopes,
            with: snapshot.files
        )

        let persistedFiles = try await database.fetchFiles()
        let persistedCategoryIDs = try await database.fetchCategoryIDs(forFile: failedFile.id)
        XCTAssertEqual(Set(persistedFiles.map(\.name)), [goodURL.lastPathComponent, failedURL.lastPathComponent])
        XCTAssertEqual(
            persistedCategoryIDs,
            [category.id],
            "失败范围不得参与差集删除，旧文件与分类关联必须保留"
        )
    }
}

final class FileSystemChangeEventTests: XCTestCase {
    func testCanonicalizesUnicodePathComposition() {
        let composedPath = "/tmp/监听/移出.txt"
        let decomposedPath = composedPath.decomposedStringWithCanonicalMapping
        let event = FileSystemChangeEvent(
            path: decomposedPath,
            kinds: [.modified],
            isDirectory: false
        )
        let expectedPath = URL(fileURLWithPath: composedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping

        XCTAssertEqual(event.path, expectedPath)
    }

    func testClassifiesItemEventsAndRecoveryFlags() {
        let itemEvent = FileSystemChangeEvent(
            path: "/tmp/报告.md",
            flags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemModified
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagItemIsFile
            )
        )
        let recoveryEvent = FileSystemChangeEvent(
            path: "/tmp",
            flags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagKernelDropped
            )
        )

        XCTAssertTrue(itemEvent.kinds.contains(.created))
        XCTAssertTrue(itemEvent.kinds.contains(.modified))
        XCTAssertTrue(itemEvent.kinds.contains(.renamed))
        XCTAssertFalse(itemEvent.isDirectory)
        XCTAssertFalse(itemEvent.requiresFullRescan)
        XCTAssertTrue(recoveryEvent.requiresFullRescan)
    }

    func testRealFSEventsMonitorReportsCreatedFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let createdURL = root.appendingPathComponent("新增文件.txt")
        let probe = FileEventProbe()
        let monitor = FileSystemChangeMonitor(latency: 0.05)
        monitor.update(
            sources: [MonitoredSource(sourceID: sourceID, rootPath: root.path)]
        ) { reportedSourceID, events in
            Task {
                await probe.record(sourceID: reportedSourceID, events: events)
            }
        }
        defer { monitor.stopAll() }
        try await Task.sleep(for: .milliseconds(200))

        try Data("created".utf8).write(to: createdURL)

        var didObserveCreatedFile = false
        for _ in 0..<50 {
            if await probe.containsCreatedFile(sourceID: sourceID, path: createdURL.path) {
                didObserveCreatedFile = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(didObserveCreatedFile)
    }

    func testRealFSEventsMonitorReportsMoveOutsideWatchedRoot() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let watchedRoot = container.appendingPathComponent("监听", isDirectory: true)
        let outsideRoot = container.appendingPathComponent("外部", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let sourceURL = watchedRoot.appendingPathComponent("移出.txt")
        let destinationURL = outsideRoot.appendingPathComponent("移出.txt")
        try Data("move".utf8).write(to: sourceURL)
        let sourceID = UUID()
        let probe = FileEventProbe()
        let monitor = FileSystemChangeMonitor(latency: 0.05)
        monitor.update(
            sources: [MonitoredSource(sourceID: sourceID, rootPath: watchedRoot.path)]
        ) { reportedSourceID, events in
            Task {
                await probe.record(sourceID: reportedSourceID, events: events)
            }
        }
        defer { monitor.stopAll() }
        try await Task.sleep(for: .milliseconds(200))

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let canonicalSourcePath = watchedRoot.resolvingSymlinksInPath()
            .appendingPathComponent(sourceURL.lastPathComponent)
            .standardizedFileURL.path
        var didObserveMoveOut = false
        for _ in 0..<50 {
            if await probe.containsPath(sourceID: sourceID, path: canonicalSourcePath) {
                didObserveMoveOut = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reportedPaths = await probe.paths(sourceID: sourceID)
        // FSEvents does not guarantee a rename/removal flag for a move across
        // the watched-root boundary. The production reconciler handles any
        // event for this now-missing path, so path delivery is the contract.
        XCTAssertTrue(didObserveMoveOut, "收到的路径：\(reportedPaths)")
        XCTAssertTrue(
            reportedPaths.contains(canonicalSourcePath),
            "收到的路径：\(reportedPaths)"
        )
    }
}

final class TextExtractionServiceTests: XCTestCase {
    func testExtractorReadsSupportedTextAndLimitsStoredCharacters() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("部署说明.md")
        try Data("服务器部署流程与回滚方案".utf8).write(to: fileURL)

        let extractor = TextExtractionService(maxFileSize: 1_024, maxCharacterCount: 6)
        let text = extractor.extractText(from: fileURL)

        XCTAssertEqual(text, "服务器部署流")
    }

    func testExtractorSkipsUnsupportedAndOversizedFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("image.png")
        let oversizedURL = root.appendingPathComponent("large.txt")
        try Data([0, 1, 2, 3]).write(to: imageURL)
        try Data(repeating: 65, count: 17).write(to: oversizedURL)

        let extractor = TextExtractionService(maxFileSize: 16, maxCharacterCount: 100)
        let unsupportedText = extractor.extractText(from: imageURL)
        let oversizedText = extractor.extractText(from: oversizedURL)

        XCTAssertNil(unsupportedText)
        XCTAssertNil(oversizedText)
    }

    func testExtractorReadsSelectablePDFText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("部署手册.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(
            CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        )
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "PDF deployment guide").draw(at: CGPoint(x: 30, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try data.write(to: pdfURL)

        let text = TextExtractionService().extractText(from: pdfURL)

        XCTAssertTrue(text?.contains("PDF deployment guide") == true)
    }
}

final class FileOperationServiceTests: XCTestCase {
    @MainActor
    func testServicesPasteboardReadsDeclaredFileURLType() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("service.txt")
        try Data("service".utf8).write(to: fileURL)
        let pasteboard = NSPasteboard(name: .init("XunJianServicesTest"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        XCTAssertEqual(XunJianAppDelegate.fileURLs(from: pasteboard), [fileURL])
    }

    func testRenameAndMoveOperateOnRealTemporaryFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("原文件.txt")
        let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
        try Data("content".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let service = FileOperationService()
        let renamed = try await service.rename(fileAt: source, to: "新文件.txt")
        let moved = try await service.move(
            fileAt: renamed,
            to: destinationDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "content")
    }

    func testRenameRejectsExistingDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let existing = root.appendingPathComponent("existing.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)

        do {
            _ = try await FileOperationService().rename(fileAt: source, to: "existing.txt")
            XCTFail("重名冲突必须失败")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .destinationExists("existing.txt"))
        }

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
    }

    func testFileIdentityRejectsReplacementAtTheSamePath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("same-path.txt")
        try Data("original".utf8).write(to: url)

        let service = FileOperationService()
        let identity = try await service.identity(of: url)
        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)

        do {
            try await service.requireIdentity(identity, at: url)
            XCTFail("同路径替代文件不得通过撤销身份复验")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .fileIdentityChanged)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
    }
}

final class FileIndexDatabaseTests: XCTestCase {
    func testSearchPageReportsTotalAndCanLoadEveryMatch() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "分页搜索",
            path: container.path,
            bookmark: Data([9, 8, 7])
        )
        let visibleFiles = (0..<3).map { index in
            IndexedFile(
                id: "visible-\(index)", sourceID: source.id,
                name: "匹配文件-\(index).txt",
                path: container.appendingPathComponent("匹配文件-\(index).txt").path,
                fileExtension: "txt", kind: .document, size: 1,
                createdAt: nil, modifiedAt: nil, indexedAt: Date(),
                textContent: "分页命中"
            )
        }
        let hiddenFile = IndexedFile(
            id: "hidden", sourceID: source.id, name: ".隐藏.txt",
            path: container.appendingPathComponent(".隐藏.txt").path,
            fileExtension: "txt", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(),
            textContent: "分页命中"
        )
        try await database.replaceFiles(for: source.id, with: visibleFiles + [hiddenFile])

        let firstPage = try await database.searchFilesPage(
            matching: "分页命中",
            limit: 2,
            includesHiddenFiles: false
        )
        let completePage = try await database.searchFilesPage(
            matching: "分页命中",
            limit: 10,
            includesHiddenFiles: false
        )
        let pageIncludingHidden = try await database.searchFilesPage(
            matching: "分页命中",
            limit: 10,
            includesHiddenFiles: true
        )

        XCTAssertEqual(firstPage.files.count, 2)
        XCTAssertEqual(firstPage.totalCount, 3)
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(completePage.files.count, 3)
        XCTAssertFalse(completePage.hasMore)
        XCTAssertEqual(pageIncludingHidden.totalCount, 4)
    }

    func testTextContentIsLoadedOnlyOnDemand() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "正文门禁",
            path: container.path,
            bookmark: Data([1, 2, 3])
        )
        let file = IndexedFile(
            id: "on-demand-text",
            sourceID: source.id,
            name: "正文.md",
            path: container.appendingPathComponent("正文.md").path,
            fileExtension: "md",
            kind: .document,
            size: 12,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(),
            textContent: "只在 AI 请求时读取"
        )
        try await database.replaceFiles(for: source.id, with: [file])

        let listed = try await database.fetchFiles()
        XCTAssertNil(try XCTUnwrap(listed.first).textContent)
        let textContent = try await database.fetchTextContent(forFileID: file.id)
        let missingContent = try await database.fetchTextContent(forFileID: "missing")
        XCTAssertEqual(textContent, "只在 AI 请求时读取")
        XCTAssertNil(missingContent)
    }

    func testBatchCategoryChangesApplyAndUndoAtomically() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "批量分类",
            path: container.path,
            bookmark: Data([4, 5, 6])
        )
        let files = ["first", "second"].map { id in
            IndexedFile(
                id: id,
                sourceID: source.id,
                name: "\(id).txt",
                path: container.appendingPathComponent("\(id).txt").path,
                fileExtension: "txt",
                kind: .document,
                size: 1,
                createdAt: nil,
                modifiedAt: nil,
                indexedAt: Date()
            )
        }
        try await database.replaceFiles(for: source.id, with: files)
        let category = try await database.createCategory(name: "待办", symbolName: "checkmark")
        let changes = files.map {
            AIClassificationChange(fileID: $0.id, categoryID: category.id)
        }

        try await database.setCategories(changes, assigned: true)
        let assignedLinks = try await database.fetchFileCategoryLinks()
        XCTAssertEqual(
            assignedLinks,
            ["first": [category.id], "second": [category.id]]
        )

        try await database.setCategories(changes, assigned: false)
        let unassignedLinks = try await database.fetchFileCategoryLinks()
        XCTAssertTrue(unassignedLinks.isEmpty)
    }

    func testReauthorizationToMovedFolderAndSourceRemovalKeepIndexConsistent() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let original = container.appendingPathComponent("原位置", isDirectory: true)
        let moved = container.appendingPathComponent("新位置", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let fileURL = original.appendingPathComponent("重新授权验收.txt")
        try Data("重新授权索引内容".utf8).write(to: fileURL)

        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let manager = BookmarkManager()
        let source = try await database.upsertSource(
            displayName: original.lastPathComponent,
            path: original.standardizedFileURL.path,
            bookmark: try manager.createBookmark(for: original)
        )
        let originalFiles = try await FileScanner().scan(sourceID: source.id, rootURL: original)
        let file = try XCTUnwrap(originalFiles.first)
        try await database.replaceFiles(for: source.id, with: originalFiles)
        let category = try await database.createCategory(name: "重新授权分类", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: file.id)

        try FileManager.default.moveItem(at: original, to: moved)
        try await database.updateBookmark(
            for: source.id,
            bookmark: try manager.createBookmark(for: moved),
            path: moved.standardizedFileURL.path
        )
        let movedFiles = try await FileScanner().scan(sourceID: source.id, rootURL: moved)
        try await database.replaceFiles(for: source.id, with: movedFiles)

        let refreshedSources = try await database.fetchSources()
        let refreshedFiles = try await database.fetchFiles()
        let refreshedCategoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
        let refreshedSearchResults = try await database.searchFiles(
            matching: "重新授权索引内容"
        )
        let refreshedSource = try XCTUnwrap(refreshedSources.first)
        let refreshedFile = try XCTUnwrap(refreshedFiles.first)
        XCTAssertEqual(refreshedSource.id, source.id)
        XCTAssertEqual(refreshedSource.path, moved.standardizedFileURL.path)
        XCTAssertEqual(refreshedFile.id, file.id)
        XCTAssertEqual(
            URL(fileURLWithPath: refreshedFile.path).resolvingSymlinksInPath().path,
            moved.appendingPathComponent(file.name).resolvingSymlinksInPath().path
        )
        XCTAssertEqual(refreshedCategoryIDs, [category.id])
        XCTAssertEqual(refreshedSearchResults.map(\.id), [file.id])

        try await database.deleteSource(source.id)

        let remainingSources = try await database.fetchSources()
        let remainingFiles = try await database.fetchFiles()
        let remainingSearchResults = try await database.searchFiles(
            matching: "重新授权索引内容"
        )
        let remainingCategoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
        let remainingCategories = try await database.fetchCategories()
        XCTAssertTrue(remainingSources.isEmpty)
        XCTAssertTrue(remainingFiles.isEmpty)
        XCTAssertTrue(remainingSearchResults.isEmpty)
        XCTAssertTrue(remainingCategoryIDs.isEmpty)
        XCTAssertTrue(remainingCategories.contains(where: { $0.id == category.id }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(file.name).path))
    }

    func testHundredThousandFileAndAllFilesInteractionGateWhenEnabled() async throws {
        #if !XUNJIAN_LARGE_INDEX_GATE
        throw XCTSkip("仅在发布验收时运行 10 万文件与页面交互门禁")
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("index.sqlite3")
        let database = try FileIndexDatabase(databaseURL: databaseURL)
        let source = try await database.upsertSource(
            displayName: "10 万文件交互门禁",
            path: "/tmp/XunJian-Hundred-Thousand",
            bookmark: Data([100, 0, 0])
        )
        let indexedAt = Date(timeIntervalSince1970: 1_786_464_000)
        let kinds = FileKind.allCases
        var files: [IndexedFile] = []
        files.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let reverseIndex = 99_999 - index
            let name = String(format: "文件-%06d.txt", reverseIndex)
            let path = String(
                format: "/tmp/XunJian-Hundred-Thousand/目录-%03d/%@",
                index % 500,
                name
            )
            let file = IndexedFile(
                id: "hundred-thousand-\(index)",
                sourceID: source.id,
                name: name,
                path: path,
                fileExtension: "txt",
                kind: kinds[index % kinds.count],
                size: Int64(100_000 - index),
                createdAt: indexedAt.addingTimeInterval(TimeInterval(index % 1_000)),
                modifiedAt: indexedAt.addingTimeInterval(TimeInterval(index)),
                indexedAt: indexedAt,
                textContent: index == 84_731 ? "十万门禁唯一标记" : nil
            )
            files.append(file)
        }

        let writeStart = ContinuousClock.now
        try await database.replaceFiles(for: source.id, with: files)
        let writeDuration = ContinuousClock.now - writeStart

        let reloadStart = ContinuousClock.now
        let reloadedFiles = try await database.fetchFiles()
        let reloadDuration = ContinuousClock.now - reloadStart

        let searchStart = ContinuousClock.now
        let matches = try await database.searchFiles(matching: "十万门禁唯一标记")
        let searchDuration = ContinuousClock.now - searchStart

        let interactionStart = ContinuousClock.now
        var stepStart = ContinuousClock.now
        let documents = reloadedFiles.filter { $0.kind == .document }
        let filterDuration = ContinuousClock.now - stepStart
        stepStart = ContinuousClock.now
        let nameAscending = FileSortOrder.name.sorted(reloadedFiles, ascending: true)
        let nameSortDuration = ContinuousClock.now - stepStart
        stepStart = ContinuousClock.now
        let modifiedDescending = FileSortOrder.modifiedAt.sorted(reloadedFiles, ascending: false)
        let modifiedSortDuration = ContinuousClock.now - stepStart
        stepStart = ContinuousClock.now
        let createdAscending = FileSortOrder.createdAt.sorted(reloadedFiles, ascending: true)
        let createdSortDuration = ContinuousClock.now - stepStart
        stepStart = ContinuousClock.now
        let sizeDescending = FileSortOrder.size.sorted(reloadedFiles, ascending: false)
        let sizeSortDuration = ContinuousClock.now - stepStart
        stepStart = ContinuousClock.now
        let kindAscending = FileSortOrder.kind.sorted(reloadedFiles, ascending: true)
        let kindSortDuration = ContinuousClock.now - stepStart
        let interactionDuration = ContinuousClock.now - interactionStart

        print(
            "XUNJIAN_100K_METRICS "
                + "write=\(writeDuration) reload=\(reloadDuration) "
                + "search=\(searchDuration) interactions=\(interactionDuration) "
                + "filter=\(filterDuration) name=\(nameSortDuration) "
                + "modified=\(modifiedSortDuration) created=\(createdSortDuration) "
                + "size=\(sizeSortDuration) kind=\(kindSortDuration)"
        )

        XCTAssertEqual(reloadedFiles.count, 100_000)
        XCTAssertEqual(matches.map(\.id), ["hundred-thousand-84731"])
        XCTAssertEqual(documents.count, 14_286)
        XCTAssertEqual(nameAscending.first?.name, "文件-000000.txt")
        XCTAssertEqual(modifiedDescending.first?.id, "hundred-thousand-99999")
        XCTAssertEqual(createdAscending.first?.createdAt, indexedAt)
        XCTAssertEqual(sizeDescending.first?.size, 100_000)
        XCTAssertEqual(kindAscending.count, 100_000)
        XCTAssertLessThan(writeDuration, .seconds(60), "10 万文件批量索引超过 60 秒：\(writeDuration)")
        XCTAssertLessThan(reloadDuration, .seconds(10), "10 万文件恢复超过 10 秒：\(reloadDuration)")
        XCTAssertLessThan(searchDuration, .seconds(1), "10 万文件 FTS 搜索超过 1 秒：\(searchDuration)")
        for (operation, duration) in [
            ("类型筛选", filterDuration),
            ("名称排序", nameSortDuration),
            ("修改时间排序", modifiedSortDuration),
            ("创建时间排序", createdSortDuration),
            ("大小排序", sizeSortDuration),
            ("类型排序", kindSortDuration)
        ] {
            XCTAssertLessThan(duration, .seconds(1), "\(operation) 超过 1 秒：\(duration)")
        }
        XCTAssertLessThan(
            interactionDuration,
            .seconds(10),
            "所有文件页面的筛选和五种排序超过 10 秒：\(interactionDuration)"
        )

        let databaseSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber
        ).int64Value
        XCTAssertLessThan(databaseSize, 512 * 1_024 * 1_024, "10 万文件索引数据库超过 512 MiB")
        #endif
    }

    func testFiftyThousandFilePerformanceGateWhenEnabled() async throws {
        #if !XUNJIAN_LARGE_INDEX_GATE
        throw XCTSkip("仅在发布验收时运行 5 万文件性能门禁")
        #else

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("index.sqlite3")
        let database = try FileIndexDatabase(databaseURL: databaseURL)
        let source = try await database.upsertSource(
            displayName: "5 万文件性能门禁",
            path: "/tmp/XunJian-Large-Index",
            bookmark: Data([50, 0, 0])
        )
        let indexedAt = Date(timeIntervalSince1970: 1_786_464_000)
        let files = (0..<50_000).map { index in
            let marker = index == 37_421 ? "唯一检索标记" : ""
            return IndexedFile(
                id: "large-index-\(index)",
                sourceID: source.id,
                name: String(format: "文件-%05d.txt", index),
                path: String(format: "/tmp/XunJian-Large-Index/目录-%03d/文件-%05d.txt", index % 250, index),
                fileExtension: "txt",
                kind: .document,
                size: Int64(index + 1),
                createdAt: indexedAt,
                modifiedAt: indexedAt.addingTimeInterval(TimeInterval(index)),
                indexedAt: indexedAt,
                textContent: marker
            )
        }

        let writeStart = ContinuousClock.now
        try await database.replaceFiles(for: source.id, with: files)
        let writeDuration = ContinuousClock.now - writeStart

        let reloadStart = ContinuousClock.now
        let reloadedFiles = try await database.fetchFiles()
        let reloadDuration = ContinuousClock.now - reloadStart

        let searchStart = ContinuousClock.now
        let matches = try await database.searchFiles(matching: "唯一检索标记")
        let searchDuration = ContinuousClock.now - searchStart

        XCTAssertEqual(reloadedFiles.count, 50_000)
        XCTAssertEqual(matches.map(\.id), ["large-index-37421"])
        XCTAssertLessThan(writeDuration, .seconds(30), "5 万文件批量索引超过 30 秒：\(writeDuration)")
        XCTAssertLessThan(reloadDuration, .seconds(5), "5 万文件恢复超过 5 秒：\(reloadDuration)")
        XCTAssertLessThan(searchDuration, .seconds(1), "5 万文件 FTS 搜索超过 1 秒：\(searchDuration)")

        let databaseSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber
        ).int64Value
        XCTAssertLessThan(databaseSize, 256 * 1_024 * 1_024, "5 万文件索引数据库超过 256 MiB")
        #endif
    }

    func testSourceAndFilesPersistAcrossDatabaseInstances() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("index.sqlite3")
        let sourceID: UUID

        do {
            let database = try FileIndexDatabase(databaseURL: databaseURL)
            let source = try await database.upsertSource(
                displayName: "测试目录",
                path: "/tmp/测试目录",
                bookmark: Data([1, 2, 3])
            )
            sourceID = source.id

            let file = IndexedFile(
                id: "stable-id",
                sourceID: source.id,
                name: "合同.pdf",
                path: "/tmp/测试目录/合同.pdf",
                fileExtension: "pdf",
                kind: .document,
                size: 42,
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 200),
                indexedAt: Date(timeIntervalSince1970: 300)
            )
            try await database.replaceFiles(for: source.id, with: [file])
        }

        let reopened = try FileIndexDatabase(databaseURL: databaseURL)
        let sources = try await reopened.fetchSources()
        let files = try await reopened.fetchFiles()

        XCTAssertEqual(sources.map(\.id), [sourceID])
        XCTAssertEqual(files.map(\.name), ["合同.pdf"])
        XCTAssertEqual(files.first?.kind, .document)

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        try await reopened.replaceFiles(for: sourceID, with: [])
        let remainingFiles = try await reopened.fetchFiles()
        XCTAssertTrue(remainingFiles.isEmpty)
    }

    func testCategoriesPersistAndSurviveFileMetadataRefresh() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "分类测试",
            path: "/tmp/分类测试",
            bookmark: Data([4, 5, 6])
        )
        let file = IndexedFile(
            id: "category-stable-id",
            sourceID: source.id,
            name: "报价单.pdf",
            path: "/tmp/分类测试/报价单.pdf",
            fileExtension: "pdf",
            kind: .document,
            size: 100,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 100),
            indexedAt: Date(timeIntervalSince1970: 100)
        )
        try await database.replaceFiles(for: source.id, with: [file])

        let category = try await database.createCategory(name: "上海项目", symbolName: "building.2")
        try await database.setCategory(category.id, assigned: true, toFile: file.id)
        try await database.replaceFiles(
            for: source.id,
            with: [
                IndexedFile(
                    id: file.id,
                    sourceID: source.id,
                    name: file.name,
                    path: "/tmp/分类测试/新位置/报价单.pdf",
                    fileExtension: file.fileExtension,
                    kind: file.kind,
                    size: file.size,
                    createdAt: file.createdAt,
                    modifiedAt: Date(timeIntervalSince1970: 200),
                    indexedAt: Date(timeIntervalSince1970: 200)
                )
            ]
        )

        let persistedCategories = try await database.fetchCategories()
        XCTAssertTrue(persistedCategories.contains(where: { $0.id == category.id }))
        let assignedCategoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
        XCTAssertEqual(assignedCategoryIDs, [category.id])

        try await database.deleteCategory(category.id)
        let categoryIDsAfterDelete = try await database.fetchCategoryIDs(forFile: file.id)
        let filesAfterDelete = try await database.fetchFiles()
        XCTAssertTrue(categoryIDsAfterDelete.isEmpty)
        XCTAssertEqual(filesAfterDelete.map(\.id), [file.id])
    }

    func testFTSSearchFindsContentMetadataAndCategoryThenRefreshesContent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "搜索测试",
            path: "/tmp/搜索测试",
            bookmark: Data([7, 8, 9])
        )
        let deployment = IndexedFile(
            id: "deployment-id",
            sourceID: source.id,
            name: "上线手册.md",
            path: "/tmp/搜索测试/运维/上线手册.md",
            fileExtension: "md",
            kind: .document,
            size: 200,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 300),
            indexedAt: Date(timeIntervalSince1970: 400),
            textContent: "服务器部署流程 Docker VPS"
        )
        let budget = IndexedFile(
            id: "budget-id",
            sourceID: source.id,
            name: "年度预算.csv",
            path: "/tmp/搜索测试/财务/年度预算.csv",
            fileExtension: "csv",
            kind: .document,
            size: 100,
            createdAt: Date(timeIntervalSince1970: 200),
            modifiedAt: Date(timeIntervalSince1970: 200),
            indexedAt: Date(timeIntervalSince1970: 400),
            textContent: "采购预算审批"
        )
        try await database.replaceFiles(for: source.id, with: [deployment, budget])
        let category = try await database.createCategory(name: "上海项目", symbolName: "building.2")
        try await database.setCategory(category.id, assigned: true, toFile: budget.id)

        let contentMatches = try await database.searchFiles(matching: "部署")
        let pathMatches = try await database.searchFiles(matching: "运维")
        let categoryMatches = try await database.searchFiles(matching: "上海项目")
        XCTAssertEqual(contentMatches.map(\.id), [deployment.id])
        XCTAssertEqual(pathMatches.map(\.id), [deployment.id])
        XCTAssertEqual(categoryMatches.map(\.id), [budget.id])
        _ = try await database.searchFiles(matching: "\" OR *")

        let refreshed = IndexedFile(
            id: deployment.id,
            sourceID: source.id,
            name: deployment.name,
            path: deployment.path,
            fileExtension: deployment.fileExtension,
            kind: deployment.kind,
            size: deployment.size,
            createdAt: deployment.createdAt,
            modifiedAt: Date(timeIntervalSince1970: 500),
            indexedAt: Date(timeIntervalSince1970: 500),
            textContent: "回滚检查清单"
        )
        try await database.replaceFiles(for: source.id, with: [refreshed, budget])

        let staleMatches = try await database.searchFiles(matching: "部署")
        let refreshedMatches = try await database.searchFiles(matching: "回滚")
        let persistedCategoryMatches = try await database.searchFiles(matching: "上海项目")
        XCTAssertTrue(staleMatches.isEmpty)
        XCTAssertEqual(refreshedMatches.map(\.id), [deployment.id])
        XCTAssertEqual(persistedCategoryMatches.map(\.id), [budget.id])
    }

    func testIncrementalReconciliationPreservesUnrelatedFilesIdentityAndCategory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "增量测试",
            path: "/tmp/增量测试",
            bookmark: Data([10, 11, 12])
        )
        let moving = IndexedFile(
            id: "resource-stable-id",
            sourceID: source.id,
            name: "旧名称.md",
            path: "/tmp/增量测试/旧名称.md",
            fileExtension: "md",
            kind: .document,
            size: 10,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 100),
            indexedAt: Date(timeIntervalSince1970: 100),
            textContent: "旧正文"
        )
        let unrelated = IndexedFile(
            id: "unrelated-id",
            sourceID: source.id,
            name: "不相关.txt",
            path: "/tmp/增量测试/不相关.txt",
            fileExtension: "txt",
            kind: .document,
            size: 20,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(timeIntervalSince1970: 100),
            textContent: "保留"
        )
        try await database.replaceFiles(for: source.id, with: [moving, unrelated])
        let category = try await database.createCategory(name: "持续分类", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: moving.id)
        let moved = IndexedFile(
            id: moving.id,
            sourceID: source.id,
            name: "新名称.md",
            path: "/tmp/增量测试/子目录/新名称.md",
            fileExtension: "md",
            kind: .document,
            size: 12,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 200),
            indexedAt: Date(timeIntervalSince1970: 200),
            textContent: "新正文"
        )

        try await database.reconcileFiles(
            for: source.id,
            scopes: [
                FileIndexScope(path: moving.path, includesDescendants: false),
                FileIndexScope(path: moved.path, includesDescendants: false)
            ],
            with: [moved]
        )

        let filesAfterMove = try await database.fetchFiles()
        let categoryIDsAfterMove = try await database.fetchCategoryIDs(forFile: moving.id)
        let staleMatches = try await database.searchFiles(matching: "旧正文")
        let refreshedMatches = try await database.searchFiles(matching: "新正文")
        XCTAssertEqual(Set(filesAfterMove.map(\.id)), [moving.id, unrelated.id])
        XCTAssertEqual(filesAfterMove.first(where: { $0.id == moving.id })?.path, moved.path)
        XCTAssertEqual(categoryIDsAfterMove, [category.id])
        XCTAssertTrue(staleMatches.isEmpty)
        XCTAssertEqual(refreshedMatches.map(\.id), [moving.id])

        try await database.reconcileFiles(
            for: source.id,
            scopes: [FileIndexScope(path: moved.path, includesDescendants: false)],
            with: []
        )
        let filesAfterDelete = try await database.fetchFiles()
        XCTAssertEqual(filesAfterDelete.map(\.id), [unrelated.id])
    }

    func testCrossSourceMoveReconciliationTransfersCategoriesAndSearchEntryAtomically() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "来源",
            path: "/tmp/来源",
            bookmark: Data([1])
        )
        let destination = try await database.upsertSource(
            displayName: "目标",
            path: "/tmp/目标",
            bookmark: Data([2])
        )
        let original = IndexedFile(
            id: "source-file-id",
            sourceID: source.id,
            name: "合同.txt",
            path: "/tmp/来源/合同.txt",
            fileExtension: "txt",
            kind: .document,
            size: 10,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(timeIntervalSince1970: 100),
            textContent: "旧位置内容"
        )
        try await database.replaceFiles(for: source.id, with: [original])
        let category = try await database.createCategory(name: "必须保留", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: original.id)

        let moved = IndexedFile(
            id: "destination-file-id",
            sourceID: destination.id,
            name: "合同.txt",
            path: "/tmp/目标/合同.txt",
            fileExtension: "txt",
            kind: .document,
            size: 10,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(timeIntervalSince1970: 200),
            textContent: "新位置内容"
        )
        let categorySnapshot = try await database.fetchCategoryIDs(forFile: original.id)
        try await database.reconcileMovedFile(
            fromFile: original.id,
            to: moved,
            preserving: categorySnapshot
        )

        let persistedFiles = try await database.fetchFiles()
        let links = try await database.fetchFileCategoryLinks()
        let categoryMatches = try await database.searchFiles(matching: "必须保留")
        let staleMatches = try await database.searchFiles(matching: "旧位置内容")
        let movedMatches = try await database.searchFiles(matching: "新位置内容")
        XCTAssertEqual(persistedFiles.map(\.id), [moved.id])
        XCTAssertNil(links[original.id])
        XCTAssertEqual(links[moved.id], [category.id])
        XCTAssertEqual(categoryMatches.map(\.id), [moved.id])
        XCTAssertTrue(staleMatches.isEmpty)
        XCTAssertEqual(movedMatches.map(\.id), [moved.id])
    }

    func testCrossSourceMoveReconciliationFailureKeepsOriginalCategoryRelationship() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "来源",
            path: "/tmp/来源",
            bookmark: Data([1])
        )
        let original = IndexedFile(
            id: "source-file-id",
            sourceID: source.id,
            name: "合同.txt",
            path: "/tmp/来源/合同.txt",
            fileExtension: "txt",
            kind: .document,
            size: 10,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(timeIntervalSince1970: 100)
        )
        try await database.replaceFiles(for: source.id, with: [original])
        let category = try await database.createCategory(name: "必须保留", symbolName: "folder")
        try await database.setCategory(category.id, assigned: true, toFile: original.id)
        let invalidDestination = IndexedFile(
            id: "destination-file-id",
            sourceID: UUID(),
            name: "合同.txt",
            path: "/tmp/未授权/合同.txt",
            fileExtension: "txt",
            kind: .document,
            size: 10,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date(timeIntervalSince1970: 200)
        )

        do {
            try await database.reconcileMovedFile(
                fromFile: original.id,
                to: invalidDestination,
                preserving: [category.id]
            )
            XCTFail("A destination without an indexed source must fail")
        } catch {
            // Expected: the foreign-key failure rolls back every index mutation.
        }

        let persistedFiles = try await database.fetchFiles()
        let links = try await database.fetchFileCategoryLinks()
        XCTAssertEqual(persistedFiles.map(\.id), [original.id])
        XCTAssertEqual(links[original.id], [category.id])
        XCTAssertNil(links[invalidDestination.id])
    }

    func testMissingFileConsistencyCheckRemovesOnlyMissingRows() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("监听", isDirectory: true)
        let outside = container.appendingPathComponent("外部", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keptURL = root.appendingPathComponent("保留.txt")
        let removedURL = root.appendingPathComponent("移出.txt")
        try Data("kept".utf8).write(to: keptURL)
        try Data("removed".utf8).write(to: removedURL)
        let database = try FileIndexDatabase(
            databaseURL: container.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "监听",
            path: root.path,
            bookmark: Data([13, 14, 15])
        )
        let files = [
            IndexedFile(
                id: "kept-id", sourceID: source.id, name: "保留.txt", path: keptURL.path,
                fileExtension: "txt", kind: .document, size: 4, createdAt: nil,
                modifiedAt: nil, indexedAt: Date(), textContent: "kept"
            ),
            IndexedFile(
                id: "removed-id", sourceID: source.id, name: "移出.txt", path: removedURL.path,
                fileExtension: "txt", kind: .document, size: 7, createdAt: nil,
                modifiedAt: nil, indexedAt: Date(), textContent: "removed"
            )
        ]
        try await database.replaceFiles(for: source.id, with: files)
        try FileManager.default.moveItem(
            at: removedURL,
            to: outside.appendingPathComponent(removedURL.lastPathComponent)
        )

        let removedCount = try await database.removeMissingFiles(for: source.id)
        let remainingFiles = try await database.fetchFiles()
        let staleSearch = try await database.searchFiles(matching: "removed")

        XCTAssertEqual(removedCount, 1)
        XCTAssertEqual(remainingFiles.map(\.id), ["kept-id"])
        XCTAssertTrue(staleSearch.isEmpty)
    }
}

final class FileSortOrderTests: XCTestCase {
    func testSortOrdersCoverNameDatesSizeAndType() {
        let sourceID = UUID()
        let files = [
            IndexedFile(
                id: "b", sourceID: sourceID, name: "B.txt", path: "/B.txt",
                fileExtension: "txt", kind: .document, size: 20,
                createdAt: Date(timeIntervalSince1970: 200),
                modifiedAt: Date(timeIntervalSince1970: 100),
                indexedAt: Date(timeIntervalSince1970: 300)
            ),
            IndexedFile(
                id: "a", sourceID: sourceID, name: "A.swift", path: "/A.swift",
                fileExtension: "swift", kind: .code, size: 10,
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 200),
                indexedAt: Date(timeIntervalSince1970: 300)
            )
        ]

        XCTAssertEqual(FileSortOrder.name.sorted(files, ascending: true).map(\.id), ["a", "b"])
        XCTAssertEqual(FileSortOrder.modifiedAt.sorted(files, ascending: true).map(\.id), ["b", "a"])
        XCTAssertEqual(FileSortOrder.createdAt.sorted(files, ascending: true).map(\.id), ["a", "b"])
        XCTAssertEqual(FileSortOrder.size.sorted(files, ascending: true).map(\.id), ["a", "b"])
        XCTAssertEqual(FileSortOrder.kind.sorted(files, ascending: true).map(\.id), ["a", "b"])
    }
}

final class PhaseSixAITests: XCTestCase {
    func testLocalCredentialStorePersistsAndRecreatesMissingFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-CredentialStore-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL
            .appendingPathComponent("Credentials", isDirectory: true)
            .appendingPathComponent("ai-credentials.plist")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = LocalCredentialStore(fileURL: fileURL)
        XCTAssertNil(try store.read(account: AIProviderKind.deepSeek.rawValue))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(posixPermissions(at: fileURL), 0o600)
        XCTAssertEqual(posixPermissions(at: fileURL.deletingLastPathComponent()), 0o700)

        try store.save("test-secret", account: AIProviderKind.deepSeek.rawValue)
        let relaunchedStore = LocalCredentialStore(fileURL: fileURL)
        XCTAssertEqual(
            try relaunchedStore.read(account: AIProviderKind.deepSeek.rawValue),
            "test-secret"
        )

        try FileManager.default.removeItem(at: fileURL)
        XCTAssertNil(try relaunchedStore.read(account: AIProviderKind.deepSeek.rawValue))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(posixPermissions(at: fileURL), 0o600)
    }

    func testLocalCredentialStoreDeletesOnlySelectedProviderKey() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-CredentialStore-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL
            .appendingPathComponent("Credentials", isDirectory: true)
            .appendingPathComponent("ai-credentials.plist")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = LocalCredentialStore(fileURL: fileURL)

        try store.save("deepseek-secret", account: AIProviderKind.deepSeek.rawValue)
        try store.save("qwen-secret", account: AIProviderKind.qwen.rawValue)
        try store.delete(account: AIProviderKind.deepSeek.rawValue)

        XCTAssertNil(try store.read(account: AIProviderKind.deepSeek.rawValue))
        XCTAssertEqual(try store.read(account: AIProviderKind.qwen.rawValue), "qwen-secret")
    }

    func testDefaultCredentialFileLivesOutsideApplicationBundle() {
        let fileURL = LocalCredentialStore().fileURL

        XCTAssertTrue(fileURL.path.hasSuffix("/XunJian/Credentials/ai-credentials.plist"))
        XCTAssertFalse(
            fileURL.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/")
        )
    }

    func testLocalCredentialStoreRejectsCredentialFileSymlink() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-CredentialStore-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Credentials", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("ai-credentials.plist")
        let sentinelURL = rootURL.appendingPathComponent("sentinel")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("do-not-touch".utf8).write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: sentinelURL
        )

        let store = LocalCredentialStore(fileURL: fileURL)
        XCTAssertThrowsError(try store.read(account: AIProviderKind.deepSeek.rawValue)) { error in
            guard let storeError = error as? LocalCredentialStoreError,
                  case .unavailable = storeError else {
                return XCTFail("Expected LocalCredentialStoreError.unavailable, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("do-not-touch".utf8))
    }

    func testLocalCredentialStorePreservesCorruptFileWhenReadSaveAndDeleteFail() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-CredentialCorruption-\(UUID().uuidString)")
        let directoryURL = rootURL.appendingPathComponent("Credentials", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("ai-credentials.plist")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let originalData = Data("corrupt-credential-file".utf8)
        try originalData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        let store = LocalCredentialStore(fileURL: fileURL)
        XCTAssertThrowsError(try store.read(account: AIProviderKind.codex.rawValue)) { error in
            guard let storeError = error as? LocalCredentialStoreError,
                  case .invalidData = storeError else {
                return XCTFail("Expected invalidData, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.save("replacement", account: AIProviderKind.codex.rawValue))
        XCTAssertThrowsError(try store.delete(account: AIProviderKind.codex.rawValue))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    private func posixPermissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testOfficialProviderDefaultsUseCurrentDocumentedModels() {
        XCTAssertEqual(AIProviderKind.codex.defaultModel, "gpt-5.3-codex")
        XCTAssertEqual(AIProviderKind.grok.defaultModel, "grok-4.5")
        XCTAssertEqual(AIProviderKind.deepSeek.defaultModel, "deepseek-v4-flash")
        XCTAssertEqual(AIProviderKind.qwen.defaultModel, "qwen3.7-plus")
    }

    func testSearchClassifierKeepsKeywordsLocalAndDetectsNaturalLanguage() {
        XCTAssertFalse(AISearchQueryClassifier.shouldUseAI("logo"))
        XCTAssertFalse(AISearchQueryClassifier.shouldUseAI("服务器 部署"))
        XCTAssertTrue(AISearchQueryClassifier.shouldUseAI("找一下上个月关于服务器部署的文档"))
        XCTAssertTrue(AISearchQueryClassifier.shouldUseAI("找我去年保存的合同"))
    }

    func testOpenAICompatibleProviderBuildsAuthenticatedChatCompletionRequest() async throws {
        let transport = RecordingAITransport(
            data: Data(#"{"choices":[{"message":{"content":"完成"}}]}"#.utf8),
            statusCode: 200
        )
        let provider = OpenAICompatibleAIProvider(
            kind: .deepSeek,
            apiKey: "test-secret",
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-v4-flash",
            transport: transport
        )

        let response = try await provider.chat([
            AIMessage(role: .user, content: "请简短回答")
        ])
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(response, "完成")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(payload["model"] as? String, "deepseek-v4-flash")
    }

    func testOpenAICompatibleProviderStreamsSSEContent() async throws {
        let transport = StreamingAITransport(lines: [
            #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"好"}}]}"#,
            "data: [DONE]"
        ])
        let provider = OpenAICompatibleAIProvider(
            kind: .deepSeek,
            apiKey: "test-secret",
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-v4-flash",
            transport: transport
        )

        let stream = try await provider.chatStream([
            AIMessage(role: .user, content: "问候")
        ])
        var response = ""
        for try await chunk in stream { response += chunk }

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(response, "你好")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testAIStreamParserIgnoresMetadataAndRejectsMalformedJSON() throws {
        XCTAssertNil(try AIStreamParser.event(from: "event: message"))
        XCTAssertNil(try AIStreamParser.event(from: ": keep-alive"))
        XCTAssertEqual(try AIStreamParser.event(from: "data: [DONE]"), .done)
        XCTAssertThrowsError(try AIStreamParser.event(from: "data: not-json"))
    }

    func testSearchPlanFiltersOnlyLocalFilesByKindAndDate() {
        let sourceID = UUID()
        let files = [
            IndexedFile(
                id: "old-contract", sourceID: sourceID, name: "旧合同.md", path: "/private/旧合同.md",
                fileExtension: "md", kind: .document, size: 10,
                createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 100),
                indexedAt: Date(timeIntervalSince1970: 300), textContent: "合同"
            ),
            IndexedFile(
                id: "new-code", sourceID: sourceID, name: "deploy.swift", path: "/private/deploy.swift",
                fileExtension: "swift", kind: .code, size: 20,
                createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 300),
                indexedAt: Date(timeIntervalSince1970: 300), textContent: "deploy"
            )
        ]
        let plan = AISearchPlan(
            keywords: ["合同"],
            fileKinds: [.document],
            modifiedAfter: Date(timeIntervalSince1970: 50),
            modifiedBefore: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(plan.filter(files).map(\.id), ["old-contract"])
    }

    func testFileContextOmitsPrivatePathAndCapsContent() throws {
        let file = IndexedFile(
            id: "file-id", sourceID: UUID(), name: "合同.md", path: "/Users/test/秘密/合同.md",
            fileExtension: "md", kind: .document, size: 100,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(), textContent: "1234567890"
        )

        let context = try AIFileContext(file: file, maximumCharacterCount: 5)

        XCTAssertTrue(context.promptText.contains("合同.md"))
        XCTAssertTrue(context.promptText.contains("12345"))
        XCTAssertFalse(context.promptText.contains("67890"))
        XCTAssertFalse(context.promptText.contains("/Users/test"))
    }

    func testJSONDecoderAcceptsFencedProviderOutput() throws {
        let decoded = try AIJSON.decode(
            AISearchPlanPayload.self,
            from: "```json\n{\"keywords\":[\"合同\"],\"fileKinds\":[\"document\"]}\n```"
        )

        XCTAssertEqual(decoded.keywords, ["合同"])
        XCTAssertEqual(decoded.fileKinds, ["document"])
    }

    func testAISearchSendsOnlyNaturalLanguageQueryBeforeLocalFiltering() async throws {
        let provider = ScriptedAIProvider(
            response: #"{"keywords":["合同"],"fileKinds":["document"],"modifiedAfter":null,"modifiedBefore":null}"#
        )
        let service = AIService(provider: provider)

        let plan = try await service.searchPlan(
            for: "找我去年保存的合同",
            now: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let messages = await provider.lastMessages()

        XCTAssertEqual(plan.keywords, ["合同"])
        XCTAssertEqual(messages.last?.content, "找我去年保存的合同")
        XCTAssertFalse(messages.map(\.content).joined().contains("/Users/"))
    }

    func testAIExplainAndQuestionUseOnlyCurrentFileContext() async throws {
        let file = IndexedFile(
            id: "contract", sourceID: UUID(), name: "合同.md", path: "/Users/test/秘密/合同.md",
            fileExtension: "md", kind: .document, size: 100,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(),
            textContent: "到期日是 2026 年 12 月 31 日。"
        )
        let explainProvider = ScriptedAIProvider(response: "这是一份合同。")
        let questionProvider = ScriptedAIProvider(response: "2026 年 12 月 31 日。")

        let explanation = try await AIService(provider: explainProvider).explain(file: file)
        let answer = try await AIService(provider: questionProvider)
            .answer(question: "什么时候到期？", about: file)

        XCTAssertEqual(explanation, "这是一份合同。")
        XCTAssertEqual(answer, "2026 年 12 月 31 日。")

        let explainMessages = await explainProvider.lastMessages()
        let questionMessages = await questionProvider.lastMessages()
        let prompts = explainMessages + questionMessages
        let sentText = prompts.map(\.content).joined()
        XCTAssertTrue(sentText.contains("到期日"))
        XCTAssertFalse(sentText.contains("/Users/test"))
    }

    func testAIClassificationMapsOnlyExistingCategoriesAndRequiresLaterConfirmation() async throws {
        let work = FileCategory(id: UUID(), name: "工作", symbolName: "briefcase")
        let file = IndexedFile(
            id: "contract", sourceID: UUID(), name: "合同.md", path: "/private/合同.md",
            fileExtension: "md", kind: .document, size: 100,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(), textContent: nil
        )
        let provider = ScriptedAIProvider(
            response: #"{"suggestions":[{"token":"F1","categoryNames":["工作","不存在"]}]}"#
        )

        let suggestions = try await AIService(provider: provider)
            .classify(files: [file], categories: [work])

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].fileID, file.id)
        XCTAssertEqual(suggestions[0].categoryIDs, [work.id])
        XCTAssertEqual(suggestions[0].categoryNames, ["工作"])
        let messages = await provider.lastMessages()
        XCTAssertFalse(messages.map(\.content).joined().contains("/private"))
    }

    func testAIClassificationRejectsMissingCategoriesBeforeProviderCall() async throws {
        let file = IndexedFile(
            id: "contract", sourceID: UUID(), name: "合同.md", path: "/private/合同.md",
            fileExtension: "md", kind: .document, size: 100,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(), textContent: "正文"
        )
        let provider = ScriptedAIProvider(response: #"{"suggestions":[]}"#)

        do {
            _ = try await AIService(provider: provider).classify(files: [file], categories: [])
            XCTFail("无分类时不得调用 AI")
        } catch let error as AIServiceError {
            guard case .noCategories = error else {
                return XCTFail("预期 noCategories，实际为 \(error)")
            }
        }
        let messages = await provider.lastMessages()
        XCTAssertTrue(messages.isEmpty)
    }

    func testEnglishAIContextAndPromptsDoNotForceChinese() async throws {
        let oldLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        defer {
            if let oldLanguage {
                UserDefaults.standard.set(oldLanguage, forKey: AppLanguage.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
            }
        }
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        let file = IndexedFile(
            id: "english", sourceID: UUID(), name: "contract.md", path: "/private/contract.md",
            fileExtension: "md", kind: .document, size: 100,
            createdAt: nil, modifiedAt: nil, indexedAt: Date(), textContent: "Expires in 2027."
        )
        let provider = ScriptedAIProvider(response: "A contract.")

        _ = try await AIService(provider: provider).explain(file: file)
        let sent = await provider.lastMessages().map(\.content).joined(separator: "\n")
        XCTAssertTrue(sent.contains("File name:"))
        XCTAssertTrue(sent.contains("Briefly explain"))
        XCTAssertFalse(sent.contains("用简体中文"))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XunJianTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private actor RecordingAITransport: AIHTTPTransport {
    private let data: Data
    private let statusCode: Int
    private var request: URLRequest?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func lastRequest() -> URLRequest? {
        request
    }
}

private actor StreamingAITransport: AIStreamingHTTPTransport {
    private let responseLines: [String]
    private var request: URLRequest?

    init(lines: [String]) {
        responseLines = lines
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        fatalError("Streaming test must not use the buffered transport")
    }

    func lines(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        self.request = request
        let responseLines = self.responseLines
        let stream = AsyncThrowingStream<String, any Error> {
            (continuation: AsyncThrowingStream<String, any Error>.Continuation) in
            for line in responseLines { continuation.yield(line) }
            continuation.finish()
        }
        return (
            stream,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
        )
    }

    func lastRequest() -> URLRequest? { request }
}

private actor ScriptedAIProvider: AIProvider {
    nonisolated let kind = AIProviderKind.deepSeek
    private let response: String
    private var messages: [AIMessage] = []

    init(response: String) {
        self.response = response
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        self.messages = messages
        return response
    }

    func lastMessages() -> [AIMessage] {
        messages
    }
}

private actor FileEventProbe {
    private var eventsBySourceID: [UUID: [FileSystemChangeEvent]] = [:]

    func record(sourceID: UUID, events: [FileSystemChangeEvent]) {
        eventsBySourceID[sourceID, default: []].append(contentsOf: events)
    }

    func containsCreatedFile(sourceID: UUID, path: String) -> Bool {
        eventsBySourceID[sourceID, default: []].contains {
            $0.path == path && $0.kinds.contains(.created)
        }
    }


    func containsPath(sourceID: UUID, path: String) -> Bool {
        eventsBySourceID[sourceID, default: []].contains { $0.path == path }
    }

    func paths(sourceID: UUID) -> [String] {
        eventsBySourceID[sourceID, default: []].map(\.path)
    }
}
