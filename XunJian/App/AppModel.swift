import AppKit
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

private struct FileCategoryAssignmentKey: Hashable, Sendable {
    let fileID: String
    let categoryID: UUID
}

private struct PendingCategoryAssignment: Equatable, Sendable {
    let desiredAssignment: Bool
    let revision: UInt64
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [FileSource] = []
    @Published private(set) var files: [IndexedFile] = []
    @Published private(set) var categories: [FileCategory] = []
    @Published private(set) var fileCategoryLinks: [String: Set<UUID>] = [:]
    @Published private(set) var searchResults: [IndexedFile]? = nil
    @Published private(set) var searchResultTotalCount: Int? = nil
    @Published private(set) var isSearching = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var aiProviderSettings: [AIProviderSettings] = []
    @Published private(set) var activeAIProviderKind: AIProviderKind?
    @Published private(set) var activeAIAuthenticationMode: AIAuthenticationMode?
    @Published private(set) var aiConnectionStates: [AIProviderKind: AIConnectionState] = [:]
    @Published private(set) var aiCredentialErrors: [AIProviderKind: String] = [:]
    @Published private(set) var aiOAuthStates: [AIProviderKind: AIOAuthState] = [
        .codex: .statusUnknown,
        .grok: .statusUnknown
    ]
    @Published private(set) var aiOAuthDeviceCodePresentations: [
        AIProviderKind: AIOAuthDeviceCodePresentation
    ] = [:]
    @Published private(set) var aiOAuthVerificationsInFlight = Set<AIProviderKind>()
    @Published private(set) var aiSearchResults: [IndexedFile]?
    @Published private(set) var aiSearchPlan: AISearchPlan?
    @Published private(set) var aiSearchQuery: String?
    @Published private(set) var isDatabaseAvailable = true
    @Published var selectedFileID: String?
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
    @Published private(set) var includesHiddenFiles = false
    @Published var errorMessage: String?
    @Published var renameRequest: IndexedFile?
    @Published var trashRequest: IndexedFile?
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }

    private var database: FileIndexDatabase?
    private let isRunningTests: Bool
    private let scanner = FileScanner()
    private let bookmarkManager = BookmarkManager()
    private let fileOperations = FileOperationService()
    private let fileSystemMonitor = FileSystemChangeMonitor()
    private let credentialStore: LocalCredentialStore
    private let aiConfigurationStore: AIConfigurationStore
    private let oauthBridgeService: any OAuthBridgeServicing
    private static let selectedKindPreferenceKey = "allFiles.selectedKind"
    private static let searchResultBatchSize = 500
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanningSourceIDs = Set<UUID>()
    private var currentScanningSourceID: UUID?
    private var failedScanningSourceIDs = Set<UUID>()
    private var searchTask: Task<Void, Never>?
    private var fileChangeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileChanges: [UUID: Set<FileSystemChangeEvent>] = [:]
    private var pendingFullRescanSourceIDs = Set<UUID>()
    private var activeSecurityScopes: [UUID: URL] = [:]
    private var oauthOperationGenerations: [AIProviderKind: UUID] = [:]
    private var oauthLoginAttemptIDs: [AIProviderKind: UUID] = [:]
    private var oauthLoginStartGenerations: [AIProviderKind: UUID] = [:]
    private var oauthMutationGenerations: [AIProviderKind: UUID] = [:]
    private var oauthMutationWaiters: [
        AIProviderKind: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var oauthStatusInFlight = Set<AIProviderKind>()
    private var oauthStatusWaiters: [
        AIProviderKind: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var aiVerificationFingerprints: [AIProviderKind: String] = [:]
    private var aiVerificationGenerations: [AIProviderKind: UUID] = [:]
    private var aiVerificationTasks: [AIProviderKind: Task<Void, Never>] = [:]
    private var categoryMutationTasks: [FileCategoryAssignmentKey: Task<Void, Never>] = [:]
    private var pendingCategoryAssignments: [
        FileCategoryAssignmentKey: PendingCategoryAssignment
    ] = [:]
    private var oauthPollingTask: Task<Void, Never>?
    private var pendingActiveAIProviderKind: AIProviderKind?
    private var pendingActiveAIAuthenticationMode: AIAuthenticationMode?

    init(
        oauthBridgeService: any OAuthBridgeServicing = OAuthBridgeClient.shared,
        credentialStore: LocalCredentialStore = LocalCredentialStore(),
        aiConfigurationStore: AIConfigurationStore = AIConfigurationStore()
    ) {
        self.oauthBridgeService = oauthBridgeService
        self.credentialStore = credentialStore
        self.aiConfigurationStore = aiConfigurationStore
        pendingActiveAIProviderKind = aiConfigurationStore.activeKind
        pendingActiveAIAuthenticationMode = aiConfigurationStore.activeAuthenticationMode
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningTests = isRunningTests
        let oauthKindToRefresh: AIProviderKind? = if !isRunningTests,
                                                    aiConfigurationStore.activeAuthenticationMode == .oauth,
                                                    let activeKind = aiConfigurationStore.activeKind,
                                                    Self.oauthProvider(for: activeKind) != nil {
            activeKind
        } else {
            nil
        }
        if !isRunningTests {
            selectedKind = UserDefaults.standard.string(forKey: Self.selectedKindPreferenceKey)
                .flatMap(FileKind.init(rawValue:))
            includesHiddenFiles = UserDefaults.standard.bool(
                forKey: FileIndexPreferences.includesHiddenFilesKey
            )
        }
        do {
            let databaseURL: URL
            if isRunningTests {
                databaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "XunJian-TestHost-\(ProcessInfo.processInfo.processIdentifier)",
                        isDirectory: true
                    )
                    .appendingPathComponent("index.sqlite3")
            } else {
                databaseURL = try FileIndexDatabase.defaultDatabaseURL()
            }
            database = try FileIndexDatabase(
                databaseURL: databaseURL
            )
        } catch {
            database = nil
            isDatabaseAvailable = false
            errorMessage = Self.message(for: error)
        }

        if isRunningTests {
            aiProviderSettings = AIProviderKind.allCases.map {
                AIProviderSettings(
                    kind: $0,
                    baseURL: $0.defaultBaseURL,
                    model: $0.defaultModel,
                    hasAPIKey: false
                )
            }
            aiConnectionStates = Dictionary(
                uniqueKeysWithValues: AIProviderKind.allCases.map { ($0, .notConfigured) }
            )
        } else {
            aiVerificationFingerprints = Dictionary(
                uniqueKeysWithValues: AIProviderKind.allCases.compactMap { kind in
                    aiConfigurationStore.apiKeyVerificationFingerprint(for: kind)
                        .map { (kind, $0) }
                }
            )
            reloadAISettings()
        }
        Task { [weak self] in
            await self?.reloadIndex()
        }
        if let oauthKindToRefresh {
            Task { [weak self] in
                await self?.refreshOAuthStatus(
                    for: oauthKindToRefresh,
                    presentsFailure: false
                )
            }
        }
    }

    deinit {
        oauthPollingTask?.cancel()
        aiVerificationTasks.values.forEach { $0.cancel() }
        categoryMutationTasks.values.forEach { $0.cancel() }
    }

    var selectedFile: IndexedFile? {
        guard let selectedFileID else { return nil }
        return files.first(where: { $0.id == selectedFileID })
    }

    var recentFiles: [IndexedFile] {
        Array(files.prefix(8))
    }

    var hasMoreSearchResults: Bool {
        guard let searchResults, let searchResultTotalCount else { return false }
        return searchResults.count < searchResultTotalCount
    }

    func categories(for file: IndexedFile) -> [FileCategory] {
        let assignedIDs = fileCategoryLinks[file.id] ?? []
        return categories.filter { assignedIDs.contains($0.id) }
    }

    func files(in category: FileCategory) -> [IndexedFile] {
        files.filter { fileCategoryLinks[$0.id]?.contains(category.id) == true }
    }

    func fileCount(in category: FileCategory) -> Int {
        files.lazy.filter { self.fileCategoryLinks[$0.id]?.contains(category.id) == true }.count
    }

    func isCategory(_ category: FileCategory, assignedTo file: IndexedFile) -> Bool {
        fileCategoryLinks[file.id]?.contains(category.id) == true
    }

    func fileCount(for kind: FileKind) -> Int {
        files.lazy.filter { $0.kind == kind }.count
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

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
                try await Task.sleep(for: .milliseconds(120))
                let page = try await database.searchFilesPage(
                    matching: query,
                    limit: Self.searchResultBatchSize,
                    includesHiddenFiles: includesHiddenFiles
                )
                try Task.checkCancellation()
                guard let self,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.searchResults = page.files
                self.searchResultTotalCount = page.totalCount
                self.isSearching = false
            } catch is CancellationError {
                // 新输入会替换尚未完成的查询。
            } catch {
                guard let self,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.searchResults = []
                self.searchResultTotalCount = 0
                self.isSearching = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func loadMoreSearchResults() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                guard self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.searchResults = page.files
                self.searchResultTotalCount = page.totalCount
                self.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.isSearching = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

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
                self.errorMessage = Self.message(for: error)
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
            aiSearchResults?.removeAll(where: Self.isDotPrefixedFile)
            if let selectedFileID,
               !files.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
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

    func clearError() {
        errorMessage = nil
    }

    func retryDatabase() async {
        database = nil
        do {
            database = try FileIndexDatabase(databaseURL: try databaseURL())
            isDatabaseAvailable = true
            errorMessage = nil
            await reloadIndex()
        } catch {
            suspendIndexAfterDatabaseFailure(error)
        }
    }

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

    func requestRename(_ file: IndexedFile) {
        renameRequest = file
    }

    func requestTrash(_ file: IndexedFile) {
        trashRequest = file
    }

    func rename(_ file: IndexedFile, to newName: String) async throws {
        guard isDatabaseAvailable else {
            throw FileIndexError.database("database unavailable")
        }
        let renamedURL = try await fileOperations.rename(fileAt: file.url, to: newName)
        await reconcileKnownFileChanges([file.url, renamedURL])
        selectFileIfIndexed(at: renamedURL)
        renameRequest = nil
    }

    func chooseMoveDestination(for file: IndexedFile) {
        guard isDatabaseAvailable else {
            errorMessage = FileIndexError.database("database unavailable").localizedDescription
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

    func confirmTrash() {
        guard let file = trashRequest else { return }
        guard isDatabaseAvailable else {
            errorMessage = FileIndexError.database("database unavailable").localizedDescription
            return
        }
        trashRequest = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await fileOperations.moveToTrash(fileAt: file.url)
                selectedFileID = nil
                await reconcileKnownFileChanges([file.url])
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

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
        guard let database else { return }
        Task { [weak self] in
            do {
                try await database.deleteCategory(category.id)
                await self?.reloadIndex()
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
        }
    }

    func toggleCategory(_ category: FileCategory, for file: IndexedFile) {
        guard let database else { return }
        let key = FileCategoryAssignmentKey(fileID: file.id, categoryID: category.id)
        let existing = pendingCategoryAssignments[key]
        let shouldAssign = Self.categoryAssignmentAfterToggle(
            persistedAssignment: isCategory(category, assignedTo: file),
            pendingAssignment: existing?.desiredAssignment
        )
        pendingCategoryAssignments[key] = PendingCategoryAssignment(
            desiredAssignment: shouldAssign,
            revision: (existing?.revision ?? 0) &+ 1
        )
        applyCategoryAssignment(shouldAssign, for: key)

        guard categoryMutationTasks[key] == nil else { return }
        categoryMutationTasks[key] = Task { [weak self] in
            await self?.drainCategoryAssignments(for: key, database: database)
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
                errorMessage = Self.message(for: error)
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

    func aiSettings(for kind: AIProviderKind) -> AIProviderSettings {
        aiProviderSettings.first(where: { $0.kind == kind })
            ?? AIProviderSettings(
                kind: kind,
                baseURL: kind.defaultBaseURL,
                model: kind.defaultModel,
                hasAPIKey: false
            )
    }

    func aiConnectionState(for kind: AIProviderKind) -> AIConnectionState {
        aiConnectionStates[kind] ?? .notConfigured
    }

    func aiCredentialError(for kind: AIProviderKind) -> String? {
        aiCredentialErrors[kind]
    }

    func refreshOAuthStatus(
        for kind: AIProviderKind,
        presentsFailure: Bool = true
    ) async {
        guard let provider = Self.oauthProvider(for: kind),
              oauthLoginStartGenerations[kind] == nil,
              oauthMutationGenerations[kind] == nil,
              !oauthStatusInFlight.contains(kind) else { return }
        oauthStatusInFlight.insert(kind)
        defer { finishOAuthStatus(for: kind) }
        let generation = beginOAuthOperation(for: kind)

        do {
            let status = try await oauthBridgeService.authenticationStatus(for: provider)
            applyOAuthStatus(status, to: kind, generation: generation)
        } catch {
            applyOAuthFailure(
                error,
                to: kind,
                generation: generation,
                presentsFailure: presentsFailure
            )
        }
    }

    func applicationBecameActive() {
        guard !isRunningTests else { return }
        oauthPollingTask?.cancel()
        oauthPollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshOAuthProviders(presentsFailure: false)
            while !Task.isCancelled {
                let shouldContinue = AIProviderKind.allCases.contains { kind in
                    Self.oauthProvider(for: kind) != nil
                        && self.aiOAuthStates[kind]?.shouldPoll == true
                }
                guard shouldContinue else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                await self.refreshOAuthProviders(presentsFailure: false)
            }
        }
    }

    func applicationResignedActive() {
        oauthPollingTask?.cancel()
        oauthPollingTask = nil
    }

    private func refreshOAuthProviders(presentsFailure: Bool) async {
        for kind in AIProviderKind.allCases where Self.oauthProvider(for: kind) != nil {
            guard !Task.isCancelled else { return }
            await refreshOAuthStatus(for: kind, presentsFailure: presentsFailure)
        }
    }

    @discardableResult
    func beginOAuthLogin(for kind: AIProviderKind) async -> URL? {
        await beginOAuthLogin(for: kind, method: .browser)
    }

    @discardableResult
    func beginOAuthDeviceCodeLogin(
        for kind: AIProviderKind
    ) async -> AIOAuthDeviceCodePresentation? {
        guard kind == .codex else { return nil }
        _ = await beginOAuthLogin(for: kind, method: .deviceCode)
        guard let presentation = aiOAuthDeviceCodePresentations[kind],
              case let .authenticating(attemptID, authorizationURL) = aiOAuthStates[kind],
              attemptID == presentation.attemptID,
              authorizationURL == presentation.verificationURL else {
            return nil
        }
        return presentation
    }

    private func beginOAuthLogin(
        for kind: AIProviderKind,
        method: OAuthBridgeLoginMethod
    ) async -> URL? {
        guard let provider = Self.oauthProvider(for: kind) else { return nil }
        guard method == .browser || kind == .codex else { return nil }
        let waitedForStatus = oauthStatusInFlight.contains(kind)
        await waitForOAuthStatus(for: kind)
        if waitedForStatus {
            guard case .disconnected = aiOAuthStates[kind] else { return nil }
        }
        guard oauthLoginStartGenerations[kind] == nil,
              oauthMutationGenerations[kind] == nil,
              oauthLoginAttemptIDs[kind] == nil else { return nil }
        let generation = beginOAuthOperation(for: kind)
        oauthLoginStartGenerations[kind] = generation
        oauthLoginAttemptIDs.removeValue(forKey: kind)
        aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
        aiOAuthStates[kind] = .starting
        defer {
            if oauthLoginStartGenerations[kind] == generation {
                oauthLoginStartGenerations.removeValue(forKey: kind)
            }
        }

        do {
            let attempt = try await oauthBridgeService.startLogin(
                for: provider,
                method: method
            )
            guard oauthOperationGenerations[kind] == generation else {
                _ = try? await oauthBridgeService.cancelLogin(
                    for: provider,
                    attemptID: attempt.attemptID
                )
                return nil
            }
            guard attempt.provider == provider else {
                applyOAuthFailure(
                    OAuthStateError.providerMismatch,
                    to: kind,
                    generation: generation
                )
                return nil
            }
            switch method {
            case .browser:
                guard attempt.userCode == nil else {
                    applyOAuthFailure(
                        OAuthStateError.invalidLoginPresentation,
                        to: kind,
                        generation: generation
                    )
                    return nil
                }
            case .deviceCode:
                guard kind == .codex,
                      let verificationURL = attempt.authorizationURL,
                      Self.validOAuthAuthorizationURL(verificationURL),
                      let userCode = attempt.userCode,
                      Self.validDeviceUserCode(userCode) else {
                    applyOAuthFailure(
                        OAuthStateError.invalidLoginPresentation,
                        to: kind,
                        generation: generation
                    )
                    return nil
                }
                aiOAuthDeviceCodePresentations[kind] = AIOAuthDeviceCodePresentation(
                    attemptID: attempt.attemptID,
                    verificationURL: verificationURL,
                    userCode: userCode
                )
            }
            oauthLoginAttemptIDs[kind] = attempt.attemptID
            aiOAuthStates[kind] = .authenticating(
                attemptID: attempt.attemptID,
                authorizationURL: attempt.authorizationURL
            )
            return attempt.authorizationURL
        } catch {
            applyOAuthFailure(error, to: kind, generation: generation)
            return nil
        }
    }

    func cancelOAuthLogin(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForOAuthStatus(for: kind)
        if oauthLoginStartGenerations[kind] != nil {
            _ = beginOAuthOperation(for: kind)
            aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
            aiOAuthStates[kind] = .disconnected
            return
        }
        guard oauthMutationGenerations[kind] == nil,
              let attemptID = oauthLoginAttemptIDs[kind] else { return }
        let generation = beginOAuthOperation(for: kind)
        oauthMutationGenerations[kind] = generation
        defer { finishOAuthMutation(for: kind, generation: generation) }

        do {
            let status = try await oauthBridgeService.cancelLogin(
                for: provider,
                attemptID: attemptID
            )
            applyOAuthStatus(status, to: kind, generation: generation)
        } catch {
            applyOAuthFailure(error, to: kind, generation: generation)
        }
    }

    func verifyOAuthConnection(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForOAuthStatus(for: kind)
        guard !Task.isCancelled,
              oauthLoginStartGenerations[kind] == nil,
              oauthMutationGenerations[kind] == nil,
              aiOAuthStates[kind] == .signedInUnverified else { return }

        let generation = beginOAuthOperation(for: kind)
        oauthMutationGenerations[kind] = generation
        aiOAuthVerificationsInFlight.insert(kind)
        defer {
            aiOAuthVerificationsInFlight.remove(kind)
            finishOAuthMutation(for: kind, generation: generation)
        }

        do {
            let status = try await oauthBridgeService.verifyConnection(provider)
            guard !Task.isCancelled else { return }
            applyOAuthStatus(status, to: kind, generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            applyOAuthFailure(error, to: kind, generation: generation)
        }
    }

    func disconnectOAuthProvider(_ kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForOAuthStatus(for: kind)
        if oauthLoginStartGenerations[kind] != nil {
            _ = beginOAuthOperation(for: kind)
            aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
            aiOAuthStates[kind] = .disconnected
            return
        }

        let generation: UUID
        if aiOAuthVerificationsInFlight.contains(kind) {
            generation = beginOAuthOperation(for: kind)
            await waitForOAuthMutation(for: kind)
        } else {
            guard oauthMutationGenerations[kind] == nil else { return }
            generation = beginOAuthOperation(for: kind)
        }
        guard !Task.isCancelled,
              oauthOperationGenerations[kind] == generation,
              oauthLoginStartGenerations[kind] == nil,
              oauthMutationGenerations[kind] == nil else { return }
        oauthMutationGenerations[kind] = generation
        oauthLoginAttemptIDs.removeValue(forKey: kind)
        aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
        defer { finishOAuthMutation(for: kind, generation: generation) }

        do {
            let status = try await oauthBridgeService.disconnect(provider)
            applyOAuthStatus(status, to: kind, generation: generation)
        } catch {
            applyOAuthFailure(error, to: kind, generation: generation)
        }
    }

    func logoutOAuthProvider(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForOAuthStatus(for: kind)

        let generation: UUID
        if aiOAuthVerificationsInFlight.contains(kind) {
            generation = beginOAuthOperation(for: kind)
            await waitForOAuthMutation(for: kind)
        } else {
            guard oauthMutationGenerations[kind] == nil else { return }
            generation = beginOAuthOperation(for: kind)
        }
        guard !Task.isCancelled,
              oauthOperationGenerations[kind] == generation,
              oauthLoginStartGenerations[kind] == nil,
              oauthMutationGenerations[kind] == nil else { return }
        oauthMutationGenerations[kind] = generation
        oauthLoginAttemptIDs.removeValue(forKey: kind)
        aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
        defer { finishOAuthMutation(for: kind, generation: generation) }

        do {
            let status = try await oauthBridgeService.logout(provider)
            applyOAuthStatus(status, to: kind, generation: generation)
        } catch {
            applyOAuthFailure(error, to: kind, generation: generation)
        }
    }

    @discardableResult
    func saveAIProvider(
        _ kind: AIProviderKind,
        baseURL: String,
        model: String,
        apiKey: String
    ) -> Bool {
        do {
            guard AIProviderFactory.validatedBaseURL(baseURL) != nil else {
                throw AIServiceError.invalidBaseURL
            }
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw AIServiceError.invalidModel }

            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try credentialStore.save(trimmedKey, account: kind.rawValue)
            }
            let settings = AIProviderSettings(
                kind: kind,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model,
                hasAPIKey: !trimmedKey.isEmpty || aiSettings(for: kind).hasAPIKey
            )
            aiConfigurationStore.save(settings)
            cancelAIProviderTest(kind)
            aiVerificationGenerations[kind] = UUID()
            aiVerificationFingerprints.removeValue(forKey: kind)
            aiConfigurationStore.setAPIKeyVerificationFingerprint(nil, for: kind)
            reloadAISettings()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func deleteAIKey(for kind: AIProviderKind) {
        do {
            cancelAIProviderTest(kind)
            aiVerificationGenerations[kind] = UUID()
            aiVerificationFingerprints.removeValue(forKey: kind)
            aiConfigurationStore.setAPIKeyVerificationFingerprint(nil, for: kind)
            try credentialStore.delete(account: kind.rawValue)
            if (activeAIProviderKind == kind && activeAIAuthenticationMode == .apiKey)
                || (pendingActiveAIProviderKind == kind
                    && pendingActiveAIAuthenticationMode == .apiKey) {
                clearActiveAIProvider()
            }
            reloadAISettings()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func setActiveAIProvider(_ kind: AIProviderKind) {
        guard aiSettings(for: kind).hasAPIKey,
              aiConnectionState(for: kind) == .verified else {
            errorMessage = AIServiceError.notConfigured.localizedDescription
            return
        }
        setActiveAIProvider(kind, authenticationMode: .apiKey)
    }

    func setActiveOAuthAIProvider(_ kind: AIProviderKind) {
        guard Self.oauthProvider(for: kind) != nil,
              aiOAuthStates[kind] == .connected else {
            errorMessage = AIServiceError.notConfigured.localizedDescription
            return
        }
        setActiveAIProvider(kind, authenticationMode: .oauth)
    }

    private func setActiveAIProvider(
        _ kind: AIProviderKind,
        authenticationMode: AIAuthenticationMode
    ) {
        aiConfigurationStore.activeKind = kind
        aiConfigurationStore.activeAuthenticationMode = authenticationMode
        activeAIProviderKind = kind
        activeAIAuthenticationMode = authenticationMode
        pendingActiveAIProviderKind = kind
        pendingActiveAIAuthenticationMode = authenticationMode
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch()
        }
    }

    func testAIProvider(_ kind: AIProviderKind) {
        cancelAIProviderTest(kind)
        let generation = UUID()
        aiVerificationGenerations[kind] = generation
        aiConnectionStates[kind] = .testing
        if Self.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: activeAIProviderKind,
            activeMode: activeAIAuthenticationMode,
            testedKind: kind
        ) {
            deactivateCurrentAIProvider(preservingPreference: true)
        }
        let testedSettings = aiSettings(for: kind)
        aiVerificationTasks[kind] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.aiVerificationGenerations[kind] == generation {
                    self.aiVerificationTasks.removeValue(forKey: kind)
                }
            }
            do {
                let provider = try provider(for: kind, authenticationMode: .apiKey)
                _ = try await provider.chat([
                    AIMessage(role: .system, content: "这是连接测试。"),
                    AIMessage(role: .user, content: "请只回复 OK")
                ])
                try Task.checkCancellation()
                guard aiVerificationGenerations[kind] == generation,
                      aiSettings(for: kind).baseURL == testedSettings.baseURL,
                      aiSettings(for: kind).model == testedSettings.model else {
                    return
                }
                guard let secret = try credentialStore.read(account: kind.rawValue) else {
                    return
                }
                let fingerprint = AIConfigurationStore.apiKeyVerificationFingerprint(
                    settings: testedSettings,
                    secret: secret
                )
                aiVerificationFingerprints[kind] = fingerprint
                aiConfigurationStore.setAPIKeyVerificationFingerprint(fingerprint, for: kind)
                aiConnectionStates[kind] = .verified
                restorePendingActiveAIProviderIfEligible()
            } catch is CancellationError {
                guard aiVerificationGenerations[kind] == generation else { return }
                aiConnectionStates[kind] = testedSettings.hasAPIKey ? .saved : .notConfigured
            } catch {
                guard aiVerificationGenerations[kind] == generation else { return }
                aiConnectionStates[kind] = .failed(Self.message(for: error))
            }
        }
    }

    func cancelAIProviderTest(_ kind: AIProviderKind) {
        guard aiConnectionStates[kind] == .testing || aiVerificationTasks[kind] != nil else {
            return
        }
        aiVerificationGenerations[kind] = UUID()
        aiVerificationTasks.removeValue(forKey: kind)?.cancel()
        aiConnectionStates[kind] = aiSettings(for: kind).hasAPIKey ? .saved : .notConfigured
    }

    func performAISearch(_ query: String) async throws {
        guard let database else { return }
        let service = try currentAIService()
        let plan = try await service.searchPlan(for: query)
        try Task.checkCancellation()

        let candidates: [IndexedFile]
        if plan.keywords.isEmpty {
            candidates = files
        } else {
            var candidateByID: [String: IndexedFile] = [:]
            for keyword in plan.keywords {
                for file in try await database.searchFiles(matching: keyword, limit: 500) {
                    candidateByID[file.id] = file
                }
            }
            candidates = files.filter { candidateByID[$0.id] != nil }
        }

        try Task.checkCancellation()
        aiSearchResults = plan.filter(candidates)
        aiSearchPlan = plan
        aiSearchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch()
        }
    }

    func clearAISearch() {
        aiSearchResults = nil
        aiSearchPlan = nil
        aiSearchQuery = nil
    }

    func explainWithAI(_ file: IndexedFile) async throws -> String {
        try await currentAIService().explain(file: try await fileWithText(file))
    }

    func askAI(_ question: String, about file: IndexedFile) async throws -> String {
        try await currentAIService().answer(
            question: question,
            about: try await fileWithText(file)
        )
    }

    func classifyWithAI(_ files: [IndexedFile]) async throws -> [AIClassificationSuggestion] {
        guard !categories.isEmpty else { throw AIServiceError.noCategories }
        var filesWithText: [IndexedFile] = []
        filesWithText.reserveCapacity(files.count)
        for file in files {
            filesWithText.append(try await fileWithText(file))
        }
        return try await currentAIService().classify(files: filesWithText, categories: categories)
    }

    func applyAIClassification(
        _ suggestions: [AIClassificationSuggestion]
    ) async throws -> [AIClassificationChange] {
        guard let database else { return [] }
        let validFileIDs = Set(files.map(\.id))
        let validCategoryIDs = Set(categories.map(\.id))
        var changes: [AIClassificationChange] = []

        for suggestion in suggestions where validFileIDs.contains(suggestion.fileID) {
            for categoryID in suggestion.categoryIDs where validCategoryIDs.contains(categoryID) {
                guard fileCategoryLinks[suggestion.fileID]?.contains(categoryID) != true else {
                    continue
                }
                changes.append(AIClassificationChange(
                    fileID: suggestion.fileID,
                    categoryID: categoryID
                ))
            }
        }
        try await database.setCategories(changes, assigned: true)
        await reloadIndex()
        return changes
    }

    func undoAIClassification(_ changes: [AIClassificationChange]) async throws {
        guard let database else { return }
        try await database.setCategories(changes, assigned: false)
        await reloadIndex()
    }

    private func reloadAISettings() {
        var settings: [AIProviderSettings] = []
        var states: [AIProviderKind: AIConnectionState] = [:]
        var credentialErrors: [AIProviderKind: String] = [:]
        for kind in AIProviderKind.allCases {
            let secret: String?
            do {
                secret = try credentialStore.read(account: kind.rawValue)
            } catch {
                let message = Self.message(for: error)
                credentialErrors[kind] = message
                let previousHasAPIKey = aiProviderSettings
                    .first(where: { $0.kind == kind })?.hasAPIKey ?? false
                settings.append(
                    aiConfigurationStore.settings(for: kind, hasAPIKey: previousHasAPIKey)
                )
                states[kind] = .failed(message)
                continue
            }
            let hasAPIKey = secret != nil
            let currentSettings = aiConfigurationStore.settings(
                for: kind,
                hasAPIKey: hasAPIKey
            )
            settings.append(currentSettings)
            let fingerprint = secret.map {
                AIConfigurationStore.apiKeyVerificationFingerprint(
                    settings: currentSettings,
                    secret: $0
                )
            }
            states[kind] = if hasAPIKey,
                              aiVerificationFingerprints[kind] == fingerprint {
                .verified
            } else if hasAPIKey {
                .saved
            } else {
                .notConfigured
            }
        }
        aiProviderSettings = settings
        aiConnectionStates = states
        aiCredentialErrors = credentialErrors
        guard let activeKind = aiConfigurationStore.activeKind else {
            clearActiveAIProvider()
            return
        }
        let storedMode = aiConfigurationStore.activeAuthenticationMode
        let mode = storedMode ?? .apiKey
        switch mode {
        case .apiKey:
            guard settings.first(where: { $0.kind == activeKind })?.hasAPIKey == true,
                  states[activeKind] == .verified else {
                deactivateCurrentAIProvider(preservingPreference: true)
                return
            }
        case .oauth:
            guard Self.oauthProvider(for: activeKind) != nil,
                  aiOAuthStates[activeKind] == .connected else {
                deactivateCurrentAIProvider(preservingPreference: true)
                return
            }
        }
        aiConfigurationStore.activeAuthenticationMode = mode
        activeAIProviderKind = activeKind
        activeAIAuthenticationMode = mode
    }

    static func shouldDeactivateActiveAPIKeyForVerification(
        activeKind: AIProviderKind?,
        activeMode: AIAuthenticationMode?,
        testedKind: AIProviderKind
    ) -> Bool {
        activeKind == testedKind && activeMode == .apiKey
    }

    private func provider(
        for kind: AIProviderKind,
        authenticationMode: AIAuthenticationMode
    ) throws -> any AIProvider {
        switch authenticationMode {
        case .apiKey:
            return try AIProviderFactory.make(
                settings: aiSettings(for: kind),
                credentialStore: credentialStore
            )
        case .oauth:
            guard oauthStateAllowsGeneration(aiOAuthStates[kind]) else {
                throw AIServiceError.notConfigured
            }
            return try AIProviderFactory.makeOAuth(
                settings: aiSettings(for: kind),
                bridge: oauthBridgeService
            )
        }
    }

    private func currentAIService() throws -> AIService {
        guard let activeAIProviderKind,
              let activeAIAuthenticationMode else {
            throw AIServiceError.notConfigured
        }
        switch activeAIAuthenticationMode {
        case .apiKey:
            guard aiConnectionStates[activeAIProviderKind] == .verified else {
                throw AIServiceError.notConfigured
            }
        case .oauth:
            guard aiOAuthStates[activeAIProviderKind] == .connected else {
                throw AIServiceError.notConfigured
            }
        }
        let provider = try provider(
            for: activeAIProviderKind,
            authenticationMode: activeAIAuthenticationMode
        )
        if activeAIAuthenticationMode == .oauth {
            return AIService(provider: OAuthStatePromotingProvider(
                base: provider,
                onSuccess: { [weak self] in
                    await MainActor.run {
                        guard let self,
                              self.activeAIProviderKind == activeAIProviderKind,
                              self.activeAIAuthenticationMode == .oauth else { return }
                        self.aiOAuthStates[activeAIProviderKind] = .connected
                    }
                }
            ))
        }
        return AIService(provider: provider)
    }

    private func oauthStateAllowsGeneration(_ state: AIOAuthState?) -> Bool {
        state == .connected
    }

    private func clearActiveAIProvider() {
        aiConfigurationStore.activeKind = nil
        aiConfigurationStore.activeAuthenticationMode = nil
        pendingActiveAIProviderKind = nil
        pendingActiveAIAuthenticationMode = nil
        activeAIProviderKind = nil
        activeAIAuthenticationMode = nil
    }

    private func deactivateCurrentAIProvider(preservingPreference: Bool) {
        if !preservingPreference {
            aiConfigurationStore.activeKind = nil
            aiConfigurationStore.activeAuthenticationMode = nil
            pendingActiveAIProviderKind = nil
            pendingActiveAIAuthenticationMode = nil
        }
        activeAIProviderKind = nil
        activeAIAuthenticationMode = nil
    }

    private func restorePendingActiveAIProviderIfEligible() {
        guard activeAIProviderKind == nil,
              let pendingKind = pendingActiveAIProviderKind,
              let pendingMode = pendingActiveAIAuthenticationMode else { return }
        switch pendingMode {
        case .apiKey:
            guard aiConnectionStates[pendingKind] == .verified else { return }
        case .oauth:
            guard aiOAuthStates[pendingKind] == .connected else { return }
        }
        activeAIProviderKind = pendingKind
        activeAIAuthenticationMode = pendingMode
    }

    private func clearActiveOAuthProviderIfNeeded(
        _ kind: AIProviderKind,
        preservingPreference: Bool = true
    ) {
        let isRuntimeActive = activeAIProviderKind == kind
            && activeAIAuthenticationMode == .oauth
        let isPendingActive = pendingActiveAIProviderKind == kind
            && pendingActiveAIAuthenticationMode == .oauth
        guard isRuntimeActive || isPendingActive else { return }
        deactivateCurrentAIProvider(preservingPreference: preservingPreference)
    }

    private func beginOAuthOperation(for kind: AIProviderKind) -> UUID {
        let generation = UUID()
        oauthOperationGenerations[kind] = generation
        return generation
    }

    private func waitForOAuthStatus(for kind: AIProviderKind) async {
        while oauthStatusInFlight.contains(kind) {
            await withCheckedContinuation { continuation in
                oauthStatusWaiters[kind, default: []].append(continuation)
            }
        }
    }

    private func finishOAuthStatus(for kind: AIProviderKind) {
        oauthStatusInFlight.remove(kind)
        let waiters = oauthStatusWaiters.removeValue(forKey: kind) ?? []
        waiters.forEach { $0.resume() }
    }

    private func waitForOAuthMutation(for kind: AIProviderKind) async {
        while oauthMutationGenerations[kind] != nil {
            await withCheckedContinuation { continuation in
                oauthMutationWaiters[kind, default: []].append(continuation)
            }
        }
    }

    private func finishOAuthMutation(for kind: AIProviderKind, generation: UUID) {
        guard oauthMutationGenerations[kind] == generation else { return }
        oauthMutationGenerations.removeValue(forKey: kind)
        let waiters = oauthMutationWaiters.removeValue(forKey: kind) ?? []
        waiters.forEach { $0.resume() }
    }

    private func applyOAuthStatus(
        _ status: OAuthBridgeAuthStatus,
        to kind: AIProviderKind,
        generation: UUID
    ) {
        guard oauthOperationGenerations[kind] == generation,
              let expectedProvider = Self.oauthProvider(for: kind) else { return }
        guard status.provider == expectedProvider else {
            applyOAuthFailure(
                OAuthStateError.providerMismatch,
                to: kind,
                generation: generation
            )
            return
        }

        guard status.cliStatus == .available else {
            oauthLoginAttemptIDs.removeValue(forKey: kind)
            aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
            aiOAuthStates[kind] = .unavailable(status.cliStatus)
            clearActiveOAuthProviderIfNeeded(kind)
            return
        }
        if let attemptID = status.loginAttemptID {
            clearActiveOAuthProviderIfNeeded(kind)
            let authorizationURL: URL?
            if case let .authenticating(currentAttemptID, currentURL) = aiOAuthStates[kind],
               currentAttemptID == attemptID {
                authorizationURL = currentURL
            } else {
                authorizationURL = nil
            }
            if aiOAuthDeviceCodePresentations[kind]?.attemptID != attemptID {
                aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
            }
            oauthLoginAttemptIDs[kind] = attemptID
            aiOAuthStates[kind] = .authenticating(
                attemptID: attemptID,
                authorizationURL: authorizationURL
            )
            return
        }

        oauthLoginAttemptIDs.removeValue(forKey: kind)
        aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
        switch status.credentialState {
        case .unknown:
            aiOAuthStates[kind] = .statusUnknown
            clearActiveOAuthProviderIfNeeded(kind)
        case .signedOut:
            aiOAuthStates[kind] = .disconnected
            clearActiveOAuthProviderIfNeeded(kind, preservingPreference: false)
        case .signedIn:
            switch status.connectionState {
            case .disconnected:
                aiOAuthStates[kind] = .signedInDisconnected
                clearActiveOAuthProviderIfNeeded(kind)
            case .authorizing:
                aiOAuthStates[kind] = .statusUnknown
                clearActiveOAuthProviderIfNeeded(kind)
            case .authenticated:
                aiOAuthStates[kind] = .signedInUnverified
                clearActiveOAuthProviderIfNeeded(kind)
            case .connected:
                aiOAuthStates[kind] = .connected
                restorePendingActiveAIProviderIfEligible()
            }
        }
    }

    private func applyOAuthFailure(
        _ error: Error,
        to kind: AIProviderKind,
        generation: UUID,
        presentsFailure: Bool = true
    ) {
        guard oauthOperationGenerations[kind] == generation else { return }
        oauthLoginAttemptIDs.removeValue(forKey: kind)
        aiOAuthDeviceCodePresentations.removeValue(forKey: kind)
        let message = Self.message(for: error)
        aiOAuthStates[kind] = .failed(message)
        clearActiveOAuthProviderIfNeeded(kind)
        if presentsFailure {
            errorMessage = message
        }
    }

    private static func oauthProvider(for kind: AIProviderKind) -> OAuthBridgeProvider? {
        switch kind {
        case .codex: .codex
        case .grok: .grok
        case .deepSeek, .qwen: nil
        }
    }

    private enum OAuthStateError: LocalizedError {
        case providerMismatch
        case invalidLoginPresentation

        var errorDescription: String? {
            switch self {
            case .providerMismatch:
                "OAuth 伴随服务返回了不匹配的 AI 提供商。"
            case .invalidLoginPresentation:
                "OAuth 伴随服务返回了无效的登录信息。"
            }
        }
    }

    private static func validDeviceUserCode(_ userCode: String) -> Bool {
        (4...64).contains(userCode.utf8.count)
            && userCode.unicodeScalars.allSatisfy {
                ($0.value >= 0x30 && $0.value <= 0x39)
                    || ($0.value >= 0x41 && $0.value <= 0x5A)
                    || $0.value == 0x2D
            }
    }

    private static func validOAuthAuthorizationURL(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.absoluteString.utf8.count <= 2_048
            && components?.scheme?.lowercased() == "https"
            && ["auth.openai.com", "chatgpt.com"].contains(
                components?.host?.lowercased() ?? ""
            )
            && (components?.port == nil || components?.port == 443)
            && components?.user == nil
            && components?.password == nil
            && components?.fragment == nil
    }

    private func addSource(_ url: URL) async {
        guard let database else { return }

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
            errorMessage = Self.message(for: error)
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
        guard let database else { return }

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
            errorMessage = Self.message(for: error)
        }
    }

    private func move(_ file: IndexedFile, to destinationURL: URL) async {
        guard let database else {
            errorMessage = FileIndexError.database("database unavailable").localizedDescription
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
            selectFileIfIndexed(at: movedURL)
        } catch {
            if let physicallyMovedURL {
                errorMessage = AppLanguage.localized(
                    "文件已移动到“\(physicallyMovedURL.lastPathComponent)”，但索引更新失败。原分类尚未主动清除，请重新扫描后再试。",
                    english: "The file moved to “\(physicallyMovedURL.lastPathComponent)”, but its index could not be updated. Its original categories were not intentionally removed; rescan and try again."
                )
            } else {
                errorMessage = Self.message(for: error)
            }
        }
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

    private func performScan(
        _ source: FileSource,
        keepsScanningState: Bool = false,
        generation: UUID
    ) async {
        guard let database else { return }
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
            try await database.replaceFiles(for: source.id, with: scannedFiles)
            guard scanGeneration == generation else { return }
            await reloadIndex()
        } catch is CancellationError {
            // 用户取消扫描时保留上一次完整索引。
        } catch {
            guard scanGeneration == generation else { return }
            failedScanningSourceIDs.insert(source.id)
            errorMessage = Self.message(for: error)
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
            errorMessage = AppLanguage.localized(
                "扫描未完成：无法读取\(failedNames)。旧索引已保留，请检查权限后重试。",
                english: "Scan incomplete: couldn’t read \(failedNames). The previous index was preserved; check permissions and retry."
            )
        }
        failedScanningSourceIDs.removeAll()
        scanningSourceIDs.removeAll()
        currentScanningSourceID = nil
        startNextPendingFullRescanIfNeeded()
    }

    private func fileWithText(_ file: IndexedFile) async throws -> IndexedFile {
        guard let database else { throw FileIndexError.database("database unavailable") }
        let textContent = try await database.fetchTextContent(forFileID: file.id)
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

    func clearSelectionIfHidden(from visibleFileIDs: Set<String>) {
        guard let selectedFileID,
              !visibleFileIDs.contains(selectedFileID) else { return }
        self.selectedFileID = nil
    }

    private func selectFileIfIndexed(at url: URL) {
        let path = url.standardizedFileURL.path
        selectedFileID = files.first {
            $0.url.standardizedFileURL.path == path
        }?.id
    }

    static func scanCleanupOwnsState(
        currentGeneration: UUID,
        finishingGeneration: UUID
    ) -> Bool {
        currentGeneration == finishingGeneration
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
            activateSecurityScopes()
            configureFileSystemMonitoring()
            if let aiSearchResults {
                let resultIDs = Set(aiSearchResults.map(\.id))
                self.aiSearchResults = files.filter { resultIDs.contains($0.id) }
            }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleSearch()
            }

            if let selectedFileID,
               !files.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            isDatabaseAvailable = true
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
        errorMessage = Self.message(for: error)
    }

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
                try await Task.sleep(for: .milliseconds(350))
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
                errorMessage = AppLanguage.localized(
                    "“\(source.displayName)”的部分文件暂时无法读取，本次更新未完成，请稍后重新扫描。",
                    english: "Some files in “\(source.displayName)” could not be read. This update is incomplete; rescan later."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(for: error)
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
        errorMessage = FileOperationError.fileNotFound.localizedDescription
        if selectedFileID == file.id {
            selectedFileID = nil
        }
        files.removeAll { $0.id == file.id }
        searchResults?.removeAll { $0.id == file.id }
        if let searchResultTotalCount {
            self.searchResultTotalCount = max(0, searchResultTotalCount - 1)
        }
        aiSearchResults?.removeAll { $0.id == file.id }
        fileCategoryLinks.removeValue(forKey: file.id)
        if renameRequest?.id == file.id {
            renameRequest = nil
        }
        if trashRequest?.id == file.id {
            trashRequest = nil
        }

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
            errorMessage = Self.message(for: error)
            await reloadIndex()
        }
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

    private static func isDotPrefixedFile(_ file: IndexedFile) -> Bool {
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
}

private struct OAuthStatePromotingProvider: AIProvider {
    let base: any AIProvider
    let onSuccess: @Sendable () async -> Void

    var kind: AIProviderKind { base.kind }

    func chat(_ messages: [AIMessage]) async throws -> String {
        let response = try await base.chat(messages)
        await onSuccess()
        return response
    }
}
