import Foundation

enum OAuthBridgeClientError: LocalizedError, Equatable, Sendable {
    case connectionFailed(Int)
    case signingRequirementUnavailable
    case invalidRequest
    case requestTimedOut
    case invalidResponse
    case protocolMismatch
    case requestMismatch
    case service(OAuthBridgeErrorPayload)

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(code):
            AppLanguage.localized("OAuth 伴随服务连接失败（错误码 \(code)）。", english: "Could not connect to the OAuth helper (error \(code)).")
        case .signingRequirementUnavailable:
            AppLanguage.localized("无法验证 OAuth 伴随服务签名。", english: "The OAuth helper signature could not be verified.")
        case .invalidRequest:
            AppLanguage.localized("OAuth 伴随服务请求参数无效。", english: "The OAuth helper request is invalid.")
        case .requestTimedOut:
            AppLanguage.localized("OAuth 伴随服务响应超时。", english: "The OAuth companion service timed out.")
        case .invalidResponse:
            AppLanguage.localized("OAuth 伴随服务返回了无法识别的响应。", english: "The OAuth helper returned an unrecognized response.")
        case .protocolMismatch:
            AppLanguage.localized("OAuth 伴随服务版本不兼容，请更新寻简。", english: "The OAuth helper is incompatible. Update XunJian.")
        case .requestMismatch:
            AppLanguage.localized("OAuth 伴随服务响应与请求不匹配。", english: "The OAuth helper response does not match the request.")
        case let .service(error):
            Self.localizedServiceMessage(error)
        }
    }

    private static func localizedServiceMessage(_ error: OAuthBridgeErrorPayload) -> String {
        guard AppLanguage.selected.usesEnglish else { return error.message }
        return switch error.code {
        case .malformedRequest, .invalidArguments: "The OAuth request is invalid."
        case .payloadTooLarge: "The OAuth request is too large."
        case .protocolMismatch: "The OAuth helper is incompatible. Update XunJian."
        case .unsupportedOperation: "This OAuth operation is not supported."
        case .cliUnavailable: "The embedded OAuth runtime is unavailable."
        case .loginAlreadyInProgress: "A sign-in is already in progress."
        case .loginAttemptMismatch: "The sign-in attempt no longer matches the active request."
        case .safeVerificationUnavailable: "Safe connection verification is unavailable."
        case .authenticationFailed: "Authentication failed."
        case .generationFailed: "The AI request failed."
        case .internalFailure: "The OAuth helper encountered an internal error."
        }
    }
}

actor OAuthBridgeClient: OAuthBridgeServicing {
    static let shared = OAuthBridgeClient()

    enum ConnectionLane: Hashable, Sendable {
        case shared
        case codex
        case grok
    }

    private let serviceName: String
    private let codeSigningRequirementOverride: String?
    private let helperURLOverride: URL?
    private var connections: [ConnectionLane: NSXPCConnection] = [:]
    private var connectionGenerations: [ConnectionLane: UUID] = [:]

    init(
        serviceName: String = OAuthBridgeConstants.serviceName,
        codeSigningRequirement: String? = nil,
        helperURL: URL? = nil
    ) {
        self.serviceName = serviceName
        codeSigningRequirementOverride = codeSigningRequirement
        helperURLOverride = helperURL
    }

    func capabilities() async throws -> OAuthBridgeCapabilities {
        let result = try await perform(.capabilities)
        guard let capabilities = result.capabilities else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return capabilities
    }

    func probeOfficialCLIs() async throws -> [OAuthCLIProbe] {
        let result = try await perform(.probeOfficialCLIs)
        guard let probes = result.cliProbes else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return probes
    }

    func authenticationStatus(
        for provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        let result = try await perform(
            .authenticationStatus,
            arguments: OAuthBridgeRequestArguments(provider: provider)
        )
        guard let status = result.authStatus else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return status
    }

    func startLogin(
        for provider: OAuthBridgeProvider,
        method: OAuthBridgeLoginMethod
    ) async throws -> OAuthBridgeLoginAttempt {
        guard provider == .codex || method == .browser else {
            throw OAuthBridgeClientError.invalidRequest
        }
        let attemptID = UUID()
        let result = try await perform(
            .startLogin,
            arguments: OAuthBridgeRequestArguments(
                provider: provider,
                loginAttemptID: attemptID,
                loginMethod: provider == .codex ? method : nil
            )
        )
        guard let attempt = result.loginAttempt else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return attempt
    }

    func cancelLogin(
        for provider: OAuthBridgeProvider,
        attemptID: UUID
    ) async throws -> OAuthBridgeAuthStatus {
        let result = try await perform(
            .cancelLogin,
            arguments: OAuthBridgeRequestArguments(
                provider: provider,
                loginAttemptID: attemptID
            )
        )
        guard let status = result.authStatus else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return status
    }

    func verifyConnection(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        let result = try await perform(
            .verifyConnection,
            arguments: OAuthBridgeRequestArguments(provider: provider)
        )
        guard let status = result.authStatus else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return status
    }

    func listModels(
        for provider: OAuthBridgeProvider
    ) async throws -> [OAuthBridgeModel] {
        let result = try await perform(
            .listModels,
            arguments: OAuthBridgeRequestArguments(provider: provider)
        )
        guard let models = result.models else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return models
    }

    func generateText(
        provider: OAuthBridgeProvider,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let result = try await perform(
            .generateText,
            arguments: OAuthBridgeRequestArguments(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        )
        guard let generated = result.generatedText,
              generated.provider == provider,
              OAuthBridgeGenerationPolicy.outputIsValid(generated.text) else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return generated.text
    }

    func disconnect(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        let result = try await perform(
            .disconnectProvider,
            arguments: OAuthBridgeRequestArguments(provider: provider)
        )
        guard let status = result.authStatus else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return status
    }

    func logout(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        let result = try await perform(
            .logoutProvider,
            arguments: OAuthBridgeRequestArguments(provider: provider)
        )
        guard let status = result.authStatus else {
            throw OAuthBridgeClientError.invalidResponse
        }
        return status
    }

    func perform(
        _ operation: OAuthBridgeOperation,
        arguments: OAuthBridgeRequestArguments? = nil,
        protocolVersion: Int = OAuthBridgeConstants.protocolVersion
    ) async throws -> OAuthBridgeResult {
        guard Self.argumentsAreValid(arguments, for: operation) else {
            throw OAuthBridgeClientError.invalidRequest
        }
        let request = OAuthBridgeRequest(
            operation: operation,
            arguments: arguments,
            protocolVersion: protocolVersion
        )
        let lane = Self.connectionLane(for: request)
        let response: OAuthBridgeResponse
        do {
            response = try await send(request, lane: lane)
        } catch {
            invalidate(lane)
            throw error
        }

        guard response.protocolVersion == OAuthBridgeConstants.protocolVersion else {
            invalidate(lane)
            throw OAuthBridgeClientError.protocolMismatch
        }
        guard response.requestID == request.requestID else {
            invalidate(lane)
            throw OAuthBridgeClientError.requestMismatch
        }
        if let error = response.error, response.result == nil {
            guard Self.isValidServiceError(error) else {
                invalidate(lane)
                throw OAuthBridgeClientError.invalidResponse
            }
            throw OAuthBridgeClientError.service(error)
        }
        guard response.error == nil,
              let result = response.result,
              Self.resultIsValid(result, for: request) else {
            invalidate(lane)
            throw OAuthBridgeClientError.invalidResponse
        }
        return result
    }

    func invalidate() {
        let activeConnections = Array(connections.values)
        connections.removeAll()
        connectionGenerations.removeAll()
        activeConnections.forEach { $0.invalidate() }
    }

    static func connectionLane(for request: OAuthBridgeRequest) -> ConnectionLane {
        switch request.arguments?.provider {
        case .codex: .codex
        case .grok: .grok
        case nil: .shared
        }
    }

    private func invalidate(_ lane: ConnectionLane) {
        let connection = connections.removeValue(forKey: lane)
        connectionGenerations.removeValue(forKey: lane)
        connection?.invalidate()
    }

    static func argumentsAreValid(
        _ arguments: OAuthBridgeRequestArguments?,
        for operation: OAuthBridgeOperation
    ) -> Bool {
        switch operation {
        case .capabilities, .probeOfficialCLIs:
            return arguments == nil
        case .authenticationStatus, .verifyConnection, .listModels,
             .disconnectProvider, .logoutProvider:
            return arguments?.provider != nil
                && arguments?.loginAttemptID == nil
                && arguments?.loginMethod == nil
                && arguments?.model == nil
                && arguments?.systemPrompt == nil
                && arguments?.userPrompt == nil
        case .startLogin:
            guard let provider = arguments?.provider,
                  arguments?.loginAttemptID != nil,
                  arguments?.model == nil,
                  arguments?.systemPrompt == nil,
                  arguments?.userPrompt == nil else { return false }
            return switch provider {
            case .codex: arguments?.loginMethod != nil
            case .grok: arguments?.loginMethod == nil
            }
        case .cancelLogin:
            return arguments?.provider != nil
                && arguments?.loginAttemptID != nil
                && arguments?.loginMethod == nil
                && arguments?.model == nil
                && arguments?.systemPrompt == nil
                && arguments?.userPrompt == nil
        case .generateText:
            return arguments?.loginAttemptID == nil
                && arguments?.loginMethod == nil
                && OAuthBridgeGenerationPolicy.requestIsValid(
                    provider: arguments?.provider,
                    model: arguments?.model,
                    systemPrompt: arguments?.systemPrompt,
                    userPrompt: arguments?.userPrompt
                )
        }
    }

    static func resultIsValid(
        _ result: OAuthBridgeResult,
        for request: OAuthBridgeRequest
    ) -> Bool {
        let payloadCount = [
            result.capabilities != nil,
            result.cliProbes != nil,
            result.authStatus != nil,
            result.loginAttempt != nil,
            result.models != nil,
            result.generatedText != nil
        ].filter { $0 }.count
        guard payloadCount == 1 else { return false }

        switch request.operation {
        case .capabilities:
            guard let capabilities = result.capabilities else { return false }
            return capabilities.protocolVersion == OAuthBridgeConstants.protocolVersion
                && Set(capabilities.supportedOperations)
                    == Set(OAuthBridgeOperation.safeOperations)
                && capabilities.supportedOperations.count
                    == OAuthBridgeOperation.safeOperations.count
                && Set(capabilities.supportedProviders)
                    == Set(OAuthBridgeProvider.allCases)
                && capabilities.supportedProviders.count
                    == OAuthBridgeProvider.allCases.count
                && !capabilities.storesCredentials

        case .probeOfficialCLIs:
            guard let probes = result.cliProbes,
                  Set(probes.map(\.provider)) == Set(OAuthBridgeProvider.allCases),
                  probes.count == OAuthBridgeProvider.allCases.count else {
                return false
            }
            return probes.allSatisfy { probe in
                guard let version = probe.version else { return true }
                return version.utf8.count <= 160
                    && !version.contains("\n")
                    && !version.contains("\r")
            }

        case .authenticationStatus:
            guard let provider = request.arguments?.provider,
                  let status = result.authStatus else {
                return false
            }
            return authStatusIsValid(status, expectedProvider: provider)

        case .startLogin:
            guard let provider = request.arguments?.provider,
                  let attemptID = request.arguments?.loginAttemptID,
                  let attempt = result.loginAttempt,
                  attempt.provider == provider,
                  attempt.attemptID == attemptID else {
                return false
            }
            let method = request.arguments?.loginMethod ?? .browser
            switch (provider, method) {
            case (.codex, .browser):
                guard let authorizationURL = attempt.authorizationURL else { return false }
                return authorizationURLIsValid(authorizationURL)
                    && attempt.userCode == nil
            case (.codex, .deviceCode):
                guard let authorizationURL = attempt.authorizationURL,
                      let userCode = attempt.userCode else { return false }
                return authorizationURLIsValid(authorizationURL)
                    && userCodeIsValid(userCode)
            case (.grok, .browser):
                return attempt.authorizationURL == nil
                    && attempt.userCode == nil
            case (.grok, .deviceCode):
                return false
            }

        case .cancelLogin:
            guard let provider = request.arguments?.provider,
                  let status = result.authStatus,
                  authStatusIsValid(status, expectedProvider: provider) else {
                return false
            }
            return status.connectionState != .authorizing
                && status.loginAttemptID == nil

        case .verifyConnection:
            guard let provider = request.arguments?.provider,
                  let status = result.authStatus,
                  authStatusIsValid(status, expectedProvider: provider) else {
                return false
            }
            return status.cliStatus == .available
                && status.credentialState == .signedIn
                && status.connectionState == .connected
                && status.loginAttemptID == nil

        case .listModels:
            guard let provider = request.arguments?.provider,
                  let models = result.models,
                  !models.isEmpty,
                  models.count <= 2_000,
                  Set(models.map(\.id)).count == models.count else {
                return false
            }
            return models.allSatisfy { model in
                model.provider == provider
                    && OAuthBridgeGenerationPolicy.requestIsValid(
                        provider: provider,
                        model: model.id,
                        systemPrompt: "model-list-validation",
                        userPrompt: "model-list-validation"
                    )
            }

        case .generateText:
            guard let provider = request.arguments?.provider,
                  let generated = result.generatedText else {
                return false
            }
            return generated.provider == provider
                && OAuthBridgeGenerationPolicy.outputIsValid(generated.text)

        case .disconnectProvider:
            guard let provider = request.arguments?.provider,
                  let status = result.authStatus,
                  authStatusIsValid(status, expectedProvider: provider) else {
                return false
            }
            return status.connectionState == .disconnected
                && status.loginAttemptID == nil

        case .logoutProvider:
            guard let provider = request.arguments?.provider,
                  let status = result.authStatus,
                  authStatusIsValid(status, expectedProvider: provider) else {
                return false
            }
            return status.cliStatus == .available
                && status.credentialState == .signedOut
                && status.connectionState == .disconnected
                && status.loginAttemptID == nil
        }
    }

    private static func authStatusIsValid(
        _ status: OAuthBridgeAuthStatus,
        expectedProvider: OAuthBridgeProvider
    ) -> Bool {
        guard status.provider == expectedProvider else { return false }

        if status.cliStatus != .available {
            return status.credentialState == .unknown
                && status.connectionState == .disconnected
                && status.loginAttemptID == nil
        }

        switch status.connectionState {
        case .disconnected:
            return status.loginAttemptID == nil
        case .authorizing:
            return status.loginAttemptID != nil
        case .authenticated, .connected:
            return status.credentialState == .signedIn
                && status.loginAttemptID == nil
        }
    }

    private static func authorizationURLIsValid(_ url: URL) -> Bool {
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

    private static func userCodeIsValid(_ userCode: String) -> Bool {
        guard (4...64).contains(userCode.utf8.count) else { return false }
        return userCode.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x41 && $0.value <= 0x5A)
                || $0.value == 0x2D
        }
    }

    private static func isValidServiceError(_ error: OAuthBridgeErrorPayload) -> Bool {
        !error.message.isEmpty
            && error.message.utf8.count <= 512
            && !error.message.contains("\n")
            && !error.message.contains("\r")
    }

    private func send(
        _ request: OAuthBridgeRequest,
        lane: ConnectionLane
    ) async throws -> OAuthBridgeResponse {
        let requestData = try OAuthBridgeCodec.encode(request)
        let connection = try connections[lane] ?? makeConnection(lane: lane)
        connections[lane] = connection

        let gate = OAuthBridgeReplyGate()
        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    let timeoutSeconds = OAuthBridgeTiming.clientTimeoutSeconds(
                        for: request.operation
                    )
                    let timeoutTask = Task.detached {
                        do {
                            try await Task.sleep(for: .seconds(timeoutSeconds))
                        } catch {
                            return
                        }
                        gate.resume(throwing: OAuthBridgeClientError.requestTimedOut)
                    }
                    gate.install(timeoutTask: timeoutTask)

                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                        let code = (error as NSError).code
                        gate.resume(throwing: OAuthBridgeClientError.connectionFailed(code))
                    }) as? OAuthBridgeXPCProtocol else {
                        gate.resume(throwing: OAuthBridgeClientError.invalidResponse)
                        return
                    }
                    proxy.handle(requestData) { data in
                        gate.resume(returning: data)
                    }
                }
            } onCancel: {
                gate.resume(throwing: CancellationError())
            }
        } catch {
            // Drop the cached reference before invalidation. The invalidation
            // handler is delivered asynchronously; without this synchronous
            // detach, a request started immediately after an alert closes can
            // reuse the already-invalid connection and fail at its first RPC.
            if connections[lane] === connection {
                connections.removeValue(forKey: lane)
                connectionGenerations.removeValue(forKey: lane)
            }
            connection.invalidate()
            throw error
        }

        do {
            return try OAuthBridgeCodec.decode(OAuthBridgeResponse.self, from: responseData)
        } catch {
            throw OAuthBridgeClientError.invalidResponse
        }
    }

    private func makeConnection(lane: ConnectionLane) throws -> NSXPCConnection {
        let applicationURL = Bundle.main.bundleURL
        let helperURL = helperURLOverride ?? applicationURL
            .appending(
                path: "Contents/XPCServices/XunJianOAuthBridge.xpc",
                directoryHint: .isDirectory
            )
        guard let requirement = codeSigningRequirementOverride
            ?? OAuthBridgeCodeSigning.trustedHelperRequirement(
                forApplicationAt: applicationURL,
                debugHelperURL: helperURL
            ) else {
            throw OAuthBridgeClientError.signingRequirementUnavailable
        }

        let connection = NSXPCConnection(serviceName: serviceName)
        let generation = UUID()
        connectionGenerations[lane] = generation
        connection.remoteObjectInterface = NSXPCInterface(with: OAuthBridgeXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.interruptionHandler = { [weak self] in
            Task { await self?.dropConnection(lane: lane, generation: generation) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.dropConnection(lane: lane, generation: generation) }
        }
        connection.activate()
        return connection
    }

    private func dropConnection(lane: ConnectionLane, generation: UUID) {
        guard connectionGenerations[lane] == generation else { return }
        connections.removeValue(forKey: lane)
        connectionGenerations.removeValue(forKey: lane)
    }
}

private final class OAuthBridgeReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var pendingResult: Result<Data, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(timeoutTask: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func resume(returning data: Data) {
        resolve(.success(data))
    }

    func resume(throwing error: any Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()
            timeoutTask?.cancel()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
