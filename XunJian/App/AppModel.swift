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

    @Published private(set) var aiSearchResults: [IndexedFile]?
    @Published private(set) var aiSearchPlan: AISearchPlan?
    @Published private(set) var aiSearchQuery: String?
    /// Multi-selection in the file table/grid (F05). `selectedFileID` remains
    /// as the single-selection compatibility surface on top of this set.
    @Published var selectedFileIDs: Set<String> = []
    var selectedFileID: String? {
        get { selectedFileIDs.first }
        set {
            if let newValue {
                selectedFileIDs = [newValue]
            } else {
                selectedFileIDs = []
            }
        }
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
    /// the app. Its mutations are forwarded below so existing views keep
    /// observing the same names.
    let oauth: OAuthCoordinator
    private var oauthObservation: AnyCancellable?

    /// AI session state machine (settings, verification, active provider),
    /// extracted so it can be tested without the file-index machinery.
    let ai: AISessionCoordinator
    private var aiObservation: AnyCancellable?

    /// File index domain (database, scanning, search, file operations),
    /// extracted so it can be tested without the AI machinery.
    let index: FileIndexCoordinator
    private var indexObservation: AnyCancellable?

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
            for file in try await index.searchFiles(matchingAnyOf: plan.keywords, limit: 500) {
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

    func askAI(_ question: String, about file: IndexedFile) async throws -> String {
        try await ai.currentService().answer(
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

    /// Connects the OAuth coordinator to the AI layer and re-emits its
    /// `objectWillChange` so views observing `AppModel` refresh on OAuth
    /// changes exactly as they did before the extraction.
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
        oauthObservation = oauth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func wireAISessionCoordinator() {
        ai.onError = { [weak self] message in
            self?.errorMessage = message
        }
        ai.onActiveProviderChanged = { [weak self] in
            self?.index.scheduleSearch(query: self?.searchText ?? "")
        }
        aiObservation = ai.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func wireIndexCoordinator() {
        index.onError = { [weak self] message in
            self?.errorMessage = message
        }
        index.onFilesChanged = { [weak self] in
            guard let self else { return }
            // Keep selection and AI results consistent with the new file set.
            if let selectedFileID,
               !self.index.files.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            if let aiSearchResults {
                let resultIDs = Set(aiSearchResults.map(\.id))
                self.aiSearchResults = self.index.files.filter { resultIDs.contains($0.id) }
            }
        }
        index.onFileResolved = { [weak self] url in
            guard let self else { return }
            let path = url.standardizedFileURL.path
            self.selectedFileID = self.index.files.first {
                $0.url.standardizedFileURL.path == path
            }?.id
        }
        indexObservation = index.objectWillChange.sink { [weak self] _ in
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
        guard !selectedFiles.isEmpty else { return }
        batchTrashRequest = selectedFiles
    }

    func confirmBatchTrash() {
        guard let files = batchTrashRequest else { return }
        batchTrashRequest = nil
        selectedFileIDs = []
        index.confirmBatchTrash(files)
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
    /// not indexed yet are ignored (scan them first).
    func assignDroppedFile(url: URL, to category: FileCategory) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let file = index.files.first(where: {
            $0.url.standardizedFileURL.path == path
        }) else { return }
        index.addCategory(category, toFiles: [file])
    }

    /// A path received from another app via the Services menu (N14).
    /// Selects the file when it is indexed; reveals it in Finder otherwise.
    func handleExternalPath(_ path: String) {
        let standardized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if let file = index.files.first(where: {
            $0.url.standardizedFileURL.path == standardized
        }) {
            selectedFileIDs = [file.id]
            errorMessage = nil
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: path)
            ])
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

    func deleteSearch(id: UUID) {
        index.deleteSearch(id: id)
    }

    /// Applies a saved search: restores the query plus manual filters (N07).
    func applySavedSearch(_ search: SavedSearch) {
        searchText = search.query
        applyManualFilter(minSizeBytes: search.minSizeBytes, minDate: search.minDate)
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

    func clearSelectionIfHidden(from visibleFileIDs: Set<String>) {
        guard let selectedFileID,
              !visibleFileIDs.contains(selectedFileID) else { return }
        self.selectedFileID = nil
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
