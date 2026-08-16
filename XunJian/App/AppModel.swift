import AppKit
import Combine
import Foundation

struct PaginatedSelectAllContext: Equatable {
    let query: String
    let kind: FileKind?
    let minimumSizeMB: Double
    let minimumDate: Double
    let aiSearchRevision: UInt64
}

enum AIOAuthState: Equatable, Sendable {
    case unavailable(OAuthCLIProbe.Status)
    case statusUnknown
    case starting
    case disconnected
    case authenticating(attemptID: UUID, authorizationURL: URL?)
    case signedInDisconnected
    case signedInUnverified
    case connected
    case failed(String)

    var shouldPoll: Bool {
        switch self {
        case .starting, .authenticating:
            true
        case .unavailable, .statusUnknown, .disconnected,
             .signedInDisconnected, .signedInUnverified, .connected, .failed:
            false
        }
    }
}

struct AIOAuthDeviceCodePresentation: Equatable, Sendable {
    let attemptID: UUID
    let verificationURL: URL
    let userCode: String
}

struct FileCategoryAssignmentKey: Hashable, Sendable {
    let fileID: String
    let categoryID: UUID
}

struct PendingCategoryAssignment: Equatable, Sendable {
    let desiredAssignment: Bool
    let revision: UInt64
    let recordsUndo: Bool
}

@MainActor
final class AppModel: ObservableObject {
    // File index state now lives on `index` (FileIndexCoordinator); see the
    // forwarding section below for the compatible names.
    // AI session state now lives on `ai` (AISessionCoordinator); same deal.

    @Published private(set) var aiSearchResults: [IndexedFile]? {
        didSet { aiSearchRevision &+= 1 }
    }
    @Published private(set) var aiSearchRevision: UInt64 = 0
    @Published private(set) var aiSearchPlan: AISearchPlan?
    @Published private(set) var aiSearchQuery: String?
    /// Multi-selection in the file table/grid (F05). `selectedFileID` remains
    /// as the single-selection compatibility surface on top of this set.
    @Published var selectedFileIDs: Set<String> = [] {
        didSet {
            if oldValue != selectedFileIDs {
                fileSelectionRevision &+= 1
                selectedFileTotalSize = index.totalSize(of: selectedFileIDs)
            }
            reconcileFileSelectionMetadata()
        }
    }
    private(set) var fileSelectionRevision: UInt64 = 0
    private(set) var selectedFileTotalSize: Int64 = 0
    var selectedFileID: String? {
        get { fileSelection.primaryID }
        set {
            var next = fileSelection
            if let newValue {
                next.replace(with: newValue)
            } else {
                next.clear()
            }
            applyFileSelection(next)
        }
    }
    /// Sticky range-select anchor (Finder ⇧-click / ⇧-arrow).
    private var selectionAnchorID: String?
    /// The file the inspector and keyboard treat as current.
    private var selectionLeadID: String?
    private var fileSelection: FileSelection {
        FileSelection(
            ids: selectedFileIDs,
            leadID: selectionLeadID,
            anchorID: selectionAnchorID
        )
    }
    @Published var selectedKind: FileKind? = nil {
        didSet {
            guard !isRunningTests else { return }
            if let selectedKind {
                UserDefaults.standard.set(
                    selectedKind.rawValue,
                    forKey: Self.selectedKindPreferenceKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedKindPreferenceKey)
            }
        }
    }
    @Published private(set) var errorMessage: String?
    private var pendingErrorMessages: [String] = []
    @Published var settingsErrorMessage: String?
    @Published var renameRequest: IndexedFile?
    @Published var trashRequest: IndexedFile?
    /// Batch trash confirmation (F05 multi-select).
    @Published var batchTrashRequest: [IndexedFile]?
    /// AI sheet request, owned here so both the file list and the inspector
    /// can open the same sheets (N04).
    @Published var aiSheetRequest: AITaskSheet?
    let fileExportProgressStore = FileExportProgressStore()
    var fileExportProgress: FileExportProgress? { fileExportProgressStore.progress }
    private var fileExportTask: Task<Void, Never>?
    private var fileExportRevision = UUID()
    @Published var searchText = "" {
        didSet { index.scheduleSearch(query: searchText) }
    }
    /// Search term used for inspector/preview highlighting. The visible page
    /// owns this so category search and All Files search stay independent.
    @Published var highlightQuery = ""
    /// Bumped when the preferred language changes while the app is open, so
    /// hand-written `AppLanguage.localized` strings refresh.
    @Published private(set) var localeRevision: UInt64 = 0
    private var lastPreferredLanguage = Locale.preferredLanguages.first

    // Manual filter values (N02), persisted so saved searches can restore
    // them. MB is the UI unit; bytes are derived by the view.
    @Published var filterMinSizeMB: Double {
        didSet { scheduleManualFilterPersistence() }
    }
    @Published var filterMinDate: Double {
        didSet { scheduleManualFilterPersistence() }
    }

    /// Debounced persistence for the manual filters: the size filter is a
    /// text field, and writing UserDefaults on every typed digit was
    /// pointless churn. Flushed immediately when the app resigns active.
    private var manualFilterPersistenceTask: Task<Void, Never>?

    private func scheduleManualFilterPersistence() {
        guard !isRunningTests else { return }
        manualFilterPersistenceTask?.cancel()
        let minSize = filterMinSizeMB
        let minDate = filterMinDate
        manualFilterPersistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(minSize, forKey: "allFiles.filterMinSizeMB")
            UserDefaults.standard.set(minDate, forKey: "allFiles.filterMinDate")
        }
    }

    private func flushManualFilterPersistence() {
        manualFilterPersistenceTask?.cancel()
        manualFilterPersistenceTask = nil
        guard !isRunningTests else { return }
        UserDefaults.standard.set(filterMinSizeMB, forKey: "allFiles.filterMinSizeMB")
        UserDefaults.standard.set(filterMinDate, forKey: "allFiles.filterMinDate")
    }

    func applyManualFilter(minSizeBytes: Int64, minDate: Date?) {
        filterMinSizeMB = Double(minSizeBytes) / (1_024 * 1_024)
        filterMinDate = minDate?.timeIntervalSince1970 ?? 0
    }

    private let isRunningTests: Bool
    private let credentialStore: LocalCredentialStore
    private let aiConfigurationStore: AIConfigurationStore
    private let oauthBridgeService: any OAuthBridgeServicing

    /// OAuth state machine, extracted so it can be tested without the rest of
    /// the app. Settings observes it directly; it is not forwarded through
    /// `AppModel.objectWillChange`.
    let oauth: OAuthCoordinator

    /// AI session state machine (settings, verification, active provider),
    /// extracted so it can be tested without the file-index machinery.
    let ai: AISessionCoordinator
    private var aiObservation: AnyCancellable?

    /// File index domain (database, scanning, search, file operations),
    /// extracted so it can be tested without the AI machinery.
    let index: FileIndexCoordinator
    private var indexObservations = Set<AnyCancellable>()

    /// General undo stack for reversible actions (N16).
    let undo = UndoCoordinator()

    var canUndo: Bool { undo.canUndo }

    /// Menu title for the next undo, e.g. "撤销重命名".
    var undoTitle: String {
        undo.nextTitle ?? AppLanguage.localized("撤销", english: "Undo")
    }

    /// Filtered and sorted "All Files" list, cached here rather than in the
    /// view so switching pages does not throw it away and force a visible
    /// re-preparation every time the user comes back.
    @Published private(set) var browseSnapshot: [IndexedFile] = []
    /// Ordered IDs for the cached snapshot. Grid selection uses this instead
    /// of rebuilding an O(n) ID array on every click.
    private(set) var browseSnapshotIDs: [String] = []
    /// id -> position in `browseSnapshotIDs`, so grid/category selection and
    /// arrow-key navigation skip O(n) index scans per click/keypress.
    private(set) var browseSnapshotIDIndex: [String: Int] = [:]
    private(set) var browseSnapshotIDSet: Set<String> = []
    /// Identifies the inputs `browseSnapshot` was built from. `nil` means
    /// nothing has been prepared yet, which is the only case that warrants
    /// showing a spinner.
    private(set) var browseSnapshotSignature: Int?
    /// Hash of the user-driven snapshot inputs (query, kind, sort, filters).
    /// When a refresh's signature differs only through index revisions, the
    /// view can settle the burst before re-sorting a six-figure list.
    private(set) var browseSnapshotUserSignature: Int?

    func publishBrowseSnapshot(
        _ files: [IndexedFile],
        orderedIDs: [String],
        idIndex: [String: Int],
        visibleIDs: Set<String>,
        signature: Int,
        userSignature: Int
    ) {
        browseSnapshotIDs = orderedIDs
        browseSnapshotIDIndex = idIndex
        browseSnapshotIDSet = visibleIDs
        browseSnapshotSignature = signature
        browseSnapshotUserSignature = userSignature
        // Publish once, after every piece of metadata is coherent. The old
        // path emitted three extra object changes for each six-figure list.
        browseSnapshot = files
    }

    /// The files currently visible on the active page. Export and ⌘A read
    /// this rather than the All Files snapshot, which goes stale after the
    /// user leaves that page.
    @Published var commandTargetFiles: [IndexedFile] = []
    /// Distinguishes “no page has published yet” from “this page has nothing
    /// to export”, so Settings cannot silently dump the whole index.
    @Published private(set) var hasPublishedCommandTarget = false
    @Published private(set) var commandTargetUsesGlobalSearchPagination = false
    private var commandTargetSignature: Int?

    func updateCommandTargetFiles(
        _ files: [IndexedFile],
        usesGlobalSearchPagination: Bool = false,
        signature: Int? = nil
    ) {
        if let signature,
           hasPublishedCommandTarget,
           commandTargetSignature == signature,
           commandTargetUsesGlobalSearchPagination == usesGlobalSearchPagination {
            return
        }
        // Compare without allocating two ID arrays: publishing a 100k-file
        // snapshot was churning two full-size arrays per call.
        if signature == nil,
           hasPublishedCommandTarget,
           commandTargetUsesGlobalSearchPagination == usesGlobalSearchPagination,
           files.count == commandTargetFiles.count,
           zip(files, commandTargetFiles).allSatisfy({ $0.id == $1.id }) {
            return
        }
        commandTargetFiles = files
        commandTargetUsesGlobalSearchPagination = usesGlobalSearchPagination
        commandTargetSignature = signature
        hasPublishedCommandTarget = true
    }

    /// Keeps the current search-pagination ownership while a replacement
    /// snapshot is being prepared, so an in-flight Select All is not lost.
    func clearCommandTargetFilesKeepingPagination() {
        commandTargetFiles = []
        commandTargetSignature = nil
        hasPublishedCommandTarget = true
    }

    var filesRevision: UInt64 { index.filesRevision }
    var categoryRevision: UInt64 { index.categoryRevision }

    /// Selects everything currently visible in the file list, which is what
    /// ⌘A means to the user — not every file in the index.
    func selectAllDisplayedFiles() {
        if commandTargetUsesGlobalSearchPagination, hasMoreSearchResults {
            let context = paginatedSelectAllContext
            Task { [weak self] in
                guard let self else { return }
                guard await self.index.loadAllSearchResults(query: context.query),
                      self.paginatedSelectAllContext == context,
                      self.hasPublishedCommandTarget,
                      self.commandTargetUsesGlobalSearchPagination else { return }
                let files = await self.filesMatchingCurrentBrowseFilters()
                guard self.paginatedSelectAllContext == context,
                      self.hasPublishedCommandTarget,
                      self.commandTargetUsesGlobalSearchPagination else { return }
                self.updateCommandTargetFiles(
                    files,
                    usesGlobalSearchPagination: true
                )
                self.applySelectAll(to: files)
            }
            return
        }
        applySelectAll(to: commandTargetFiles)
    }

    private var paginatedSelectAllContext: PaginatedSelectAllContext {
        PaginatedSelectAllContext(
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: selectedKind,
            minimumSizeMB: filterMinSizeMB,
            minimumDate: filterMinDate,
            aiSearchRevision: aiSearchRevision
        )
    }

    func loadAllSearchResults() async -> Bool {
        let query = searchText
        guard await index.loadAllSearchResults(query: query) else { return false }
        return searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func searchFiles(matching query: String, limit: Int) async throws -> [IndexedFile] {
        try await index.searchFiles(matching: query, limit: limit)
    }

    func searchFileIDs(
        matching query: String,
        inCategory categoryID: UUID,
        limit: Int
    ) async throws -> Set<String> {
        try await index.searchFileIDs(
            matching: query,
            inCategory: categoryID,
            limit: limit
        )
    }

    func removeSelectedFiles(from category: FileCategory) {
        index.removeCategory(category, fromFiles: selectedFiles)
    }

    private func applySelectAll(to files: [IndexedFile]) {
        var next = FileSelection()
        next.selectAll(orderedIDs: files.map(\.id))
        applyFileSelection(next)
    }

    func filesMatchingCurrentBrowseFilters() async -> [IndexedFile] {
        let minSize = Int64(filterMinSizeMB * 1_024 * 1_024)
        let minDate = filterMinDate > 0 ? Date(timeIntervalSince1970: filterMinDate) : nil
        let kind = selectedKind
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexedFiles = files
        let aiResults = aiSearchResults
        let localResults = searchResults
        return await Task.detached(priority: .userInitiated) {
            Self.filesMatchingBrowseFilters(
                indexedFiles: indexedFiles,
                aiSearchResults: aiResults,
                searchResults: localResults,
                query: query,
                kind: kind,
                minimumSize: minSize,
                minimumDate: minDate
            )
        }.value
    }

    nonisolated static func filesMatchingBrowseFilters(
        indexedFiles: [IndexedFile],
        aiSearchResults: [IndexedFile]?,
        searchResults: [IndexedFile]?,
        query: String,
        kind: FileKind?,
        minimumSize: Int64,
        minimumDate: Date?
    ) -> [IndexedFile] {
        let source: [IndexedFile]
        if let aiSearchResults {
            if query.isEmpty {
                source = aiSearchResults
            } else {
                let matchingIDs = Set((searchResults ?? []).map(\.id))
                source = aiSearchResults.filter { matchingIDs.contains($0.id) }
            }
        } else if query.isEmpty {
            source = indexedFiles
        } else {
            source = searchResults ?? []
        }
        return source.filter { file in
            if let kind, file.kind != kind { return false }
            if minimumSize > 0, file.size < minimumSize { return false }
            if let minimumDate {
                guard let modifiedAt = file.modifiedAt,
                      modifiedAt >= minimumDate else { return false }
            }
            return true
        }
    }

    func categoryNamesForExport(_ files: [IndexedFile]) async -> [String: [String]] {
        let links = index.fileCategoryLinksSnapshot()
        let namesByID = Dictionary(uniqueKeysWithValues: index.categories.map {
            ($0.id, $0.localizedDisplayName)
        })
        let orderByID = Dictionary(uniqueKeysWithValues: index.categories.enumerated().map {
            ($0.element.id, $0.offset)
        })
        return await Task.detached(priority: .userInitiated) {
            FileListExport.categoryNames(
                for: files,
                links: links,
                namesByID: namesByID,
                orderByID: orderByID
            )
        }.value
    }

    /// Click in a custom list or grid. Reads ⌘/⇧ from the current event so
    /// hosts don't each reimplement Finder-style multi-select.
    func selectDisplayedFile(_ file: IndexedFile, in files: [IndexedFile]) {
        let modifiers = NSEvent.modifierFlags
        selectDisplayedFile(
            file.id,
            inIDs: files.map(\.id),
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
    }

    func selectDisplayedFile(
        _ fileID: String,
        in files: [IndexedFile],
        command: Bool,
        shift: Bool
    ) {
        selectDisplayedFile(
            fileID,
            inIDs: files.map(\.id),
            command: command,
            shift: shift
        )
    }

    func selectDisplayedFile(
        _ fileID: String,
        inIDs orderedIDs: [String],
        command: Bool,
        shift: Bool,
        idIndex: [String: Int]? = nil
    ) {
        var next = fileSelection
        next.select(
            fileID,
            in: orderedIDs,
            command: command,
            shift: shift,
            idIndex: idIndex
        )
        applyFileSelection(next)
    }

    func moveDisplayedSelection(
        by offset: Int,
        in files: [IndexedFile],
        extending: Bool,
        idIndex: [String: Int]? = nil
    ) {
        moveDisplayedSelection(
            by: offset,
            inIDs: files.map(\.id),
            extending: extending,
            idIndex: idIndex
        )
    }

    func moveDisplayedSelection(
        by offset: Int,
        inIDs orderedIDs: [String],
        extending: Bool,
        idIndex: [String: Int]? = nil
    ) {
        var next = fileSelection
        next.moveLead(
            by: offset,
            in: orderedIDs,
            extending: extending,
            idIndex: idIndex
        )
        applyFileSelection(next)
    }

    private func applyFileSelection(_ next: FileSelection) {
        selectionLeadID = next.leadID
        selectionAnchorID = next.anchorID
        selectedFileIDs = next.ids
    }

    func applyNativeTableSelection(
        _ ids: Set<String>,
        orderedIDs: [String],
        idIndex: [String: Int]? = nil,
        command: Bool = false,
        shift: Bool = false
    ) {
        var next = fileSelection
        next.applyNativeTableSelection(
            ids,
            orderedIDs: orderedIDs,
            idIndex: idIndex,
            command: command,
            shift: shift
        )
        applyFileSelection(next)
    }

    private func reconcileFileSelectionMetadata() {
        var next = fileSelection
        next.reconcileMetadata()
        selectionLeadID = next.leadID
        selectionAnchorID = next.anchorID
    }

    func rebuildSearchIndex() async {
        await index.rebuildSearchIndex()
    }

    func performUndo() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await undo.undoLast()
            } catch {
                reportError(Self.message(for: error))
            }
        }
    }

    private static let selectedKindPreferenceKey = "allFiles.selectedKind"

    init(
        oauthBridgeService: any OAuthBridgeServicing = OAuthBridgeClient.shared,
        credentialStore: LocalCredentialStore = LocalCredentialStore(),
        aiConfigurationStore: AIConfigurationStore = AIConfigurationStore()
    ) {
        self.oauthBridgeService = oauthBridgeService
        self.credentialStore = credentialStore
        self.aiConfigurationStore = aiConfigurationStore
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningTests = isRunningTests
        self.oauth = OAuthCoordinator(
            bridgeService: oauthBridgeService,
            isRunningTests: isRunningTests
        )
        self.ai = AISessionCoordinator(
            credentialStore: credentialStore,
            aiConfigurationStore: aiConfigurationStore,
            oauthBridgeService: oauthBridgeService,
            oauth: oauth,
            isRunningTests: isRunningTests
        )
        self.index = FileIndexCoordinator(isRunningTests: isRunningTests)
        self.filterMinSizeMB = UserDefaults.standard.double(
            forKey: "allFiles.filterMinSizeMB"
        )
        self.filterMinDate = UserDefaults.standard.double(
            forKey: "allFiles.filterMinDate"
        )
        wireOAuthCoordinator()
        wireAISessionCoordinator()
        wireIndexCoordinator()
        let oauthKindToRefresh: AIProviderKind? = if !isRunningTests,
                                                    aiConfigurationStore.activeAuthenticationMode == .oauth,
                                                    let activeKind = aiConfigurationStore.activeKind,
                                                    OAuthCoordinator.oauthProvider(for: activeKind) != nil {
            activeKind
        } else {
            nil
        }
        if !isRunningTests {
            selectedKind = UserDefaults.standard.string(forKey: Self.selectedKindPreferenceKey)
                .flatMap(FileKind.init(rawValue:))
        }

        index.start()
        if let oauthKindToRefresh {
            Task { [weak self] in
                await self?.oauth.refreshStatus(
                    for: oauthKindToRefresh,
                    presentsFailure: false
                )
            }
        }
    }

    deinit {
        fileExportTask?.cancel()
        let oauth = oauth
        let ai = ai
        let index = index
        Task { @MainActor in
            oauth.applicationResignedActive()
            ai.cancelAllTasks()
            index.cancelAllTasks()
        }
    }

    func clearError() {
        if pendingErrorMessages.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = pendingErrorMessages.removeFirst()
        }
    }

    func reportError(_ message: String) {
        guard !message.isEmpty else { return }
        guard let errorMessage else {
            self.errorMessage = message
            return
        }
        guard errorMessage != message,
              !pendingErrorMessages.contains(message) else { return }
        pendingErrorMessages.append(message)
    }

    func clearSettingsError() {
        settingsErrorMessage = nil
    }

    var isExportingFileList: Bool { fileExportProgress != nil }

    func startFileListExport(
        totalCount: Int,
        operation: @escaping @Sendable (
            _ reportProgress: @escaping @Sendable (Int) -> Void
        ) async throws -> Void
    ) {
        fileExportTask?.cancel()
        let revision = UUID()
        fileExportRevision = revision
        fileExportProgressStore.update(FileExportProgress(completed: 0, total: totalCount))
        fileExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation { [weak self] completed in
                    Task { @MainActor [weak self] in
                        guard let self, self.fileExportRevision == revision else { return }
                        self.fileExportProgressStore.update(
                            FileExportProgress(
                                completed: min(completed, totalCount),
                                total: totalCount
                            )
                        )
                    }
                }
            } catch is CancellationError {
                // The atomic writer removes its temporary artifact.
            } catch {
                guard fileExportRevision == revision else { return }
                reportError(error.localizedDescription)
            }
            guard fileExportRevision == revision else { return }
            fileExportProgressStore.update(nil)
            fileExportTask = nil
        }
    }

    func cancelFileListExport() {
        fileExportRevision = UUID()
        fileExportTask?.cancel()
        fileExportTask = nil
        fileExportProgressStore.update(nil)
    }

    func requestRename(_ file: IndexedFile) {
        renameRequest = file
    }

    func requestTrash(_ file: IndexedFile) {
        trashRequest = file
    }

    func confirmDuplicateTrash(_ group: DuplicateGroup) async throws {
        try await index.confirmDuplicateTrash(group)
    }

    static func shouldDeactivateActiveAPIKeyForVerification(
        activeKind: AIProviderKind?,
        activeMode: AIAuthenticationMode?,
        testedKind: AIProviderKind
    ) -> Bool {
        AISessionCoordinator.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: activeKind,
            activeMode: activeMode,
            testedKind: testedKind
        )
    }

    static func categoryAssignmentAfterToggle(
        persistedAssignment: Bool,
        pendingAssignment: Bool?
    ) -> Bool {
        !(pendingAssignment ?? persistedAssignment)
    }

    func performAISearch(_ query: String) async throws {
        guard index.isDatabaseAvailable else {
            throw FileIndexError.databaseUnavailable
        }
        let service = try ai.currentService()
        let plan = try await service.searchPlan(for: query)
        try Task.checkCancellation()

        let indexedFiles = index.files
        let matchedFiles: [IndexedFile]?
        if plan.keywords.isEmpty {
            matchedFiles = nil
        } else {
            // F13: one OR query instead of up to 12 separate FTS round-trips.
            // The candidate order comes from `files` either way, so batching
            // the lookup does not change the result set.
            // AI filters must see the complete local candidate set. Ordinary
            // search paginates for presentation, but silently truncating this
            // set would make a valid file impossible for the plan to return.
            let candidateLimit = max(index.files.count, 1)
            matchedFiles = try await index.searchFiles(
                matchingAnyOf: plan.keywords,
                limit: candidateLimit
            )
        }

        try Task.checkCancellation()
        let filteredResults = await Task.detached(priority: .userInitiated) {
            let candidates: [IndexedFile]
            if let matchedFiles {
                let matchingIDs = Set(matchedFiles.map(\.id))
                candidates = indexedFiles.filter { matchingIDs.contains($0.id) }
            } else {
                candidates = indexedFiles
            }
            return plan.filter(candidates)
        }.value
        try Task.checkCancellation()
        aiSearchResults = filteredResults
        aiSearchPlan = plan
        aiSearchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index.scheduleSearch(query: searchText)
        }
    }

    func clearAISearch() {
        aiSearchResults = nil
        aiSearchPlan = nil
        aiSearchQuery = nil
    }

    func explainWithAI(_ file: IndexedFile) async throws -> String {
        try await ai.currentService().explain(file: try await fileWithText(file))
    }

    func explainWithAIStream(
        _ file: IndexedFile
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await ai.currentService().explainStream(file: try await fileWithText(file))
    }

    func askAI(_ question: String, about file: IndexedFile) async throws -> String {
        try await ai.currentService().answer(
            question: question,
            about: try await fileWithText(file)
        )
    }

    func askAIStream(
        _ question: String,
        about file: IndexedFile
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await ai.currentService().answerStream(
            question: question,
            about: try await fileWithText(file)
        )
    }

    func classifyWithAI(
        _ files: [IndexedFile],
        includesFileContent: Bool = true
    ) async throws -> [AIClassificationSuggestion] {
        guard !index.categories.isEmpty else { throw AIServiceError.noCategories }
        var filesWithText: [IndexedFile] = []
        filesWithText.reserveCapacity(files.count)
        for file in files {
            if includesFileContent {
                filesWithText.append(try await fileWithText(file))
            } else {
                filesWithText.append(IndexedFile(
                    id: file.id,
                    sourceID: file.sourceID,
                    name: file.name,
                    path: file.path,
                    fileExtension: file.fileExtension,
                    kind: file.kind,
                    size: file.size,
                    createdAt: file.createdAt,
                    modifiedAt: file.modifiedAt,
                    indexedAt: file.indexedAt,
                    textContent: nil
                ))
            }
        }
        return try await ai.currentService().classify(
            files: filesWithText,
            categories: index.categories,
            includesFileContent: includesFileContent
        )
    }

    private func fileWithText(_ file: IndexedFile) async throws -> IndexedFile {
        let textContent = try await textContentForExplicitUse(file)
        return IndexedFile(
            id: file.id,
            sourceID: file.sourceID,
            name: file.name,
            path: file.path,
            fileExtension: file.fileExtension,
            kind: file.kind,
            size: file.size,
            createdAt: file.createdAt,
            modifiedAt: file.modifiedAt,
            indexedAt: file.indexedAt,
            textContent: textContent
        )
    }

    func supportsTextContent(_ file: IndexedFile) -> Bool {
        TextExtractionService.supports(file.url)
    }

    private func textContentForExplicitUse(_ file: IndexedFile) async throws -> String? {
        if let indexed = try await index.textContent(forFileID: file.id),
           !indexed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return indexed
        }
        guard supportsTextContent(file) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            TextExtractionService().extractText(from: file.url)
        }.value
    }

    func applyAIClassification(
        _ suggestions: [AIClassificationSuggestion]
    ) async throws -> [AIClassificationChange] {
        guard index.isDatabaseAvailable else { return [] }
        let validFileIDs = index.allFileIDs
        let validCategoryIDs = Set(index.categories.map(\.id))
        var changes: [AIClassificationChange] = []

        for suggestion in suggestions where validFileIDs.contains(suggestion.fileID) {
            for categoryID in suggestion.categoryIDs where validCategoryIDs.contains(categoryID) {
                guard index.fileCategoryLinks[suggestion.fileID]?.contains(categoryID) != true else {
                    continue
                }
                changes.append(AIClassificationChange(
                    fileID: suggestion.fileID,
                    categoryID: categoryID
                ))
            }
        }
        try await index.applyAICategories(changes, assigned: true)
        return changes
    }

    func undoAIClassification(_ changes: [AIClassificationChange]) async throws {
        guard index.isDatabaseAvailable else {
            throw FileIndexError.databaseUnavailable
        }
        try await index.applyAICategories(changes, assigned: false)
    }

    // MARK: - OAuth forwarding

    /// Connects the OAuth coordinator to the AI layer. Settings observes
    /// `oauth` directly, so polling does not redraw the rest of the window.
    private func wireOAuthCoordinator() {
        oauth.onProviderUnavailable = { [weak self] kind, preservingPreference in
            self?.ai.clearActiveOAuthProviderIfNeeded(
                kind,
                preservingPreference: preservingPreference
            )
        }
        oauth.onProviderConnected = { [weak self] in
            self?.ai.restorePendingActiveProviderIfEligible()
        }
        oauth.onFailure = { [weak self] message in
            self?.reportError(message)
        }
    }

    private func wireAISessionCoordinator() {
        ai.onError = { [weak self] message in
            self?.reportError(message)
        }
        ai.onActiveProviderChanged = { [weak self] in
            self?.index.scheduleSearch(query: self?.searchText ?? "")
        }
        // Only the active provider is needed by the file toolbar. OAuth polling
        // and connection tests stay on the coordinators so they do not redraw
        // the whole window.
        aiObservation = ai.$activeProviderKind.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func wireIndexCoordinator() {
        index.undoCoordinator = undo
        index.onError = { [weak self] message in
            self?.reportError(message)
        }
        index.onFilesChanged = { [weak self] in
            guard let self else { return }
            // Keep selection and AI results consistent with the new file set.
            if !selectedFileIDs.isEmpty {
                clearSelectionIfHidden(from: index.allFileIDs)
            }
            if let aiSearchResults {
                let resultIDs = Set(aiSearchResults.map(\.id))
                self.aiSearchResults = self.index.files(ids: resultIDs)
            }
        }
        index.onFileResolved = { [weak self] url in
            guard let self else { return }
            let path = FilePathCanonicalizer.path(url)
            guard let newID = self.index.file(at: URL(fileURLWithPath: path))?.id else { return }
            var next = self.fileSelection
            next.resolveIdentity(from: self.selectedFileID, to: newID)
            self.applyFileSelection(next)
        }
        // Forward only the index fields that change the shell's own state.
        // Category links, trash-undo, and search-in-progress live on dedicated
        // stores so toggling a category or dismissing a banner does not rebuild
        // the All Files table, sidebar, and inspector together.
        func forward<Value>(_ publisher: Published<Value>.Publisher) {
            publisher
                .dropFirst()
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &indexObservations)
        }
        forward(index.$files)
        forward(index.$categories)
        forward(index.$savedSearches)
        forward(index.$sources)
        forward(index.$searchResults)
        forward(index.$searchResultTotalCount)
        forward(index.$isDatabaseAvailable)
        forward(index.$includesHiddenFiles)
        forward(index.$scanScopeMode)
        forward(index.$wholeMacSourceID)
        forward(index.$isWholeMacScanPaused)
        forward(index.$isScanning)
        forward(index.$isUpdatingContentIndex)
    }

    // MARK: - File index forwarding

    var sources: [FileSource] { index.sources }
    var selectedFolderSources: [FileSource] { index.selectedFolderSources }
    var wholeMacSource: FileSource? { index.wholeMacSource }
    var scanScopeMode: FileScanScopeMode { index.scanScopeMode }
    var isWholeMacScanPaused: Bool { index.isWholeMacScanPaused }
    var files: [IndexedFile] { index.files }
    var categories: [FileCategory] { index.categories }
    var fileCategoryLinks: [String: Set<UUID>] { index.fileCategoryLinks }
    var searchResults: [IndexedFile]? { index.searchResults }
    var searchResultTotalCount: Int? { index.searchResultTotalCount }
    var searchResultsRevision: UInt64 { index.searchResultsRevision }
    var isSearching: Bool { index.isSearching }
    var searchProgressStore: SearchProgressStore { index.searchProgressStore }
    var scanProgressStore: ScanProgressStore { index.scanProgressStore }
    var scanProgress: ScanProgress? { index.scanProgress }
    var isScanning: Bool { index.isScanning }
    var includesHiddenFiles: Bool { index.includesHiddenFiles }
    var isDatabaseAvailable: Bool { index.isDatabaseAvailable }
    var isUpdatingContentIndex: Bool { index.isUpdatingContentIndex }

    var selectedFile: IndexedFile? {
        guard let selectedFileID else { return nil }
        return index.file(id: selectedFileID)
    }

    var recentFiles: [IndexedFile] { index.recentFiles }
    var hasMoreSearchResults: Bool { index.hasMoreSearchResults }

    func categories(for file: IndexedFile) -> [FileCategory] {
        index.categories(for: file)
    }

    func files(in category: FileCategory) -> [IndexedFile] {
        index.files(in: category)
    }

    func files(ids: Set<String>) -> [IndexedFile] {
        index.files(ids: ids)
    }

    func fileCount(in category: FileCategory) -> Int {
        index.fileCount(in: category)
    }

    func isCategory(_ category: FileCategory, assignedTo file: IndexedFile) -> Bool {
        index.isCategory(category, assignedTo: file)
    }

    /// Maintained ID set of every indexed file (O(1) lookup); views use it
    /// instead of building `Set(files.map(\.id))` per change.
    var allFileIDs: Set<String> { index.allFileIDs }

    func fileCount(for kind: FileKind) -> Int {
        index.fileCount(for: kind)
    }

    func files(for kind: FileKind) -> [IndexedFile] {
        index.files(for: kind)
    }

    func loadMoreSearchResults() {
        index.loadMoreSearchResults(query: searchText)
    }

    func chooseFolder(startingAt directoryURL: URL? = nil) {
        index.chooseFolder(startingAt: directoryURL)
    }

    func chooseWholeMacScope() {
        index.chooseWholeMacScope()
    }

    func setScanScopeMode(_ mode: FileScanScopeMode) {
        index.setScanScopeMode(mode)
    }

    func openFullDiskAccessSettings() {
        index.openFullDiskAccessSettings()
    }

    func pauseWholeMacScan() {
        index.pauseWholeMacScan()
    }

    func resumeWholeMacScan() {
        index.resumeWholeMacScan()
    }

    func reauthorizeSource(_ source: FileSource) {
        index.reauthorizeSource(source)
    }

    func removeSource(_ source: FileSource) {
        index.removeSource(source)
    }

    func setSourceEnabled(_ source: FileSource, enabled: Bool) {
        index.setSourceEnabled(source, enabled: enabled)
    }

    func scanSource(_ source: FileSource) {
        index.scanSource(source)
    }

    func refreshAllSources() {
        index.refreshAllSources()
    }

    func setIncludesHiddenFiles(_ includesHiddenFiles: Bool) {
        index.setIncludesHiddenFiles(includesHiddenFiles)
    }

    func setIndexesFileContents(_ enabled: Bool) {
        index.setIndexesFileContents(enabled)
    }

    func cancelScan(startsPendingFullRescan: Bool = true) {
        index.cancelScan(startsPendingFullRescan: startsPendingFullRescan)
    }

    func retryDatabase() async {
        await index.retryDatabase()
    }

    func open(_ file: IndexedFile) {
        index.open(file)
    }

    func showInFinder(_ file: IndexedFile) {
        index.showInFinder(file)
    }

    func quickLook(_ file: IndexedFile) {
        index.quickLook(file)
    }

    func copyPath(_ file: IndexedFile) {
        index.copyPath(file)
    }

    /// On-demand text content for the inspector's inline preview (N08).
    func fetchTextContent(forFileID fileID: String) async throws -> String? {
        guard let file = index.file(id: fileID) else { return nil }
        return try await textContentForExplicitUse(file)
    }

    /// Cancellable, bounded text path for Inspector. AI requests continue to
    /// use `textContentForExplicitUse` and its larger explicit-use budget.
    func fetchInspectorPreviewText(
        forFileID fileID: String,
        maximumCharacters: Int
    ) async throws -> String? {
        guard let file = index.file(id: fileID), maximumCharacters > 0 else { return nil }
        if let indexed = try await index.textContentPrefix(
            forFileID: fileID,
            maximumCharacters: maximumCharacters
        ), !indexed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return indexed
        }
        guard supportsTextContent(file) else { return nil }
        let extraction = Task.detached(priority: .userInitiated) {
            TextExtractionService(maxCharacterCount: maximumCharacters).extractText(
                from: file.url,
                isCancelled: { Task.isCancelled }
            )
        }
        return try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }
    }

    func rename(_ file: IndexedFile, to newName: String) async throws {
        try await index.rename(file, to: newName)
        renameRequest = nil
    }

    func chooseMoveDestination(for file: IndexedFile) {
        index.chooseMoveDestination(for: file)
    }

    func confirmTrash() {
        guard let file = trashRequest else { return }
        trashRequest = nil
        index.confirmTrash(file)
    }

    // MARK: - Batch operations (F05)

    var selectedFiles: [IndexedFile] {
        index.files(ids: selectedFileIDs)
    }

    func requestBatchTrash() {
        requestBatchTrash(Self.filesForBatchAction(
            selectedIDs: selectedFileIDs,
            commandTargetFiles: commandTargetFiles
        ))
    }

    nonisolated static func filesForBatchAction(
        selectedIDs: Set<String>,
        commandTargetFiles: [IndexedFile]
    ) -> [IndexedFile] {
        commandTargetFiles.filter { selectedIDs.contains($0.id) }
    }

    func requestBatchTrash(_ files: [IndexedFile]) {
        guard !files.isEmpty else { return }
        batchTrashRequest = files
    }

    func confirmBatchTrash() {
        guard let files = batchTrashRequest else { return }
        batchTrashRequest = nil
        selectedFileIDs = []
        index.confirmBatchTrash(files)
    }

    // MARK: - Undo (N10)

    var lastTrashUndo: FileIndexCoordinator.TrashUndo? {
        index.lastTrashUndo
    }

    func undoLastTrash() {
        index.undoLastTrash()
    }

    func dismissTrashUndoBanner() {
        index.dismissTrashUndoBanner()
    }

    func cancelBatchTrash() {
        batchTrashRequest = nil
    }

    /// Adds every selected file to a category (files already in it are
    /// skipped), reusing the same debounced write path as single-file menus.
    func assignSelectedFiles(to category: FileCategory) {
        index.addCategory(category, toFiles: selectedFiles)
    }

    // MARK: - Drag and drop (F06)

    /// A folder dropped onto the Settings view becomes a scan source.
    func addFolderDropped(url: URL) {
        Task { await index.addSource(url) }
    }

    /// A file dropped onto a category row gets that category. Files that are
    /// not indexed yet show an error instead of failing silently.
    @discardableResult
    func assignDroppedFiles(urls: [URL], to category: FileCategory) -> Bool {
        var assigned: [IndexedFile] = []
        var skippedNames: [String] = []
        for url in urls {
            if let file = index.file(at: url) {
                assigned.append(file)
            } else {
                skippedNames.append(url.lastPathComponent)
            }
        }
        if !assigned.isEmpty {
            index.addCategory(category, toFiles: assigned)
        }
        if !skippedNames.isEmpty {
            reportError(assigned.isEmpty
                ? AppLanguage.localized(
                    "这些文件尚未建立索引，请先在设置中添加它们所在的文件夹。",
                    english: "These files are not indexed yet. Add their folders in Settings first."
                )
                : AppLanguage.localized(
                    "已添加 \(assigned.count) 个文件；有 \(skippedNames.count) 个还不在索引中。",
                    english: "Added \(assigned.count) file(s); \(skippedNames.count) are not indexed yet."
                )
            )
        }
        return !assigned.isEmpty
    }

    func assignDroppedFile(url: URL, to category: FileCategory) {
        _ = assignDroppedFiles(urls: [url], to: category)
    }

    /// A path received from another app via the Services menu (N14).
    /// Selects the file when it is indexed; reveals it in Finder otherwise.
    func handleExternalPath(_ path: String) {
        handleExternalPaths([path])
    }

    func handleExternalPaths(_ paths: [String]) {
        var matchedIDs: Set<String> = []
        var unmatchedURLs: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let file = index.file(at: url) {
                matchedIDs.insert(file.id)
            } else {
                unmatchedURLs.append(url)
            }
        }
        if !matchedIDs.isEmpty {
            selectedFileIDs = matchedIDs
            if !unmatchedURLs.isEmpty {
                reportError(AppLanguage.localized(
                    "已选择索引中的文件；另有 \(unmatchedURLs.count) 个文件尚未建立索引。",
                    english: "Selected the indexed files; \(unmatchedURLs.count) file(s) are not indexed yet."
                ))
            }
        }
        if matchedIDs.isEmpty, !unmatchedURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(unmatchedURLs)
        }
    }

    func createCategory(name: String, symbolName: String) async throws {
        try await index.createCategory(name: name, symbolName: symbolName)
    }

    func renameCategory(_ category: FileCategory, to name: String) async throws {
        try await index.renameCategory(category, to: name)
    }

    func deleteCategory(_ category: FileCategory) {
        index.deleteCategory(category)
    }

    func toggleCategory(_ category: FileCategory, for file: IndexedFile) {
        index.toggleCategory(category, for: file)
    }

    static func validateSourceCandidate(
        _ candidateURL: URL,
        against existingSources: [FileSource],
        excluding sourceID: UUID? = nil
    ) throws {
        try FileIndexCoordinator.validateSourceCandidate(
            candidateURL,
            against: existingSources,
            excluding: sourceID
        )
    }

    static func scanCleanupOwnsState(
        currentGeneration: UUID,
        finishingGeneration: UUID
    ) -> Bool {
        FileIndexCoordinator.scanCleanupOwnsState(
            currentGeneration: currentGeneration,
            finishingGeneration: finishingGeneration
        )
    }

    static func sourcesAffected(
        by urls: [URL],
        in sources: [FileSource]
    ) -> [FileSource] {
        FileIndexCoordinator.sourcesAffected(by: urls, in: sources)
    }

    static func shouldQueueFullRescan(isScanning: Bool) -> Bool {
        FileIndexCoordinator.shouldQueueFullRescan(isScanning: isScanning)
    }

    // MARK: - AI forwarding

    var aiProviderSettings: [AIProviderSettings] { ai.providerSettings }
    var activeAIProviderKind: AIProviderKind? { ai.activeProviderKind }
    var activeAIAuthenticationMode: AIAuthenticationMode? { ai.activeAuthenticationMode }
    var aiConnectionStates: [AIProviderKind: AIConnectionState] { ai.connectionStates }
    var aiCredentialErrors: [AIProviderKind: String] { ai.credentialErrors }

    func aiSettings(for kind: AIProviderKind) -> AIProviderSettings {
        ai.settings(for: kind)
    }

    func aiConnectionState(for kind: AIProviderKind) -> AIConnectionState {
        ai.connectionState(for: kind)
    }

    func aiCredentialError(for kind: AIProviderKind) -> String? {
        ai.credentialError(for: kind)
    }

    @discardableResult
    func saveAIProvider(
        _ kind: AIProviderKind,
        baseURL: String,
        model: String,
        apiKey: String
    ) -> Bool {
        ai.saveProvider(kind, baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func deleteAIKey(for kind: AIProviderKind) {
        ai.deleteAPIKey(for: kind)
    }

    func setActiveAIProvider(_ kind: AIProviderKind) {
        ai.setActiveAPIKeyProvider(kind)
    }

    func setActiveOAuthAIProvider(_ kind: AIProviderKind) {
        ai.setActiveOAuthProvider(kind)
    }

    func testAIProvider(_ kind: AIProviderKind) {
        ai.testProvider(kind)
    }

    func cancelAIProviderTest(_ kind: AIProviderKind) {
        ai.cancelTest(kind)
    }

    // Compatibility surface: keep the pre-extraction names working so views
    // don't have to be touched.

    var aiOAuthStates: [AIProviderKind: AIOAuthState] { oauth.states }
    var aiOAuthDeviceCodePresentations: [AIProviderKind: AIOAuthDeviceCodePresentation] {
        oauth.deviceCodePresentations
    }
    var aiOAuthVerificationsInFlight: Set<AIProviderKind> { oauth.verificationsInFlight }

    var savedSearches: [SavedSearch] { index.savedSearches }

    func saveSearch(
        name: String,
        query: String,
        minSizeBytes: Int64,
        minDate: Date?
    ) {
        index.saveSearch(
            name: name,
            query: query,
            minSizeBytes: minSizeBytes,
            minDate: minDate,
            fileKind: selectedKind
        )
    }

    func renameSavedSearch(_ search: SavedSearch, to name: String) {
        index.saveSearch(
            name: name,
            query: search.query,
            minSizeBytes: search.minSizeBytes,
            minDate: search.minDate,
            fileKind: search.fileKind,
            id: search.id,
            createdAt: search.createdAt
        )
    }

    func updateSavedSearch(_ search: SavedSearch) {
        index.saveSearch(
            name: search.name,
            query: searchText,
            minSizeBytes: Int64(filterMinSizeMB * 1_024 * 1_024),
            minDate: filterMinDate > 0 ? Date(timeIntervalSince1970: filterMinDate) : nil,
            fileKind: selectedKind,
            id: search.id,
            createdAt: search.createdAt
        )
    }

    func deleteSearch(id: UUID) {
        index.deleteSearch(id: id)
    }

    /// Applies a saved search: restores the query plus manual filters (N07).
    func applySavedSearch(_ search: SavedSearch) {
        clearAISearch()
        selectedKind = search.fileKind
        searchText = search.query
        applyManualFilter(minSizeBytes: search.minSizeBytes, minDate: search.minDate)
    }

    /// Keyword search from Home, the palette, or the menu bar: drop type, AI,
    /// and manual filters so the query is what the user actually sees.
    func searchAllFiles(query: String) {
        updateCommandTargetFiles([])
        clearAISearch()
        selectedKind = nil
        searchText = query
        filterMinSizeMB = 0
        filterMinDate = 0
        NotificationCenter.default.post(name: .xunJianRevealInAllFiles, object: nil)
    }

    /// Selects a file (or group) and asks the shell to show All Files.
    func revealInAllFiles(_ files: [IndexedFile]) {
        guard !files.isEmpty else { return }
        clearAISearch()
        selectedKind = nil
        searchText = ""
        filterMinSizeMB = 0
        filterMinDate = 0
        if files.count == 1, let file = files.first {
            selectedFileID = file.id
        } else {
            selectedFileIDs = Set(files.map(\.id))
        }
        NotificationCenter.default.post(name: .xunJianRevealInAllFiles, object: nil)
    }

    func revealInAllFiles(_ file: IndexedFile) {
        revealInAllFiles([file])
    }

    func refreshOAuthStatus(
        for kind: AIProviderKind,
        presentsFailure: Bool = true
    ) async {
        await oauth.refreshStatus(for: kind, presentsFailure: presentsFailure)
    }

    @discardableResult
    func beginOAuthLogin(for kind: AIProviderKind) async -> URL? {
        await oauth.beginLogin(for: kind)
    }

    @discardableResult
    func beginOAuthDeviceCodeLogin(
        for kind: AIProviderKind
    ) async -> AIOAuthDeviceCodePresentation? {
        await oauth.beginDeviceCodeLogin(for: kind)
    }

    func cancelOAuthLogin(for kind: AIProviderKind) async {
        await oauth.cancelLogin(for: kind)
    }

    func verifyOAuthConnection(for kind: AIProviderKind) async {
        await oauth.verifyConnection(for: kind)
    }

    func disconnectOAuthProvider(_ kind: AIProviderKind) async {
        await oauth.disconnect(kind)
    }

    func logoutOAuthProvider(for kind: AIProviderKind) async {
        await oauth.logout(for: kind)
    }

    func applicationBecameActive() {
        oauth.applicationBecameActive()
        let current = Locale.preferredLanguages.first
        if current != lastPreferredLanguage {
            lastPreferredLanguage = current
            localeRevision &+= 1
        }
    }

    func applicationResignedActive() {
        oauth.applicationResignedActive()
        flushManualFilterPersistence()
    }

    /// Drops every selected file that is no longer visible, keeping the rest.
    ///
    /// Checking only the first selection left stale IDs in the set, so the
    /// batch bar could claim "3 selected" while showing two rows.
    func clearSelectionIfHidden(from visibleFileIDs: Set<String>) {
        let remaining = selectedFileIDs.intersection(visibleFileIDs)
        guard remaining.count != selectedFileIDs.count else { return }
        selectedFileIDs = remaining
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
