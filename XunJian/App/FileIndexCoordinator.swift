import AppKit
import Foundation
import UserNotifications

/// Owns the local file index: database lifecycle, scanning, search, file
/// operations, categories, and filesystem monitoring.
///
/// Extracted from `AppModel` so the index can be reasoned about (and tested)
/// independently of AI and UI state. Cross-domain effects surface through
/// callbacks instead of reaching into other objects:
/// - `onError` — a failure the user should see
/// - `onFilesChanged` — the file set changed, so selection and AI results may
///   need recomputing
/// - `onFileResolved` — a file was renamed/moved and is still indexed; the UI
///   should select the new URL
@MainActor
final class FileIndexCoordinator: ObservableObject {
    private struct FileDerivedIndexes: Sendable {
        let kindCounts: [FileKind: Int]
        let byID: [String: IndexedFile]
        let orderByID: [String: Int]
        let idByPath: [String: String]
        let recentFiles: [IndexedFile]
    }

    private struct CategoryDerivedIndexes: Sendable {
        let categoriesByFileID: [String: [FileCategory]]
        let fileCountsByCategoryID: [UUID: Int]
        let filesByCategoryID: [UUID: [IndexedFile]]
    }

    private struct IncrementalIndexSnapshot: Sendable {
        let files: [IndexedFile]
        let links: [String: Set<UUID>]
        let fileDerived: FileDerivedIndexes
        let categoryDerived: CategoryDerivedIndexes
    }

    private struct FileRemovalSnapshot: Sendable {
        let files: [IndexedFile]
        let searchResults: [IndexedFile]?
        let links: [String: Set<UUID>]
        let fileDerived: FileDerivedIndexes
        let categoryDerived: CategoryDerivedIndexes
    }

    enum ReloadPublicationDecision: Equatable {
        case publish
        case retry
        case discard
    }

    static func reloadPublicationDecision(
        isCancelled: Bool,
        capturedDatabaseGeneration: UInt64,
        currentDatabaseGeneration: UInt64,
        requestedReloadGeneration: UInt64,
        currentReloadGeneration: UInt64,
        capturedPublicationGeneration: UInt64,
        currentPublicationGeneration: UInt64
    ) -> ReloadPublicationDecision {
        guard !isCancelled,
              capturedDatabaseGeneration == currentDatabaseGeneration,
              requestedReloadGeneration == currentReloadGeneration else {
            return .discard
        }
        return capturedPublicationGeneration == currentPublicationGeneration
            ? .publish
            : .retry
    }

    @Published private(set) var sources: [FileSource] = []
    @Published private(set) var files: [IndexedFile] = [] {
        didSet {
            guard !isBatchingIndexReload else { return }
            rebuildFileDerivedIndexes()
            rebuildCategoryDerivedIndexes()
        }
    }
    @Published private(set) var categories: [FileCategory] = [] {
        didSet {
            guard !isBatchingIndexReload else { return }
            rebuildCategoryDerivedIndexes()
        }
    }
    @Published private(set) var fileCategoryLinks: [String: Set<UUID>] = [:] {
        didSet {
            guard !isBatchingIndexReload else { return }
            rebuildCategoryDerivedIndexes()
        }
    }
    @Published private(set) var savedSearches: [SavedSearch] = []
    @Published private(set) var searchResults: [IndexedFile]? = nil
    @Published private(set) var searchResultTotalCount: Int? = nil
    private(set) var searchResultsRevision: UInt64 = 0
    /// High-frequency search flag. Not `@Published` here: forwarding it
    /// through `AppModel` rebuilt the whole window on every keystroke.
    let searchProgressStore = SearchProgressStore()
    var isSearching: Bool { searchProgressStore.isSearching }
    /// High-frequency scan UI. Not `@Published` on this object: forwarding it
    /// through `AppModel` rebuilt the whole window every 100 files.
    let scanProgressStore = ScanProgressStore()
    /// Category chips and inspector checkboxes observe this instead of the
    /// whole coordinator, so toggling one assignment does not rebuild All Files.
    let categoryIndexStore = CategoryIndexStore()
    /// Trash undo banner observes this instead of `objectWillChange`.
    let trashUndoStore = TrashUndoStore()
    @Published private(set) var isScanning = false
    var scanProgress: ScanProgress? { scanProgressStore.progress }
    @Published private(set) var includesHiddenFiles = false
    @Published private(set) var isDatabaseAvailable = true
    @Published private(set) var isUpdatingContentIndex = false

    // MARK: - Hooks into the rest of the app

    var onError: ((String) -> Void)?
    var onFilesChanged: (() -> Void)?
    var onFileResolved: ((URL) -> Void)?

    /// Reversible actions are pushed here so the app can offer a general Undo
    /// (N16). Set by `AppModel`; nil in contexts that do not surface undo.
    var undoCoordinator: UndoCoordinator?

    /// One-hop undo for move-to-Trash (N10).
    struct TrashUndo: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            let trashURL: URL
            let originalURL: URL
            let identity: FileSystemObjectIdentity
            let originalParentIdentity: FileSystemObjectIdentity
            let originalFileID: String
            let sourceID: UUID
            let categoryIDs: Set<UUID>
        }

        let items: [Item]
        /// The matching entry on the general undo stack, so using the banner
        /// and using ⌘Z cannot both restore the same item.
        var undoEntryID: UUID?

        var fileCount: Int { items.count }
    }

    var lastTrashUndo: TrashUndo? {
        get { trashUndoStore.undo }
        set { trashUndoStore.update(newValue) }
    }

    // MARK: - Storage

    private var database: FileIndexDatabase?
    /// Invalidates work captured from an older SQLite actor after retry/reopen.
    private var databaseGeneration: UInt64 = 0
    /// Invalidates older full reloads and detached snapshots before publication.
    private var indexPublicationGeneration: UInt64 = 0
    private var reloadGeneration: UInt64 = 0
    private var isBatchingIndexReload = false
    private let isRunningTests: Bool
    private let scanner = FileScanner()
    private let bookmarkManager = BookmarkManager()
    private let fileOperations = FileOperationService()
    private let fileSystemMonitor = FileSystemChangeMonitor()

    private static let searchResultBatchSize = 500
    private static let searchDebounce: Duration = .milliseconds(120)
    private static let fileChangeDebounce: Duration = .milliseconds(350)

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var activeSearchQuery = ""
    private var queuedFileUpserts = Set<String>()
    private var queuedFileRemovals = Set<String>()
    private var isRefreshingFiles = false
    private var scanTask: Task<Void, Never>?
    private var hiddenFilesPreferenceTask: Task<Void, Never>?
    private var hiddenFilesPreferenceRevision = UUID()
    private var contentIndexPreferenceTask: Task<Void, Never>?
    private var contentIndexPreferenceRevision = UUID()
    private var pendingFullTextExtractionSourceIDs: Set<UUID> = []
    private var scanGeneration = UUID()
    private var scanningSourceIDs = Set<UUID>()
    private var currentScanningSourceID: UUID?
    private var failedScanningSourceIDs = Set<UUID>()
    private var fileChangeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileChanges: [UUID: Set<FileSystemChangeEvent>] = [:]
    private var pendingFullRescanSourceIDs = Set<UUID>()
    private var sourceEnabledTasks: [UUID: Task<Void, Never>] = [:]
    private var sourceEnabledRevisions: [UUID: UUID] = [:]
    private var activeSecurityScopes: [UUID: URL] = [:]
    private var categoryMutationTasks: [FileCategoryAssignmentKey: Task<Void, Never>] = [:]
    private var batchCategoryMutationTask: Task<Void, Never>?
    private var pendingCategoryAssignments: [
        FileCategoryAssignmentKey: PendingCategoryAssignment
    ] = [:]

    init(isRunningTests: Bool) {
        self.isRunningTests = isRunningTests
        if !isRunningTests {
            includesHiddenFiles = UserDefaults.standard.bool(
                forKey: FileIndexPreferences.includesHiddenFilesKey
            )
        }
        openDatabase()
        configureFileSystemMonitoring()
    }

    func start() {
        Task { [weak self] in
            guard let self, await self.ensureDisabledContentIsPurged() else { return }
            await self.reloadIndex()
        }
    }

    func cancelAllTasks() {
        searchTask?.cancel()
        searchGeneration &+= 1
        scanTask?.cancel()
        hiddenFilesPreferenceTask?.cancel()
        contentIndexPreferenceTask?.cancel()
        sourceEnabledTasks.values.forEach { $0.cancel() }
        fileChangeTasks.values.forEach { $0.cancel() }
        categoryMutationTasks.values.forEach { $0.cancel() }
        batchCategoryMutationTask?.cancel()
    }

    // MARK: - Database lifecycle

    private func openDatabase() {
        do {
            database = try FileIndexDatabase(databaseURL: try databaseURL())
            databaseGeneration &+= 1
        } catch {
            database = nil
            databaseGeneration &+= 1
            isDatabaseAvailable = false
            onError?(Self.message(for: error))
        }
    }

    /// Regenerates the search index and compacts the database. Files, sources
    /// and categories are untouched, so this is safe to offer as a recovery
    /// action when search results look wrong.
    func rebuildSearchIndex() async {
        guard let database else { return reportDatabaseUnavailable() }
        do {
            try await database.rebuildSearchIndex()
            await reloadIndex()
        } catch {
            onError?(Self.message(for: error))
        }
    }

    func retryDatabase() async {
        searchTask?.cancel()
        searchGeneration &+= 1
        database = nil
        databaseGeneration &+= 1
        reloadGeneration &+= 1
        indexPublicationGeneration &+= 1
        do {
            database = try FileIndexDatabase(databaseURL: try databaseURL())
            databaseGeneration &+= 1
            isDatabaseAvailable = true
            guard await ensureDisabledContentIsPurged() else { return }
            await reloadIndex()
            startNextPendingFullRescanIfNeeded()
        } catch {
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    private func suspendIndexAfterDatabaseFailure(_ error: Error) {
        cancelScan(startsPendingFullRescan: false)
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        searchProgressStore.update(false)
        fileChangeTasks.values.forEach { $0.cancel() }
        fileChangeTasks.removeAll()
        pendingFileChanges.removeAll()
        // Category drains capture the old database actor; without cancelling
        // them here they keep writing to the stale handle and re-surface
        // errors after a retry reopens the database.
        categoryMutationTasks.values.forEach { $0.cancel() }
        categoryMutationTasks.removeAll()
        batchCategoryMutationTask?.cancel()
        batchCategoryMutationTask = nil
        pendingCategoryAssignments.removeAll()
        fileSystemMonitor.stopAll()
        for sourceID in Array(activeSecurityScopes.keys) {
            activeSecurityScopes.removeValue(forKey: sourceID)?
                .stopAccessingSecurityScopedResource()
        }
        database = nil
        databaseGeneration &+= 1
        reloadGeneration &+= 1
        indexPublicationGeneration &+= 1
        isDatabaseAvailable = false
        onError?(Self.message(for: error))
    }

    private func databaseURL() throws -> URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "XunJian-TestHost-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
                .appendingPathComponent("index.sqlite3")
        }
        return try FileIndexDatabase.defaultDatabaseURL()
    }

    private func reloadIndex() async {
        guard let database else { return }
        reloadGeneration &+= 1
        let requestedReload = reloadGeneration
        let capturedDatabaseGeneration = databaseGeneration

        while !Task.isCancelled {
            let capturedPublicationGeneration = indexPublicationGeneration
            do {
                let storedSources = try await database.fetchSources()
                let indexedFiles = try await database.fetchFiles()
                let requestedIncludesHiddenFiles = includesHiddenFiles
                let storedCategories = try await database.fetchCategories()
                let storedLinks = try await database.fetchFileCategoryLinks()
                let storedSearches = try await database.fetchSavedSearches()
                let derived = await Task.detached(priority: .userInitiated) {
                    let visibleFiles = requestedIncludesHiddenFiles
                        ? indexedFiles
                        : indexedFiles.filter { !Self.isDotPrefixedFile($0) }
                    return IncrementalIndexSnapshot(
                        files: visibleFiles,
                        links: storedLinks,
                        fileDerived: Self.makeFileDerivedIndexes(visibleFiles),
                        categoryDerived: Self.makeCategoryDerivedIndexes(
                            categories: storedCategories,
                            files: visibleFiles,
                            links: storedLinks
                        )
                    )
                }.value

                switch Self.reloadPublicationDecision(
                    isCancelled: Task.isCancelled,
                    capturedDatabaseGeneration: capturedDatabaseGeneration,
                    currentDatabaseGeneration: databaseGeneration,
                    requestedReloadGeneration: requestedReload,
                    currentReloadGeneration: reloadGeneration,
                    capturedPublicationGeneration: capturedPublicationGeneration,
                    currentPublicationGeneration: indexPublicationGeneration
                ) {
                case .discard:
                    return
                case .retry:
                    continue
                case .publish:
                    break
                }

                // Publish one coherent snapshot. Without batching, a reload rebuilt
                // the 100k-file/category indexes once for every individual field.
                isBatchingIndexReload = true
                sources = storedSources.map { source in
                    var source = source
                    do {
                        let restored = try bookmarkManager.resolveBookmark(source.bookmark)
                        source.accessState = FileManager.default.fileExists(atPath: restored.url.path)
                            ? .available
                            : .unavailable
                    } catch {
                        source.accessState = .needsAuthorization
                    }
                    return source
                }
                files = derived.files
                categories = storedCategories
                fileCategoryLinks = derived.links
                savedSearches = storedSearches
                isBatchingIndexReload = false
                apply(derived.fileDerived)
                apply(derived.categoryDerived)
                indexPublicationGeneration &+= 1
                activateSecurityScopes()
                configureFileSystemMonitoring()
                onFilesChanged?()
                refreshActiveSearchIfNeeded()
                isDatabaseAvailable = true
                return
            } catch {
                guard databaseGeneration == capturedDatabaseGeneration else { return }
                suspendIndexAfterDatabaseFailure(error)
                return
            }
        }
    }

    /// Canonical in-memory order: modified_at DESC (NULLs last), then name
    /// NOCASE ascending — matches `fetchFiles`'s ORDER BY.
    nonisolated private static func comesBefore(_ lhs: IndexedFile, _ rhs: IndexedFile) -> Bool {
        let lhsDate = lhs.modifiedAt ?? .distantPast
        let rhsDate = rhs.modifiedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    nonisolated static func mergeIncrementalFiles(
        current: [IndexedFile],
        fetched: [IndexedFile],
        removedIDs: Set<String>,
        includesHiddenFiles: Bool
    ) -> [IndexedFile] {
        let visibleFetched = fetched.filter {
            includesHiddenFiles || !isDotPrefixedFile($0)
        }
        let fetchedByID = Dictionary(
            uniqueKeysWithValues: visibleFetched.map { ($0.id, $0) }
        )
        let hiddenFetchedIDs = Set(fetched.lazy.filter {
            !includesHiddenFiles && isDotPrefixedFile($0)
        }.map(\.id))
        let updated = current.compactMap { file -> IndexedFile? in
            guard !removedIDs.contains(file.id), !hiddenFetchedIDs.contains(file.id) else {
                return nil
            }
            return fetchedByID[file.id] ?? file
        }
        let currentIDs = Set(current.map(\.id))
        let newFiles = visibleFetched.filter { !currentIDs.contains($0.id) }
        guard !newFiles.isEmpty else { return updated }

        var merged: [IndexedFile] = []
        merged.reserveCapacity(updated.count + newFiles.count)
        var existingIndex = 0
        var newIndex = 0
        while existingIndex < updated.count, newIndex < newFiles.count {
            if comesBefore(newFiles[newIndex], updated[existingIndex]) {
                merged.append(newFiles[newIndex])
                newIndex += 1
            } else {
                merged.append(updated[existingIndex])
                existingIndex += 1
            }
        }
        if existingIndex < updated.count {
            merged.append(contentsOf: updated[existingIndex...])
        }
        if newIndex < newFiles.count {
            merged.append(contentsOf: newFiles[newIndex...])
        }
        return merged
    }

    /// Applies a small, known set of file changes to the in-memory model
    /// without refetching the whole `files`/`file_categories` tables (H2).
    /// The database is authoritative for the changed rows; anything else
    /// keeps the previous in-memory state. Any failure falls back to a full
    /// reload through `suspendIndexAfterDatabaseFailure` + retry.
    private func refreshFiles(
        upsertedFileIDs: [String],
        removedFileIDs: Set<String>
    ) async {
        queuedFileRemovals.formUnion(removedFileIDs)
        queuedFileUpserts.formUnion(upsertedFileIDs)
        queuedFileUpserts.subtract(queuedFileRemovals)
        guard !isRefreshingFiles else { return }

        isRefreshingFiles = true
        defer { isRefreshingFiles = false }
        while !queuedFileUpserts.isEmpty || !queuedFileRemovals.isEmpty {
            let upserts = queuedFileUpserts
            let removals = queuedFileRemovals
            queuedFileUpserts.removeAll(keepingCapacity: true)
            queuedFileRemovals.removeAll(keepingCapacity: true)
            await performRefreshFiles(
                upsertedFileIDs: Array(upserts),
                removedFileIDs: removals
            )
            guard database != nil else { return }
        }
    }

    private func performRefreshFiles(
        upsertedFileIDs: [String],
        removedFileIDs: Set<String>
    ) async {
        guard let database else { return }
        let capturedDatabaseGeneration = databaseGeneration
        let capturedPublicationGeneration = indexPublicationGeneration
        let upsertedIDs = Array(Set(upsertedFileIDs).subtracting(removedFileIDs))
        do {
            let fetchedFiles = try await database.fetchFiles(fileIDs: upsertedIDs)
            let fetchedLinks = try await database.fetchFileCategoryLinks(
                fileIDs: upsertedIDs
            )
            await FinderTagService.shared.invalidate(
                fileIDs: Set(upsertedIDs).union(removedFileIDs)
            )

            var links = fileCategoryLinks
            for removedID in removedFileIDs {
                links.removeValue(forKey: removedID)
            }
            for (fileID, categoryIDs) in fetchedLinks {
                links[fileID] = categoryIDs
            }

            let currentFiles = files
            let currentCategories = categories
            let includesHidden = includesHiddenFiles
            let snapshot = await Task.detached(priority: .userInitiated) {
                let updated = Self.mergeIncrementalFiles(
                    current: currentFiles,
                    fetched: fetchedFiles,
                    removedIDs: removedFileIDs,
                    includesHiddenFiles: includesHidden
                )
                return IncrementalIndexSnapshot(
                    files: updated,
                    links: links,
                    fileDerived: Self.makeFileDerivedIndexes(updated),
                    categoryDerived: Self.makeCategoryDerivedIndexes(
                        categories: currentCategories,
                        files: updated,
                        links: links
                    )
                )
            }.value
            guard !Task.isCancelled,
                  databaseGeneration == capturedDatabaseGeneration,
                  indexPublicationGeneration == capturedPublicationGeneration else {
                return
            }

            isBatchingIndexReload = true
            files = snapshot.files
            fileCategoryLinks = snapshot.links
            isBatchingIndexReload = false
            apply(snapshot.fileDerived)
            apply(snapshot.categoryDerived)
            indexPublicationGeneration &+= 1

            refreshActiveSearchIfNeeded()
            onFilesChanged?()
            isDatabaseAvailable = true
        } catch {
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    /// Refetches category links for the given file IDs and merges them into
    /// the in-memory link table. Queried-but-linkless IDs are set to empty so
    /// removals are reflected, not just additions.
    private func refreshLinks(forFileIDs fileIDs: [String]) async {
        guard let database, !fileIDs.isEmpty else { return }
        let capturedDatabaseGeneration = databaseGeneration
        do {
            let fetchedLinks = try await database.fetchFileCategoryLinks(
                fileIDs: fileIDs
            )
            let sourceLinks = fileCategoryLinks
            let sourceFiles = files
            let sourceCategories = categories
            let sourceFilesRevision = filesRevision
            let sourceCategoryRevision = categoryRevision
            let derived = await Task.detached(priority: .userInitiated) {
                var links = sourceLinks
                for fileID in fileIDs {
                    links[fileID] = fetchedLinks[fileID] ?? []
                }
                return (
                    links: links,
                    categories: Self.makeCategoryDerivedIndexes(
                        categories: sourceCategories,
                        files: sourceFiles,
                        links: links
                    )
                )
            }.value
            guard !Task.isCancelled else { return }
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            guard filesRevision == sourceFilesRevision,
                  categoryRevision == sourceCategoryRevision else {
                await refreshLinks(forFileIDs: fileIDs)
                return
            }
            isBatchingIndexReload = true
            fileCategoryLinks = derived.links
            isBatchingIndexReload = false
            apply(derived.categories)
            indexPublicationGeneration &+= 1
            refreshActiveSearchIfNeeded()
            isDatabaseAvailable = true
        } catch {
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    /// Refetches categories (and optionally the whole link table) after a
    /// category mutation, avoiding a full file-table reload.
    private func refreshCategories(refetchingLinks: Bool) async {
        guard let database else { return }
        let capturedDatabaseGeneration = databaseGeneration
        do {
            let refreshedCategories = try await database.fetchCategories()
            let refreshedLinks = refetchingLinks
                ? try await database.fetchFileCategoryLinks()
                : fileCategoryLinks
            let sourceFiles = files
            let sourceFilesRevision = filesRevision
            let sourceCategoryRevision = categoryRevision
            let derived = await Task.detached(priority: .userInitiated) {
                Self.makeCategoryDerivedIndexes(
                    categories: refreshedCategories,
                    files: sourceFiles,
                    links: refreshedLinks
                )
            }.value
            guard !Task.isCancelled else { return }
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            guard filesRevision == sourceFilesRevision,
                  categoryRevision == sourceCategoryRevision else {
                await refreshCategories(refetchingLinks: refetchingLinks)
                return
            }
            isBatchingIndexReload = true
            categories = refreshedCategories
            if refetchingLinks {
                fileCategoryLinks = refreshedLinks
            }
            isBatchingIndexReload = false
            apply(derived)
            indexPublicationGeneration &+= 1
            refreshActiveSearchIfNeeded()
            isDatabaseAvailable = true
        } catch {
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    /// Refetches sources (and their access states) after add/remove/reauthorize
    /// or enable toggling, avoiding a full file-table reload.
    private func refreshSources() async {
        guard let database else { return }
        let capturedDatabaseGeneration = databaseGeneration
        do {
            let storedSources = try await database.fetchSources()
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            sources = storedSources.map { source in
                var source = source
                do {
                    let restored = try bookmarkManager.resolveBookmark(source.bookmark)
                    source.accessState = FileManager.default.fileExists(atPath: restored.url.path)
                        ? .available
                        : .unavailable
                } catch {
                    source.accessState = .needsAuthorization
                }
                return source
            }
            activateSecurityScopes()
            configureFileSystemMonitoring()
            indexPublicationGeneration &+= 1
            isDatabaseAvailable = true
        } catch {
            guard databaseGeneration == capturedDatabaseGeneration else { return }
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    /// FTS lookup used by AI search to gather candidates for one keyword.
    func searchFiles(matching query: String, limit: Int) async throws -> [IndexedFile] {
        guard let database else { throw FileIndexError.databaseUnavailable }
        return try await database.searchFiles(matching: query, limit: limit)
    }

    /// FTS lookup across many keywords in a single query (F13).
    func searchFiles(matchingAnyOf keywords: [String], limit: Int) async throws -> [IndexedFile] {
        guard let database else { throw FileIndexError.databaseUnavailable }
        return try await database.searchFiles(matchingAnyOf: keywords, limit: limit)
    }

    /// Applies AI-suggested category changes and refreshes the affected links.
    func applyAICategories(
        _ changes: [AIClassificationChange],
        assigned: Bool
    ) async throws {
        guard let database else { throw FileIndexError.databaseUnavailable }
        try await database.setCategories(changes, assigned: assigned)
        await refreshLinks(forFileIDs: Array(Set(changes.map(\.fileID))))
    }

    /// Text content of a file, used by the AI explain/ask flows.
    func textContent(forFileID fileID: String) async throws -> String? {
        guard let database else { throw FileIndexError.databaseUnavailable }
        return try await database.fetchTextContent(forFileID: fileID)
    }

    // MARK: - Saved searches (N07)

    func saveSearch(
        name: String,
        query: String,
        minSizeBytes: Int64,
        minDate: Date?,
        fileKind: FileKind? = nil,
        id: UUID = UUID(),
        createdAt: Date? = nil
    ) {
        guard let database else { return reportDatabaseUnavailable() }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let search = SavedSearch(
            id: id,
            name: trimmedName,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            minSizeBytes: minSizeBytes,
            minDate: minDate,
            createdAt: createdAt ?? Date(),
            fileKind: fileKind
        )
        Task { [weak self] in
            do {
                try await database.upsertSavedSearch(search)
                self?.savedSearches = try await database.fetchSavedSearches()
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
    }

    func deleteSearch(id: UUID) {
        guard let database else { return reportDatabaseUnavailable() }
        Task { [weak self] in
            do {
                try await database.deleteSavedSearch(id: id)
                self?.savedSearches = try await database.fetchSavedSearches()
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
    }

    // MARK: - Queries

    /// Cached: the home page reads this several times per body evaluation, and
    /// recomputing meant a full filter + sort of the index each time.
    private(set) var recentFiles: [IndexedFile] = []

    nonisolated private static let recentFileCount = 8

    /// Hot-path lookup caches. Selection, inspector refreshes, and keyboard
    /// commands should not linearly scan a six-figure file index.
    private var filesByID: [String: IndexedFile] = [:]
    private var fileOrderByID: [String: Int] = [:]
    private var fileIDByCanonicalPath: [String: String] = [:]
    private(set) var allFileIDs = Set<String>()

    var hasMoreSearchResults: Bool {
        searchResults != nil
            && searchResultTotalCount != nil
            && (searchResults?.count ?? 0) < (searchResultTotalCount ?? 0)
    }

    func categories(for file: IndexedFile) -> [FileCategory] {
        guard fileCategoryLinks[file.id]?.isEmpty == false else {
            return []
        }
        return categoriesByFileID[file.id] ?? []
    }

    func files(in category: FileCategory) -> [IndexedFile] {
        filesByCategoryID[category.id] ?? []
    }

    func file(id: String) -> IndexedFile? {
        filesByID[id]
    }

    func file(at url: URL) -> IndexedFile? {
        guard let id = fileIDByCanonicalPath[FilePathCanonicalizer.path(url)] else { return nil }
        return filesByID[id]
    }

    func fileCategoryLinksSnapshot() -> [String: Set<UUID>] {
        fileCategoryLinks
    }

    func files(ids: Set<String>) -> [IndexedFile] {
        ids.compactMap { filesByID[$0] }.sorted {
            (fileOrderByID[$0.id] ?? .max) < (fileOrderByID[$1.id] ?? .max)
        }
    }

    func fileCount(in category: FileCategory) -> Int {
        fileCountsByCategoryID[category.id] ?? 0
    }

    func isCategory(_ category: FileCategory, assignedTo file: IndexedFile) -> Bool {
        fileCategoryLinks[file.id]?.contains(category.id) == true
    }

    /// F12: O(1) per-kind counts instead of scanning `files` once per kind on
    /// the home page (7 scans of up to 100k files each).
    private var fileCountsByKind: [FileKind: Int] = [:]
    /// Same idea for categories: the overview draws one card per category, and
    /// counting by scanning `files` per card was O(categories × files).
    private var fileCountsByCategoryID: [UUID: Int] = [:]
    private var filesByCategoryID: [UUID: [IndexedFile]] = [:]
    /// Canonically ordered labels prepared once per index mutation. Building a
    /// visible table row no longer scans every category.
    private var categoriesByFileID: [String: [FileCategory]] = [:]

    func fileCount(for kind: FileKind) -> Int {
        fileCountsByKind[kind] ?? 0
    }

    /// Separate revisions keep a category-only edit from invalidating every
    /// file-metadata snapshot in the app.
    private(set) var filesRevision: UInt64 = 0
    private(set) var categoryRevision: UInt64 = 0

    private func rebuildFileDerivedIndexes() {
        apply(Self.makeFileDerivedIndexes(files))
    }

    nonisolated private static func makeFileDerivedIndexes(
        _ files: [IndexedFile]
    ) -> FileDerivedIndexes {
        var kindCounts: [FileKind: Int] = [:]
        var byID: [String: IndexedFile] = [:]
        var orderByID: [String: Int] = [:]
        var idByPath: [String: String] = [:]
        byID.reserveCapacity(files.count)
        orderByID.reserveCapacity(files.count)
        idByPath.reserveCapacity(files.count)
        var newest: [IndexedFile] = []
        newest.reserveCapacity(Self.recentFileCount)

        for (index, file) in files.enumerated() {
            kindCounts[file.kind, default: 0] += 1
            byID[file.id] = file
            orderByID[file.id] = index
            // `file.path` is already the canonical form: the scanner and
            // every writer canonicalize before persisting. Re-resolving it
            // here cost one stat + realpath syscall per file per mutation on
            // the main actor (~200k syscalls per FSEvents batch at 100k
            // files), which froze the UI during file activity.
            idByPath[file.path] = file.id
            guard file.modifiedAt != nil else { continue }
            let insertionIndex = newest.firstIndex {
                ($0.modifiedAt ?? .distantPast) < (file.modifiedAt ?? .distantPast)
            } ?? newest.endIndex
            newest.insert(file, at: insertionIndex)
            if newest.count > Self.recentFileCount {
                newest.removeLast()
            }
        }
        return FileDerivedIndexes(
            kindCounts: kindCounts,
            byID: byID,
            orderByID: orderByID,
            idByPath: idByPath,
            recentFiles: newest
        )
    }

    private func apply(_ derived: FileDerivedIndexes) {
        filesRevision &+= 1
        fileCountsByKind = derived.kindCounts
        filesByID = derived.byID
        fileOrderByID = derived.orderByID
        fileIDByCanonicalPath = derived.idByPath
        allFileIDs = Set(derived.byID.keys)
        recentFiles = derived.recentFiles
    }

    private func rebuildCategoryDerivedIndexes() {
        apply(Self.makeCategoryDerivedIndexes(
            categories: categories,
            files: files,
            links: fileCategoryLinks
        ))
    }

    nonisolated private static func makeCategoryDerivedIndexes(
        categories: [FileCategory],
        files: [IndexedFile],
        links: [String: Set<UUID>]
    ) -> CategoryDerivedIndexes {
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var categoryLists: [String: [FileCategory]] = [:]
        categoryLists.reserveCapacity(links.count)
        var categoryCounts: [UUID: Int] = [:]
        for (fileID, assignedIDs) in links where !assignedIDs.isEmpty {
            categoryLists[fileID] = assignedIDs.compactMap { categoryByID[$0] }
            for categoryID in assignedIDs {
                categoryCounts[categoryID, default: 0] += 1
            }
        }
        var categoryFiles: [UUID: [IndexedFile]] = [:]
        for file in files {
            for categoryID in links[file.id] ?? [] {
                categoryFiles[categoryID, default: []].append(file)
            }
        }
        return CategoryDerivedIndexes(
            categoriesByFileID: categoryLists,
            fileCountsByCategoryID: categoryCounts,
            filesByCategoryID: categoryFiles
        )
    }

    private func apply(_ derived: CategoryDerivedIndexes) {
        categoryRevision &+= 1
        categoriesByFileID = derived.categoriesByFileID
        fileCountsByCategoryID = derived.fileCountsByCategoryID
        filesByCategoryID = derived.filesByCategoryID
        categoryIndexStore.replaceAll(
            categories: categories,
            links: fileCategoryLinks,
            categoriesByFileID: derived.categoriesByFileID,
            fileCountsByCategoryID: derived.fileCountsByCategoryID,
            filesByCategoryID: derived.filesByCategoryID
        )
    }

    // MARK: - Search

    func scheduleSearch(query: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let requestedGeneration = searchGeneration
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = query

        guard !query.isEmpty else {
            publishSearchResults(nil, totalCount: nil)
            searchProgressStore.update(false)
            return
        }
        guard let database else {
            publishSearchResults([], totalCount: 0)
            searchProgressStore.update(false)
            return
        }
        let capturedDatabaseGeneration = databaseGeneration

        // Keep the previous page on screen. Assigning `nil` here published
        // through AppModel and rebuilt the file table on every keystroke.
        searchProgressStore.update(true)
        let includesHiddenFiles = includesHiddenFiles
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.searchDebounce)
                let page = try await database.searchFilesPage(
                    matching: query,
                    limit: Self.searchResultBatchSize,
                    includesHiddenFiles: includesHiddenFiles
                )
                try Task.checkCancellation()
                guard let self,
                      self.databaseGeneration == capturedDatabaseGeneration,
                      self.searchGeneration == requestedGeneration,
                      self.activeSearchQuery == query else { return }
                self.publishSearchResults(page.files, totalCount: page.totalCount)
                self.searchProgressStore.update(false)
            } catch is CancellationError {
                // 新输入会替换尚未完成的查询。
            } catch {
                guard let self else { return }
                guard self.databaseGeneration == capturedDatabaseGeneration,
                      self.searchGeneration == requestedGeneration,
                      self.activeSearchQuery == query else { return }
                self.publishSearchResults([], totalCount: 0)
                self.searchProgressStore.update(false)
                self.onError?(Self.message(for: error))
            }
        }
    }

    func loadMoreSearchResults(query: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let requestedGeneration = searchGeneration
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query == activeSearchQuery, let database else { return }
        let capturedDatabaseGeneration = databaseGeneration
        let existing = searchResults ?? []
        let existingIDs = Set(existing.map(\.id))
        searchProgressStore.update(true)
        searchTask = Task { [weak self] in
            do {
                guard let self else { return }
                let page = try await database.searchFilesPage(
                    matching: query,
                    limit: Self.searchResultBatchSize,
                    offset: existing.count,
                    includesHiddenFiles: self.includesHiddenFiles,
                    fetchesTotalCount: false
                )
                try Task.checkCancellation()
                guard self.searchGeneration == requestedGeneration,
                      self.databaseGeneration == capturedDatabaseGeneration,
                      self.activeSearchQuery == query else { return }
                self.publishSearchResults(
                    existing + page.files.filter { !existingIDs.contains($0.id) },
                    totalCount: self.searchResultTotalCount
                )
                self.searchProgressStore.update(false)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                guard self.databaseGeneration == capturedDatabaseGeneration,
                      self.searchGeneration == requestedGeneration,
                      self.activeSearchQuery == query else { return }
                self.searchProgressStore.update(false)
                self.onError?(Self.message(for: error))
            }
        }
    }

    func loadAllSearchResults(query: String) async -> Bool {
        searchTask?.cancel()
        searchGeneration &+= 1
        let requestedGeneration = searchGeneration
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query == activeSearchQuery, let database else { return false }
        let capturedDatabaseGeneration = databaseGeneration
        let requestedLimit = max(searchResultTotalCount ?? 0, searchResults?.count ?? 0, 1)
        searchProgressStore.update(true)
        defer {
            if searchGeneration == requestedGeneration,
               databaseGeneration == capturedDatabaseGeneration,
               activeSearchQuery == query {
                searchProgressStore.update(false)
            }
        }
        do {
            let page = try await database.searchFilesPage(
                matching: query,
                limit: requestedLimit,
                includesHiddenFiles: includesHiddenFiles
            )
            guard searchGeneration == requestedGeneration,
                  databaseGeneration == capturedDatabaseGeneration,
                  activeSearchQuery == query else { return false }
            publishSearchResults(page.files, totalCount: page.totalCount)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard databaseGeneration == capturedDatabaseGeneration,
                  searchGeneration == requestedGeneration,
                  activeSearchQuery == query else { return false }
            onError?(Self.message(for: error))
            return false
        }
    }

    static func retainedSearchResults(
        forQuery query: String,
        previous: [IndexedFile]?
    ) -> [IndexedFile]? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : previous
    }

    private func publishSearchResults(
        _ results: [IndexedFile]?,
        totalCount: Int?
    ) {
        searchResults = results
        searchResultTotalCount = totalCount
        searchResultsRevision &+= 1
    }

    private func refreshActiveSearchIfNeeded() {
        guard !activeSearchQuery.isEmpty else { return }
        scheduleSearch(query: activeSearchQuery)
    }

    func searchFileIDs(
        matching query: String,
        inCategory categoryID: UUID,
        limit: Int
    ) async throws -> Set<String> {
        guard let database else { throw FileIndexError.databaseUnavailable }
        return try await database.searchFileIDs(
            matching: query,
            inCategory: categoryID,
            limit: limit
        )
    }

    // MARK: - Sources

    func chooseFolder(startingAt directoryURL: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized(
            "选择你希望管理的文件位置",
            english: "Choose a Folder to Manage"
        )
        panel.prompt = AppLanguage.localized("添加文件夹", english: "Add Folder")
        panel.message = AppLanguage.localized(
            "寻简只会建立本地索引，不会复制或移动文件。",
            english: "XunJian only builds a local index. It doesn’t copy or move your files."
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.addSource(url)
            }
        }
    }

    func reauthorizeSource(_ source: FileSource) {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized(
            "重新授权文件夹",
            english: "Reauthorize Folder"
        )
        panel.prompt = AppLanguage.localized("重新授权", english: "Reauthorize")
        panel.message = AppLanguage.localized(
            "请选择“\(source.displayName)”当前所在的文件夹以恢复访问权限。",
            english: "Select the current location of “\(source.displayName)” to restore access."
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.fileExists(atPath: source.path)
            ? source.url
            : source.url.deletingLastPathComponent()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.restoreAuthorization(for: source, using: url)
            }
        }
    }

    /// Pauses or resumes indexing for one source (N06).
    func setSourceEnabled(_ source: FileSource, enabled: Bool) {
        guard let database else { return reportDatabaseUnavailable() }
        let revision = UUID()
        sourceEnabledRevisions[source.id] = revision
        let previousTask = sourceEnabledTasks[source.id]
        previousTask?.cancel()
        sourceEnabledTasks[source.id] = Task { [weak self] in
            await previousTask?.value
            guard let self,
                  !Task.isCancelled,
                  self.sourceEnabledRevisions[source.id] == revision else { return }
            do {
                try await database.setSourceEnabled(id: source.id, enabled: enabled)
                try Task.checkCancellation()
                guard self.sourceEnabledRevisions[source.id] == revision else { return }
                await self.refreshSources()
                guard self.sourceEnabledRevisions[source.id] == revision else { return }
                if enabled {
                    self.pendingFullRescanSourceIDs.insert(source.id)
                    self.startNextPendingFullRescanIfNeeded()
                } else {
                    self.pendingFullRescanSourceIDs.remove(source.id)
                    self.fileChangeTasks.removeValue(forKey: source.id)?.cancel()
                    self.pendingFileChanges.removeValue(forKey: source.id)
                    if self.currentScanningSourceID == source.id {
                        let remaining = self.scanningSourceIDs.subtracting([source.id])
                        self.pendingFullRescanSourceIDs.formUnion(remaining)
                        self.cancelScan(startsPendingFullRescan: false)
                        self.startNextPendingFullRescanIfNeeded()
                    } else {
                        self.scanningSourceIDs.remove(source.id)
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      self.sourceEnabledRevisions[source.id] == revision else { return }
                self.onError?(Self.message(for: error))
            }
            guard self.sourceEnabledRevisions[source.id] == revision else { return }
            self.sourceEnabledTasks[source.id] = nil
            self.sourceEnabledRevisions[source.id] = nil
        }
    }

    func removeSource(_ source: FileSource) {
        // Only closures that captured this source become invalid. Undos for
        // unrelated folders must remain available.
        undoCoordinator?.removeEntries(affecting: source.id)
        if lastTrashUndo?.items.contains(where: { $0.sourceID == source.id }) == true {
            lastTrashUndo = nil
        }
        pendingFullRescanSourceIDs.remove(source.id)
        if currentScanningSourceID == source.id {
            cancelScan(startsPendingFullRescan: false)
        } else {
            scanningSourceIDs.remove(source.id)
        }
        fileChangeTasks.removeValue(forKey: source.id)?.cancel()
        pendingFileChanges.removeValue(forKey: source.id)

        Task { [weak self] in
            guard let self, let database = self.database else { return }
            do {
                try await database.deleteSource(source.id)
                self.activeSecurityScopes.removeValue(forKey: source.id)?
                    .stopAccessingSecurityScopedResource()
                await self.reloadIndex()
                self.startNextPendingFullRescanIfNeeded()
            } catch {
                self.onError?(Self.message(for: error))
            }
        }
    }

    func scanSource(_ source: FileSource) {
        guard Self.isSourceEligibleForScanning(source) else { return }
        cancelScan(startsPendingFullRescan: false)
        let generation = UUID()
        scanGeneration = generation
        scanningSourceIDs = [source.id]
        failedScanningSourceIDs.removeAll()
        currentScanningSourceID = source.id
        isScanning = true
        scanProgressStore.update(scopedProgress(
            ScanProgress(discoveredCount: 0, currentPath: source.path),
            sourceID: source.id
        ))
        scanTask = Task { [weak self] in
            await self?.performScan(source, generation: generation)
        }
    }

    func refreshAllSources() {
        let sourcesToScan = sources.filter(Self.isSourceEligibleForScanning)
        guard !sourcesToScan.isEmpty else { return }
        cancelScan(startsPendingFullRescan: false)
        let generation = UUID()
        scanGeneration = generation
        scanningSourceIDs = Set(sourcesToScan.map(\.id))
        failedScanningSourceIDs.removeAll()
        isScanning = true
        scanProgressStore.update(scopedProgress(
            ScanProgress(discoveredCount: 0, currentPath: sourcesToScan[0].path),
            sourceID: sourcesToScan[0].id
        ))
        scanTask = Task { [weak self] in
            guard let self else { return }
            for source in sourcesToScan {
                guard !Task.isCancelled,
                      self.scanGeneration == generation else { return }
                guard self.scanningSourceIDs.contains(source.id) else { continue }
                self.currentScanningSourceID = source.id
                await self.performScan(
                    source,
                    keepsScanningState: true,
                    generation: generation
                )
            }
            self.finishScan(generation: generation)
        }
    }

    func setIncludesHiddenFiles(_ includesHiddenFiles: Bool) {
        guard self.includesHiddenFiles != includesHiddenFiles else { return }
        self.includesHiddenFiles = includesHiddenFiles
        UserDefaults.standard.set(
            includesHiddenFiles,
            forKey: FileIndexPreferences.includesHiddenFilesKey
        )
        hiddenFilesPreferenceTask?.cancel()
        let revision = UUID()
        hiddenFilesPreferenceRevision = revision
        hiddenFilesPreferenceTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadIndex()
            guard !Task.isCancelled,
                  self.hiddenFilesPreferenceRevision == revision,
                  self.includesHiddenFiles == includesHiddenFiles else { return }
            self.hiddenFilesPreferenceTask = nil
            guard self.isDatabaseAvailable else { return }
            self.refreshActiveSearchIfNeeded()
            self.refreshAllSources()
        }
    }

    func setIndexesFileContents(_ enabled: Bool) {
        let revision = UUID()
        contentIndexPreferenceRevision = revision
        let previousTask = contentIndexPreferenceTask
        previousTask?.cancel()
        UserDefaults.standard.set(enabled, forKey: FileIndexPreferences.indexesFileContentsKey)
        UserDefaults.standard.set(false, forKey: FileIndexPreferences.disabledContentPurgeCompletedKey)
        if enabled {
            pendingFullTextExtractionSourceIDs = Set(
                sources.filter(Self.isSourceEligibleForScanning).map(\.id)
            )
            isUpdatingContentIndex = !pendingFullTextExtractionSourceIDs.isEmpty
            contentIndexPreferenceTask = Task { [weak self] in
                await previousTask?.value
                guard !Task.isCancelled,
                      self?.contentIndexPreferenceRevision == revision else { return }
                self?.refreshAllSources()
                self?.contentIndexPreferenceTask = nil
            }
            return
        }

        pendingFullTextExtractionSourceIDs.removeAll()
        cancelScan(startsPendingFullRescan: false)
        guard let database else { return reportDatabaseUnavailable() }
        isUpdatingContentIndex = true
        contentIndexPreferenceTask = Task { [weak self] in
            await previousTask?.value
            do {
                try Task.checkCancellation()
                try await database.clearTextContents()
                try Task.checkCancellation()
                guard self?.contentIndexPreferenceRevision == revision,
                      !FileIndexPreferences.indexesFileContents else { return }
                UserDefaults.standard.set(
                    true,
                    forKey: FileIndexPreferences.disabledContentPurgeCompletedKey
                )
                self?.refreshActiveSearchIfNeeded()
            } catch {
                guard !Task.isCancelled,
                      self?.contentIndexPreferenceRevision == revision else { return }
                self?.onError?(Self.message(for: error))
            }
            guard self?.contentIndexPreferenceRevision == revision else { return }
            self?.isUpdatingContentIndex = false
            self?.contentIndexPreferenceTask = nil
        }
    }

    static func isSourceEligibleForScanning(_ source: FileSource) -> Bool {
        source.enabled && source.accessState == .available
    }

    private func ensureDisabledContentIsPurged() async -> Bool {
        guard !FileIndexPreferences.indexesFileContents else { return true }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: FileIndexPreferences.disabledContentPurgeCompletedKey) else {
            return true
        }
        guard let database else {
            reportDatabaseUnavailable()
            return false
        }
        isUpdatingContentIndex = true
        defer { isUpdatingContentIndex = false }
        do {
            try await database.clearTextContents()
            defaults.set(true, forKey: FileIndexPreferences.disabledContentPurgeCompletedKey)
            return true
        } catch {
            suspendIndexAfterDatabaseFailure(error)
            return false
        }
    }

    func cancelScan(startsPendingFullRescan: Bool = true) {
        let completedSourceIDs = scanningSourceIDs
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanningSourceIDs.removeAll()
        currentScanningSourceID = nil
        isScanning = false
        scanProgressStore.update(nil)
        failedScanningSourceIDs.removeAll()
        schedulePendingFileChanges(for: completedSourceIDs)
        if startsPendingFullRescan {
            startNextPendingFullRescanIfNeeded()
        }
    }

    // MARK: - File operations

    func open(_ file: IndexedFile) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            handleMissingIndexedFile(file)
            return
        }
        NSWorkspace.shared.open(file.url)
    }

    func showInFinder(_ file: IndexedFile) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            handleMissingIndexedFile(file)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func quickLook(_ file: IndexedFile) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            handleMissingIndexedFile(file)
            return
        }
        QuickLookPresenter.shared.present(file.url)
    }

    /// Copies the file's POSIX path to the pasteboard (N01). The most common
    /// next step after finding a file used to require the context menu only.
    func copyPath(_ file: IndexedFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
    }

    func rename(_ file: IndexedFile, to newName: String) async throws {
        guard isDatabaseAvailable else {
            throw FileIndexError.databaseUnavailable
        }
        let originalParentIdentity = try await fileOperations.directoryIdentity(
            of: file.url.deletingLastPathComponent()
        )
        let renamedURL = try await fileOperations.rename(indexedFile: file, to: newName)
        guard FilePathCanonicalizer.path(renamedURL) != FilePathCanonicalizer.path(file.url) else {
            return
        }
        let renamedIdentity = try await fileOperations.identity(of: renamedURL)
        await reconcileKnownFileChanges([file.url, renamedURL])
        onFileResolved?(renamedURL)

        let originalName = file.name
        undoCoordinator?.record(
            title: UndoCoordinator.renameTitle,
            affectedSourceIDs: [file.sourceID]
        ) { [weak self] in
            guard let self else { return }
            let restoredURL = try await fileOperations.rename(
                fileAt: renamedURL,
                expectedIdentity: renamedIdentity,
                expectedParentIdentity: originalParentIdentity,
                to: originalName
            )
            await reconcileKnownFileChanges([renamedURL, restoredURL])
            onFileResolved?(restoredURL)
        }
    }

    func chooseMoveDestination(for file: IndexedFile) {
        guard isDatabaseAvailable else {
            onError?(FileIndexError.databaseUnavailable.localizedDescription)
            return
        }
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized(
            "选择移动目标文件夹",
            english: "Choose a Destination Folder"
        )
        panel.prompt = AppLanguage.localized("移动", english: "Move")
        panel.message = AppLanguage.localized(
            "文件将从原位置移动到你选择的文件夹。",
            english: "The file will move from its current location to the folder you choose."
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let destinationURL = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let destinationFileURL = destinationURL.appendingPathComponent(file.name)
                if self.indexedSource(containing: destinationFileURL) == nil {
                    guard self.confirmMoveOutsideIndexedSources(fileName: file.name) else { return }
                }
                await self.move(file, to: destinationURL)
            }
        }
    }

    private func confirmMoveOutsideIndexedSources(fileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLanguage.localized(
            "移出已授权文件夹？",
            english: "Move Outside Indexed Folders?"
        )
        alert.informativeText = AppLanguage.localized(
            "“\(fileName)”将离开寻简已授权的文件夹，分类关联无法保留，文件也不会再出现在搜索结果中。",
            english: "“\(fileName)” will leave XunJian’s authorized folders. Category links cannot be kept, and the file will no longer appear in search."
        )
        alert.addButton(withTitle: AppLanguage.localized("仍然移动", english: "Move Anyway"))
        alert.addButton(withTitle: AppLanguage.localized("取消", english: "Cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmTrash(_ file: IndexedFile) {
        guard isDatabaseAvailable, let database else {
            onError?(FileIndexError.databaseUnavailable.localizedDescription)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let categoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
                let originalParentIdentity = try await fileOperations.directoryIdentity(
                    of: file.url.deletingLastPathComponent()
                )
                if let trashURL = try await fileOperations.moveToTrash(indexedFile: file) {
                    let identity = try await fileOperations.identity(of: trashURL)
                    // Keep one undo hop so an accidental delete can be
                    // reversed without digging through the Trash. Also pushed
                    // onto the general stack so ⌘Z covers it (N16).
                    let entryID = recordTrashUndo(
                        items: [
                            TrashUndo.Item(
                                trashURL: trashURL,
                                originalURL: file.url,
                                identity: identity,
                                originalParentIdentity: originalParentIdentity,
                                originalFileID: file.id,
                                sourceID: file.sourceID,
                                categoryIDs: categoryIDs
                            )
                        ]
                    )
                    lastTrashUndo = TrashUndo(items: [
                        TrashUndo.Item(
                            trashURL: trashURL,
                            originalURL: file.url,
                            identity: identity,
                            originalParentIdentity: originalParentIdentity,
                            originalFileID: file.id,
                            sourceID: file.sourceID,
                            categoryIDs: categoryIDs
                        )
                    ], undoEntryID: entryID)
                }
                await forgetFiles([file])
                onFilesChanged?()
                await reconcileKnownFileChanges([file.url])
            } catch {
                onError?(Self.message(for: error))
            }
        }
    }

    /// Undo the most recent move-to-Trash by putting the item back.
    func undoLastTrash() {
        guard let undo = lastTrashUndo else { return }
        lastTrashUndo = nil
        // Drop the twin stack entry, otherwise ⌘Z would try to restore an
        // item that is already back in place.
        undo.undoEntryID.map { undoCoordinator?.remove($0) }
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for item in undo.items {
                do {
                    try await restoreFromTrash(
                        trashURL: item.trashURL,
                        originalURL: item.originalURL,
                        identity: item.identity,
                        originalParentIdentity: item.originalParentIdentity,
                        originalFileID: item.originalFileID,
                        categoryIDs: item.categoryIDs
                    )
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                onError?(AppLanguage.localized(
                    "有 \(failed) 个文件未能从废纸篓恢复。",
                    english: "\(failed) file(s) couldn’t be restored from the Trash."
                ))
            }
        }
    }

    func dismissTrashUndoBanner() {
        lastTrashUndo = nil
    }

    private func recordTrashUndo(items: [TrashUndo.Item]) -> UUID? {
        guard !items.isEmpty else { return nil }
        return undoCoordinator?.record(
            title: UndoCoordinator.trashTitle,
            affectedSourceIDs: Set(items.map(\.sourceID))
        ) { [weak self] in
            guard let self else { return }
            // Clears the one-hop banner so it cannot restore the same items a
            // second time after ⌘Z already did.
            if lastTrashUndo?.items == items {
                lastTrashUndo = nil
            }
            var failed = 0
            for item in items {
                do {
                    try await restoreFromTrash(
                        trashURL: item.trashURL,
                        originalURL: item.originalURL,
                        identity: item.identity,
                        originalParentIdentity: item.originalParentIdentity,
                        originalFileID: item.originalFileID,
                        categoryIDs: item.categoryIDs
                    )
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                throw FileIndexError.database(AppLanguage.localized(
                    "有 \(failed) 个文件未能从废纸篓恢复。",
                    english: "\(failed) file(s) couldn’t be restored from the Trash."
                ))
            }
        }
    }

    /// One stack entry for the whole batch. Individual failures are surfaced
    /// rather than aborting, so a partially restorable batch still recovers
    /// everything it can.
    private func recordBatchTrashUndo(
        _ trashed: [(
            trashURL: URL,
            originalURL: URL,
            identity: FileSystemObjectIdentity,
            originalParentIdentity: FileSystemObjectIdentity,
            originalFileID: String,
            sourceID: UUID,
            categoryIDs: Set<UUID>
        )]
    ) {
        let items = trashed.map {
            TrashUndo.Item(
                trashURL: $0.trashURL,
                originalURL: $0.originalURL,
                identity: $0.identity,
                originalParentIdentity: $0.originalParentIdentity,
                originalFileID: $0.originalFileID,
                sourceID: $0.sourceID,
                categoryIDs: $0.categoryIDs
            )
        }
        guard !items.isEmpty else { return }
        let entryID = recordTrashUndo(items: items)
        lastTrashUndo = TrashUndo(items: items, undoEntryID: entryID)
    }

    private func restoreFromTrash(
        trashURL: URL,
        originalURL: URL,
        identity: FileSystemObjectIdentity,
        originalParentIdentity: FileSystemObjectIdentity,
        originalFileID: String,
        categoryIDs: Set<UUID>
    ) async throws {
        guard FileManager.default.fileExists(atPath: trashURL.path) else {
            throw FileIndexError.database(AppLanguage.localized(
                "无法从废纸篓恢复：项目已不在废纸篓中。",
                english: "Cannot restore from the Trash: the item is no longer there."
            ))
        }
        let restoredURL = try await fileOperations.move(
            fileAt: trashURL,
            expectedIdentity: identity,
            expectedDestinationIdentity: originalParentIdentity,
            to: originalURL.deletingLastPathComponent()
        )
        try await reconcileRestoredIndexedFile(
            at: restoredURL,
            replacingFileID: originalFileID,
            preserving: categoryIDs
        )
        onFilesChanged?()
    }

    /// Reindexes a file restored by Undo and reattaches the metadata captured
    /// before the destructive operation in the same SQLite transaction.
    private func reconcileRestoredIndexedFile(
        at restoredURL: URL,
        replacingFileID sourceFileID: String,
        preserving categoryIDs: Set<UUID>
    ) async throws {
        guard let database,
              let source = indexedSource(containing: restoredURL) else {
            throw FileIndexError.databaseUnavailable
        }
        await syncScanExclusions()
        let snapshot = try await scanner.scanChanges(
            sourceID: source.id,
            rootURL: source.url,
            events: [
                FileSystemChangeEvent(
                    path: restoredURL.path,
                    kinds: [.created, .renamed],
                    isDirectory: false
                )
            ],
            includesHiddenFiles: includesHiddenFiles,
            extractsText: FileIndexPreferences.indexesFileContents
        )
        guard snapshot.failedScopes.isEmpty,
              let restoredFile = snapshot.files.first(where: {
                  FilePathCanonicalizer.path($0.url)
                      == FilePathCanonicalizer.path(restoredURL)
              }) else {
            throw FileIndexError.unreadableFolder(restoredURL.lastPathComponent)
        }
        try await database.reconcileMovedFile(
            fromFile: sourceFileID,
            to: restoredFile,
            preserving: categoryIDs
        )
        await refreshFiles(
            upsertedFileIDs: [restoredFile.id],
            removedFileIDs: sourceFileID == restoredFile.id ? [] : [sourceFileID]
        )
        onFileResolved?(restoredURL)
    }

    // MARK: - Categories

    func createCategory(name: String, symbolName: String) async throws {
        guard let database else { throw FileIndexError.databaseUnavailable }
        _ = try await database.createCategory(name: name, symbolName: symbolName)
        await refreshCategories(refetchingLinks: false)
    }

    func renameCategory(_ category: FileCategory, to name: String) async throws {
        guard let database else { throw FileIndexError.databaseUnavailable }
        try await database.renameCategory(category.id, to: name)
        await refreshCategories(refetchingLinks: false)
    }

    func deleteCategory(_ category: FileCategory) {
        guard let database else { return reportDatabaseUnavailable() }
        Task { [weak self] in
            do {
                let fileIDs = try await database.deleteCategory(category.id)
                await self?.refreshCategories(refetchingLinks: true)
                let affectedSourceIDs = Set(fileIDs.compactMap {
                    self?.file(id: $0)?.sourceID
                })
                self?.undoCoordinator?.record(
                    title: UndoCoordinator.deleteCategoryTitle,
                    affectedSourceIDs: affectedSourceIDs
                ) { [weak self] in
                    try await self?.restoreDeletedCategory(category, fileIDs: fileIDs)
                }
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
    }

    private func restoreDeletedCategory(
        _ category: FileCategory,
        fileIDs: [String]
    ) async throws {
        guard let database else { throw FileIndexError.databaseUnavailable }
        try await database.restoreCategory(category, fileIDs: fileIDs)
        await refreshCategories(refetchingLinks: true)
    }

    func toggleCategory(_ category: FileCategory, for file: IndexedFile) {
        let key = FileCategoryAssignmentKey(fileID: file.id, categoryID: category.id)
        let existing = pendingCategoryAssignments[key]
        let shouldAssign = Self.categoryAssignmentAfterToggle(
            persistedAssignment: isCategory(category, assignedTo: file),
            pendingAssignment: existing?.desiredAssignment
        )
        setCategory(category, assigned: shouldAssign, for: file)
    }

    /// Explicit (non-toggling) assignment, used by single-file menus and
    /// multi-select batch operations alike.
    ///
    /// `recordsUndo` is false for the individual writes inside a batch, which
    /// registers one combined entry instead of one per file.
    func setCategory(
        _ category: FileCategory,
        assigned: Bool,
        for file: IndexedFile,
        recordsUndo: Bool = true
    ) {
        guard let database else { return reportDatabaseUnavailable() }
        let key = FileCategoryAssignmentKey(fileID: file.id, categoryID: category.id)
        let existing = pendingCategoryAssignments[key]
        guard assigned != isCategory(category, assignedTo: file) || existing != nil else {
            return
        }
        pendingCategoryAssignments[key] = PendingCategoryAssignment(
            desiredAssignment: assigned,
            revision: (existing?.revision ?? 0) &+ 1,
            recordsUndo: recordsUndo
        )
        applyCategoryAssignment(assigned, for: key)

        guard categoryMutationTasks[key] == nil else { return }
        categoryMutationTasks[key] = Task { [weak self] in
            await self?.drainCategoryAssignments(for: key, database: database)
        }
    }

    /// Batch: add every file to a category. Files already in it are skipped.
    func addCategory(_ category: FileCategory, toFiles files: [IndexedFile]) {
        applyBatchCategory(category, assigned: true, to: files)
    }

    /// Batch: remove every file from a category.
    func removeCategory(_ category: FileCategory, fromFiles files: [IndexedFile]) {
        applyBatchCategory(category, assigned: false, to: files)
    }

    /// Undo only reverses the files this call actually changed, so files that
    /// were already in the category are left untouched when reverting.
    private func applyBatchCategory(
        _ category: FileCategory,
        assigned: Bool,
        to files: [IndexedFile],
        recordsUndo: Bool = true
    ) {
        guard let database else { return reportDatabaseUnavailable() }
        let changed = files.filter { isCategory(category, assignedTo: $0) != assigned }
        guard !changed.isEmpty else { return }

        var links = fileCategoryLinks
        for file in changed {
            if assigned {
                links[file.id, default: []].insert(category.id)
            } else {
                links[file.id]?.remove(category.id)
                if links[file.id]?.isEmpty == true {
                    links.removeValue(forKey: file.id)
                }
            }
        }
        isBatchingIndexReload = true
        fileCategoryLinks = links
        isBatchingIndexReload = false
        patchCategoryDerivedIndexes(assigned: assigned, files: changed, category: category)

        let changes = changed.map {
            AIClassificationChange(fileID: $0.id, categoryID: category.id)
        }
        let previousTask = batchCategoryMutationTask
        batchCategoryMutationTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await database.setCategories(changes, assigned: assigned)
                if recordsUndo {
                    self.undoCoordinator?.record(
                        title: UndoCoordinator.batchCategoryTitle,
                        affectedSourceIDs: Set(changed.map(\.sourceID))
                    ) { [weak self] in
                        self?.applyBatchCategory(
                            category,
                            assigned: !assigned,
                            to: changed,
                            recordsUndo: false
                        )
                    }
                }
                self.refreshActiveSearchIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                self.onError?(Self.message(for: error))
                await self.reloadIndex()
            }
        }
    }

    /// Batch: move all files to the Trash. Used by multi-select.
    func confirmBatchTrash(_ files: [IndexedFile]) {
        Task { [weak self] in
            do {
                try await self?.performBatchTrash(
                    files,
                    requiredDuplicateHash: nil,
                    duplicateKeeper: nil
                )
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
    }

    /// Duplicate cleanup has its own explicit confirmation. Re-hash the whole
    /// group after that confirmation and each deletion candidate again directly
    /// before moving it, so stale scan results cannot delete a unique file.
    func confirmDuplicateTrash(_ group: DuplicateGroup) async throws {
        guard let keeper = DuplicateCleanup.fileToKeep(in: group.files),
              try await DuplicateFileFinder.stillMatches(group) else {
            throw duplicateContentChangedError()
        }
        try await performBatchTrash(
            DuplicateCleanup.filesToTrash(keepingNewestIn: group.files),
            requiredDuplicateHash: group.hash,
            duplicateKeeper: keeper
        )
    }

    private func performBatchTrash(
        _ files: [IndexedFile],
        requiredDuplicateHash: String?,
        duplicateKeeper: IndexedFile?
    ) async throws {
        guard isDatabaseAvailable, let database else {
            throw FileIndexError.databaseUnavailable
        }
        let categoryLinks = try await database.fetchFileCategoryLinks(
            fileIDs: files.map(\.id)
        )
        var failed = 0
        var duplicateFailure: Error?
        var trashed: [(
            trashURL: URL,
            originalURL: URL,
            identity: FileSystemObjectIdentity,
            originalParentIdentity: FileSystemObjectIdentity,
            originalFileID: String,
            sourceID: UUID,
            categoryIDs: Set<UUID>
        )] = []
        for file in files {
            do {
                let originalParentIdentity = try await fileOperations.directoryIdentity(
                    of: file.url.deletingLastPathComponent()
                )
                let trashURL: URL?
                if let requiredDuplicateHash, let duplicateKeeper {
                    let keeperFingerprint = try await DuplicateFileFinder.fingerprint(
                        fileAt: duplicateKeeper.url
                    )
                    let candidateFingerprint = try await DuplicateFileFinder.fingerprint(
                        fileAt: file.url
                    )
                    guard keeperFingerprint.digest == requiredDuplicateHash,
                          candidateFingerprint.digest == requiredDuplicateHash else {
                        throw duplicateContentChangedError()
                    }
                    trashURL = try await fileOperations.moveDuplicateToTrash(
                        indexedFile: file,
                        expectedVersion: candidateFingerprint.version,
                        matching: duplicateKeeper.url,
                        expectedReferenceVersion: keeperFingerprint.version
                    )
                } else {
                    trashURL = try await fileOperations.moveToTrash(indexedFile: file)
                }
                if let trashURL {
                    let identity = try await fileOperations.identity(of: trashURL)
                    trashed.append((
                        trashURL,
                        file.url,
                        identity,
                        originalParentIdentity,
                        file.id,
                        file.sourceID,
                        categoryLinks[file.id] ?? []
                    ))
                }
            } catch {
                failed += 1
                if requiredDuplicateHash != nil {
                    duplicateFailure = error
                    break
                }
            }
        }
        recordBatchTrashUndo(trashed)
        if failed > 0, requiredDuplicateHash == nil {
            onError?(AppLanguage.localized(
                "有 \(failed) 个文件未能移到废纸篓。",
                english: "\(failed) file(s) couldn’t be moved to the Trash."
            ))
        }
        let trashedPaths = Set(trashed.map { FilePathCanonicalizer.path($0.originalURL) })
        await forgetFiles(
            files.filter { trashedPaths.contains(FilePathCanonicalizer.path($0.url)) }
        )
        let paths = trashed.map(\.originalURL)
        onFilesChanged?()
        await reconcileKnownFileChanges(paths)
        if let duplicateFailure {
            throw duplicateFailure
        }
    }

    private func duplicateContentChangedError() -> FileIndexError {
        .database(AppLanguage.localized(
            "重复文件内容已经变化，请重新检测后再清理。",
            english: "The duplicate files changed. Run duplicate detection again before cleaning up."
        ))
    }

    static func categoryAssignmentAfterToggle(
        persistedAssignment: Bool,
        pendingAssignment: Bool?
    ) -> Bool {
        !(pendingAssignment ?? persistedAssignment)
    }

    private func drainCategoryAssignments(
        for key: FileCategoryAssignmentKey,
        database: FileIndexDatabase
    ) async {
        while !Task.isCancelled, let pending = pendingCategoryAssignments[key] {
            do {
                try await database.setCategory(
                    key.categoryID,
                    assigned: pending.desiredAssignment,
                    toFile: key.fileID
                )
                if pending.recordsUndo,
                   let category = categories.first(where: { $0.id == key.categoryID }),
                   let file = file(id: key.fileID) {
                    undoCoordinator?.record(
                        title: UndoCoordinator.categoryTitle(
                            assigned: pending.desiredAssignment
                        ),
                        affectedSourceIDs: [file.sourceID]
                    ) { [weak self] in
                        self?.setCategory(
                            category,
                            assigned: !pending.desiredAssignment,
                            for: file,
                            recordsUndo: false
                        )
                    }
                }
                refreshActiveSearchIfNeeded()
                guard pendingCategoryAssignments[key]?.revision == pending.revision else {
                    if let newest = pendingCategoryAssignments[key] {
                        applyCategoryAssignment(newest.desiredAssignment, for: key)
                    }
                    continue
                }
                pendingCategoryAssignments.removeValue(forKey: key)
                applyCategoryAssignment(pending.desiredAssignment, for: key)
            } catch is CancellationError {
                break
            } catch {
                if pendingCategoryAssignments[key]?.revision == pending.revision {
                    pendingCategoryAssignments.removeValue(forKey: key)
                }
                onError?(Self.message(for: error))
                await reloadIndex()
                if let newest = pendingCategoryAssignments[key] {
                    applyCategoryAssignment(newest.desiredAssignment, for: key)
                    continue
                }
            }
        }
        categoryMutationTasks.removeValue(forKey: key)
    }

    private func applyCategoryAssignment(
        _ assigned: Bool,
        for key: FileCategoryAssignmentKey
    ) {
        var links = fileCategoryLinks
        if assigned {
            links[key.fileID, default: []].insert(key.categoryID)
        } else {
            links[key.fileID]?.remove(key.categoryID)
            if links[key.fileID]?.isEmpty == true {
                links.removeValue(forKey: key.fileID)
            }
        }
        isBatchingIndexReload = true
        fileCategoryLinks = links
        isBatchingIndexReload = false
        patchCategoryDerivedIndexes(assigned: assigned, for: key)
    }

    /// Updates one file's category caches without scanning the whole library.
    private func patchCategoryDerivedIndexes(
        assigned: Bool,
        for key: FileCategoryAssignmentKey
    ) {
        guard let file = filesByID[key.fileID],
              let category = categories.first(where: { $0.id == key.categoryID }) else {
            rebuildCategoryDerivedIndexes()
            return
        }

        let assignedIDs = fileCategoryLinks[key.fileID] ?? []
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        if assignedIDs.isEmpty {
            categoriesByFileID.removeValue(forKey: key.fileID)
        } else {
            categoriesByFileID[key.fileID] = assignedIDs.compactMap { categoryByID[$0] }
        }
        var list = filesByCategoryID[key.categoryID] ?? []
        if assigned {
            if !list.contains(where: { $0.id == file.id }) {
                list.append(file)
            }
        } else {
            list.removeAll { $0.id == file.id }
        }
        filesByCategoryID[key.categoryID] = list
        fileCountsByCategoryID[key.categoryID] = list.count
        categoryRevision &+= 1
        categoryIndexStore.applyAssignment(assigned: assigned, file: file, category: category)
    }

    /// Updates one category for a batch without repeatedly scanning its file list.
    private func patchCategoryDerivedIndexes(
        assigned: Bool,
        files changedFiles: [IndexedFile],
        category: FileCategory
    ) {
        guard !changedFiles.isEmpty else { return }
        let changedIDs = Set(changedFiles.map(\.id))
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        for file in changedFiles {
            let assignedIDs = fileCategoryLinks[file.id] ?? []
            if assignedIDs.isEmpty {
                categoriesByFileID.removeValue(forKey: file.id)
            } else {
                categoriesByFileID[file.id] = assignedIDs.compactMap { categoryByID[$0] }
            }
        }

        var categoryFiles = filesByCategoryID[category.id] ?? []
        if assigned {
            var existingIDs = Set(categoryFiles.map(\.id))
            for file in changedFiles where existingIDs.insert(file.id).inserted {
                categoryFiles.append(file)
            }
        } else {
            categoryFiles.removeAll { changedIDs.contains($0.id) }
        }
        filesByCategoryID[category.id] = categoryFiles
        fileCountsByCategoryID[category.id] = categoryFiles.count
        categoryRevision &+= 1
        categoryIndexStore.applyAssignments(
            assigned: assigned,
            files: changedFiles,
            category: category
        )
    }

    // MARK: - Source management

    /// Adds a folder as a scan source, e.g. dropped onto the Settings view.
    func addSource(_ url: URL) async {
        guard let database else { return reportDatabaseUnavailable() }

        do {
            try Self.validateSourceCandidate(url, against: sources)
            let bookmark = try bookmarkManager.createBookmark(for: url)
            let source = try await database.upsertSource(
                displayName: url.lastPathComponent,
                path: Self.canonicalSourceURL(url).path,
                bookmark: bookmark
            )
            await refreshSources()
            scanSource(source)
        } catch {
            onError?(Self.message(for: error))
        }
    }

    static func validateSourceCandidate(
        _ candidateURL: URL,
        against existingSources: [FileSource],
        excluding sourceID: UUID? = nil
    ) throws {
        let candidateURL = canonicalSourceURL(candidateURL)
        for source in existingSources where source.id != sourceID {
            let existingURL = canonicalSourceURL(source.url)
            guard sourceURLsOverlap(candidateURL, existingURL) else { continue }
            throw FileIndexError.overlappingSource(source.displayName)
        }
    }

    private static func canonicalSourceURL(_ url: URL) -> URL {
        let path = url.resolvingSymlinksInPath()
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func sourceURLsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count >= ancestorComponents.count else { return false }
        return candidateComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private func restoreAuthorization(for source: FileSource, using url: URL) async {
        guard let database else { return reportDatabaseUnavailable() }

        do {
            try Self.validateSourceCandidate(
                url,
                against: sources,
                excluding: source.id
            )
            let selectedPath = Self.canonicalSourceURL(url).path
            let bookmark = try bookmarkManager.createBookmark(for: url)
            try await database.updateBookmark(
                for: source.id,
                bookmark: bookmark,
                path: selectedPath
            )
            await refreshSources()
            if let refreshedSource = sources.first(where: { $0.id == source.id }) {
                scanSource(refreshedSource)
            }
        } catch {
            onError?(Self.message(for: error))
        }
    }

    private func move(_ file: IndexedFile, to destinationURL: URL) async {
        guard let database else {
            onError?(FileIndexError.databaseUnavailable.localizedDescription)
            return
        }
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        guard didAccess else {
            onError?(FileIndexError.unreadableFolder(destinationURL.lastPathComponent).localizedDescription)
            return
        }
        defer { destinationURL.stopAccessingSecurityScopedResource() }

        var physicallyMovedURL: URL?
        var movedIdentityForUndo: FileSystemObjectIdentity?
        var originalParentIdentityForUndo: FileSystemObjectIdentity?
        var categoryIDsForUndo: Set<UUID> = []
        var didRecordUndo = false
        do {
            let categoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
            categoryIDsForUndo = categoryIDs
            let originalParentIdentity = try await fileOperations.directoryIdentity(
                of: file.url.deletingLastPathComponent()
            )
            originalParentIdentityForUndo = originalParentIdentity
            var indexedFileIDAtMovedLocation = file.id
            let movedURL = try await fileOperations.move(
                indexedFile: file,
                to: destinationURL
            )
            guard FilePathCanonicalizer.path(movedURL) != FilePathCanonicalizer.path(file.url) else {
                return
            }
            let movedIdentity = try await fileOperations.identity(of: movedURL)
            movedIdentityForUndo = movedIdentity
            physicallyMovedURL = movedURL

            if let destinationSource = indexedSource(containing: movedURL) {
                await syncScanExclusions()
                let snapshot = try await scanner.scanChanges(
                    sourceID: destinationSource.id,
                    rootURL: destinationSource.url,
                    events: [
                        FileSystemChangeEvent(
                            path: movedURL.path,
                            kinds: [.created, .renamed],
                            isDirectory: false
                        )
                    ],
                    includesHiddenFiles: includesHiddenFiles,
                    extractsText: FileIndexPreferences.indexesFileContents
                )
                if !snapshot.failedScopes.isEmpty {
                    throw FileIndexError.unreadableFolder(movedURL.lastPathComponent)
                }

                if let movedFile = snapshot.files.first(where: {
                    FilePathCanonicalizer.path($0.url) == FilePathCanonicalizer.path(movedURL)
                }) {
                    indexedFileIDAtMovedLocation = movedFile.id
                    try await database.reconcileMovedFile(
                        fromFile: file.id,
                        to: movedFile,
                        preserving: categoryIDs
                    )
                    await refreshFiles(
                        upsertedFileIDs: [movedFile.id],
                        removedFileIDs: [file.id]
                    )
                } else {
                    // Hidden/excluded destinations intentionally leave the searchable index.
                    await reconcileKnownFileChanges([file.url, movedURL])
                    await forgetFiles([file])
                }
            } else {
                await reconcileKnownFileChanges([file.url, movedURL])
                await forgetFiles([file])
            }
            onFileResolved?(movedURL)
            didRecordUndo = recordMoveUndo(
                movedURL: movedURL,
                originalURL: file.url,
                identity: movedIdentity,
                originalParentIdentity: originalParentIdentity,
                indexedFileIDAtMovedLocation: indexedFileIDAtMovedLocation,
                affectedSourceIDs: Set(
                    [file.sourceID] + [indexedSource(containing: movedURL)?.id].compactMap { $0 }
                ),
                categoryIDs: categoryIDs
            )
        } catch {
            if let physicallyMovedURL {
                if !didRecordUndo,
                   let movedIdentityForUndo,
                   let originalParentIdentityForUndo {
                    didRecordUndo = recordMoveUndo(
                        movedURL: physicallyMovedURL,
                        originalURL: file.url,
                        identity: movedIdentityForUndo,
                        originalParentIdentity: originalParentIdentityForUndo,
                        indexedFileIDAtMovedLocation: file.id,
                        affectedSourceIDs: Set(
                            [file.sourceID] + [indexedSource(containing: physicallyMovedURL)?.id]
                                .compactMap { $0 }
                        ),
                        categoryIDs: categoryIDsForUndo
                    )
                }
                let message = didRecordUndo
                    ? AppLanguage.localized(
                        "文件已移动到“\(physicallyMovedURL.lastPathComponent)”，但索引更新失败。可先撤销移动，再重新扫描。",
                        english: "The file moved to “\(physicallyMovedURL.lastPathComponent)”, but its index could not be updated. You can undo the move, then rescan."
                    )
                    : AppLanguage.localized(
                        "文件已移动到“\(physicallyMovedURL.lastPathComponent)”，但索引更新失败。请检查文件位置后重新扫描。",
                        english: "The file moved to “\(physicallyMovedURL.lastPathComponent)”, but its index could not be updated. Check its location, then rescan."
                    )
                onError?(message)
            } else {
                onError?(Self.message(for: error))
            }
        }
    }

    /// Registers the inverse move. The original folder is inside an authorized
    /// source, so its security scope is already held; the destination scope
    /// came from a one-off panel grant and is not needed to move back out.
    @discardableResult
    private func recordMoveUndo(
        movedURL: URL,
        originalURL: URL,
        identity: FileSystemObjectIdentity,
        originalParentIdentity: FileSystemObjectIdentity,
        indexedFileIDAtMovedLocation: String,
        affectedSourceIDs: Set<UUID>,
        categoryIDs: Set<UUID>
    ) -> Bool {
        let originalDirectory = originalURL.deletingLastPathComponent()
        guard let undoCoordinator else { return false }
        undoCoordinator.record(
            title: UndoCoordinator.moveTitle,
            affectedSourceIDs: affectedSourceIDs
        ) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: movedURL.path) else {
                throw FileIndexError.database(AppLanguage.localized(
                    "无法撤销移动：文件已不在“\(movedURL.lastPathComponent)”。",
                    english: "Cannot undo the move: the file is no longer at “\(movedURL.lastPathComponent)”."
                ))
            }
            let restoredURL = try await fileOperations.move(
                fileAt: movedURL,
                expectedIdentity: identity,
                expectedDestinationIdentity: originalParentIdentity,
                to: originalDirectory
            )
            try await reconcileRestoredIndexedFile(
                at: restoredURL,
                replacingFileID: indexedFileIDAtMovedLocation,
                preserving: categoryIDs
            )
        }
        return true
    }

    /// Applied before every scan so a preference change takes effect on the
    /// next scan without needing to rebuild the scanner.
    private func syncScanExclusions() async {
        await scanner.setAdditionalExcludedNames(Set(ScanExclusions.current()))
    }

    private func indexedSource(containing url: URL) -> FileSource? {
        let path = FilePathCanonicalizer.path(url)
        return sources
            .filter { source in
                guard source.accessState == .available else { return false }
                let rootPath = FilePathCanonicalizer.path(source.url)
                let candidateComponents = URL(fileURLWithPath: path).pathComponents
                let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
                return candidateComponents.count >= rootComponents.count
                    && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
            }
            .max { $0.path.count < $1.path.count }
    }

    // MARK: - Scanning

    private func performScan(
        _ source: FileSource,
        keepsScanningState: Bool = false,
        generation: UUID
    ) async {
        guard let database else { return reportDatabaseUnavailable() }
        let contentScanID = UUID()
        var hasStagedTextContents = false
        var didReplaceFiles = false
        isScanning = true
        scanProgressStore.update(scopedProgress(
            ScanProgress(discoveredCount: 0, currentPath: source.path),
            sourceID: source.id
        ))

        do {
            let restored = try bookmarkManager.resolveBookmark(source.bookmark)
            if restored.isStale {
                let refreshedBookmark = try bookmarkManager.createBookmark(for: restored.url)
                try await database.updateBookmark(
                    for: source.id,
                    bookmark: refreshedBookmark,
                    path: restored.url.standardizedFileURL.path
                )
            }

            let didAccess = restored.url.startAccessingSecurityScopedResource()
            guard didAccess else {
                markSourceNeedsAuthorization(source.id)
                throw FileIndexError.bookmarkResolution
            }
            defer {
                restored.url.stopAccessingSecurityScopedResource()
            }

            await syncScanExclusions()
            let indexesFileContents = FileIndexPreferences.indexesFileContents
            let excludedNames = ScanExclusions.builtIn.union(ScanExclusions.current())
            let existingSourceFiles = try await database.fetchFiles(forSourceID: source.id)
            let forcesFullTextExtraction = pendingFullTextExtractionSourceIDs.contains(source.id)
            let includesHiddenFiles = self.includesHiddenFiles
            // Path-only comparison off the main actor: the root is
            // canonicalized once, and the stored file paths are already
            // canonical. Previously this pass re-resolved every existing
            // file (two syscalls each) on the main actor before each scan.
            let canonicalRootPath = FilePathCanonicalizer.path(restored.url)
            let preservedUnscannedFileIDs = await Task.detached(priority: .utility) {
                Set(existingSourceFiles.lazy.filter {
                    Self.shouldPreserveUnscannedFile(
                        $0,
                        canonicalSourceRootPath: canonicalRootPath,
                        includesHiddenFiles: includesHiddenFiles,
                        excludedDirectoryNames: excludedNames
                    )
                }.map(\.id))
            }.value
            let scannedFiles = try await scanner.scan(
                sourceID: source.id,
                rootURL: restored.url,
                includesHiddenFiles: includesHiddenFiles,
                extractsText: false
            ) { [weak self] progress in
                Task { @MainActor in
                    guard self?.scanGeneration == generation else { return }
                    self?.scanProgressStore.update(
                        self?.scopedProgress(progress, sourceID: source.id)
                    )
                }
            }
            try Task.checkCancellation()
            guard scanGeneration == generation,
                  scanningSourceIDs.contains(source.id) else { return }
            let filesRequiringTextRefresh = Self.filesRequiringTextRefresh(
                scannedFiles: scannedFiles,
                existingFiles: existingSourceFiles,
                forcesFullRefresh: forcesFullTextExtraction
            )
            try await database.replaceFiles(
                for: source.id,
                with: scannedFiles,
                deletesUnscanned: true,
                preservesExistingText: indexesFileContents,
                preservedUnscannedFileIDs: preservedUnscannedFileIDs
            )
            didReplaceFiles = true
            await FinderTagService.shared.invalidateAll()
            guard scanGeneration == generation else {
                await reloadIndex()
                return
            }
            await reloadIndex()

            if indexesFileContents && (forcesFullTextExtraction || !filesRequiringTextRefresh.isEmpty) {
                hasStagedTextContents = true
                if !forcesFullTextExtraction {
                    try await database.stageTextContents(
                        filesRequiringTextRefresh.map {
                            FileTextContentUpdate(fileID: $0.id, textContent: nil)
                        },
                        scanID: contentScanID
                    )
                }
                try await scanner.extractTextContents(
                    in: forcesFullTextExtraction ? scannedFiles : filesRequiringTextRefresh,
                    consume: { updates in
                        try Task.checkCancellation()
                        try await database.stageTextContents(updates, scanID: contentScanID)
                    },
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            guard self?.scanGeneration == generation else { return }
                            self?.scanProgressStore.update(
                                self?.scopedProgress(progress, sourceID: source.id)
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard scanGeneration == generation else { throw CancellationError() }
                if forcesFullTextExtraction {
                    try await database.commitStagedTextContents(
                        scanID: contentScanID,
                        sourceID: source.id,
                        preservedUnscannedFileIDs: preservedUnscannedFileIDs
                    )
                    pendingFullTextExtractionSourceIDs.remove(source.id)
                    if pendingFullTextExtractionSourceIDs.isEmpty {
                        isUpdatingContentIndex = false
                    }
                } else {
                    try await database.commitStagedTextContentUpdates(scanID: contentScanID)
                }
                hasStagedTextContents = false
                refreshActiveSearchIfNeeded()
            }
        } catch is CancellationError {
            if hasStagedTextContents {
                try? await database.discardStagedTextContents(scanID: contentScanID)
            }
            if didReplaceFiles {
                await reloadIndex()
            }
            // Metadata may already be current, but searchable content remains
            // the previous complete snapshot until a full extraction commits.
        } catch {
            if hasStagedTextContents {
                try? await database.discardStagedTextContents(scanID: contentScanID)
            }
            guard scanGeneration == generation else { return }
            failedScanningSourceIDs.insert(source.id)
            onError?(Self.message(for: error))
            await reloadIndex()
        }

        if !keepsScanningState {
            finishScan(generation: generation)
        }
    }

    nonisolated static func shouldPreserveUnscannedFile(
        _ file: IndexedFile,
        sourceRoot: URL,
        includesHiddenFiles: Bool,
        excludedDirectoryNames: Set<String>
    ) -> Bool {
        shouldPreserveUnscannedFile(
            file,
            canonicalSourceRootPath: FilePathCanonicalizer.path(sourceRoot),
            includesHiddenFiles: includesHiddenFiles,
            excludedDirectoryNames: excludedDirectoryNames
        )
    }

    nonisolated static func filesRequiringTextRefresh(
        scannedFiles: [IndexedFile],
        existingFiles: [IndexedFile],
        forcesFullRefresh: Bool
    ) -> [IndexedFile] {
        guard !forcesFullRefresh else { return scannedFiles }
        let existingByID = Dictionary(uniqueKeysWithValues: existingFiles.map { ($0.id, $0) })
        return scannedFiles.filter { scanned in
            guard let existing = existingByID[scanned.id] else { return true }
            return scanned.size != existing.size
                || scanned.modifiedAt != existing.modifiedAt
                || scanned.fileExtension != existing.fileExtension
        }
    }

    /// Path-only comparison. The stored `file.path` is already canonical, so
    /// only the root needs canonicalizing — per-file canonicalization made
    /// every full scan pay two stat + realpath syscalls per existing file on
    /// the main actor.
    nonisolated static func shouldPreserveUnscannedFile(
        _ file: IndexedFile,
        canonicalSourceRootPath: String,
        includesHiddenFiles: Bool,
        excludedDirectoryNames: Set<String>
    ) -> Bool {
        let rootComponents = URL(
            fileURLWithPath: canonicalSourceRootPath
        ).pathComponents
        let fileComponents = URL(fileURLWithPath: file.path).pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            return false
        }
        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
        if !includesHiddenFiles,
           relativeComponents.contains(where: { $0.count > 1 && $0.hasPrefix(".") }) {
            return true
        }
        return relativeComponents.dropLast().contains {
            excludedDirectoryNames.contains($0.lowercased())
        }
    }

    private func scopedProgress(
        _ progress: ScanProgress,
        sourceID: UUID
    ) -> ScanProgress {
        let orderedIDs = sources.map(\.id).filter { scanningSourceIDs.contains($0) }
        return ScanProgress(
            discoveredCount: progress.discoveredCount,
            currentPath: progress.currentPath,
            sourceIndex: (orderedIDs.firstIndex(of: sourceID) ?? 0) + 1,
            sourceCount: max(orderedIDs.count, 1)
        )
    }

    private func finishScan(generation: UUID) {
        guard Self.scanCleanupOwnsState(
            currentGeneration: scanGeneration,
            finishingGeneration: generation
        ) else { return }
        isScanning = false
        scanProgressStore.update(nil)
        scanTask = nil
        if !failedScanningSourceIDs.isEmpty {
            let failedNames = sources
                .filter { failedScanningSourceIDs.contains($0.id) }
                .map(\.displayName)
                .joined(separator: AppLanguage.localized("、", english: ", "))
            onError?(AppLanguage.localized(
                "扫描未完成：无法读取\(failedNames)。旧索引已保留，请检查权限后重试。",
                english: "Scan incomplete: couldn’t read \(failedNames). The previous index was preserved; check permissions and retry."
            ))
        }
        // Captured before the reset below, otherwise the notification's
        // "did everything succeed?" check always saw an empty set.
        let scanSucceeded = failedScanningSourceIDs.isEmpty
        failedScanningSourceIDs.removeAll()
        let completedSourceIDs = scanningSourceIDs
        scanningSourceIDs.removeAll()
        currentScanningSourceID = nil
        schedulePendingFileChanges(for: completedSourceIDs)
        startNextPendingFullRescanIfNeeded()
        notifyScanFinished(succeeded: scanSucceeded)
    }

    /// Completion notification, opt-in via Settings. Suppressed when the scan
    /// hit unreadable locations, since an on-screen error already explains
    /// that the index is incomplete.
    private func notifyScanFinished(succeeded: Bool) {
        guard succeeded,
              UserDefaults.standard.bool(forKey: "notifications.scanComplete") else { return }
        let content = UNMutableNotificationContent()
        content.title = AppLanguage.localized(
            "索引更新完成",
            english: "Index update finished"
        )
        content.body = AppLanguage.localized(
            AppLanguage.fileCount(files.count) + "，共 \(sources.count) 个位置。",
            english: "\(files.count) files across \(sources.count) locations."
        )
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "scan-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func scanCleanupOwnsState(
        currentGeneration: UUID,
        finishingGeneration: UUID
    ) -> Bool {
        currentGeneration == finishingGeneration
    }

    private func startNextPendingFullRescanIfNeeded() {
        guard !isScanning else { return }
        while let sourceID = pendingFullRescanSourceIDs.first {
            pendingFullRescanSourceIDs.remove(sourceID)
            guard let source = sources.first(where: {
                $0.id == sourceID && $0.enabled && $0.accessState == .available
            }) else { continue }
            scanSource(source)
            return
        }
    }

    // MARK: - Filesystem monitoring

    private func configureFileSystemMonitoring() {
        let monitoredSources = sources
            .filter { $0.enabled && $0.accessState == .available }
            .map { MonitoredSource(sourceID: $0.id, rootPath: $0.path) }

        fileSystemMonitor.update(
            sources: monitoredSources,
            handler: { [weak self] sourceID, events in
                Task { @MainActor [weak self] in
                    self?.enqueueFileSystemChanges(events, for: sourceID)
                }
            },
            onFailure: { [weak self] sourceID, rootPath in
                Task { @MainActor [weak self] in
                    self?.reportMonitorRegistrationFailure(sourceID: sourceID, rootPath: rootPath)
                }
            }
        )
    }

    private func reportMonitorRegistrationFailure(sourceID: UUID, rootPath: String) {
        let name = sources.first { $0.id == sourceID }?.displayName
            ?? URL(fileURLWithPath: rootPath).lastPathComponent
        onError?(AppLanguage.localized(
            "“\(name)”无法监听文件变更，Finder 中的改动不会自动更新。请重新授权或手动重新扫描。",
            english: "“\(name)” could not be monitored for changes. Finder edits will not update automatically. Reauthorize or rescan."
        ))
        pendingFullRescanSourceIDs.insert(sourceID)
        startNextPendingFullRescanIfNeeded()
    }

    private func enqueueFileSystemChanges(
        _ events: [FileSystemChangeEvent],
        for sourceID: UUID
    ) {
        pendingFileChanges[sourceID, default: []].formUnion(events)
        fileChangeTasks[sourceID]?.cancel()
        fileChangeTasks[sourceID] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.fileChangeDebounce)
            } catch {
                return
            }
            guard let self else { return }
            await self.consumeFileSystemChanges(for: sourceID)
        }
    }

    private func consumeFileSystemChanges(for sourceID: UUID) async {
        fileChangeTasks[sourceID] = nil
        guard !Self.shouldDeferFileSystemChanges(
            scanningSourceIDs: scanningSourceIDs,
            sourceID: sourceID
        ) else { return }
        guard let events = pendingFileChanges.removeValue(forKey: sourceID),
              let source = sources.first(where: { $0.id == sourceID }) else {
            return
        }
        await applyFileSystemChanges(Array(events), to: source)
    }

    private func applyFileSystemChanges(
        _ events: [FileSystemChangeEvent],
        to source: FileSource
    ) async {
        guard let database,
              !events.isEmpty,
              Self.isSourceEligibleForScanning(source) else { return }
        guard !Self.shouldDeferFileSystemChanges(
            scanningSourceIDs: scanningSourceIDs,
            sourceID: source.id
        ) else {
            pendingFileChanges[source.id, default: []].formUnion(events)
            return
        }
        if events.contains(where: \.requiresFullRescan) {
            if Self.shouldQueueFullRescan(isScanning: isScanning) {
                pendingFullRescanSourceIDs.insert(source.id)
            } else {
                scanSource(source)
            }
            return
        }

        do {
            let restored = try bookmarkManager.resolveBookmark(source.bookmark)
            let didAccess = restored.url.startAccessingSecurityScopedResource()
            guard didAccess else {
                markSourceNeedsAuthorization(source.id)
                throw FileIndexError.bookmarkResolution
            }
            defer {
                restored.url.stopAccessingSecurityScopedResource()
            }

            await syncScanExclusions()
            let snapshot = try await scanner.scanChanges(
                sourceID: source.id,
                rootURL: restored.url,
                events: events,
                includesHiddenFiles: includesHiddenFiles,
                extractsText: FileIndexPreferences.indexesFileContents
            )
            guard !Self.shouldDeferFileSystemChanges(
                scanningSourceIDs: scanningSourceIDs,
                sourceID: source.id
            ) else {
                pendingFileChanges[source.id, default: []].formUnion(events)
                return
            }
            var removedFileIDs = Set<String>()
            if !snapshot.scopes.isEmpty {
                removedFileIDs = try await database.reconcileFiles(
                    for: source.id,
                    scopes: snapshot.scopes,
                    with: snapshot.files
                )
            }
            guard !snapshot.scopes.isEmpty
                    || !snapshot.failedScopes.isEmpty else { return }
            if !snapshot.scopes.isEmpty {
                await refreshFiles(
                    upsertedFileIDs: snapshot.files.map(\.id),
                    removedFileIDs: removedFileIDs
                )
            }
            if !snapshot.failedScopes.isEmpty {
                onError?(AppLanguage.localized(
                    "“\(source.displayName)”的部分文件暂时无法读取，本次更新未完成，请稍后重新扫描。",
                    english: "Some files in “\(source.displayName)” could not be read. This update is incomplete; rescan later."
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            onError?(Self.message(for: error))
            await reloadIndex()
        }
    }

    private func reconcileKnownFileChanges(_ urls: [URL]) async {
        let events = urls.map {
            FileSystemChangeEvent(
                path: $0.path,
                kinds: [.modified, .renamed],
                isDirectory: false
            )
        }

        for source in Self.sourcesAffected(by: urls, in: sources) {
            await applyFileSystemChanges(events, to: source)
        }
    }

    private func schedulePendingFileChanges(for sourceIDs: Set<UUID>) {
        for sourceID in sourceIDs where pendingFileChanges[sourceID]?.isEmpty == false {
            enqueueFileSystemChanges([], for: sourceID)
        }
    }

    static func sourcesAffected(by urls: [URL], in sources: [FileSource]) -> [FileSource] {
        sources.filter { source in
            guard isSourceEligibleForScanning(source) else { return false }
            let rootPath = FilePathCanonicalizer.path(source.url)
            return urls.contains { url in
                let path = FilePathCanonicalizer.path(url)
                return path == rootPath
                    || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
        }
    }

    private func forgetFiles(_ filesToDrop: [IndexedFile]) async {
        let ids = Set(filesToDrop.map(\.id))
        guard !ids.isEmpty else { return }

        while !Task.isCancelled {
            let sourceFiles = files
            let sourceSearchResults = searchResults
            let sourceLinks = fileCategoryLinks
            let sourceCategories = categories
            let sourceFilesRevision = filesRevision
            let sourceCategoryRevision = categoryRevision
            let sourceSearchRevision = searchResultsRevision

            let snapshot = await Task.detached(priority: .userInitiated) {
                let remainingFiles = sourceFiles.filter { !ids.contains($0.id) }
                let remainingSearchResults = sourceSearchResults?.filter { !ids.contains($0.id) }
                var remainingLinks = sourceLinks
                for id in ids {
                    remainingLinks.removeValue(forKey: id)
                }
                return FileRemovalSnapshot(
                    files: remainingFiles,
                    searchResults: remainingSearchResults,
                    links: remainingLinks,
                    fileDerived: Self.makeFileDerivedIndexes(remainingFiles),
                    categoryDerived: Self.makeCategoryDerivedIndexes(
                        categories: sourceCategories,
                        files: remainingFiles,
                        links: remainingLinks
                    )
                )
            }.value

            guard !Task.isCancelled else { return }
            guard filesRevision == sourceFilesRevision,
                  categoryRevision == sourceCategoryRevision,
                  searchResultsRevision == sourceSearchRevision else {
                continue
            }

            isBatchingIndexReload = true
            files = snapshot.files
            fileCategoryLinks = snapshot.links
            isBatchingIndexReload = false
            publishSearchResults(snapshot.searchResults, totalCount: nil)
            apply(snapshot.fileDerived)
            apply(snapshot.categoryDerived)
            return
        }
    }

    private func handleMissingIndexedFile(_ file: IndexedFile) {
        onError?(FileOperationError.fileNotFound.localizedDescription)
        Task { [weak self] in
            guard let self else { return }
            await forgetFiles([file])
            onFilesChanged?()
            await removeMissingIndexedFile(file)
        }
    }

    private func removeMissingIndexedFile(_ file: IndexedFile) async {
        guard let database else { return }
        do {
            guard !FileManager.default.fileExists(atPath: file.path) else {
                await reloadIndex()
                return
            }
            let removedFileIDs = try await database.reconcileFiles(
                for: file.sourceID,
                scopes: [FileIndexScope(path: file.path, includesDescendants: false)],
                with: []
            )
            await refreshFiles(upsertedFileIDs: [], removedFileIDs: removedFileIDs)
        } catch {
            onError?(Self.message(for: error))
            await reloadIndex()
        }
    }

    private func activateSecurityScopes() {
        let currentSourceIDs = Set(sources.map(\.id))
        let removedSourceIDs = activeSecurityScopes.keys.filter { !currentSourceIDs.contains($0) }
        for sourceID in removedSourceIDs {
            activeSecurityScopes.removeValue(forKey: sourceID)?
                .stopAccessingSecurityScopedResource()
        }

        for index in sources.indices where sources[index].accessState == .available {
            let source = sources[index]
            guard let restored = try? bookmarkManager.resolveBookmark(source.bookmark) else {
                sources[index].accessState = .needsAuthorization
                continue
            }
            if let activeURL = activeSecurityScopes[source.id],
               activeURL.standardizedFileURL == restored.url.standardizedFileURL {
                continue
            }
            activeSecurityScopes.removeValue(forKey: source.id)?
                .stopAccessingSecurityScopedResource()
            if restored.url.startAccessingSecurityScopedResource() {
                activeSecurityScopes[source.id] = restored.url
            } else {
                sources[index].accessState = .needsAuthorization
            }
        }
    }

    private func markSourceNeedsAuthorization(_ sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].accessState = .needsAuthorization
        activeSecurityScopes.removeValue(forKey: sourceID)?
            .stopAccessingSecurityScopedResource()
        configureFileSystemMonitoring()
    }

    // MARK: - Helpers

    private func reportDatabaseUnavailable() {
        onError?(AppLanguage.localized(
            "文件索引当前不可用，请在设置中重试后再操作。",
            english: "The file index is currently unavailable. Retry from Settings and try again."
        ))
    }

    nonisolated static func isDotPrefixedFile(_ file: IndexedFile) -> Bool {
        file.url.pathComponents.contains { component in
            component.count > 1 && component.hasPrefix(".")
        }
    }

    static func shouldQueueFullRescan(isScanning: Bool) -> Bool {
        isScanning
    }

    static func shouldDeferFileSystemChanges(
        scanningSourceIDs: Set<UUID>,
        sourceID: UUID
    ) -> Bool {
        scanningSourceIDs.contains(sourceID)
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
