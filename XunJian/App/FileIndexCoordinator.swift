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
    @Published private(set) var sources: [FileSource] = []
    @Published private(set) var files: [IndexedFile] = [] {
        didSet { rebuildDerivedIndexes() }
    }
    @Published private(set) var categories: [FileCategory] = [] {
        didSet { rebuildDerivedIndexes() }
    }
    @Published private(set) var fileCategoryLinks: [String: Set<UUID>] = [:]
    @Published private(set) var savedSearches: [SavedSearch] = []
    @Published private(set) var searchResults: [IndexedFile]? = nil
    @Published private(set) var searchResultTotalCount: Int? = nil
    @Published private(set) var isSearching = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var includesHiddenFiles = false
    @Published private(set) var isDatabaseAvailable = true

    // MARK: - Hooks into the rest of the app

    var onError: ((String) -> Void)?
    var onFilesChanged: (() -> Void)?
    var onFileResolved: ((URL) -> Void)?

    /// Reversible actions are pushed here so the app can offer a general Undo
    /// (N16). Set by `AppModel`; nil in contexts that do not surface undo.
    var undoCoordinator: UndoCoordinator?

    /// One-hop undo for move-to-Trash (N10).
    struct TrashUndo: Equatable, Sendable {
        let trashURL: URL
        let originalURL: URL
    }

    @Published private(set) var lastTrashUndo: TrashUndo?

    // MARK: - Storage

    private var database: FileIndexDatabase?
    private let isRunningTests: Bool
    private let scanner = FileScanner()
    private let bookmarkManager = BookmarkManager()
    private let fileOperations = FileOperationService()
    private let fileSystemMonitor = FileSystemChangeMonitor()

    private static let searchResultBatchSize = 500
    private static let searchDebounce: Duration = .milliseconds(120)
    private static let fileChangeDebounce: Duration = .milliseconds(350)

    private var searchTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanningSourceIDs = Set<UUID>()
    private var currentScanningSourceID: UUID?
    private var failedScanningSourceIDs = Set<UUID>()
    /// Folders skipped during the current scan because they were unreadable.
    /// Summarised once the scan finishes so the user knows the index is partial.
    private var skippedScanPaths: [String] = []
    private var fileChangeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileChanges: [UUID: Set<FileSystemChangeEvent>] = [:]
    private var pendingFullRescanSourceIDs = Set<UUID>()
    private var activeSecurityScopes: [UUID: URL] = [:]
    private var categoryMutationTasks: [FileCategoryAssignmentKey: Task<Void, Never>] = [:]
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
            await self?.reloadIndex()
        }
    }

    func cancelAllTasks() {
        searchTask?.cancel()
        scanTask?.cancel()
        fileChangeTasks.values.forEach { $0.cancel() }
        categoryMutationTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Database lifecycle

    private func openDatabase() {
        do {
            database = try FileIndexDatabase(databaseURL: try databaseURL())
        } catch {
            database = nil
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
        database = nil
        do {
            database = try FileIndexDatabase(databaseURL: try databaseURL())
            isDatabaseAvailable = true
            await reloadIndex()
        } catch {
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    private func suspendIndexAfterDatabaseFailure(_ error: Error) {
        cancelScan(startsPendingFullRescan: false)
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        fileChangeTasks.values.forEach { $0.cancel() }
        fileChangeTasks.removeAll()
        pendingFileChanges.removeAll()
        pendingFullRescanSourceIDs.removeAll()
        fileSystemMonitor.stopAll()
        for sourceID in Array(activeSecurityScopes.keys) {
            activeSecurityScopes.removeValue(forKey: sourceID)?
                .stopAccessingSecurityScopedResource()
        }
        database = nil
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

        do {
            let storedSources = try await database.fetchSources()
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
            let indexedFiles = try await database.fetchFiles()
            files = includesHiddenFiles
                ? indexedFiles
                : indexedFiles.filter { !Self.isDotPrefixedFile($0) }
            categories = try await database.fetchCategories()
            fileCategoryLinks = try await database.fetchFileCategoryLinks()
            savedSearches = try await database.fetchSavedSearches()
            activateSecurityScopes()
            configureFileSystemMonitoring()
            onFilesChanged?()
            isDatabaseAvailable = true
        } catch {
            suspendIndexAfterDatabaseFailure(error)
        }
    }

    // MARK: - AI support surface

    /// FTS lookup used by AI search to gather candidates for one keyword.
    func searchFiles(matching query: String, limit: Int) async throws -> [IndexedFile] {
        guard let database else { throw FileIndexError.database("database unavailable") }
        return try await database.searchFiles(matching: query, limit: limit)
    }

    /// FTS lookup across many keywords in a single query (F13).
    func searchFiles(matchingAnyOf keywords: [String], limit: Int) async throws -> [IndexedFile] {
        guard let database else { throw FileIndexError.database("database unavailable") }
        return try await database.searchFiles(matchingAnyOf: keywords, limit: limit)
    }

    /// Applies AI-suggested category changes and reloads the index.
    func applyAICategories(
        _ changes: [AIClassificationChange],
        assigned: Bool
    ) async throws {
        guard let database else { throw FileIndexError.database("database unavailable") }
        try await database.setCategories(changes, assigned: assigned)
        await reloadIndex()
    }

    /// Text content of a file, used by the AI explain/ask flows.
    func textContent(forFileID fileID: String) async throws -> String? {
        guard let database else { throw FileIndexError.database("database unavailable") }
        return try await database.fetchTextContent(forFileID: fileID)
    }

    // MARK: - Saved searches (N07)

    func saveSearch(
        name: String,
        query: String,
        minSizeBytes: Int64,
        minDate: Date?,
        id: UUID = UUID()
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
            createdAt: Date()
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

    var recentFiles: [IndexedFile] {
        files
            .filter { $0.modifiedAt != nil }
            .sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            .prefix(8)
            .map { $0 }
    }

    var hasMoreSearchResults: Bool {
        searchResults != nil
            && searchResultTotalCount != nil
            && (searchResults?.count ?? 0) < (searchResultTotalCount ?? 0)
    }

    func categories(for file: IndexedFile) -> [FileCategory] {
        let assignedIDs = fileCategoryLinks[file.id] ?? []
        return categories.filter { assignedIDs.contains($0.id) }
    }

    func files(in category: FileCategory) -> [IndexedFile] {
        files.filter { isCategory(category, assignedTo: $0) }
    }

    func fileCount(in category: FileCategory) -> Int {
        files(in: category).count
    }

    func isCategory(_ category: FileCategory, assignedTo file: IndexedFile) -> Bool {
        fileCategoryLinks[file.id]?.contains(category.id) == true
    }

    /// F12: O(1) per-kind counts instead of scanning `files` once per kind on
    /// the home page (7 scans of up to 100k files each).
    private var fileCountsByKind: [FileKind: Int] = [:]

    func fileCount(for kind: FileKind) -> Int {
        fileCountsByKind[kind] ?? 0
    }

    /// Rebuilt once per `files`/`categories` change, not per row.
    private func rebuildDerivedIndexes() {
        var counts: [FileKind: Int] = [:]
        for file in files {
            counts[file.kind, default: 0] += 1
        }
        fileCountsByKind = counts
    }

    // MARK: - Search

    func scheduleSearch(query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            searchResults = nil
            searchResultTotalCount = nil
            isSearching = false
            return
        }
        guard let database else {
            searchResults = []
            searchResultTotalCount = 0
            isSearching = false
            return
        }

        isSearching = true
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
                guard let self else { return }
                self.searchResults = page.files
                self.searchResultTotalCount = page.totalCount
                self.isSearching = false
            } catch is CancellationError {
                // 新输入会替换尚未完成的查询。
            } catch {
                guard let self else { return }
                self.searchResults = []
                self.searchResultTotalCount = 0
                self.isSearching = false
                self.onError?(Self.message(for: error))
            }
        }
    }

    func loadMoreSearchResults(query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let database else { return }
        let requestedLimit = (searchResults?.count ?? 0) + Self.searchResultBatchSize
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                guard let self else { return }
                let page = try await database.searchFilesPage(
                    matching: query,
                    limit: requestedLimit,
                    includesHiddenFiles: self.includesHiddenFiles
                )
                try Task.checkCancellation()
                self.searchResults = page.files
                self.searchResultTotalCount = page.totalCount
                self.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.isSearching = false
                self.onError?(Self.message(for: error))
            }
        }
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
        Task { [weak self] in
            do {
                try await database.setSourceEnabled(id: source.id, enabled: enabled)
                await self?.reloadIndex()
                if enabled {
                    if let refreshed = self?.sources.first(where: { $0.id == source.id }) {
                        self?.scanSource(refreshed)
                    }
                } else {
                    self?.cancelScan(startsPendingFullRescan: false)
                    self?.fileChangeTasks.removeValue(forKey: source.id)?.cancel()
                    self?.pendingFileChanges.removeValue(forKey: source.id)
                }
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
    }

    func removeSource(_ source: FileSource) {
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
        cancelScan(startsPendingFullRescan: false)
        let generation = UUID()
        scanGeneration = generation
        scanningSourceIDs = [source.id]
        failedScanningSourceIDs.removeAll()
        currentScanningSourceID = source.id
        isScanning = true
        scanProgress = ScanProgress(discoveredCount: 0, currentPath: source.path)
        scanTask = Task { [weak self] in
            await self?.performScan(source, generation: generation)
        }
    }

    func refreshAllSources() {
        guard !sources.isEmpty else { return }
        cancelScan(startsPendingFullRescan: false)
        let sourcesToScan = sources
        let generation = UUID()
        scanGeneration = generation
        scanningSourceIDs = Set(sourcesToScan.map(\.id))
        failedScanningSourceIDs.removeAll()
        isScanning = true
        scanProgress = ScanProgress(discoveredCount: 0, currentPath: sourcesToScan[0].path)
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
        if !includesHiddenFiles {
            files.removeAll(where: Self.isDotPrefixedFile)
            searchResults?.removeAll(where: Self.isDotPrefixedFile)
            onFilesChanged?()
        }
        refreshAllSources()
    }

    func cancelScan(startsPendingFullRescan: Bool = true) {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanningSourceIDs.removeAll()
        currentScanningSourceID = nil
        isScanning = false
        scanProgress = nil
        failedScanningSourceIDs.removeAll()
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
            throw FileIndexError.database("database unavailable")
        }
        let renamedURL = try await fileOperations.rename(fileAt: file.url, to: newName)
        await reconcileKnownFileChanges([file.url, renamedURL])
        onFileResolved?(renamedURL)

        let originalName = file.name
        undoCoordinator?.record(title: UndoCoordinator.renameTitle) { [weak self] in
            guard let self else { return }
            let restoredURL = try await fileOperations.rename(
                fileAt: renamedURL,
                to: originalName
            )
            await reconcileKnownFileChanges([renamedURL, restoredURL])
            onFileResolved?(restoredURL)
        }
    }

    func chooseMoveDestination(for file: IndexedFile) {
        guard isDatabaseAvailable else {
            onError?(FileIndexError.database("database unavailable").localizedDescription)
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
                await self?.move(file, to: destinationURL)
            }
        }
    }

    func confirmTrash(_ file: IndexedFile) {
        guard isDatabaseAvailable else {
            onError?(FileIndexError.database("database unavailable").localizedDescription)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                if let trashURL = try await fileOperations.moveToTrash(fileAt: file.url) {
                    // Keep one undo hop so an accidental delete can be
                    // reversed without digging through the Trash. Also pushed
                    // onto the general stack so ⌘Z covers it (N16).
                    lastTrashUndo = TrashUndo(
                        trashURL: trashURL,
                        originalURL: file.url
                    )
                    recordTrashUndo(trashURL: trashURL, originalURL: file.url)
                }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await restoreFromTrash(
                    trashURL: undo.trashURL,
                    originalURL: undo.originalURL
                )
            } catch {
                onError?(Self.message(for: error))
            }
        }
    }

    private func recordTrashUndo(trashURL: URL, originalURL: URL) {
        undoCoordinator?.record(title: UndoCoordinator.trashTitle) { [weak self] in
            guard let self else { return }
            // Clears the one-hop banner so it cannot restore the same item a
            // second time after ⌘Z already did.
            if lastTrashUndo?.trashURL == trashURL {
                lastTrashUndo = nil
            }
            try await restoreFromTrash(trashURL: trashURL, originalURL: originalURL)
        }
    }

    /// One stack entry for the whole batch. Individual failures are surfaced
    /// rather than aborting, so a partially restorable batch still recovers
    /// everything it can.
    private func recordBatchTrashUndo(_ trashed: [(trashURL: URL, originalURL: URL)]) {
        guard !trashed.isEmpty else { return }
        undoCoordinator?.record(title: UndoCoordinator.trashTitle) { [weak self] in
            guard let self else { return }
            var failed = 0
            for item in trashed {
                do {
                    try await restoreFromTrash(
                        trashURL: item.trashURL,
                        originalURL: item.originalURL
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

    private func restoreFromTrash(trashURL: URL, originalURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: trashURL.path) else {
            throw FileIndexError.database(AppLanguage.localized(
                "无法从废纸篓恢复：项目已不在废纸篓中。",
                english: "Cannot restore from the Trash: the item is no longer there."
            ))
        }
        _ = try await fileOperations.move(
            fileAt: trashURL,
            to: originalURL.deletingLastPathComponent()
        )
        await reconcileKnownFileChanges([trashURL, originalURL])
        onFilesChanged?()
    }

    // MARK: - Categories

    func createCategory(name: String, symbolName: String) async throws {
        guard let database else { throw FileIndexError.database("database unavailable") }
        _ = try await database.createCategory(name: name, symbolName: symbolName)
        await reloadIndex()
    }

    func renameCategory(_ category: FileCategory, to name: String) async throws {
        guard let database else { throw FileIndexError.database("database unavailable") }
        try await database.renameCategory(category.id, to: name)
        await reloadIndex()
    }

    func deleteCategory(_ category: FileCategory) {
        guard let database else { return reportDatabaseUnavailable() }
        Task { [weak self] in
            do {
                try await database.deleteCategory(category.id)
                await self?.reloadIndex()
            } catch {
                self?.onError?(Self.message(for: error))
            }
        }
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
            revision: (existing?.revision ?? 0) &+ 1
        )
        applyCategoryAssignment(assigned, for: key)

        if recordsUndo {
            undoCoordinator?.record(
                title: UndoCoordinator.categoryTitle(assigned: assigned)
            ) { [weak self] in
                self?.setCategory(category, assigned: !assigned, for: file, recordsUndo: false)
            }
        }

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
        to files: [IndexedFile]
    ) {
        let changed = files.filter { isCategory(category, assignedTo: $0) != assigned }
        guard !changed.isEmpty else { return }

        for file in changed {
            setCategory(category, assigned: assigned, for: file, recordsUndo: false)
        }

        undoCoordinator?.record(title: UndoCoordinator.batchCategoryTitle) { [weak self] in
            guard let self else { return }
            for file in changed {
                setCategory(category, assigned: !assigned, for: file, recordsUndo: false)
            }
        }
    }

    /// Batch: move all files to the Trash. Used by multi-select.
    func confirmBatchTrash(_ files: [IndexedFile]) {
        guard isDatabaseAvailable else {
            onError?(FileIndexError.database("database unavailable").localizedDescription)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            var trashed: [(trashURL: URL, originalURL: URL)] = []
            for file in files {
                do {
                    if let trashURL = try await fileOperations.moveToTrash(fileAt: file.url) {
                        trashed.append((trashURL, file.url))
                    }
                } catch {
                    failed += 1
                }
            }
            recordBatchTrashUndo(trashed)
            if failed > 0 {
                onError?(AppLanguage.localized(
                    "有 \(failed) 个文件未能移到废纸篓。",
                    english: "\(failed) file(s) couldn’t be moved to the Trash."
                ))
            }
            let paths = files.map(\.url)
            onFilesChanged?()
            await reconcileKnownFileChanges(paths)
        }
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
        fileCategoryLinks = links
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
            await reloadIndex()
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
        url.resolvingSymlinksInPath().standardizedFileURL
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
            await reloadIndex()
            if let refreshedSource = sources.first(where: { $0.id == source.id }) {
                scanSource(refreshedSource)
            }
        } catch {
            onError?(Self.message(for: error))
        }
    }

    private func move(_ file: IndexedFile, to destinationURL: URL) async {
        guard let database else {
            onError?(FileIndexError.database("database unavailable").localizedDescription)
            return
        }
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        var physicallyMovedURL: URL?
        do {
            let categoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
            let movedURL = try await fileOperations.move(fileAt: file.url, to: destinationURL)
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
                    includesHiddenFiles: includesHiddenFiles
                )
                if !snapshot.failedScopes.isEmpty {
                    throw FileIndexError.unreadableFolder(movedURL.lastPathComponent)
                }

                if let movedFile = snapshot.files.first(where: {
                    $0.url.standardizedFileURL.path == movedURL.standardizedFileURL.path
                }) {
                    try await database.reconcileMovedFile(
                        fromFile: file.id,
                        to: movedFile,
                        preserving: categoryIDs
                    )
                    await reloadIndex()
                } else {
                    // Hidden/excluded destinations intentionally leave the searchable index.
                    await reconcileKnownFileChanges([file.url, movedURL])
                }
            } else {
                await reconcileKnownFileChanges([file.url, movedURL])
            }
            onFileResolved?(movedURL)
            recordMoveUndo(movedURL: movedURL, originalURL: file.url)
        } catch {
            if let physicallyMovedURL {
                onError?(AppLanguage.localized(
                    "文件已移动到“\(physicallyMovedURL.lastPathComponent)”，但索引更新失败。原分类尚未主动清除，请重新扫描后再试。",
                    english: "The file moved to “\(physicallyMovedURL.lastPathComponent)”, but its index could not be updated. Its original categories were not intentionally removed; rescan and try again."
                ))
            } else {
                onError?(Self.message(for: error))
            }
        }
    }

    /// Registers the inverse move. The original folder is inside an authorized
    /// source, so its security scope is already held; the destination scope
    /// came from a one-off panel grant and is not needed to move back out.
    private func recordMoveUndo(movedURL: URL, originalURL: URL) {
        let originalDirectory = originalURL.deletingLastPathComponent()
        undoCoordinator?.record(title: UndoCoordinator.moveTitle) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: movedURL.path) else {
                throw FileIndexError.database(AppLanguage.localized(
                    "无法撤销移动：文件已不在“\(movedURL.lastPathComponent)”。",
                    english: "Cannot undo the move: the file is no longer at “\(movedURL.lastPathComponent)”."
                ))
            }
            let restoredURL = try await fileOperations.move(
                fileAt: movedURL,
                to: originalDirectory
            )
            await reconcileKnownFileChanges([movedURL, restoredURL])
            await reloadIndex()
            onFileResolved?(restoredURL)
        }
    }

    /// Applied before every scan so a preference change takes effect on the
    /// next scan without needing to rebuild the scanner.
    private func syncScanExclusions() async {
        await scanner.setAdditionalExcludedNames(Set(ScanExclusions.current()))
    }

    private func indexedSource(containing url: URL) -> FileSource? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return sources
            .filter { source in
                guard source.accessState == .available else { return false }
                let rootPath = source.url.resolvingSymlinksInPath().standardizedFileURL.path
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
        isScanning = true
        scanProgress = ScanProgress(discoveredCount: 0, currentPath: source.path)

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
            defer {
                if didAccess {
                    restored.url.stopAccessingSecurityScopedResource()
                }
            }

            await syncScanExclusions()
            let scannedFiles = try await scanner.scan(
                sourceID: source.id,
                rootURL: restored.url,
                includesHiddenFiles: includesHiddenFiles
            ) { [weak self] progress in
                Task { @MainActor in
                    guard self?.scanGeneration == generation else { return }
                    self?.scanProgress = progress
                }
            }
            try Task.checkCancellation()
            guard scanGeneration == generation,
                  scanningSourceIDs.contains(source.id) else { return }
            let skipped = await scanner.lastScanSkippedPaths
            // Fail-closed: when folders were skipped, merge instead of
            // replacing, so files in unreadable folders are not deleted
            // from the index (and their category links survive).
            try await database.replaceFiles(
                for: source.id,
                with: scannedFiles,
                deletesUnscanned: skipped.isEmpty
            )
            guard scanGeneration == generation else { return }
            skippedScanPaths.append(contentsOf: skipped)
            await reloadIndex()
        } catch is CancellationError {
            // 用户取消扫描时保留上一次完整索引。
        } catch {
            guard scanGeneration == generation else { return }
            failedScanningSourceIDs.insert(source.id)
            onError?(Self.message(for: error))
            await reloadIndex()
        }

        if !keepsScanningState {
            finishScan(generation: generation)
        }
    }

    private func finishScan(generation: UUID) {
        guard Self.scanCleanupOwnsState(
            currentGeneration: scanGeneration,
            finishingGeneration: generation
        ) else { return }
        isScanning = false
        scanProgress = nil
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
        } else if !skippedScanPaths.isEmpty {
            // The scan itself succeeded, but some folders were unreadable and
            // their contents are missing from the index. Say so rather than
            // letting the user assume the index is complete.
            let count = skippedScanPaths.count
            let sample = skippedScanPaths.prefix(3)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: AppLanguage.localized("、", english: ", "))
            onError?(AppLanguage.localized(
                "扫描完成，但有 \(count) 个位置无法读取，已跳过（例如 \(sample)）。这些位置的文件不在索引中。",
                english: "Scan finished, but \(count) location(s) couldn’t be read and were skipped (for example \(sample)). Files there are not in the index."
            ))
        }
        skippedScanPaths.removeAll()
        failedScanningSourceIDs.removeAll()
        scanningSourceIDs.removeAll()
        currentScanningSourceID = nil
        startNextPendingFullRescanIfNeeded()
        notifyScanFinished()
    }

    /// Completion notification (N12), opt-in via Settings. Only fires for
    /// full passes over every source, not single-folder rescans.
    private func notifyScanFinished() {
        guard UserDefaults.standard.bool(forKey: "notifications.scanComplete"),
              failedScanningSourceIDs.isEmpty else { return }
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

        fileSystemMonitor.update(sources: monitoredSources) { [weak self] sourceID, events in
            Task { @MainActor [weak self] in
                self?.enqueueFileSystemChanges(events, for: sourceID)
            }
        }
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
        guard let database, !events.isEmpty else { return }
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
            defer {
                if didAccess {
                    restored.url.stopAccessingSecurityScopedResource()
                }
            }

            await syncScanExclusions()
            let snapshot = try await scanner.scanChanges(
                sourceID: source.id,
                rootURL: restored.url,
                events: events,
                includesHiddenFiles: includesHiddenFiles
            )
            if !snapshot.scopes.isEmpty {
                try await database.reconcileFiles(
                    for: source.id,
                    scopes: snapshot.scopes,
                    with: snapshot.files
                )
            }
            let hasRemovalEvents = events.contains(where: {
                $0.kinds.contains(.removed) || $0.kinds.contains(.renamed)
            })
            if Self.shouldRemoveMissingFiles(
                failedScopeCount: snapshot.failedScopes.count,
                hasRemovalEvents: hasRemovalEvents
            ) {
                try await database.removeMissingFiles(for: source.id)
            }
            guard !snapshot.scopes.isEmpty
                    || !snapshot.failedScopes.isEmpty
                    || hasRemovalEvents else { return }
            if !snapshot.scopes.isEmpty || hasRemovalEvents {
                await reloadIndex()
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

        for source in sources where source.accessState == .available {
            await applyFileSystemChanges(events, to: source)
        }
    }

    private func handleMissingIndexedFile(_ file: IndexedFile) {
        onError?(FileOperationError.fileNotFound.localizedDescription)
        files.removeAll { $0.id == file.id }
        searchResults?.removeAll { $0.id == file.id }
        if let searchResultTotalCount {
            self.searchResultTotalCount = max(0, searchResultTotalCount - 1)
        }
        fileCategoryLinks.removeValue(forKey: file.id)
        onFilesChanged?()

        Task { [weak self] in
            await self?.removeMissingIndexedFile(file)
        }
    }

    private func removeMissingIndexedFile(_ file: IndexedFile) async {
        guard let database else { return }
        do {
            guard !FileManager.default.fileExists(atPath: file.path) else {
                await reloadIndex()
                return
            }
            try await database.reconcileFiles(
                for: file.sourceID,
                scopes: [FileIndexScope(path: file.path, includesDescendants: false)],
                with: []
            )
            await reloadIndex()
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

        for source in sources where source.accessState == .available {
            guard let restored = try? bookmarkManager.resolveBookmark(source.bookmark) else { continue }
            if let activeURL = activeSecurityScopes[source.id],
               activeURL.standardizedFileURL == restored.url.standardizedFileURL {
                continue
            }
            activeSecurityScopes.removeValue(forKey: source.id)?
                .stopAccessingSecurityScopedResource()
            if restored.url.startAccessingSecurityScopedResource() {
                activeSecurityScopes[source.id] = restored.url
            }
        }
    }

    // MARK: - Helpers

    private func reportDatabaseUnavailable() {
        onError?(AppLanguage.localized(
            "文件索引当前不可用，请在设置中重试后再操作。",
            english: "The file index is currently unavailable. Retry from Settings and try again."
        ))
    }

    static func isDotPrefixedFile(_ file: IndexedFile) -> Bool {
        file.url.pathComponents.contains { component in
            component.count > 1 && component.hasPrefix(".")
        }
    }

    static func shouldRemoveMissingFiles(
        failedScopeCount: Int,
        hasRemovalEvents: Bool
    ) -> Bool {
        failedScopeCount == 0 && hasRemovalEvents
    }

    static func shouldQueueFullRescan(isScanning: Bool) -> Bool {
        isScanning
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
