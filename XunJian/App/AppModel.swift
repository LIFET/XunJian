import AppKit
import Combine
import Foundation

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
        didSet { reconcileFileSelectionMetadata() }
    }
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
    @Published var errorMessage: String?
    @Published var renameRequest: IndexedFile?
    @Published var trashRequest: IndexedFile?
    /// Batch trash confirmation (F05 multi-select).
    @Published var batchTrashRequest: [IndexedFile]?
    /// AI sheet request, owned here so both the file list and the inspector
    /// can open the same sheets (N04).
    @Published var aiSheetRequest: AITaskSheet?
    @Published var searchText = "" {
        didSet { index.scheduleSearch(query: searchText) }
    }

    // Manual filter values (N02), persisted so saved searches can restore
    // them. MB is the UI unit; bytes are derived by the view.
    @Published var filterMinSizeMB: Double {
        didSet {
            UserDefaults.standard.set(
                filterMinSizeMB,
                forKey: "allFiles.filterMinSizeMB"
            )
        }
    }
    @Published var filterMinDate: Double {
        didSet {
            UserDefaults.standard.set(
                filterMinDate,
                forKey: "allFiles.filterMinDate"
            )
        }
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
    private var indexObservation: AnyCancellable?

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
    @Published var browseSnapshot: [IndexedFile] = []
    /// Identifies the inputs `browseSnapshot` was built from. `nil` means
    /// nothing has been prepared yet, which is the only case that warrants
    /// showing a spinner.
    @Published var browseSnapshotSignature: Int?

    /// The files currently visible on the active page. Export and ⌘A read
    /// this rather than the All Files snapshot, which goes stale after the
    /// user leaves that page.
    @Published var commandTargetFiles: [IndexedFile] = []

    func updateCommandTargetFiles(_ files: [IndexedFile]) {
        if commandTargetFiles.map(\.id) == files.map(\.id) { return }
        commandTargetFiles = files
    }

    var filesRevision: UInt64 { index.filesRevision }
    var categoryRevision: UInt64 { index.categoryRevision }

    /// Selects everything currently visible in the file list, which is what
    /// ⌘A means to the user — not every file in the index.
    func selectAllDisplayedFiles() {
        var next = FileSelection()
        next.selectAll(orderedIDs: commandTargetFiles.map(\.id))
        applyFileSelection(next)
    }

    /// Click in a custom list or grid. Reads ⌘/⇧ from the current event so
    /// hosts don't each reimplement Finder-style multi-select.
    func selectDisplayedFile(_ file: IndexedFile, in files: [IndexedFile]) {
        let modifiers = NSEvent.modifierFlags
        selectDisplayedFile(
            file.id,
            in: files,
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
        var next = fileSelection
        next.select(fileID, in: files.map(\.id), command: command, shift: shift)
        applyFileSelection(next)
    }

    func moveDisplayedSelection(
        by offset: Int,
        in files: [IndexedFile],
        extending: Bool
    ) {
        var next = fileSelection
        next.moveLead(by: offset, in: files.map(\.id), extending: extending)
        applyFileSelection(next)
    }

    private func applyFileSelection(_ next: FileSelection) {
        selectionLeadID = next.leadID
        selectionAnchorID = next.anchorID
        selectedFileIDs = next.ids
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
                errorMessage = Self.message(for: error)
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
        errorMessage = nil
    }

    func requestRename(_ file: IndexedFile) {
        renameRequest = file
    }

    func requestTrash(_ file: IndexedFile) {
        trashRequest = file
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
            throw FileIndexError.database("database unavailable")
        }
        let service = try ai.currentService()
        let plan = try await service.searchPlan(for: query)
        try Task.checkCancellation()

        let candidates: [IndexedFile]
        if plan.keywords.isEmpty {
            candidates = index.files
        } else {
            // F13: one OR query instead of up to 12 separate FTS round-trips.
            // The candidate order comes from `files` either way, so batching
            // the lookup does not change the result set.
            var candidateByID: [String: IndexedFile] = [:]
            // AI filters must see the complete local candidate set. Ordinary
            // search paginates for presentation, but silently truncating this
            // set would make a valid file impossible for the plan to return.
            let candidateLimit = max(index.files.count, 1)
            for file in try await index.searchFiles(
                matchingAnyOf: plan.keywords,
                limit: candidateLimit
            ) {
                candidateByID[file.id] = file
            }
            candidates = index.files.filter { candidateByID[$0.id] != nil }
        }

        try Task.checkCancellation()
        aiSearchResults = plan.filter(candidates)
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

    func classifyWithAI(_ files: [IndexedFile]) async throws -> [AIClassificationSuggestion] {
        guard !index.categories.isEmpty else { throw AIServiceError.noCategories }
        var filesWithText: [IndexedFile] = []
        filesWithText.reserveCapacity(files.count)
        for file in files {
            filesWithText.append(try await fileWithText(file))
        }
        return try await ai.currentService().classify(
            files: filesWithText,
            categories: index.categories
        )
    }

    private func fileWithText(_ file: IndexedFile) async throws -> IndexedFile {
        let textContent = try await index.textContent(forFileID: file.id)
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

    func applyAIClassification(
        _ suggestions: [AIClassificationSuggestion]
    ) async throws -> [AIClassificationChange] {
        guard index.isDatabaseAvailable else { return [] }
        let validFileIDs = Set(index.files.map(\.id))
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
            throw FileIndexError.database("database unavailable")
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
            self?.errorMessage = message
        }
    }

    private func wireAISessionCoordinator() {
        ai.onError = { [weak self] message in
            self?.errorMessage = message
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
            self?.errorMessage = message
        }
        index.onFilesChanged = { [weak self] in
            guard let self else { return }
            // Keep selection and AI results consistent with the new file set.
            if !selectedFileIDs.isEmpty {
                clearSelectionIfHidden(from: Set(index.files.map(\.id)))
            }
            if let aiSearchResults {
                let resultIDs = Set(aiSearchResults.map(\.id))
                self.aiSearchResults = self.index.files.filter { resultIDs.contains($0.id) }
            }
        }
        index.onFileResolved = { [weak self] url in
            guard let self else { return }
            let path = FilePathCanonicalizer.path(url)
            self.selectedFileID = self.index.files.first {
                FilePathCanonicalizer.path($0.url) == path
            }?.id
        }
        indexObservation = index.objectWillChange.sink { [weak self] _ in
            // Scan counting lives on `scanProgressStore` and is not
            // `@Published` here, so this fan-out is start/stop and index
            // changes, not every 100 files.
            self?.objectWillChange.send()
        }
    }

    // MARK: - File index forwarding

    var sources: [FileSource] { index.sources }
    var files: [IndexedFile] { index.files }
    var categories: [FileCategory] { index.categories }
    var fileCategoryLinks: [String: Set<UUID>] { index.fileCategoryLinks }
    var searchResults: [IndexedFile]? { index.searchResults }
    var searchResultTotalCount: Int? { index.searchResultTotalCount }
    var isSearching: Bool { index.isSearching }
    var searchProgressStore: SearchProgressStore { index.searchProgressStore }
    var scanProgressStore: ScanProgressStore { index.scanProgressStore }
    var scanProgress: ScanProgress? { index.scanProgress }
    var isScanning: Bool { index.isScanning }
    var includesHiddenFiles: Bool { index.includesHiddenFiles }
    var isDatabaseAvailable: Bool { index.isDatabaseAvailable }

    var selectedFile: IndexedFile? {
        guard let selectedFileID else { return nil }
        return index.files.first(where: { $0.id == selectedFileID })
    }

    var recentFiles: [IndexedFile] { index.recentFiles }
    var hasMoreSearchResults: Bool { index.hasMoreSearchResults }

    func categories(for file: IndexedFile) -> [FileCategory] {
        index.categories(for: file)
    }

    func files(in category: FileCategory) -> [IndexedFile] {
        index.files(in: category)
    }

    func fileCount(in category: FileCategory) -> Int {
        index.fileCount(in: category)
    }

    func isCategory(_ category: FileCategory, assignedTo file: IndexedFile) -> Bool {
        index.isCategory(category, assignedTo: file)
    }

    func fileCount(for kind: FileKind) -> Int {
        index.fileCount(for: kind)
    }

    func loadMoreSearchResults() {
        index.loadMoreSearchResults(query: searchText)
    }

    func chooseFolder(startingAt directoryURL: URL? = nil) {
        index.chooseFolder(startingAt: directoryURL)
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

    func setIndexesFileContents(_ enabled: Bool) async {
        await index.setIndexesFileContents(enabled)
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
        try await index.textContent(forFileID: fileID)
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
        index.files.filter { selectedFileIDs.contains($0.id) }
    }

    func requestBatchTrash() {
        requestBatchTrash(selectedFiles)
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
    func assignDroppedFile(url: URL, to category: FileCategory) {
        let path = FilePathCanonicalizer.path(url)
        guard let file = index.files.first(where: {
            FilePathCanonicalizer.path($0.url) == path
        }) else {
            errorMessage = AppLanguage.localized(
                "这个文件尚未建立索引，请先在设置中添加它所在的文件夹。",
                english: "This file is not indexed yet. Add its folder in Settings first."
            )
            return
        }
        index.addCategory(category, toFiles: [file])
    }

    /// A path received from another app via the Services menu (N14).
    /// Selects the file when it is indexed; reveals it in Finder otherwise.
    func handleExternalPath(_ path: String) {
        handleExternalPaths([path])
    }

    func handleExternalPaths(_ paths: [String]) {
        var filesByPath: [String: IndexedFile] = [:]
        for file in index.files {
            filesByPath[FilePathCanonicalizer.path(file.url)] = file
        }
        var matchedIDs: Set<String> = []
        var unmatchedURLs: [URL] = []
        for path in paths {
            if let file = filesByPath[FilePathCanonicalizer.path(path)] {
                matchedIDs.insert(file.id)
            } else {
                unmatchedURLs.append(URL(fileURLWithPath: path))
            }
        }
        if !matchedIDs.isEmpty {
            selectedFileIDs = matchedIDs
            errorMessage = unmatchedURLs.isEmpty ? nil : AppLanguage.localized(
                "已选择索引中的文件；另有 \(unmatchedURLs.count) 个文件尚未建立索引。",
                english: "Selected the indexed files; \(unmatchedURLs.count) file(s) are not indexed yet."
            )
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

    static func shouldRemoveMissingFiles(
        failedScopeCount: Int,
        hasRemovalEvents: Bool
    ) -> Bool {
        FileIndexCoordinator.shouldRemoveMissingFiles(
            failedScopeCount: failedScopeCount,
            hasRemovalEvents: hasRemovalEvents
        )
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
            minDate: minDate
        )
    }

    func renameSavedSearch(_ search: SavedSearch, to name: String) {
        index.saveSearch(
            name: name,
            query: search.query,
            minSizeBytes: search.minSizeBytes,
            minDate: search.minDate,
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
            id: search.id,
            createdAt: search.createdAt
        )
    }

    func deleteSearch(id: UUID) {
        index.deleteSearch(id: id)
    }

    /// Applies a saved search: restores the query plus manual filters (N07).
    func applySavedSearch(_ search: SavedSearch) {
        searchText = search.query
        applyManualFilter(minSizeBytes: search.minSizeBytes, minDate: search.minDate)
    }

    /// Selects a file (or group) and asks the shell to show All Files.
    func revealInAllFiles(_ files: [IndexedFile]) {
        guard !files.isEmpty else { return }
        selectedKind = nil
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
    }

    func applicationResignedActive() {
        oauth.applicationResignedActive()
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
