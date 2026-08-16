import Foundation

/// Owns AI provider configuration and session state: settings, API key
/// credentials, verification, and which provider is currently active.
///
/// Extracted from `AppModel` so the configuration domain can be tested without
/// the file-index machinery. OAuth is an authentication *mode* of AI providers,
/// so this type reads OAuth state from `OAuthCoordinator` but never owns it.
@MainActor
final class AISessionCoordinator: ObservableObject {
    @Published private(set) var providerSettings: [AIProviderSettings] = []
    @Published private(set) var activeProviderKind: AIProviderKind?
    @Published private(set) var activeAuthenticationMode: AIAuthenticationMode?
    @Published private(set) var connectionStates: [AIProviderKind: AIConnectionState] = [:]
    @Published private(set) var credentialErrors: [AIProviderKind: String] = [:]

    /// The active provider changed, so search results may need recomputing.
    var onActiveProviderChanged: (() -> Void)?
    /// A failure the user should see.
    var onError: ((String) -> Void)?

    private let credentialStore: LocalCredentialStore
    private let aiConfigurationStore: AIConfigurationStore
    private let oauthBridgeService: any OAuthBridgeServicing
    private let oauth: OAuthCoordinator

    private var verificationFingerprints: [AIProviderKind: String] = [:]
    private var verificationGenerations: [AIProviderKind: UUID] = [:]
    private var verificationTasks: [AIProviderKind: Task<Void, Never>] = [:]

    private var pendingActiveProviderKind: AIProviderKind?
    private var pendingActiveAuthenticationMode: AIAuthenticationMode?

    init(
        credentialStore: LocalCredentialStore,
        aiConfigurationStore: AIConfigurationStore,
        oauthBridgeService: any OAuthBridgeServicing,
        oauth: OAuthCoordinator,
        isRunningTests: Bool
    ) {
        self.credentialStore = credentialStore
        self.aiConfigurationStore = aiConfigurationStore
        self.oauthBridgeService = oauthBridgeService
        self.oauth = oauth
        self.pendingActiveProviderKind = aiConfigurationStore.activeKind
        self.pendingActiveAuthenticationMode = aiConfigurationStore.activeAuthenticationMode
        if isRunningTests {
            providerSettings = AIProviderKind.allCases.map {
                AIProviderSettings(
                    kind: $0,
                    baseURL: $0.defaultBaseURL,
                    model: $0.defaultModel,
                    hasAPIKey: false
                )
            }
            connectionStates = Dictionary(
                uniqueKeysWithValues: AIProviderKind.allCases.map { ($0, .notConfigured) }
            )
        } else {
            verificationFingerprints = Dictionary(
                uniqueKeysWithValues: AIProviderKind.allCases.compactMap { kind in
                    aiConfigurationStore.apiKeyVerificationFingerprint(for: kind)
                        .map { (kind, $0) }
                }
            )
            reloadSettings()
        }
    }

    func cancelAllTasks() {
        verificationTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Queries

    func settings(for kind: AIProviderKind) -> AIProviderSettings {
        providerSettings.first(where: { $0.kind == kind })
            ?? AIProviderSettings(
                kind: kind,
                baseURL: kind.defaultBaseURL,
                model: kind.defaultModel,
                hasAPIKey: false
            )
    }

    func connectionState(for kind: AIProviderKind) -> AIConnectionState {
        connectionStates[kind] ?? .notConfigured
    }

    func credentialError(for kind: AIProviderKind) -> String? {
        credentialErrors[kind]
    }

    // MARK: - Configuration

    @discardableResult
    func saveProvider(
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
                hasAPIKey: !trimmedKey.isEmpty || self.settings(for: kind).hasAPIKey
            )
            aiConfigurationStore.save(settings)
            cancelTest(kind)
            verificationGenerations[kind] = UUID()
            verificationFingerprints.removeValue(forKey: kind)
            aiConfigurationStore.setAPIKeyVerificationFingerprint(nil, for: kind)
            reloadSettings()
            return true
        } catch {
            onError?(Self.message(for: error))
            return false
        }
    }

    func deleteAPIKey(for kind: AIProviderKind) {
        do {
            cancelTest(kind)
            verificationGenerations[kind] = UUID()
            verificationFingerprints.removeValue(forKey: kind)
            aiConfigurationStore.setAPIKeyVerificationFingerprint(nil, for: kind)
            try credentialStore.delete(account: kind.rawValue)
            if (activeProviderKind == kind && activeAuthenticationMode == .apiKey)
                || (pendingActiveProviderKind == kind
                    && pendingActiveAuthenticationMode == .apiKey) {
                clearActiveProvider()
            }
            reloadSettings()
        } catch {
            onError?(Self.message(for: error))
        }
    }

    // MARK: - Activation

    func setActiveAPIKeyProvider(_ kind: AIProviderKind) {
        guard settings(for: kind).hasAPIKey,
              connectionState(for: kind) == .verified else {
            onError?(AIServiceError.notConfigured.localizedDescription)
            return
        }
        setActiveProvider(kind, authenticationMode: .apiKey)
    }

    func setActiveOAuthProvider(_ kind: AIProviderKind) {
        guard OAuthCoordinator.oauthProvider(for: kind) != nil,
              oauth.states[kind] == .connected else {
            onError?(AIServiceError.notConfigured.localizedDescription)
            return
        }
        setActiveProvider(kind, authenticationMode: .oauth)
    }

    private func setActiveProvider(
        _ kind: AIProviderKind,
        authenticationMode: AIAuthenticationMode
    ) {
        aiConfigurationStore.activeKind = kind
        aiConfigurationStore.activeAuthenticationMode = authenticationMode
        activeProviderKind = kind
        activeAuthenticationMode = authenticationMode
        pendingActiveProviderKind = kind
        pendingActiveAuthenticationMode = authenticationMode
        onActiveProviderChanged?()
    }

    // MARK: - Verification

    func testProvider(_ kind: AIProviderKind) {
        cancelTest(kind)
        let generation = UUID()
        verificationGenerations[kind] = generation
        connectionStates[kind] = .testing
        if Self.shouldDeactivateActiveAPIKeyForVerification(
            activeKind: activeProviderKind,
            activeMode: activeAuthenticationMode,
            testedKind: kind
        ) {
            deactivateCurrentProvider(preservingPreference: true)
        }
        let testedSettings = settings(for: kind)
        verificationTasks[kind] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.verificationGenerations[kind] == generation {
                    self.verificationTasks.removeValue(forKey: kind)
                }
            }
            do {
                let provider = try provider(for: kind, authenticationMode: .apiKey)
                _ = try await provider.chat([
                    AIMessage(role: .system, content: "这是连接测试。"),
                    AIMessage(role: .user, content: "请只回复 OK")
                ])
                try Task.checkCancellation()
                guard verificationGenerations[kind] == generation,
                      settings(for: kind).baseURL == testedSettings.baseURL,
                      settings(for: kind).model == testedSettings.model else {
                    return
                }
                guard let secret = try credentialStore.read(account: kind.rawValue) else {
                    return
                }
                let fingerprint = AIConfigurationStore.apiKeyVerificationFingerprint(
                    settings: testedSettings,
                    secret: secret
                )
                verificationFingerprints[kind] = fingerprint
                aiConfigurationStore.setAPIKeyVerificationFingerprint(fingerprint, for: kind)
                connectionStates[kind] = .verified
                restorePendingActiveProviderIfEligible()
            } catch is CancellationError {
                guard verificationGenerations[kind] == generation else { return }
                connectionStates[kind] = testedSettings.hasAPIKey ? .saved : .notConfigured
            } catch {
                guard verificationGenerations[kind] == generation else { return }
                connectionStates[kind] = .failed(Self.message(for: error))
            }
        }
    }

    func cancelTest(_ kind: AIProviderKind) {
        guard connectionStates[kind] == .testing || verificationTasks[kind] != nil else {
            return
        }
        verificationGenerations[kind] = UUID()
        verificationTasks.removeValue(forKey: kind)?.cancel()
        connectionStates[kind] = settings(for: kind).hasAPIKey ? .saved : .notConfigured
    }

    // MARK: - Service construction

    func currentService() throws -> AIService {
        guard let activeProviderKind,
              let activeAuthenticationMode else {
            throw AIServiceError.notConfigured
        }
        switch activeAuthenticationMode {
        case .apiKey:
            guard connectionStates[activeProviderKind] == .verified else {
                throw AIServiceError.notConfigured
            }
        case .oauth:
            guard oauth.states[activeProviderKind] == .connected else {
                throw AIServiceError.notConfigured
            }
        }
        let provider = try provider(
            for: activeProviderKind,
            authenticationMode: activeAuthenticationMode
        )
        if activeAuthenticationMode == .oauth {
            return AIService(provider: OAuthStatePromotingProvider(
                base: provider,
                onStart: { [weak oauth] in
                    guard let oauth else { throw CancellationError() }
                    try await oauth.beginProviderRequest(activeProviderKind)
                },
                onSuccess: { [weak self] in
                    await MainActor.run {
                        guard let self,
                              self.activeProviderKind == activeProviderKind,
                              self.activeAuthenticationMode == .oauth else { return }
                        self.oauth.markConnected(activeProviderKind)
                    }
                },
                onFinish: { [weak oauth] in
                    await MainActor.run {
                        oauth?.endProviderRequest(activeProviderKind)
                    }
                }
            ))
        }
        return AIService(provider: provider)
    }

    private func provider(
        for kind: AIProviderKind,
        authenticationMode: AIAuthenticationMode
    ) throws -> any AIProvider {
        switch authenticationMode {
        case .apiKey:
            return try AIProviderFactory.make(
                settings: settings(for: kind),
                credentialStore: credentialStore
            )
        case .oauth:
            guard oauth.states[kind] == .connected else {
                throw AIServiceError.notConfigured
            }
            return try AIProviderFactory.makeOAuth(
                settings: settings(for: kind),
                bridge: oauthBridgeService
            )
        }
    }

    // MARK: - Active provider lifecycle

    func clearActiveOAuthProviderIfNeeded(
        _ kind: AIProviderKind,
        preservingPreference: Bool = true
    ) {
        let isRuntimeActive = activeProviderKind == kind
            && activeAuthenticationMode == .oauth
        let isPendingActive = pendingActiveProviderKind == kind
            && pendingActiveAuthenticationMode == .oauth
        guard isRuntimeActive || isPendingActive else { return }
        deactivateCurrentProvider(preservingPreference: preservingPreference)
    }

    func deactivateCurrentProvider(preservingPreference: Bool) {
        if !preservingPreference {
            aiConfigurationStore.activeKind = nil
            aiConfigurationStore.activeAuthenticationMode = nil
            pendingActiveProviderKind = nil
            pendingActiveAuthenticationMode = nil
        }
        activeProviderKind = nil
        activeAuthenticationMode = nil
    }

    static func shouldDeactivateActiveAPIKeyForVerification(
        activeKind: AIProviderKind?,
        activeMode: AIAuthenticationMode?,
        testedKind: AIProviderKind
    ) -> Bool {
        activeKind == testedKind && activeMode == .apiKey
    }

    // MARK: - Reload

    private func reloadSettings() {
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
                let previousHasAPIKey = providerSettings
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
                              verificationFingerprints[kind] == fingerprint {
                .verified
            } else if hasAPIKey {
                .saved
            } else {
                .notConfigured
            }
        }
        providerSettings = settings
        connectionStates = states
        self.credentialErrors = credentialErrors
        guard let activeKind = aiConfigurationStore.activeKind else {
            clearActiveProvider()
            return
        }
        let storedMode = aiConfigurationStore.activeAuthenticationMode
        let mode = storedMode ?? .apiKey
        switch mode {
        case .apiKey:
            guard settings.first(where: { $0.kind == activeKind })?.hasAPIKey == true,
                  states[activeKind] == .verified else {
                deactivateCurrentProvider(preservingPreference: true)
                return
            }
        case .oauth:
            guard OAuthCoordinator.oauthProvider(for: activeKind) != nil,
                  oauth.states[activeKind] == .connected else {
                deactivateCurrentProvider(preservingPreference: true)
                return
            }
        }
        aiConfigurationStore.activeAuthenticationMode = mode
        activeProviderKind = activeKind
        activeAuthenticationMode = mode
    }

    private func clearActiveProvider() {
        aiConfigurationStore.activeKind = nil
        aiConfigurationStore.activeAuthenticationMode = nil
        pendingActiveProviderKind = nil
        pendingActiveAuthenticationMode = nil
        activeProviderKind = nil
        activeAuthenticationMode = nil
    }

    /// Re-activates the pending provider once its prerequisites (verified key
    /// or connected OAuth) are met. Called from OAuth callbacks too.
    func restorePendingActiveProviderIfEligible() {
        guard activeProviderKind == nil,
              let pendingKind = pendingActiveProviderKind,
              let pendingMode = pendingActiveAuthenticationMode else { return }
        switch pendingMode {
        case .apiKey:
            guard connectionStates[pendingKind] == .verified else { return }
        case .oauth:
            guard oauth.states[pendingKind] == .connected else { return }
        }
        activeProviderKind = pendingKind
        activeAuthenticationMode = pendingMode
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// Wraps an OAuth-backed provider: a successful generation proves the
/// credential works, so the OAuth state is promoted to connected.
private struct OAuthStatePromotingProvider: AIProvider {
    let base: any AIProvider
    let onStart: @Sendable () async throws -> Void
    let onSuccess: @Sendable () async -> Void
    let onFinish: @Sendable () async -> Void

    var kind: AIProviderKind { base.kind }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await onStart()
        do {
            let response = try await base.chat(messages)
            await onSuccess()
            await onFinish()
            return response
        } catch {
            await onFinish()
            throw error
        }
    }
}
