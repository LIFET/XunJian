import Darwin
import Foundation
import Security

private enum OAuthVerificationProofStore {
    struct Proof: Codable, Equatable, Sendable {
        let formatVersion: Int
        let provider: OAuthBridgeProvider
        let runtimeVersion: String
        let runtimeSHA256: String
        let credentialIdentity: CredentialIdentity
    }

    struct CredentialIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    static let maximumCredentialBytes = 1_048_576
    private static let formatVersion = 1
    private static let fileName = "verification-proof.json"

    static func makeProof(
        provider: OAuthBridgeProvider,
        runtimeVersion: String,
        runtimeURL: URL,
        credentialURL: URL
    ) throws -> Proof? {
        guard let runtimeSHA256 = try? ManagedRuntimeDigest.sha256Hex(
            fileURL: runtimeURL
        ),
              let credentialIdentity = try credentialIdentity(
                  at: credentialURL
              ) else {
            return nil
        }
        return Proof(
            formatVersion: formatVersion,
            provider: provider,
            runtimeVersion: runtimeVersion,
            runtimeSHA256: runtimeSHA256,
            credentialIdentity: credentialIdentity
        )
    }

    static func restore(
        provider: OAuthBridgeProvider,
        runtimeVersion: String,
        runtimeURL: URL,
        credentialURL: URL
    ) -> Bool {
        guard let expected = (try? makeProof(
            provider: provider,
            runtimeVersion: runtimeVersion,
            runtimeURL: runtimeURL,
            credentialURL: credentialURL
        )) ?? nil,
              let proofData = try? readRegularFile(
                  proofURL(for: credentialURL),
                  maximumBytes: 4_096
              ),
              let stored = try? JSONDecoder().decode(Proof.self, from: proofData) else {
            return false
        }
        return stored == expected
    }

    @discardableResult
    static func persist(
        provider: OAuthBridgeProvider,
        runtimeVersion: String,
        runtimeURL: URL,
        credentialURL: URL
    ) -> Bool {
        sweepStaleTemporaryProofFiles(near: credentialURL)
        guard let proof = (try? makeProof(
            provider: provider,
            runtimeVersion: runtimeVersion,
            runtimeURL: runtimeURL,
            credentialURL: credentialURL
        )) ?? nil,
              let data = try? JSONEncoder().encode(proof),
              data.count <= 4_096 else {
            clear(for: credentialURL)
            return false
        }
        let destination = proofURL(for: credentialURL)
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".verification-proof-\(UUID().uuidString).tmp"
        )
        do {
            guard writeExclusive(data, to: temporary) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            var destinationInformation = stat()
            if lstat(destination.path, &destinationInformation) == 0 {
                guard (try? readRegularFile(destination, maximumBytes: 4_096)) != nil else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            } else if errno != ENOENT {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard rename(temporary.path, destination.path) == 0,
                  try readRegularFile(destination, maximumBytes: 4_096) == data else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            clear(for: credentialURL)
            return false
        }
    }

    static func clear(for credentialURL: URL) {
        let url = proofURL(for: credentialURL)
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return }
        guard information.st_uid == getuid(),
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_mode & 0o077 == 0,
              (try? readRegularFile(url, maximumBytes: 4_096)) != nil else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func proofURL(for credentialURL: URL) -> URL {
        credentialURL.deletingLastPathComponent().appending(path: fileName)
    }

    // Removes orphaned `.verification-proof-*.tmp` files left behind by a
    // crash between the exclusive write and the rename in `persist`. Only
    // names matching the exact prefix and suffix pattern are touched, removal
    // is best-effort, and symlinks are never followed (lstat must report a
    // regular file before the entry is removed).
    private static func sweepStaleTemporaryProofFiles(near credentialURL: URL) {
        let directory = proofURL(for: credentialURL).deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return
        }
        for name in names {
            guard name.hasPrefix(".verification-proof-"), name.hasSuffix(".tmp") else {
                continue
            }
            let url = directory.appending(path: name)
            var information = stat()
            guard lstat(url.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) -> Bool {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { return false }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return fsync(descriptor) == 0
        }
    }

    private static func credentialIdentity(
        at url: URL
    ) throws -> CredentialIdentity? {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard linkInformation.st_uid == getuid(),
              linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_nlink == 1,
              linkInformation.st_mode & 0o077 == 0,
              linkInformation.st_size > 0,
              linkInformation.st_size <= maximumCredentialBytes else {
            throw CocoaError(.fileReadNoPermission)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == getuid(),
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & 0o077 == 0,
              openedInformation.st_size > 0,
              openedInformation.st_size <= maximumCredentialBytes else {
            throw CocoaError(.fileReadNoPermission)
        }
        return CredentialIdentity(
            device: UInt64(openedInformation.st_dev),
            inode: UInt64(openedInformation.st_ino),
            owner: openedInformation.st_uid,
            size: openedInformation.st_size,
            modificationSeconds: Int64(openedInformation.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(openedInformation.st_mtimespec.tv_nsec),
            changeSeconds: Int64(openedInformation.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(openedInformation.st_ctimespec.tv_nsec)
        )
    }

    private static func readRegularFile(
        _ url: URL,
        maximumBytes: Int?
    ) throws -> Data? {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard linkInformation.st_uid == getuid(),
              linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_nlink == 1,
              linkInformation.st_mode & 0o077 == 0,
              maximumBytes.map({ linkInformation.st_size <= $0 }) ?? true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == linkInformation.st_uid,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & 0o077 == 0,
              openedInformation.st_size == linkInformation.st_size else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try handle.readToEnd() ?? Data()
        var finalInformation = stat()
        guard data.count == Int(openedInformation.st_size),
              fstat(descriptor, &finalInformation) == 0,
              finalInformation.st_dev == openedInformation.st_dev,
              finalInformation.st_ino == openedInformation.st_ino,
              finalInformation.st_uid == openedInformation.st_uid,
              finalInformation.st_mode & S_IFMT == S_IFREG,
              finalInformation.st_nlink == 1,
              finalInformation.st_mode & 0o077 == 0,
              finalInformation.st_size == openedInformation.st_size,
              maximumBytes.map({ data.count <= $0 }) ?? true else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
    }
}

private final class OAuthBridgeReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: (Data) -> Void

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ response: OAuthBridgeResponse) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        let fallback = Data(#"{"protocolVersion":6,"requestID":null,"result":null,"error":{"code":"internalFailure","message":"OAuth bridge response encoding failed."}}"#.utf8)
        reply((try? OAuthBridgeCodec.encode(response)) ?? fallback)
    }
}

private final class OAuthBridgeService: NSObject, OAuthBridgeXPCProtocol {
    private let coordinator = OAuthBridgeCoordinator()

    func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let replyBox = OAuthBridgeReplyBox(reply)
        guard requestData.count <= OAuthBridgeConstants.maximumPayloadBytes else {
            replyBox.send(.failure(
                requestID: nil,
                code: .payloadTooLarge,
                message: "OAuth bridge request is too large."
            ))
            return
        }
        guard let request = try? OAuthBridgeCodec.decode(
            OAuthBridgeRequest.self,
            from: requestData
        ) else {
            replyBox.send(.failure(
                requestID: nil,
                code: .malformedRequest,
                message: "OAuth bridge request is malformed."
            ))
            return
        }

        Task { [coordinator] in
            replyBox.send(await coordinator.handle(request))
        }
    }

    func invalidate() {
        Task { [coordinator] in await coordinator.invalidate() }
    }
}

private actor OAuthBridgeCoordinator {
    private struct CodexRuntime: Sendable {
        let process: SupervisedLineProcess
        let client: CodexAppServerClient
        let executableURL: URL
        let homeLease: GrokCLIHomeLease
        let temporaryRootURL: URL
    }

    private struct GrokRuntime: Sendable {
        let process: SupervisedLineProcess
        let client: GrokACPClient
        let executableURL: URL
        let cliHome: GrokCLIHome
        let leaseOwnership: GrokCLIHomeLeaseOwnership
        let temporaryRootURL: URL
    }

    private struct CodexLoginState: Sendable {
        let localAttemptID: UUID
        let internalLoginID: String
    }

    private struct GrokLoginState: Sendable {
        let attemptID: UUID
        let process: SupervisedLineProcess
        let cliHome: GrokCLIHome
        let leaseOwnership: GrokCLIHomeLeaseOwnership
        let temporaryRootURL: URL
        let generation: UInt64
    }

    private struct GrokLoginFinalization: Equatable, Sendable {
        let attemptID: UUID
        let generation: UInt64
    }

    private enum Failure: Error {
        case response(OAuthBridgeErrorCode, String)
    }

    private enum VerificationRunError: Error, Sendable {
        case timedOut
        case rejected(String)
    }

    private enum GenerationRunError: Error, Sendable {
        case timedOut
    }

    private enum SessionHistoryDeletionError: Error, Sendable {
        case timedOut
        case outputTooLarge
    }

    private enum GrokSafetyInspectionError: Error, Sendable {
        case timedOut
        case outputTooLarge
        case invalidOutput
    }

    private enum GrokSafetyInspectionRaceResult: Sendable {
        case output(Data, finishedAt: UInt64)
        case timedOut
    }

    private let bundledCodexRuntime = BundledCodexRuntimeResolver()
    private let bundledGrokRuntime = BundledGrokRuntimeResolver()
    private var codexRuntime: CodexRuntime?
    private var grokRuntime: GrokRuntime?
    private var codexLogin: CodexLoginState?
    private var grokLogin: GrokLoginState?
    private var grokLoginFinalization: GrokLoginFinalization?
    private var codexAuthTask: Task<Void, Never>?
    private var grokLoginTask: Task<Void, Never>?
    private var grokGeneration: UInt64 = 0
    private var codexCredentialState: OAuthCredentialState = .unknown
    private var grokCredentialState: OAuthCredentialState = .unknown
    private var codexConnectionVerified = false
    private var grokConnectionVerified = false
    private var codexVerificationRestored = false
    private var grokVerificationRestored = false
    private var providersInFlight = Set<OAuthBridgeProvider>()
    private var isInvalidated = false

    func handle(_ request: OAuthBridgeRequest) async -> OAuthBridgeResponse {
        guard request.protocolVersion == OAuthBridgeConstants.protocolVersion else {
            return .failure(
                requestID: request.requestID,
                code: .protocolMismatch,
                message: "OAuth bridge protocol version is incompatible."
            )
        }
        guard !isInvalidated else {
            return .failure(
                requestID: request.requestID,
                code: .internalFailure,
                message: "OAuth bridge connection is unavailable."
            )
        }
        guard Self.argumentsAreValid(request.arguments, for: request.operation) else {
            return .failure(
                requestID: request.requestID,
                code: .invalidArguments,
                message: "OAuth bridge request arguments are invalid."
            )
        }

        let reservedProvider = request.arguments?.provider
        if let reservedProvider,
           !providersInFlight.insert(reservedProvider).inserted {
            return .failure(
                requestID: request.requestID,
                code: request.operation == .startLogin
                    ? .loginAlreadyInProgress
                    : .authenticationFailed,
                message: "An OAuth operation is already in progress."
            )
        }
        defer {
            if let reservedProvider {
                providersInFlight.remove(reservedProvider)
            }
        }

        do {
            let result: OAuthBridgeResult
            switch request.operation {
            case .capabilities:
                result = .capabilities(OAuthBridgeCapabilities(
                    protocolVersion: OAuthBridgeConstants.protocolVersion,
                    supportedOperations: OAuthBridgeOperation.safeOperations,
                    supportedProviders: OAuthBridgeProvider.allCases,
                    storesCredentials: false
                ))
            case .probeOfficialCLIs:
                result = .cliProbes([
                    managedCodexProbe(),
                    managedGrokProbe()
                ])
            case .authenticationStatus:
                result = .authenticationStatus(
                    try await authenticationStatus(for: request.arguments!.provider!)
                )
            case .startLogin:
                result = .loginAttempt(try await startLogin(
                    provider: request.arguments!.provider!,
                    attemptID: request.arguments!.loginAttemptID!,
                    method: request.arguments!.loginMethod ?? .browser
                ))
            case .cancelLogin:
                result = .authenticationStatus(try await cancelLogin(
                    provider: request.arguments!.provider!,
                    attemptID: request.arguments!.loginAttemptID!
                ))
            case .verifyConnection:
                result = .authenticationStatus(try await verifyConnection(
                    request.arguments!.provider!
                ))
            case .generateText:
                let provider = request.arguments!.provider!
                result = .generatedText(OAuthBridgeGeneratedText(
                    provider: provider,
                    text: try await generateText(
                        provider: provider,
                        model: request.arguments!.model!,
                        systemPrompt: request.arguments!.systemPrompt!,
                        userPrompt: request.arguments!.userPrompt!
                    )
                ))
            case .disconnectProvider:
                result = .authenticationStatus(
                    await disconnect(request.arguments!.provider!)
                )
            case .logoutProvider:
                result = .authenticationStatus(
                    try await logout(request.arguments!.provider!)
                )
            }
            return .success(requestID: request.requestID, result: result)
        } catch let Failure.response(code, message) {
            return .failure(requestID: request.requestID, code: code, message: message)
        } catch {
            return .failure(
                requestID: request.requestID,
                code: .authenticationFailed,
                message: "OAuth authentication operation failed."
            )
        }
    }

    func invalidate() async {
        guard !isInvalidated else { return }
        isInvalidated = true
        grokGeneration &+= 1
        codexConnectionVerified = false
        grokConnectionVerified = false
        codexAuthTask?.cancel()
        grokLoginTask?.cancel()
        codexAuthTask = nil
        grokLoginTask = nil
        codexLogin = nil

        if let login = grokLogin {
            grokLogin = nil
            await login.process.close()
            Self.removeTemporaryRoot(login.temporaryRootURL)
            login.leaseOwnership.releaseLogin()
        }
        if let runtime = codexRuntime {
            codexRuntime = nil
            await close(runtime)
        }
        if let runtime = grokRuntime {
            grokRuntime = nil
            await close(runtime)
        }
    }

    private static func argumentsAreValid(
        _ arguments: OAuthBridgeRequestArguments?,
        for operation: OAuthBridgeOperation
    ) -> Bool {
        switch operation {
        case .capabilities, .probeOfficialCLIs:
            return arguments == nil
        case .authenticationStatus, .verifyConnection, .disconnectProvider, .logoutProvider:
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

    private func authenticationStatus(
        for provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        switch provider {
        case .codex:
            let probe = managedCodexProbe()
            guard probe.status == .available else {
                clearStoredVerification(for: .codex)
                await discardCodexRuntime()
                return unavailableStatus(provider: .codex, cliStatus: probe.status)
            }
            if let login = codexLogin {
                return OAuthBridgeAuthStatus(
                    provider: .codex,
                    cliStatus: .available,
                    credentialState: .unknown,
                    connectionState: .authorizing,
                    loginAttemptID: login.localAttemptID
                )
            }
            do {
                let executable = try bundledCodexExecutable()
                let runtime = try await ensureCodexRuntime(executableURL: executable)
                switch try await runtime.client.readAccount() {
                case .signedOut:
                    clearStoredVerification(for: .codex)
                    codexCredentialState = .signedOut
                    return disconnectedStatus(provider: .codex, credential: .signedOut)
                case let .signedIn(type, _, _):
                    guard type.lowercased() == "chatgpt" else {
                        clearStoredVerification(for: .codex)
                        codexCredentialState = .signedOut
                        return disconnectedStatus(provider: .codex, credential: .signedOut)
                    }
                    codexCredentialState = .signedIn
                    if !codexConnectionVerified, !codexVerificationRestored {
                        codexConnectionVerified = restoreStoredVerification(for: .codex)
                        codexVerificationRestored = true
                    }
                    return codexConnectionVerified
                        ? connectedStatus(provider: .codex)
                        : authenticatedStatus(provider: .codex)
                }
            } catch let failure as Failure {
                clearStoredVerification(for: .codex)
                await discardCodexRuntime()
                codexCredentialState = .unknown
                throw failure
            } catch {
                clearStoredVerification(for: .codex)
                await discardCodexRuntime()
                codexCredentialState = .unknown
                return disconnectedStatus(provider: .codex, credential: .unknown)
            }

        case .grok:
            let probe = managedGrokProbe()
            guard probe.status == .available else {
                clearStoredVerification(for: .grok)
                _ = await disconnect(.grok)
                return unavailableStatus(provider: .grok, cliStatus: probe.status)
            }
            if let login = grokLogin {
                return OAuthBridgeAuthStatus(
                    provider: .grok,
                    cliStatus: .available,
                    credentialState: .unknown,
                    connectionState: .authorizing,
                    loginAttemptID: login.attemptID
                )
            }
            if let finalization = grokLoginFinalization {
                return OAuthBridgeAuthStatus(
                    provider: .grok,
                    cliStatus: .available,
                    credentialState: .unknown,
                    connectionState: .authorizing,
                    loginAttemptID: finalization.attemptID
                )
            }
            if let runtime = grokRuntime {
                guard try prepareGrokCLIHome() == runtime.cliHome else {
                    grokConnectionVerified = false
                    await discardGrokRuntime()
                    grokCredentialState = .unknown
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "XunJian's private Grok login directory changed unexpectedly."
                    )
                }
                if await runtime.process.processIdentifier != nil {
                    grokCredentialState = .signedIn
                    guard grokConnectionVerified else {
                        return authenticatedStatus(provider: .grok)
                    }
                    grokRuntime = nil
                    guard await closeAfterVerification(runtime),
                          !isInvalidated,
                          grokConnectionVerified else {
                        grokConnectionVerified = false
                        grokCredentialState = .unknown
                        return disconnectedStatus(
                            provider: .grok,
                            credential: .unknown
                        )
                    }
                    return connectedStatus(provider: .grok)
                }
                grokConnectionVerified = false
                await discardGrokRuntime()
            }
            do {
                let runtime = try await makeGrokRuntime()
                guard !isInvalidated else {
                    await close(runtime)
                    return disconnectedStatus(provider: .grok, credential: .unknown)
                }
                grokCredentialState = .signedIn
                if !grokConnectionVerified, !grokVerificationRestored {
                    grokConnectionVerified = restoreStoredVerification(for: .grok)
                    grokVerificationRestored = true
                }
                guard grokConnectionVerified else {
                    grokRuntime = runtime
                    return authenticatedStatus(provider: .grok)
                }
                guard await closeAfterVerification(runtime),
                      !isInvalidated,
                      grokConnectionVerified else {
                    grokConnectionVerified = false
                    grokCredentialState = .unknown
                    return disconnectedStatus(provider: .grok, credential: .unknown)
                }
                return connectedStatus(provider: .grok)
            } catch GrokACPError.cachedTokenUnavailable {
                clearStoredVerification(for: .grok)
                grokConnectionVerified = false
                await discardGrokRuntime()
                grokCredentialState = .signedOut
                return disconnectedStatus(provider: .grok, credential: .signedOut)
            } catch let failure as Failure {
                clearStoredVerification(for: .grok)
                grokConnectionVerified = false
                await discardGrokRuntime()
                grokCredentialState = .unknown
                throw failure
            } catch {
                clearStoredVerification(for: .grok)
                grokConnectionVerified = false
                await discardGrokRuntime()
                grokCredentialState = .unknown
                return disconnectedStatus(provider: .grok, credential: .unknown)
            }
        }
    }

    private func startLogin(
        provider: OAuthBridgeProvider,
        attemptID: UUID,
        method: OAuthBridgeLoginMethod
    ) async throws -> OAuthBridgeLoginAttempt {
        switch provider {
        case .codex:
            clearStoredVerification(for: .codex)
            codexConnectionVerified = false
            guard codexLogin == nil else {
                throw Failure.response(
                    .loginAlreadyInProgress,
                    "An OAuth login is already in progress."
                )
            }
            let executable = try bundledCodexExecutable()
            let runtime = try await ensureCodexRuntime(executableURL: executable)
            let attempt: CodexLoginAttempt
            do {
                switch method {
                case .browser:
                    attempt = try await runtime.client.startChatGPTLogin()
                case .deviceCode:
                    attempt = try await runtime.client.startChatGPTDeviceCodeLogin()
                }
            } catch CodexAppServerError.loginAlreadyActive {
                await discardCodexRuntime()
                throw Failure.response(
                    .loginAlreadyInProgress,
                    "An OAuth login is already in progress."
                )
            } catch {
                await discardCodexRuntime()
                throw Failure.response(
                    .authenticationFailed,
                    "Codex OAuth login could not be started."
                )
            }
            guard !isInvalidated, codexRuntime?.client === runtime.client else {
                try? await runtime.client.cancelLogin(loginID: attempt.loginID)
                throw Failure.response(
                    .authenticationFailed,
                    "OAuth bridge was closed."
                )
            }
            codexLogin = CodexLoginState(
                localAttemptID: attemptID,
                internalLoginID: attempt.loginID
            )
            startCodexAuthConsumer(client: runtime.client)
            return OAuthBridgeLoginAttempt(
                provider: .codex,
                attemptID: attemptID,
                authorizationURL: attempt.authorizationURL,
                userCode: attempt.userCode
            )

        case .grok:
            clearStoredVerification(for: .grok)
            guard method == .browser else {
                throw Failure.response(
                    .invalidArguments,
                    "Device-code login is only available for Codex."
                )
            }
            grokConnectionVerified = false
            guard grokLogin == nil, grokLoginFinalization == nil else {
                throw Failure.response(
                    .loginAlreadyInProgress,
                    "An OAuth login is already in progress."
                )
            }
            if let runtime = grokRuntime {
                grokRuntime = nil
                await close(runtime)
            }
            let executable = try bundledGrokExecutable()
            grokGeneration &+= 1
            let generation = grokGeneration
            let login = try await makeGrokLogin(
                executableURL: executable,
                attemptID: attemptID,
                generation: generation
            )
            guard !isInvalidated, grokGeneration == generation else {
                await login.process.close()
                Self.removeTemporaryRoot(login.temporaryRootURL)
                login.leaseOwnership.releaseLogin()
                throw Failure.response(
                    .authenticationFailed,
                    "OAuth bridge was closed."
                )
            }
            grokLogin = login
            startGrokLoginConsumer(login)
            return OAuthBridgeLoginAttempt(
                provider: .grok,
                attemptID: attemptID,
                authorizationURL: nil
            )
        }
    }

    private func cancelLogin(
        provider: OAuthBridgeProvider,
        attemptID: UUID
    ) async throws -> OAuthBridgeAuthStatus {
        switch provider {
        case .codex:
            guard let login = codexLogin,
                  login.localAttemptID == attemptID,
                  let runtime = codexRuntime else {
                throw Failure.response(
                    .loginAttemptMismatch,
                    "OAuth login attempt does not match."
                )
            }
            codexLogin = nil
            codexAuthTask?.cancel()
            codexAuthTask = nil
            try? await runtime.client.cancelLogin(loginID: login.internalLoginID)
            codexRuntime = nil
            await close(runtime)
            return disconnectedStatus(
                provider: .codex,
                credential: codexCredentialState
            )

        case .grok:
            grokConnectionVerified = false
            guard let login = grokLogin, login.attemptID == attemptID else {
                throw Failure.response(
                    .loginAttemptMismatch,
                    "OAuth login attempt does not match."
                )
            }
            grokGeneration &+= 1
            grokLogin = nil
            grokLoginTask?.cancel()
            grokLoginTask = nil
            await login.process.close()
            Self.removeTemporaryRoot(login.temporaryRootURL)
            login.leaseOwnership.releaseLogin()
            return disconnectedStatus(
                provider: .grok,
                credential: grokCredentialState
            )
        }
    }

    private func verifyConnection(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        switch provider {
        case .codex:
            guard codexLogin == nil else {
                throw Failure.response(
                    .loginAlreadyInProgress,
                    "An OAuth login is already in progress."
                )
            }
            codexConnectionVerified = false
            clearStoredVerification(for: .codex)
            do {
                let reply = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.performCodexGeneration(
                            model: "gpt-5.6-sol",
                            prompt: "Reply exactly XUNJIAN_OK. Do not use tools.",
                            fallbackToFirstListedModel: true
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        try Task.checkCancellation()
                        throw VerificationRunError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let reply = try await group.next() else {
                        throw CancellationError()
                    }
                    return reply
                }
                try Task.checkCancellation()
                guard !isInvalidated,
                      reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        == "XUNJIAN_OK" else {
                    throw VerificationRunError.rejected("unexpected_reply")
                }
                codexCredentialState = .signedIn
                codexConnectionVerified = persistStoredVerification(for: .codex)
                guard codexConnectionVerified else {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Codex verification proof could not be stored safely."
                    )
                }
                return connectedStatus(provider: .codex)
            } catch {
                codexConnectionVerified = false
                if case VerificationRunError.timedOut = error {
                    throw Failure.response(
                        .authenticationFailed,
                        "Codex connection verification timed out."
                    )
                }
                if case VerificationRunError.rejected = error {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Codex connection verification returned an unexpected reply."
                    )
                }
                if let failure = error as? Failure { throw failure }
                throw Failure.response(
                    .authenticationFailed,
                    "Codex connection verification failed."
                )
            }

        case .grok:
            guard grokLogin == nil, grokLoginFinalization == nil else {
                throw Failure.response(
                    .loginAlreadyInProgress,
                    "An OAuth login is already in progress."
                )
            }

            grokConnectionVerified = false
            clearStoredVerification(for: .grok)
            grokGeneration &+= 1
            let verificationGeneration = grokGeneration

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.performGrokVerification(
                            generation: verificationGeneration
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        try Task.checkCancellation()
                        throw VerificationRunError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard try await group.next() != nil else {
                        throw CancellationError()
                    }
                }

                try Task.checkCancellation()
                guard !isInvalidated,
                      grokGeneration == verificationGeneration else {
                    throw CancellationError()
                }
                grokCredentialState = .signedIn
                grokConnectionVerified = persistStoredVerification(for: .grok)
                guard grokConnectionVerified else {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Grok verification proof could not be stored safely."
                    )
                }
                return connectedStatus(provider: .grok)
            } catch {
                grokConnectionVerified = false
                await discardGrokRuntime()
                if case VerificationRunError.timedOut = error {
                    throw Failure.response(
                        .authenticationFailed,
                        "Grok connection verification timed out."
                    )
                }
                if case let VerificationRunError.rejected(diagnostic) = error {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Grok verification rejected [\(diagnostic)]."
                    )
                }
                if case GrokACPError.cachedTokenUnavailable = error {
                    grokCredentialState = .signedOut
                }
                if case GrokACPError.disallowedUpdate = error {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Grok reported unsafe hooks, tools, or session capabilities."
                    )
                }
                if let failure = error as? Failure {
                    throw failure
                }
                throw Failure.response(
                    .authenticationFailed,
                    "Grok connection verification failed."
                )
            }
        }
    }

    private func generateText(
        provider: OAuthBridgeProvider,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        guard OAuthBridgeGenerationPolicy.requestIsValid(
            provider: provider,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        ) else {
            throw Failure.response(
                .invalidArguments,
                "AI generation request arguments are invalid."
            )
        }
        let prompt = OAuthBridgeGenerationPolicy.makePrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )

        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.performTextGeneration(
                        provider: provider,
                        model: model,
                        prompt: prompt
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 75_000_000_000)
                    try Task.checkCancellation()
                    throw GenerationRunError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
            switch provider {
            case .codex:
                codexCredentialState = .signedIn
                codexConnectionVerified = persistStoredVerification(for: .codex)
                guard codexConnectionVerified else {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Codex verification proof could not be stored safely."
                    )
                }
            case .grok:
                grokCredentialState = .signedIn
                grokConnectionVerified = persistStoredVerification(for: .grok)
                guard grokConnectionVerified else {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "Grok verification proof could not be stored safely."
                    )
                }
            }
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch GenerationRunError.timedOut {
            throw Failure.response(
                .generationFailed,
                "AI generation timed out."
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.response(
                .generationFailed,
                "AI generation failed."
            )
        }
    }

    private func performTextGeneration(
        provider: OAuthBridgeProvider,
        model: String,
        prompt: String
    ) async throws -> String {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        switch provider {
        case .codex:
            return try await performCodexGeneration(model: model, prompt: prompt)
        case .grok:
            return try await performGrokGeneration(model: model, prompt: prompt)
        }
    }

    private func performCodexGeneration(
        model: String,
        prompt: String,
        fallbackToFirstListedModel: Bool = false
    ) async throws -> String {
        guard codexLogin == nil else {
            throw Failure.response(
                .loginAlreadyInProgress,
                "An OAuth login is already in progress."
            )
        }
        guard managedCodexProbe().status == .available else {
            throw Failure.response(
                .cliUnavailable,
                "XunJian's bundled Codex App Server is unavailable."
            )
        }
        let executable = try bundledCodexExecutable()

        let runtime = try await ensureCodexRuntime(executableURL: executable)
        let generationResult: Result<String, Error>
        do {
            switch try await runtime.client.readAccount() {
            case .signedOut:
                codexCredentialState = .signedOut
                throw Failure.response(
                    .authenticationFailed,
                    "ChatGPT authentication is required."
                )
            case let .signedIn(type, _, _):
                guard type.lowercased() == "chatgpt" else {
                    codexCredentialState = .signedOut
                    throw Failure.response(
                        .authenticationFailed,
                        "ChatGPT authentication is required."
                    )
                }
            }
            codexCredentialState = .signedIn
            let generationModel: String
            if fallbackToFirstListedModel {
                // Connection verification depends on the pinned model being
                // advertised by the server. When the pinned model is missing
                // from the live catalog but the catalog is non-empty, fall
                // back to the first listed model so verification does not
                // silently fail. An empty catalog keeps the previous behavior:
                // the pinned model attempt fails closed.
                let listedModels = try await runtime.client.listModels()
                if listedModels.contains(where: { $0.id == model }) {
                    generationModel = model
                } else {
                    generationModel = listedModels.first?.id ?? model
                }
            } else {
                generationModel = model
            }
            generationResult = .success(
                try await runtime.client.generateText(
                    model: generationModel,
                    prompt: prompt
                )
            )
        } catch {
            generationResult = .failure(error)
        }

        let cleanupSucceeded: Bool
        if codexRuntime?.client === runtime.client {
            codexRuntime = nil
            cleanupSucceeded = await close(runtime)
        } else {
            // Connection invalidation already took ownership of teardown.
            cleanupSucceeded = false
        }
        switch generationResult {
        case let .failure(error):
            throw error
        case let .success(text):
            try Task.checkCancellation()
            guard cleanupSucceeded,
                  !isInvalidated,
                  OAuthBridgeGenerationPolicy.outputIsValid(text) else {
                throw Failure.response(
                    .generationFailed,
                    "Codex generation runtime cleanup failed."
                )
            }
            return text
        }
    }

    private func performGrokGeneration(
        model: String,
        prompt: String
    ) async throws -> String {
        guard model == GrokACPClient.fixedModelID else {
            throw Failure.response(
                .invalidArguments,
                "The selected Grok model is unsupported."
            )
        }
        guard grokLogin == nil, grokLoginFinalization == nil else {
            throw Failure.response(
                .loginAlreadyInProgress,
                "An OAuth login is already in progress."
            )
        }

        let runtime: GrokRuntime
        if let existingRuntime = grokRuntime {
            runtime = existingRuntime
        } else {
            runtime = try await makeGrokRuntime()
            grokRuntime = runtime
        }

        let generationResult: Result<String, Error>
        var generationDiagnostic: GrokVerificationDiagnostic?
        do {
            generationResult = .success(
                try await runtime.client.generateText(prompt: prompt)
            )
            grokCredentialState = .signedIn
        } catch {
            generationDiagnostic = await runtime.client.takeVerificationDiagnostic()
            generationResult = .failure(error)
        }

        let cleanupSucceeded: Bool
        if grokRuntime?.client === runtime.client {
            grokRuntime = nil
            cleanupSucceeded = await close(runtime)
        } else {
            // Connection invalidation already took ownership of teardown.
            cleanupSucceeded = false
        }
        switch generationResult {
        case let .failure(error):
            if let generationDiagnostic {
                throw Failure.response(
                    .generationFailed,
                    "Grok generation rejected [\(generationDiagnostic.rawValue)]."
                )
            }
            throw error
        case let .success(text):
            try Task.checkCancellation()
            guard cleanupSucceeded,
                  !isInvalidated,
                  OAuthBridgeGenerationPolicy.outputIsValid(text) else {
                throw Failure.response(
                    .generationFailed,
                    "Grok generation runtime cleanup failed."
                )
            }
            return text
        }
    }

    private func performGrokVerification(generation: UInt64) async throws {
        try Task.checkCancellation()
        guard !isInvalidated,
              grokGeneration == generation,
              grokLogin == nil,
              grokLoginFinalization == nil else {
            throw CancellationError()
        }

        let runtime: GrokRuntime
        if let existingRuntime = grokRuntime {
            guard try bundledGrokExecutable().standardizedFileURL
                    == existingRuntime.executableURL.standardizedFileURL else {
                grokConnectionVerified = false
                await discardGrokRuntime()
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Grok Runtime is unavailable."
                )
            }
            guard try prepareGrokCLIHome() == existingRuntime.cliHome else {
                grokConnectionVerified = false
                await discardGrokRuntime()
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login storage is unavailable or unsafe."
                )
            }
            guard await existingRuntime.process.processIdentifier != nil else {
                grokConnectionVerified = false
                await discardGrokRuntime()
                throw Failure.response(
                    .authenticationFailed,
                    "Grok authentication runtime is unavailable."
                )
            }
            runtime = existingRuntime
        } else {
            runtime = try await makeGrokRuntime()
            guard !isInvalidated,
                  grokGeneration == generation,
                  !Task.isCancelled else {
                await close(runtime)
                throw CancellationError()
            }
            grokRuntime = runtime
        }

        var verificationError: Error?
        var verificationDiagnostic: GrokVerificationDiagnostic?
        do {
            try Task.checkCancellation()
            try await runtime.client.verifyMinimalConnection()
            try Task.checkCancellation()
        } catch {
            verificationError = error
            verificationDiagnostic = await runtime.client.takeVerificationDiagnostic()
        }

        if grokRuntime?.client === runtime.client {
            grokRuntime = nil
        }
        let cleanupSucceeded = await closeAfterVerification(runtime)

        if let verificationDiagnostic {
            throw VerificationRunError.rejected(verificationDiagnostic.rawValue)
        }
        if let verificationError {
            throw verificationError
        }
        try Task.checkCancellation()
        guard cleanupSucceeded,
              !isInvalidated,
              grokGeneration == generation else {
            throw Failure.response(
                .authenticationFailed,
                "Grok verification runtime cleanup failed."
            )
        }
    }

    private func disconnect(_ provider: OAuthBridgeProvider) async -> OAuthBridgeAuthStatus {
        clearStoredVerification(for: provider)
        switch provider {
        case .codex:
            codexConnectionVerified = false
            codexVerificationRestored = true
            if let login = codexLogin, let runtime = codexRuntime {
                try? await runtime.client.cancelLogin(loginID: login.internalLoginID)
            }
            codexLogin = nil
            codexAuthTask?.cancel()
            codexAuthTask = nil
            await discardCodexRuntime()

        case .grok:
            grokGeneration &+= 1
            grokConnectionVerified = false
            grokVerificationRestored = true
            if let login = grokLogin {
                grokLogin = nil
                grokLoginTask?.cancel()
                grokLoginTask = nil
                await login.process.close()
                Self.removeTemporaryRoot(login.temporaryRootURL)
                login.leaseOwnership.releaseLogin()
            }
            await discardGrokRuntime()
        }
        return disconnectedStatus(
            provider: provider,
            credential: provider == .codex
                ? codexCredentialState
                : grokCredentialState
        )
    }

    private func logout(_ provider: OAuthBridgeProvider) async throws -> OAuthBridgeAuthStatus {
        clearStoredVerification(for: provider)
        _ = await disconnect(provider)
        switch provider {
        case .codex:
            let executable = try bundledCodexExecutable()
            let runtime = try await ensureCodexRuntime(executableURL: executable)
            do {
                try await runtime.client.logout()
                guard case .signedOut = try await runtime.client.readAccount() else {
                    throw Failure.response(
                        .authenticationFailed,
                        "Codex logout did not clear XunJian's private login."
                    )
                }
            } catch {
                await discardCodexRuntime()
                throw error
            }
            await discardCodexRuntime()
            codexCredentialState = .signedOut
            codexConnectionVerified = false

        case .grok:
            let executable = try bundledGrokExecutable()
            let cliHome = try prepareGrokCLIHome()
            let lease = try acquireGrokCLIHomeLease(cliHome)
            defer { lease.release() }
            try cliHome.hardenForIsolatedRuntime()
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }

            let root = Self.makeTemporaryRootURL()
            do {
                let configuration = try OAuthCLIProcessSecurity.makeGrokLogoutConfiguration(
                    executableURL: executable,
                    grokHomeDirectoryURL: cliHome.rootURL,
                    temporaryRootURL: root
                )
                guard try bundledGrokExecutable().standardizedFileURL
                        == executable.standardizedFileURL else {
                    throw Failure.response(
                        .cliUnavailable,
                        "XunJian's bundled Grok Runtime is unavailable."
                    )
                }
                let process = try SupervisedLineProcess(configuration: configuration)
                try await process.start()
                try await waitForGrokLogout(process)
                await process.close()
            } catch {
                Self.removeTemporaryRoot(root)
                throw error
            }
            Self.removeTemporaryRoot(root)
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            let credentialURL = cliHome.rootURL.appending(path: "auth.json")
            var credentialInformation = stat()
            guard Darwin.lstat(credentialURL.path, &credentialInformation) != 0,
                  errno == ENOENT else {
                throw Failure.response(
                    .authenticationFailed,
                    "Grok logout did not clear XunJian's private login."
                )
            }
            grokCredentialState = .signedOut
            grokConnectionVerified = false
        }
        return disconnectedStatus(provider: provider, credential: .signedOut)
    }

    private func waitForGrokLogout(_ process: SupervisedLineProcess) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var outputBytes = 0
                    while let line = try await process.readLine() {
                        guard line.count <= 16_384 - outputBytes else {
                            throw VerificationRunError.rejected("output_too_large")
                        }
                        outputBytes += line.count
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    try Task.checkCancellation()
                    throw VerificationRunError.timedOut
                }
                defer { group.cancelAll() }
                guard try await group.next() != nil else { throw CancellationError() }
            }
        } catch {
            await process.close()
            throw Failure.response(
                .authenticationFailed,
                "Grok logout failed."
            )
        }
    }

    private func startCodexAuthConsumer(client: CodexAppServerClient) {
        codexAuthTask?.cancel()
        codexAuthTask = Task { [weak self, client] in
            while !Task.isCancelled {
                do {
                    let event = try await client.nextAuthEvent()
                    if await self?.consumeCodexAuthEvent(event, client: client) == true {
                        return
                    }
                } catch {
                    await self?.codexAuthConsumerFailed(client: client)
                    return
                }
            }
        }
    }

    private func consumeCodexAuthEvent(
        _ event: CodexAuthEvent,
        client: CodexAppServerClient
    ) async -> Bool {
        guard codexRuntime?.client === client, let login = codexLogin else {
            return true
        }
        switch event {
        case let .loginCompleted(loginID, success):
            guard login.internalLoginID == loginID else { return true }

            if success {
                do {
                    switch try await client.readAccount() {
                    case .signedOut:
                        codexCredentialState = .signedOut
                    case let .signedIn(type, _, _):
                        codexCredentialState = type.lowercased() == "chatgpt"
                            ? .signedIn
                            : .signedOut
                    }
                } catch {
                    codexCredentialState = .unknown
                }
            } else {
                codexCredentialState = .signedOut
            }

            codexLogin = nil
            codexAuthTask = nil
            if let runtime = codexRuntime, runtime.client === client {
                codexRuntime = nil
                await close(runtime)
            }
            return true

        case .accountUpdated:
            // This notification has no login identifier. It can be stale or belong
            // to another account change, so it never completes the owned attempt.
            codexLogin = login
            return false
        }
    }

    private func codexAuthConsumerFailed(client: CodexAppServerClient) async {
        guard let runtime = codexRuntime, runtime.client === client else { return }
        codexLogin = nil
        codexAuthTask = nil
        codexRuntime = nil
        codexCredentialState = .unknown
        await close(runtime)
    }

    private func startGrokLoginConsumer(_ login: GrokLoginState) {
        grokLoginTask?.cancel()
        grokLoginTask = Task { [weak self] in
            var succeeded = true
            do {
                while try await login.process.readLine() != nil {}
            } catch {
                succeeded = false
            }
            await self?.finishGrokLogin(login, succeeded: succeeded)
        }
    }

    private func finishGrokLogin(
        _ completed: GrokLoginState,
        succeeded: Bool
    ) async {
        guard let current = grokLogin,
              current.attemptID == completed.attemptID,
              current.generation == completed.generation,
              current.process === completed.process else {
            await completed.process.close()
            Self.removeTemporaryRoot(completed.temporaryRootURL)
            completed.leaseOwnership.releaseLogin()
            return
        }
        await completed.process.close()
        Self.removeTemporaryRoot(completed.temporaryRootURL)
        guard succeeded,
              !isInvalidated,
              !Task.isCancelled,
              grokGeneration == completed.generation,
              let currentAfterClose = grokLogin,
              currentAfterClose.attemptID == completed.attemptID,
              currentAfterClose.generation == completed.generation,
              currentAfterClose.process === completed.process else {
            if let currentAfterClose = grokLogin,
               currentAfterClose.attemptID == completed.attemptID,
               currentAfterClose.generation == completed.generation,
               currentAfterClose.process === completed.process {
                grokLogin = nil
                grokLoginTask = nil
            }
            completed.leaseOwnership.releaseLogin()
            return
        }

        let generation = completed.generation
        let finalization = GrokLoginFinalization(
            attemptID: completed.attemptID,
            generation: completed.generation
        )
        guard completed.leaseOwnership.beginFinalization() else {
            grokLogin = nil
            grokLoginTask = nil
            return
        }
        grokLoginFinalization = finalization
        do {
            let runtime = try await makeGrokRuntime(
                cliHome: completed.cliHome,
                leaseOwnership: completed.leaseOwnership
            )
            guard !isInvalidated,
                  grokGeneration == generation,
                  grokLogin?.attemptID == completed.attemptID,
                  grokLoginFinalization == finalization else {
                await close(runtime)
                if grokLoginFinalization == finalization {
                    grokLoginFinalization = nil
                }
                if grokLogin?.attemptID == completed.attemptID {
                    grokLogin = nil
                }
                grokLoginTask = nil
                return
            }
            grokRuntime = runtime
            grokCredentialState = .signedIn
            grokLoginFinalization = nil
            grokLogin = nil
            grokLoginTask = nil
        } catch {
            if case GrokACPError.cachedTokenUnavailable = error {
                grokCredentialState = .signedOut
            } else {
                grokCredentialState = .unknown
            }
            if grokLoginFinalization == finalization {
                grokLoginFinalization = nil
            }
            if grokLogin?.attemptID == completed.attemptID {
                grokLogin = nil
            }
            grokLoginTask = nil
        }
    }

    private func managedCodexProbe() -> OAuthCLIProbe {
        guard let architecture = ManagedRuntimeArchitecture.current else {
            return OAuthCLIProbe(provider: .codex, status: .incompatible, version: nil)
        }
        do {
            _ = try bundledCodexRuntime.executableURL(for: architecture)
            return OAuthCLIProbe(
                provider: .codex,
                status: .available,
                version: "codex-app-server \(BundledCodexRuntimeResolver.version)"
            )
        } catch BundledCodexRuntimeError.missingResource {
            return OAuthCLIProbe(provider: .codex, status: .missing, version: nil)
        } catch {
            return OAuthCLIProbe(
                provider: .codex,
                status: .untrusted,
                version: BundledCodexRuntimeResolver.version
            )
        }
    }

    private func bundledCodexExecutable() throws -> URL {
        guard let architecture = ManagedRuntimeArchitecture.current else {
            throw Failure.response(
                .cliUnavailable,
                "This Mac does not support XunJian's bundled Codex App Server."
            )
        }
        do {
            return try bundledCodexRuntime.executableURL(for: architecture)
        } catch {
            throw Failure.response(
                .cliUnavailable,
                "XunJian's bundled Codex App Server is missing, damaged, or untrusted."
            )
        }
    }

    private func managedGrokProbe() -> OAuthCLIProbe {
        guard let architecture = ManagedRuntimeArchitecture.current else {
            return OAuthCLIProbe(provider: .grok, status: .incompatible, version: nil)
        }
        do {
            _ = try bundledGrokRuntime.executableURL(for: architecture)
            return OAuthCLIProbe(
                provider: .grok,
                status: .available,
                version: "grok \(BundledGrokRuntimeResolver.version)"
            )
        } catch BundledGrokRuntimeError.missingResource {
            return OAuthCLIProbe(provider: .grok, status: .missing, version: nil)
        } catch {
            return OAuthCLIProbe(
                provider: .grok,
                status: .untrusted,
                version: BundledGrokRuntimeResolver.version
            )
        }
    }

    private func bundledGrokExecutable() throws -> URL {
        guard let architecture = ManagedRuntimeArchitecture.current else {
            throw Failure.response(
                .cliUnavailable,
                "This Mac does not support XunJian's bundled Grok Runtime."
            )
        }
        do {
            return try bundledGrokRuntime.executableURL(for: architecture)
        } catch {
            throw Failure.response(
                .cliUnavailable,
                "XunJian's bundled Grok Runtime is missing, damaged, or untrusted."
            )
        }
    }

    private func ensureCodexRuntime(executableURL executable: URL) async throws -> CodexRuntime {
        if let codexRuntime {
            guard codexRuntime.executableURL.standardizedFileURL
                    == executable.standardizedFileURL else {
                await discardCodexRuntime()
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Codex App Server changed unexpectedly."
                )
            }
            return codexRuntime
        }
        let codexHome: CodexAppServerHome
        let homeLease: GrokCLIHomeLease
        do {
            codexHome = try CodexAppServerHome.prepare(
                userHomeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            homeLease = try codexHome.acquireLease()
        } catch CodexAppServerHomeError.busy {
            throw Failure.response(
                .loginAlreadyInProgress,
                "XunJian's private Codex login is already in use."
            )
        } catch {
            throw Failure.response(
                .authenticationFailed,
                "XunJian's private Codex login storage is unavailable or unsafe."
            )
        }
        let root = Self.makeTemporaryRootURL()
        do {
            let configuration = try OAuthCLIProcessSecurity.makeConfiguration(
                provider: .codex,
                executableURL: executable,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                codexHomeDirectoryURL: codexHome.rootURL,
                temporaryRootURL: root
            )
            guard try bundledCodexExecutable().standardizedFileURL
                    == executable.standardizedFileURL else {
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Codex App Server changed unexpectedly."
                )
            }
            let process = try SupervisedLineProcess(configuration: configuration)
            do {
                try await process.start()
                let peer = JSONLineRPCPeer(
                    transport: process,
                    dialect: .codex,
                    allowedNotifications: CodexAppServerClient.allowedNotifications
                )
                let client = CodexAppServerClient(
                    peer: peer,
                    workingDirectoryURL: configuration.currentDirectoryURL,
                    restrictedReadSupport: .supported
                )
                try await client.initialize()
                let runtime = CodexRuntime(
                    process: process,
                    client: client,
                    executableURL: executable,
                    homeLease: homeLease,
                    temporaryRootURL: root
                )
                guard !isInvalidated else {
                    await close(runtime)
                    throw Failure.response(.authenticationFailed, "OAuth bridge was closed.")
                }
                codexRuntime = runtime
                return runtime
            } catch {
                await process.close()
                throw error
            }
        } catch {
            Self.removeTemporaryRoot(root)
            homeLease.release()
            throw error
        }
    }

    private func makeGrokRuntime(
        cliHome suppliedCLIHome: GrokCLIHome? = nil,
        leaseOwnership suppliedOwnership: GrokCLIHomeLeaseOwnership? = nil
    ) async throws -> GrokRuntime {
        guard (suppliedCLIHome == nil) == (suppliedOwnership == nil) else {
            suppliedOwnership?.releaseBuilderOrFinalizer()
            throw Failure.response(
                .safeVerificationUnavailable,
                "XunJian's private Grok login storage is unavailable or unsafe."
            )
        }
        let root = Self.makeTemporaryRootURL()
        var process: SupervisedLineProcess?
        var leaseOwnership = suppliedOwnership
        do {
            try Task.checkCancellation()
            let executable = try bundledGrokExecutable()
            let cliHome = try prepareGrokCLIHome()
            guard suppliedCLIHome == nil || suppliedCLIHome == cliHome else {
                throw Failure.response(
                    .authenticationFailed,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            if let suppliedOwnership {
                guard suppliedOwnership.isFinalizing() else {
                    throw Failure.response(
                        .safeVerificationUnavailable,
                        "XunJian's private Grok login storage is unavailable or unsafe."
                    )
                }
            } else {
                leaseOwnership = GrokCLIHomeLeaseOwnership(
                    lease: try acquireGrokCLIHomeLease(cliHome),
                    initialOwner: .runtimeBuilder
                )
            }
            guard let leaseOwnership else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login storage is unavailable or unsafe."
                )
            }
            do {
                try cliHome.hardenForIsolatedRuntime()
            } catch {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login storage is unavailable or unsafe."
                )
            }
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            let configuration = try OAuthCLIProcessSecurity.makeConfiguration(
                provider: .grok,
                executableURL: executable,
                homeDirectoryURL: cliHome.rootURL,
                grokHomeDirectoryURL: cliHome.rootURL,
                temporaryRootURL: root
            )
            guard try bundledGrokExecutable().standardizedFileURL
                    == executable.standardizedFileURL else {
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Grok Runtime is unavailable."
                )
            }
            guard let processHomePath = configuration.environment["HOME"] else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "Grok's isolated runtime safety inspection failed."
                )
            }
            try await performGrokSafetyInspection(
                executableURL: executable,
                cliHome: cliHome,
                processHomeDirectoryURL: URL(
                    fileURLWithPath: processHomePath,
                    isDirectory: true
                )
            )
            try Task.checkCancellation()
            guard !isInvalidated else {
                throw Failure.response(.authenticationFailed, "OAuth bridge was closed.")
            }
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            guard try bundledGrokExecutable().standardizedFileURL
                    == executable.standardizedFileURL else {
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Grok Runtime is unavailable."
                )
            }
            let launchedProcess = try SupervisedLineProcess(configuration: configuration)
            process = launchedProcess
            try await launchedProcess.start()
            let peer = JSONLineRPCPeer(
                transport: launchedProcess,
                dialect: .jsonRPC2,
                allowedNotifications: GrokACPClient.allowedNotifications
            )
            let client = GrokACPClient(
                peer: peer,
                workingDirectoryURL: configuration.currentDirectoryURL
            )
            try await client.initialize()
            try await client.authenticateCachedToken()
            guard leaseOwnership.transferToRuntime() else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login storage is unavailable or unsafe."
                )
            }
            let runtime = GrokRuntime(
                process: launchedProcess,
                client: client,
                executableURL: executable.standardizedFileURL,
                cliHome: cliHome,
                leaseOwnership: leaseOwnership,
                temporaryRootURL: root
            )
            guard !isInvalidated else {
                await close(runtime)
                throw Failure.response(.authenticationFailed, "OAuth bridge was closed.")
            }
            return runtime
        } catch {
            if let process {
                await process.close()
            }
            Self.removeTemporaryRoot(root)
            leaseOwnership?.releaseBuilderOrFinalizer()
            throw error
        }
    }

    private func performGrokSafetyInspection(
        executableURL: URL,
        cliHome: GrokCLIHome,
        processHomeDirectoryURL: URL
    ) async throws {
        let root = Self.makeTemporaryRootURL()
        var process: SupervisedLineProcess?
        var inspectionSucceeded = false

        do {
            let configuration = try OAuthCLIProcessSecurity
                .makeGrokInspectionConfiguration(
                    executableURL: executableURL,
                    grokHomeDirectoryURL: cliHome.rootURL,
                    processHomeDirectoryURL: processHomeDirectoryURL,
                    temporaryRootURL: root
                )
            guard configuration.environment["HOME"]
                    == processHomeDirectoryURL.standardizedFileURL.path,
                  configuration.environment["GROK_HOME"]
                    == cliHome.rootURL.standardizedFileURL.path else {
                throw GrokSafetyInspectionError.invalidOutput
            }
            let inspectionProcess = try SupervisedLineProcess(configuration: configuration)
            process = inspectionProcess
            try await inspectionProcess.start()
            let output = try await Self.readGrokSafetyInspectionOutput(inspectionProcess)
            guard GrokSafetyInspectionPolicy.isSafe(
                output,
                expectedWorkingDirectoryURL: configuration.currentDirectoryURL,
                expectedGrokHomeDirectoryURL: cliHome.rootURL
            ) else {
                throw GrokSafetyInspectionError.invalidOutput
            }
            inspectionSucceeded = true
        } catch {
            inspectionSucceeded = false
        }

        if let process {
            await process.close()
        }
        let processClosed = if let process {
            await process.processIdentifier == nil
        } else {
            true
        }
        let rootRemoved = Self.removeTemporaryRoot(root)
        guard inspectionSucceeded, processClosed, rootRemoved else {
            throw Failure.response(
                .safeVerificationUnavailable,
                "Grok's isolated runtime safety inspection failed."
            )
        }
    }

    private static func readGrokSafetyInspectionOutput(
        _ process: SupervisedLineProcess
    ) async throws -> Data {
        let timeoutNanoseconds: UInt64 = 6_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: GrokSafetyInspectionRaceResult.self
            ) { group in
                group.addTask {
                    var output = Data()
                    var lineCount = 0
                    let maximumOutputBytes = 262_144
                    let maximumLineCount = 2_048
                    while let line = try await process.readLine() {
                        let separatorBytes = output.isEmpty ? 0 : 1
                        guard lineCount < maximumLineCount,
                              output.count <= maximumOutputBytes - separatorBytes,
                              line.count <= maximumOutputBytes
                                - output.count
                                - separatorBytes else {
                            throw GrokSafetyInspectionError.outputTooLarge
                        }
                        if separatorBytes == 1 {
                            output.append(0x0A)
                        }
                        output.append(line)
                        lineCount += 1
                    }
                    return .output(
                        output,
                        finishedAt: DispatchTime.now().uptimeNanoseconds
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    try Task.checkCancellation()
                    await process.close()
                    return .timedOut
                }
                defer { group.cancelAll() }

                guard let first = try await group.next() else {
                    throw GrokSafetyInspectionError.timedOut
                }
                switch first {
                case let .output(output, finishedAt) where finishedAt < deadline:
                    return output
                case .output, .timedOut:
                    throw GrokSafetyInspectionError.timedOut
                }
            }
        } onCancel: {
            Task { await process.close() }
        }
    }

    private func makeGrokLogin(
        executableURL: URL,
        attemptID: UUID,
        generation: UInt64
    ) async throws -> GrokLoginState {
        let cliHome = try prepareGrokCLIHome()
        let cliHomeLease = try acquireGrokCLIHomeLease(cliHome)
        let leaseOwnership = GrokCLIHomeLeaseOwnership(
            lease: cliHomeLease,
            initialOwner: .login
        )
        let root = Self.makeTemporaryRootURL()
        do {
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            do {
                try cliHome.hardenForIsolatedRuntime()
            } catch {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login storage is unavailable or unsafe."
                )
            }
            guard try prepareGrokCLIHome() == cliHome else {
                throw Failure.response(
                    .safeVerificationUnavailable,
                    "XunJian's private Grok login directory changed unexpectedly."
                )
            }
            let configuration = try OAuthCLIProcessSecurity.makeGrokLoginConfiguration(
                executableURL: executableURL,
                grokHomeDirectoryURL: cliHome.rootURL,
                temporaryRootURL: root
            )
            guard try bundledGrokExecutable().standardizedFileURL
                    == executableURL.standardizedFileURL else {
                throw Failure.response(
                    .cliUnavailable,
                    "XunJian's bundled Grok Runtime is unavailable."
                )
            }
            let process = try SupervisedLineProcess(configuration: configuration)
            try await process.start()
            return GrokLoginState(
                attemptID: attemptID,
                process: process,
                cliHome: cliHome,
                leaseOwnership: leaseOwnership,
                temporaryRootURL: root,
                generation: generation
            )
        } catch {
            Self.removeTemporaryRoot(root)
            leaseOwnership.releaseLogin()
            throw error
        }
    }

    private func prepareGrokCLIHome() throws -> GrokCLIHome {
        do {
            return try GrokCLIHome.prepare(
                userHomeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            throw Failure.response(
                .safeVerificationUnavailable,
                "XunJian's private Grok login storage is unavailable or unsafe."
            )
        }
    }

    private func acquireGrokCLIHomeLease(
        _ cliHome: GrokCLIHome
    ) throws -> GrokCLIHomeLease {
        do {
            return try cliHome.acquireLease()
        } catch GrokCLIHomeError.busy {
            throw Failure.response(
                .loginAlreadyInProgress,
                "XunJian's private Grok login is already in use."
            )
        } catch {
            throw Failure.response(
                .safeVerificationUnavailable,
                "XunJian's private Grok login storage is unavailable or unsafe."
            )
        }
    }

    private func restoreStoredVerification(
        for provider: OAuthBridgeProvider
    ) -> Bool {
        guard let inputs = verificationProofInputs(for: provider) else {
            clearStoredVerification(for: provider)
            return false
        }
        return OAuthVerificationProofStore.restore(
            provider: provider,
            runtimeVersion: inputs.runtimeVersion,
            runtimeURL: inputs.runtimeURL,
            credentialURL: inputs.credentialURL
        )
    }

    private func persistStoredVerification(
        for provider: OAuthBridgeProvider
    ) -> Bool {
        guard let inputs = verificationProofInputs(for: provider) else {
            clearStoredVerification(for: provider)
            return false
        }
        // Reuse the stored proof when it is still valid instead of hashing the
        // runtime and rewriting the proof on every generation call. The proof
        // is only recomputed and persisted when restoration fails (missing or
        // stale). No state is cached across calls: this restore-first check
        // re-validates the current runtime and credential on every call.
        if OAuthVerificationProofStore.restore(
            provider: provider,
            runtimeVersion: inputs.runtimeVersion,
            runtimeURL: inputs.runtimeURL,
            credentialURL: inputs.credentialURL
        ) {
            return true
        }
        return OAuthVerificationProofStore.persist(
            provider: provider,
            runtimeVersion: inputs.runtimeVersion,
            runtimeURL: inputs.runtimeURL,
            credentialURL: inputs.credentialURL
        )
    }

    private func clearStoredVerification(for provider: OAuthBridgeProvider) {
        if let credentialURL = verificationCredentialURL(for: provider) {
            OAuthVerificationProofStore.clear(for: credentialURL)
        }
        switch provider {
        case .codex:
            codexVerificationRestored = true
        case .grok:
            grokVerificationRestored = true
        }
    }

    private func verificationProofInputs(
        for provider: OAuthBridgeProvider
    ) -> (runtimeVersion: String, runtimeURL: URL, credentialURL: URL)? {
        guard let runtimeURL = try? {
            switch provider {
            case .codex: try bundledCodexExecutable()
            case .grok: try bundledGrokExecutable()
            }
        }() else {
            return nil
        }
        let runtimeVersion = switch provider {
        case .codex: BundledCodexRuntimeResolver.version
        case .grok: BundledGrokRuntimeResolver.version
        }
        guard let credentialURL = verificationCredentialURL(for: provider) else {
            return nil
        }
        return (runtimeVersion, runtimeURL, credentialURL)
    }

    private func verificationCredentialURL(
        for provider: OAuthBridgeProvider
    ) -> URL? {
        switch provider {
        case .codex:
            guard let home = try? CodexAppServerHome.prepare(
                userHomeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            ) else { return nil }
            return home.rootURL.appending(path: "auth.json")
        case .grok:
            guard let home = try? GrokCLIHome.prepare(
                userHomeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            ) else { return nil }
            return home.rootURL.appending(path: "auth.json")
        }
    }

    private func discardCodexRuntime() async {
        guard let runtime = codexRuntime else { return }
        codexRuntime = nil
        await close(runtime)
    }

    private func discardGrokRuntime() async {
        grokConnectionVerified = false
        guard let runtime = grokRuntime else { return }
        grokRuntime = nil
        await close(runtime)
    }

    @discardableResult
    private func close(_ runtime: CodexRuntime) async -> Bool {
        defer { runtime.homeLease.release() }
        await runtime.client.close()
        await runtime.process.close()
        let processClosed = await runtime.process.processIdentifier == nil
        let rootRemoved = processClosed
            ? Self.removeTemporaryRoot(runtime.temporaryRootURL)
            : false
        return processClosed && rootRemoved
    }

    @discardableResult
    private func close(_ runtime: GrokRuntime) async -> Bool {
        defer { runtime.leaseOwnership.releaseRuntime() }
        await runtime.client.close()
        let sessionHistoryIDs = await runtime.client.takeSessionHistoryIDs()
        await runtime.process.close()
        let processClosed = await runtime.process.processIdentifier == nil
        let rootRemoved = processClosed
            ? Self.removeTemporaryRoot(runtime.temporaryRootURL)
            : false
        let historyRemoved = processClosed
            ? await removeGrokSessionHistory(
                sessionHistoryIDs,
                executableURL: runtime.executableURL,
                cliHome: runtime.cliHome
            )
            : false
        return processClosed && rootRemoved && historyRemoved
    }

    private func closeAfterVerification(_ runtime: GrokRuntime) async -> Bool {
        await close(runtime)
    }

    private func removeGrokSessionHistory(
        _ sessionIDs: [String],
        executableURL: URL,
        cliHome: GrokCLIHome
    ) async -> Bool {
        guard !sessionIDs.isEmpty else { return true }

        var uniqueSessionIDs: [String] = []
        var seenSessionIDs = Set<String>()
        for sessionID in sessionIDs where seenSessionIDs.insert(sessionID).inserted {
            uniqueSessionIDs.append(sessionID)
        }
        guard uniqueSessionIDs.count == 1,
              uniqueSessionIDs.allSatisfy(Self.isExactSessionUUID),
              (try? prepareGrokCLIHome()) == cliHome,
              (try? bundledGrokExecutable())?.standardizedFileURL
                == executableURL.standardizedFileURL else {
            return false
        }

        let sessionID = uniqueSessionIDs[0]
        return await Task.detached(priority: .utility) {
            await Self.runGrokSessionHistoryDeletion(
                sessionID: sessionID,
                executableURL: executableURL,
                grokHomeDirectoryURL: cliHome.rootURL
            )
        }.value
    }

    private static func runGrokSessionHistoryDeletion(
        sessionID: String,
        executableURL: URL,
        grokHomeDirectoryURL: URL
    ) async -> Bool {
        guard isExactSessionUUID(sessionID) else { return false }

        let root = makeTemporaryRootURL()
        var process: SupervisedLineProcess?
        var commandSucceeded = false

        do {
            let configuration = try OAuthCLIProcessSecurity
                .makeGrokSessionDeletionConfiguration(
                executableURL: executableURL,
                grokHomeDirectoryURL: grokHomeDirectoryURL,
                sessionID: sessionID,
                temporaryRootURL: root
            )
            let deletionProcess = try SupervisedLineProcess(configuration: configuration)
            process = deletionProcess
            try await deletionProcess.start()
            try await waitForGrokSessionHistoryDeletion(deletionProcess)
            commandSucceeded = true
        } catch {
            commandSucceeded = false
        }

        if let process {
            await process.close()
        }
        let processClosed = if let process {
            await process.processIdentifier == nil
        } else {
            true
        }
        let rootRemoved = removeTemporaryRoot(root)
        return commandSucceeded && processClosed && rootRemoved
    }

    private static func waitForGrokSessionHistoryDeletion(
        _ process: SupervisedLineProcess
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var outputBytes = 0
                var outputLineCount = 0
                let maximumOutputBytes = 65_536
                let maximumOutputLineCount = 1_024
                while let line = try await process.readLine() {
                    guard outputLineCount < maximumOutputLineCount,
                          line.count <= maximumOutputBytes - outputBytes else {
                        throw SessionHistoryDeletionError.outputTooLarge
                    }
                    outputBytes += line.count
                    outputLineCount += 1
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 6_000_000_000)
                try Task.checkCancellation()
                throw SessionHistoryDeletionError.timedOut
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw SessionHistoryDeletionError.timedOut
            }
        }
    }

    private static func isExactSessionUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private func unavailableStatus(
        provider: OAuthBridgeProvider,
        cliStatus: OAuthCLIProbe.Status
    ) -> OAuthBridgeAuthStatus {
        OAuthBridgeAuthStatus(
            provider: provider,
            cliStatus: cliStatus,
            credentialState: .unknown,
            connectionState: .disconnected,
            loginAttemptID: nil
        )
    }

    private func disconnectedStatus(
        provider: OAuthBridgeProvider,
        credential: OAuthCredentialState
    ) -> OAuthBridgeAuthStatus {
        OAuthBridgeAuthStatus(
            provider: provider,
            cliStatus: .available,
            credentialState: credential,
            connectionState: .disconnected,
            loginAttemptID: nil
        )
    }

    private func authenticatedStatus(
        provider: OAuthBridgeProvider
    ) -> OAuthBridgeAuthStatus {
        OAuthBridgeAuthStatus(
            provider: provider,
            cliStatus: .available,
            credentialState: .signedIn,
            connectionState: .authenticated,
            loginAttemptID: nil
        )
    }

    private func connectedStatus(
        provider: OAuthBridgeProvider
    ) -> OAuthBridgeAuthStatus {
        OAuthBridgeAuthStatus(
            provider: provider,
            cliStatus: .available,
            credentialState: .signedIn,
            connectionState: .connected,
            loginAttemptID: nil
        )
    }

    private static func makeTemporaryRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .standardizedFileURL
            .appending(
                path: "xunjian-oauth-runtime-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    @discardableResult
    private static func removeTemporaryRoot(_ url: URL) -> Bool {
        let base = FileManager.default.temporaryDirectory.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.deletingLastPathComponent() == base,
              target.lastPathComponent.hasPrefix("xunjian-oauth-runtime-") else {
            return false
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: target)
        }
        return !fileManager.fileExists(atPath: target.path)
    }
}

private final class OAuthBridgeServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier == geteuid(),
              let requirement = Self.trustedApplicationRequirement() else {
            return false
        }
        let service = OAuthBridgeService()
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: OAuthBridgeXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.interruptionHandler = { [service] in
            service.invalidate()
        }
        newConnection.invalidationHandler = { [service] in
            service.invalidate()
        }
        newConnection.resume()
        return true
    }

    private static func trustedApplicationRequirement() -> String? {
        let applicationURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return OAuthBridgeCodeSigning.trustedApplicationRequirement(
            forHelperAt: Bundle.main.bundleURL,
            debugContainingApplicationURL: applicationURL.pathExtension == "app"
                ? applicationURL
                : nil
        )
    }
}

private let delegate = OAuthBridgeServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
