import Foundation

/// Owns the OAuth state machine for AI providers that authenticate through the
/// companion bridge process.
///
/// OAuth is an authentication mechanism *for* AI providers, so connecting or
/// losing a connection has to be reflected in the AI layer (active provider,
/// connection state). Rather than reaching into `AppModel`, this type exposes
/// callbacks and lets the owner wire them up — which keeps the state machine
/// itself testable in isolation.
@MainActor
final class OAuthCoordinator: ObservableObject {
    @Published private(set) var states: [AIProviderKind: AIOAuthState] = [
        .codex: .statusUnknown,
        .grok: .statusUnknown
    ]
    @Published private(set) var deviceCodePresentations: [
        AIProviderKind: AIOAuthDeviceCodePresentation
    ] = [:]
    @Published private(set) var verificationsInFlight = Set<AIProviderKind>()

    // MARK: - Hooks into the AI layer

    /// A provider stopped being usable. `preservingPreference` is false when the
    /// user signed out explicitly, so the preference should not be restored.
    var onProviderUnavailable: ((AIProviderKind, Bool) -> Void)?
    /// A provider reached a fully connected state.
    var onProviderConnected: (() -> Void)?
    /// A failure the user should see.
    var onFailure: ((String) -> Void)?

    private let bridgeService: any OAuthBridgeServicing
    private let isRunningTests: Bool

    /// Called by the AI layer after a successful generation via OAuth, which
    /// proves the credential works and lets polling wind down.
    func markConnected(_ kind: AIProviderKind) {
        states[kind] = .connected
    }

    private var operationGenerations: [AIProviderKind: UUID] = [:]
    private var loginAttemptIDs: [AIProviderKind: UUID] = [:]
    private var loginStartGenerations: [AIProviderKind: UUID] = [:]
    private var loginStartTasks: [
        AIProviderKind: Task<OAuthBridgeLoginAttempt, Error>
    ] = [:]
    private var mutationGenerations: [AIProviderKind: UUID] = [:]
    private var mutationWaiters: [AIProviderKind: [WaiterBox]] = [:]
    private var statusInFlight = Set<AIProviderKind>()
    private var statusWaiters: [AIProviderKind: [WaiterBox]] = [:]
    private var providerRequestCounts: [AIProviderKind: Int] = [:]
    private var pollingTask: Task<Void, Never>?
    private var isApplicationActive = false
    private var isPollingPausedForVerification = false

    init(bridgeService: any OAuthBridgeServicing, isRunningTests: Bool) {
        self.bridgeService = bridgeService
        self.isRunningTests = isRunningTests
    }

    // MARK: - Status

    func refreshStatus(for kind: AIProviderKind, presentsFailure: Bool = true) async {
        guard let provider = Self.oauthProvider(for: kind),
              loginStartGenerations[kind] == nil,
              mutationGenerations[kind] == nil,
              providerRequestCounts[kind, default: 0] == 0,
              !statusInFlight.contains(kind) else { return }
        statusInFlight.insert(kind)
        defer { finishStatus(for: kind) }
        let generation = beginOperation(for: kind)

        do {
            let status = try await bridgeService.authenticationStatus(for: provider)
            applyStatus(status, to: kind, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            applyFailure(
                error,
                to: kind,
                generation: generation,
                presentsFailure: presentsFailure
            )
        }
    }

    /// App lifecycle refreshes must not be swallowed while the refresh from
    /// the previous active generation is still unwinding after cancellation.
    func refreshStatusAfterWaiting(
        for kind: AIProviderKind,
        presentsFailure: Bool = true
    ) async {
        await waitForStatus(for: kind)
        guard !Task.isCancelled else { return }
        await refreshStatus(for: kind, presentsFailure: presentsFailure)
    }

    func applicationBecameActive() {
        guard !isRunningTests else { return }
        isApplicationActive = true
        startPolling()
    }

    /// Prevents foreground status polling from racing an OAuth-backed model
    /// request. A request that begins while a status probe is already running
    /// waits for that short probe to finish; later probes skip this provider
    /// until the model request releases its ownership.
    func beginProviderRequest(_ kind: AIProviderKind) async throws {
        guard Self.oauthProvider(for: kind) != nil else {
            throw OAuthStateError.providerMismatch
        }
        providerRequestCounts[kind, default: 0] += 1
        do {
            await waitForStatus(for: kind)
            try Task.checkCancellation()
        } catch {
            endProviderRequest(kind)
            throw error
        }
    }

    func endProviderRequest(_ kind: AIProviderKind) {
        let remaining = providerRequestCounts[kind, default: 0] - 1
        if remaining > 0 {
            providerRequestCounts[kind] = remaining
        } else {
            providerRequestCounts.removeValue(forKey: kind)
        }
    }

    private func startPolling() {
        guard pollingTask == nil,
              isApplicationActive,
              !isPollingPausedForVerification else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var endedForLifecycleChange = false
            await self.refreshAllProviders(presentsFailure: false)
            while !Task.isCancelled {
                guard self.isApplicationActive,
                      !self.isPollingPausedForVerification else {
                    endedForLifecycleChange = true
                    break
                }
                let shouldContinue = AIProviderKind.allCases.contains { kind in
                    Self.oauthProvider(for: kind) != nil
                        && self.states[kind]?.shouldPoll == true
                }
                guard shouldContinue else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                await self.refreshAllProviders(presentsFailure: false)
            }
            let wasCancelled = Task.isCancelled
            self.pollingTask = nil
            if (endedForLifecycleChange || wasCancelled),
               self.isApplicationActive,
               !self.isPollingPausedForVerification {
                self.startPolling()
            }
        }
    }

    func applicationResignedActive() {
        isApplicationActive = false
        // A confirmation alert temporarily resigns the scene. Cancelling an
        // in-flight status RPC here invalidates its XPC connection while the
        // helper is still closing the managed runtime; an immediately
        // confirmed verification can then race that teardown. Let an active
        // status request finish naturally. A sleeping poll has no RPC to
        // preserve and can stop immediately.
        if statusInFlight.isEmpty {
            pollingTask?.cancel()
        }
    }

    private func refreshAllProviders(presentsFailure: Bool) async {
        for kind in AIProviderKind.allCases where Self.oauthProvider(for: kind) != nil {
            guard !Task.isCancelled else { return }
            await refreshStatusAfterWaiting(for: kind, presentsFailure: presentsFailure)
        }
    }

    // MARK: - Login

    @discardableResult
    func beginLogin(for kind: AIProviderKind) async -> URL? {
        await beginLogin(for: kind, method: .browser)
    }

    @discardableResult
    func beginDeviceCodeLogin(
        for kind: AIProviderKind
    ) async -> AIOAuthDeviceCodePresentation? {
        guard kind == .codex else { return nil }
        _ = await beginLogin(for: kind, method: .deviceCode)
        guard let presentation = deviceCodePresentations[kind],
              case let .authenticating(attemptID, authorizationURL) = states[kind],
              attemptID == presentation.attemptID,
              authorizationURL == presentation.verificationURL else {
            return nil
        }
        return presentation
    }

    private func beginLogin(
        for kind: AIProviderKind,
        method: OAuthBridgeLoginMethod
    ) async -> URL? {
        guard let provider = Self.oauthProvider(for: kind) else { return nil }
        guard method == .browser || kind == .codex else { return nil }
        let waitedForStatus = statusInFlight.contains(kind)
        await waitForStatus(for: kind)
        if waitedForStatus {
            guard case .disconnected = states[kind] else { return nil }
        }
        guard loginStartGenerations[kind] == nil,
              mutationGenerations[kind] == nil,
              loginAttemptIDs[kind] == nil else { return nil }
        let generation = beginOperation(for: kind)
        loginStartGenerations[kind] = generation
        loginAttemptIDs.removeValue(forKey: kind)
        deviceCodePresentations.removeValue(forKey: kind)
        states[kind] = .starting
        defer {
            if loginStartGenerations[kind] == generation {
                loginStartGenerations.removeValue(forKey: kind)
                loginStartTasks.removeValue(forKey: kind)
            }
        }

        do {
            let startTask = Task {
                try await bridgeService.startLogin(for: provider, method: method)
            }
            loginStartTasks[kind] = startTask
            let attempt = try await startTask.value
            guard operationGenerations[kind] == generation else {
                return nil
            }
            guard attempt.provider == provider else {
                applyFailure(
                    OAuthStateError.providerMismatch,
                    to: kind,
                    generation: generation
                )
                return nil
            }
            switch method {
            case .browser:
                guard attempt.userCode == nil else {
                    applyFailure(
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
                    applyFailure(
                        OAuthStateError.invalidLoginPresentation,
                        to: kind,
                        generation: generation
                    )
                    return nil
                }
                deviceCodePresentations[kind] = AIOAuthDeviceCodePresentation(
                    attemptID: attempt.attemptID,
                    verificationURL: verificationURL,
                    userCode: userCode
                )
            }
            loginAttemptIDs[kind] = attempt.attemptID
            states[kind] = .authenticating(
                attemptID: attempt.attemptID,
                authorizationURL: attempt.authorizationURL
            )
            return attempt.authorizationURL
        } catch is CancellationError {
            return nil
        } catch {
            applyFailure(error, to: kind, generation: generation)
            return nil
        }
    }

    func cancelLogin(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForStatus(for: kind)
        if loginStartGenerations[kind] != nil {
            await cancelPendingLoginStart(for: kind, provider: provider)
            return
        }
        guard mutationGenerations[kind] == nil,
              let attemptID = loginAttemptIDs[kind] else { return }
        let generation = beginOperation(for: kind)
        mutationGenerations[kind] = generation
        defer { finishMutation(for: kind, generation: generation) }

        do {
            let status = try await bridgeService.cancelLogin(
                for: provider,
                attemptID: attemptID
            )
            applyStatus(status, to: kind, generation: generation)
        } catch {
            applyFailure(error, to: kind, generation: generation)
        }
    }

    // MARK: - Connection lifecycle

    func verifyConnection(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        // The confirmation alert temporarily deactivates the scene and
        // cancels foreground polling. Wait for every provider's in-flight
        // status request to unwind before opening the verification request;
        // otherwise cancellation can invalidate the shared XPC connection
        // underneath the first account/session RPC.
        isPollingPausedForVerification = true
        if statusInFlight.isEmpty {
            let poll = pollingTask
            poll?.cancel()
            await poll?.value
        }
        for oauthKind in AIProviderKind.allCases where Self.oauthProvider(for: oauthKind) != nil {
            await waitForStatus(for: oauthKind)
        }
        guard !Task.isCancelled,
              loginStartGenerations[kind] == nil,
              mutationGenerations[kind] == nil,
              states[kind] == .signedInUnverified else {
            isPollingPausedForVerification = false
            if isApplicationActive { startPolling() }
            return
        }

        let generation = beginOperation(for: kind)
        mutationGenerations[kind] = generation
        verificationsInFlight.insert(kind)
        defer {
            verificationsInFlight.remove(kind)
            finishMutation(for: kind, generation: generation)
            isPollingPausedForVerification = false
            if isApplicationActive {
                startPolling()
            }
        }

        do {
            let status = try await bridgeService.verifyConnection(provider)
            guard !Task.isCancelled else { return }
            applyStatus(status, to: kind, generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            applyFailure(error, to: kind, generation: generation)
        }
    }

    func disconnect(_ kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForStatus(for: kind)
        if loginStartGenerations[kind] != nil {
            await cancelPendingLoginStart(for: kind, provider: provider)
            return
        }

        guard let generation = await acquireMutationGeneration(for: kind) else { return }
        defer { finishMutation(for: kind, generation: generation) }

        do {
            let status = try await bridgeService.disconnect(provider)
            applyStatus(status, to: kind, generation: generation)
        } catch {
            applyFailure(error, to: kind, generation: generation)
        }
    }

    func logout(for kind: AIProviderKind) async {
        guard let provider = Self.oauthProvider(for: kind) else { return }
        await waitForStatus(for: kind)
        if loginStartGenerations[kind] != nil {
            await cancelPendingLoginStart(for: kind, provider: provider)
        }

        guard let generation = await acquireMutationGeneration(for: kind) else { return }
        defer { finishMutation(for: kind, generation: generation) }

        do {
            let status = try await bridgeService.logout(provider)
            applyStatus(status, to: kind, generation: generation)
        } catch {
            applyFailure(error, to: kind, generation: generation)
        }
    }

    /// Shared preamble for disconnect and logout: wait out any in-flight
    /// verification, claim a generation, and clear login bookkeeping.
    /// Returns `nil` when another operation won the race.
    private func acquireMutationGeneration(for kind: AIProviderKind) async -> UUID? {
        let generation: UUID
        if verificationsInFlight.contains(kind) {
            generation = beginOperation(for: kind)
            await waitForMutation(for: kind)
        } else {
            guard mutationGenerations[kind] == nil else { return nil }
            generation = beginOperation(for: kind)
        }
        guard !Task.isCancelled,
              operationGenerations[kind] == generation,
              loginStartGenerations[kind] == nil,
              mutationGenerations[kind] == nil else { return nil }
        mutationGenerations[kind] = generation
        loginAttemptIDs.removeValue(forKey: kind)
        deviceCodePresentations.removeValue(forKey: kind)
        return generation
    }

    /// Cancels the actual bridge request, waits for its connection teardown,
    /// and, if the attempt won the race with cancellation, closes that exact
    /// remote attempt before a new login is allowed to start.
    private func cancelPendingLoginStart(
        for kind: AIProviderKind,
        provider: OAuthBridgeProvider
    ) async {
        _ = beginOperation(for: kind)
        let task = loginStartTasks.removeValue(forKey: kind)
        task?.cancel()
        let attempt = try? await task?.value
        loginStartGenerations.removeValue(forKey: kind)
        loginAttemptIDs.removeValue(forKey: kind)
        deviceCodePresentations.removeValue(forKey: kind)
        if let attempt {
            _ = try? await bridgeService.cancelLogin(
                for: provider,
                attemptID: attempt.attemptID
            )
        }
        states[kind] = .disconnected
    }

    // MARK: - Generation bookkeeping

    private func beginOperation(for kind: AIProviderKind) -> UUID {
        let generation = UUID()
        operationGenerations[kind] = generation
        return generation
    }

    /// Waiter slots are boxed so a cancelled waiter can be dropped from the
    /// queue exactly once; `finishStatus`/`finishMutation` still drain the
    /// queue unconditionally, so nothing can be parked forever even if the
    /// bridge call that owns the in-flight flag takes its full protocol
    /// timeout.
    private final class WaiterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CheckedContinuation<Void, Never>?

        func set(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            stored = continuation
            lock.unlock()
        }

        func take() -> CheckedContinuation<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            let continuation = stored
            stored = nil
            return continuation
        }
    }

    private func waitForStatus(for kind: AIProviderKind) async {
        while statusInFlight.contains(kind) {
            if Task.isCancelled { return }
            let box = WaiterBox()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    box.set(continuation)
                    statusWaiters[kind, default: []].append(box)
                }
            } onCancel: {
                Task { @MainActor in
                    statusWaiters[kind]?.removeAll { $0 === box }
                    box.take()?.resume()
                }
            }
        }
    }

    private func finishStatus(for kind: AIProviderKind) {
        statusInFlight.remove(kind)
        let waiters = statusWaiters.removeValue(forKey: kind) ?? []
        waiters.forEach { $0.take()?.resume() }
    }

    private func waitForMutation(for kind: AIProviderKind) async {
        while mutationGenerations[kind] != nil {
            if Task.isCancelled { return }
            let box = WaiterBox()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    box.set(continuation)
                    mutationWaiters[kind, default: []].append(box)
                }
            } onCancel: {
                Task { @MainActor in
                    mutationWaiters[kind]?.removeAll { $0 === box }
                    box.take()?.resume()
                }
            }
        }
    }

    private func finishMutation(for kind: AIProviderKind, generation: UUID) {
        guard mutationGenerations[kind] == generation else { return }
        mutationGenerations.removeValue(forKey: kind)
        let waiters = mutationWaiters.removeValue(forKey: kind) ?? []
        waiters.forEach { $0.take()?.resume() }
    }

    // MARK: - Applying results

    private func applyStatus(
        _ status: OAuthBridgeAuthStatus,
        to kind: AIProviderKind,
        generation: UUID
    ) {
        guard operationGenerations[kind] == generation,
              let expectedProvider = Self.oauthProvider(for: kind) else { return }
        guard status.provider == expectedProvider else {
            applyFailure(OAuthStateError.providerMismatch, to: kind, generation: generation)
            return
        }

        guard status.cliStatus == .available else {
            loginAttemptIDs.removeValue(forKey: kind)
            deviceCodePresentations.removeValue(forKey: kind)
            states[kind] = .unavailable(status.cliStatus)
            onProviderUnavailable?(kind, true)
            return
        }
        if let attemptID = status.loginAttemptID {
            onProviderUnavailable?(kind, true)
            let authorizationURL: URL?
            if case let .authenticating(currentAttemptID, currentURL) = states[kind],
               currentAttemptID == attemptID {
                authorizationURL = currentURL
            } else {
                authorizationURL = nil
            }
            if deviceCodePresentations[kind]?.attemptID != attemptID {
                deviceCodePresentations.removeValue(forKey: kind)
            }
            loginAttemptIDs[kind] = attemptID
            states[kind] = .authenticating(
                attemptID: attemptID,
                authorizationURL: authorizationURL
            )
            return
        }

        loginAttemptIDs.removeValue(forKey: kind)
        deviceCodePresentations.removeValue(forKey: kind)
        switch status.credentialState {
        case .unknown:
            states[kind] = .statusUnknown
            onProviderUnavailable?(kind, true)
        case .signedOut:
            states[kind] = .disconnected
            onProviderUnavailable?(kind, false)
        case .signedIn:
            switch status.connectionState {
            case .disconnected:
                states[kind] = .signedInDisconnected
                onProviderUnavailable?(kind, true)
            case .authorizing:
                states[kind] = .statusUnknown
                onProviderUnavailable?(kind, true)
            case .authenticated:
                states[kind] = .signedInUnverified
                onProviderUnavailable?(kind, true)
            case .connected:
                states[kind] = .connected
                onProviderConnected?()
            }
        }
    }

    private func applyFailure(
        _ error: Error,
        to kind: AIProviderKind,
        generation: UUID,
        presentsFailure: Bool = true
    ) {
        guard operationGenerations[kind] == generation else { return }
        loginAttemptIDs.removeValue(forKey: kind)
        deviceCodePresentations.removeValue(forKey: kind)
        let message = Self.message(for: error)
        states[kind] = .failed(message)
        onProviderUnavailable?(kind, true)
        if presentsFailure {
            onFailure?(message)
        }
    }

    // MARK: - Validation

    static func oauthProvider(for kind: AIProviderKind) -> OAuthBridgeProvider? {
        switch kind {
        case .codex: .codex
        case .grok: .grok
        case .deepSeek, .qwen: nil
        }
    }

    enum OAuthStateError: LocalizedError {
        case providerMismatch
        case invalidLoginPresentation

        var errorDescription: String? {
            switch self {
            case .providerMismatch:
                AppLanguage.localized("OAuth 伴随服务返回了不匹配的 AI 提供商。", english: "The OAuth helper returned a different AI provider.")
            case .invalidLoginPresentation:
                AppLanguage.localized("OAuth 伴随服务返回了无效的登录信息。", english: "The OAuth helper returned invalid sign-in information.")
            }
        }
    }

    static func validDeviceUserCode(_ userCode: String) -> Bool {
        (4...64).contains(userCode.utf8.count)
            && userCode.unicodeScalars.allSatisfy {
                ($0.value >= 0x30 && $0.value <= 0x39)
                    || ($0.value >= 0x41 && $0.value <= 0x5A)
                    || $0.value == 0x2D
            }
    }

    static func validOAuthAuthorizationURL(_ url: URL) -> Bool {
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

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
