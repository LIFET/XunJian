#if XUNJIAN_UNAUTHORIZED_CLIENT
import Darwin
import Foundation

private final class UnauthorizedClientOutcome: @unchecked Sendable {
    enum Value: Sendable {
        case pending
        case rejected
        case executed
    }

    private let lock = NSLock()
    private var value = Value.pending

    nonisolated func resolve(_ newValue: Value) {
        lock.lock()
        if case .pending = value {
            value = newValue
        }
        lock.unlock()
    }

    nonisolated func snapshot() -> Value {
        lock.lock()
        let currentValue = value
        lock.unlock()
        return currentValue
    }
}

@main
private enum UnauthorizedClientMain {
    nonisolated static func main() {
        let connection = NSXPCConnection(serviceName: OAuthBridgeConstants.serviceName)
        let outcome = UnauthorizedClientOutcome()
        let completion = DispatchSemaphore(value: 0)
        connection.remoteObjectInterface = NSXPCInterface(with: OAuthBridgeXPCProtocol.self)
        connection.invalidationHandler = { @Sendable in
            outcome.resolve(.rejected)
            completion.signal()
        }
        connection.activate()

        let request = OAuthBridgeRequest(operation: .capabilities)
        guard let requestData = try? OAuthBridgeCodec.encode(request),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
                outcome.resolve(.rejected)
                completion.signal()
              }) as? OAuthBridgeXPCProtocol else {
            exit(44)
        }
        proxy.handle(requestData) { @Sendable _ in
            outcome.resolve(.executed)
            completion.signal()
        }

        _ = completion.wait(timeout: .now() + 5)
        let result = outcome.snapshot()
        connection.invalidate()
        switch result {
        case .rejected:
            print("rejected")
            exit(0)
        case .executed:
            print("executed")
            exit(42)
        case .pending:
            print("timed-out")
            exit(43)
        }
    }
}
#elseif XUNJIAN_UNTRUSTED_BRIDGE
import Foundation

private final class UntrustedBridgeService: NSObject, OAuthBridgeXPCProtocol {
    func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let request = try? OAuthBridgeCodec.decode(OAuthBridgeRequest.self, from: requestData)
        let response = OAuthBridgeResponse.success(
            requestID: request?.requestID ?? UUID(),
            result: .capabilities(
                OAuthBridgeCapabilities(
                    protocolVersion: OAuthBridgeConstants.protocolVersion,
                    supportedOperations: OAuthBridgeOperation.allCases,
                    supportedProviders: OAuthBridgeProvider.allCases,
                    storesCredentials: false
                )
            )
        )
        reply((try? OAuthBridgeCodec.encode(response)) ?? Data())
    }
}

private final class UntrustedBridgeDelegate: NSObject, NSXPCListenerDelegate {
    private let service = UntrustedBridgeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: OAuthBridgeXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

@main
private enum UntrustedBridgeMain {
    nonisolated static func main() {
        let delegate = UntrustedBridgeDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}
#else
import XCTest
@testable import XunJian

private enum FakeOAuthBridgeError: LocalizedError, Sendable {
    case missingStub
    case forcedFailure

    var errorDescription: String? {
        switch self {
        case .missingStub:
            "Fake OAuth bridge response was not configured."
        case .forcedFailure:
            "Fake OAuth bridge failure."
        }
    }
}

private actor OAuthStatusGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeOAuthBridgeService: OAuthBridgeServicing {
    enum Call: Equatable, Sendable {
        case status(OAuthBridgeProvider)
        case start(OAuthBridgeProvider, OAuthBridgeLoginMethod)
        case cancel(OAuthBridgeProvider, UUID)
        case verify(OAuthBridgeProvider)
        case generate(OAuthBridgeProvider, String, String, String)
        case disconnect(OAuthBridgeProvider)
        case logout(OAuthBridgeProvider)
    }

    private struct StatusPlan: Sendable {
        let result: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError>
        let gate: OAuthStatusGate?
    }

    private var statusPlans: [StatusPlan] = []
    private var loginAttemptResult: Result<OAuthBridgeLoginAttempt, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var loginGate: OAuthStatusGate?
    private var cancelResult: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var verificationResult: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var generationResult: Result<String, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var disconnectResult: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var logoutResult: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError> =
        .failure(.missingStub)
    private var cancelGate: OAuthStatusGate?
    private var verificationGate: OAuthStatusGate?
    private var disconnectGate: OAuthStatusGate?
    private var recordedCalls: [Call] = []

    func enqueueStatus(
        _ result: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError>,
        gate: OAuthStatusGate? = nil
    ) {
        statusPlans.append(StatusPlan(result: result, gate: gate))
    }

    func configureLoginAttempt(
        _ attempt: OAuthBridgeLoginAttempt,
        gate: OAuthStatusGate? = nil
    ) {
        loginAttemptResult = .success(attempt)
        loginGate = gate
    }

    func configureCancelStatus(
        _ status: OAuthBridgeAuthStatus,
        gate: OAuthStatusGate? = nil
    ) {
        cancelResult = .success(status)
        cancelGate = gate
    }

    func configureDisconnectStatus(
        _ status: OAuthBridgeAuthStatus,
        gate: OAuthStatusGate? = nil
    ) {
        disconnectResult = .success(status)
        disconnectGate = gate
    }

    func configureLogoutStatus(_ status: OAuthBridgeAuthStatus) {
        logoutResult = .success(status)
    }

    func configureVerification(
        _ result: Result<OAuthBridgeAuthStatus, FakeOAuthBridgeError>,
        gate: OAuthStatusGate? = nil
    ) {
        verificationResult = result
        verificationGate = gate
    }

    func configureGeneration(_ result: Result<String, FakeOAuthBridgeError>) {
        generationResult = result
    }

    func calls() -> [Call] {
        recordedCalls
    }

    func authenticationStatus(
        for provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        recordedCalls.append(.status(provider))
        guard !statusPlans.isEmpty else { throw FakeOAuthBridgeError.missingStub }
        let plan = statusPlans.removeFirst()
        if let gate = plan.gate {
            await gate.wait()
        }
        return try plan.result.get()
    }

    func startLogin(
        for provider: OAuthBridgeProvider,
        method: OAuthBridgeLoginMethod
    ) async throws -> OAuthBridgeLoginAttempt {
        recordedCalls.append(.start(provider, method))
        if let loginGate {
            await loginGate.wait()
        }
        return try loginAttemptResult.get()
    }

    func cancelLogin(
        for provider: OAuthBridgeProvider,
        attemptID: UUID
    ) async throws -> OAuthBridgeAuthStatus {
        recordedCalls.append(.cancel(provider, attemptID))
        if let cancelGate {
            await cancelGate.wait()
        }
        return try cancelResult.get()
    }

    func verifyConnection(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        recordedCalls.append(.verify(provider))
        if let verificationGate {
            await verificationGate.wait()
        }
        return try verificationResult.get()
    }

    func generateText(
        provider: OAuthBridgeProvider,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        recordedCalls.append(.generate(provider, model, systemPrompt, userPrompt))
        return try generationResult.get()
    }

    func disconnect(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        recordedCalls.append(.disconnect(provider))
        if let disconnectGate {
            await disconnectGate.wait()
        }
        return try disconnectResult.get()
    }

    func logout(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus {
        recordedCalls.append(.logout(provider))
        return try logoutResult.get()
    }
}

final class OAuthBridgeTests: XCTestCase {
    func testProtocolV6GenerationRequestRoundTripPreservesTypedArguments() throws {
        let attemptID = UUID(uuidString: "991E6827-4F90-4980-963C-BF9AA5736571")!
        let cancelRequest = OAuthBridgeRequest(
            operation: .cancelLogin,
            arguments: OAuthBridgeRequestArguments(
                provider: .codex,
                loginAttemptID: attemptID
            ),
            requestID: UUID(uuidString: "18A95869-411A-44E6-8C46-A8096DD44B4F")!
        )
        let verificationRequest = OAuthBridgeRequest(
            operation: .verifyConnection,
            arguments: OAuthBridgeRequestArguments(provider: .grok),
            requestID: UUID(uuidString: "63956A9A-B81C-4DA9-93FA-CBC84287B308")!
        )
        let deviceCodeRequest = OAuthBridgeRequest(
            operation: .startLogin,
            arguments: OAuthBridgeRequestArguments(
                provider: .codex,
                loginAttemptID: attemptID,
                loginMethod: .deviceCode
            ),
            requestID: UUID(uuidString: "95F24283-AFA4-4987-8439-75D16AD7AC68")!
        )
        let generationRequest = OAuthBridgeRequest(
            operation: .generateText,
            arguments: OAuthBridgeRequestArguments(
                provider: .codex,
                model: "gpt-5.6-sol",
                systemPrompt: "Classify safely.",
                userPrompt: "invoice.pdf"
            ),
            requestID: UUID(uuidString: "C6257F3C-8947-4485-8F87-B9B0306A290C")!
        )

        XCTAssertEqual(OAuthBridgeConstants.protocolVersion, 6)
        XCTAssertEqual(
            try OAuthBridgeCodec.decode(
                OAuthBridgeRequest.self,
                from: OAuthBridgeCodec.encode(cancelRequest)
            ),
            cancelRequest
        )
        XCTAssertEqual(cancelRequest.arguments?.provider, .codex)
        XCTAssertEqual(cancelRequest.arguments?.loginAttemptID, attemptID)
        XCTAssertEqual(
            try OAuthBridgeCodec.decode(
                OAuthBridgeRequest.self,
                from: OAuthBridgeCodec.encode(verificationRequest)
            ),
            verificationRequest
        )
        XCTAssertEqual(verificationRequest.arguments?.provider, .grok)
        XCTAssertNil(verificationRequest.arguments?.loginAttemptID)
        XCTAssertEqual(
            try OAuthBridgeCodec.decode(
                OAuthBridgeRequest.self,
                from: OAuthBridgeCodec.encode(deviceCodeRequest)
            ),
            deviceCodeRequest
        )
        XCTAssertEqual(deviceCodeRequest.arguments?.provider, .codex)
        XCTAssertEqual(deviceCodeRequest.arguments?.loginAttemptID, attemptID)
        XCTAssertEqual(deviceCodeRequest.arguments?.loginMethod, .deviceCode)
        XCTAssertEqual(
            try OAuthBridgeCodec.decode(
                OAuthBridgeRequest.self,
                from: OAuthBridgeCodec.encode(generationRequest)
            ),
            generationRequest
        )
        XCTAssertEqual(generationRequest.arguments?.provider, .codex)
        XCTAssertEqual(generationRequest.arguments?.model, "gpt-5.6-sol")
        XCTAssertEqual(generationRequest.arguments?.systemPrompt, "Classify safely.")
        XCTAssertEqual(generationRequest.arguments?.userPrompt, "invoice.pdf")
    }

    func testDeviceCodeLoginAttemptRoundTripPreservesBoundedPresentation() throws {
        let attempt = OAuthBridgeLoginAttempt(
            provider: .codex,
            attemptID: UUID(uuidString: "2B168CFF-462E-4539-9B45-A2D10EC94166")!,
            authorizationURL: URL(string: "https://auth.openai.com/device")!,
            userCode: "ABCD-EFGH"
        )
        let response = OAuthBridgeResponse.success(
            requestID: UUID(uuidString: "8CC00D37-5C51-405A-B3B5-D4369EDC1AE1")!,
            result: .loginAttempt(attempt)
        )

        let decoded = try OAuthBridgeCodec.decode(
            OAuthBridgeResponse.self,
            from: OAuthBridgeCodec.encode(response)
        )
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.result?.loginAttempt?.userCode, "ABCD-EFGH")
        XCTAssertEqual(
            decoded.result?.loginAttempt?.authorizationURL,
            URL(string: "https://auth.openai.com/device")!
        )
    }

    func testProtocolEnvelopeRoundTripPreservesRequestIdentity() throws {
        let request = OAuthBridgeRequest(
            operation: .probeOfficialCLIs,
            requestID: UUID(uuidString: "18A95869-411A-44E6-8C46-A8096DD44B4F")!
        )

        let data = try OAuthBridgeCodec.encode(request)
        XCTAssertEqual(
            try OAuthBridgeCodec.decode(OAuthBridgeRequest.self, from: data),
            request
        )
    }

    func testGenerationResultRoundTripCarriesExactlyOneBoundedPayload() throws {
        let generated = OAuthBridgeResult.generatedText(
            OAuthBridgeGeneratedText(provider: .codex, text: "work")
        )
        let decoded = try OAuthBridgeCodec.decode(
            OAuthBridgeResult.self,
            from: OAuthBridgeCodec.encode(generated)
        )
        XCTAssertEqual(decoded, generated)
        XCTAssertEqual(decoded.generatedText?.provider, .codex)
        XCTAssertEqual(decoded.generatedText?.text, "work")
        XCTAssertNil(decoded.capabilities)
        XCTAssertNil(decoded.cliProbes)
        XCTAssertNil(decoded.authStatus)
        XCTAssertNil(decoded.loginAttempt)

        let result = OAuthBridgeResult.authenticationStatus(
            OAuthBridgeAuthStatus(
                provider: .grok,
                cliStatus: .available,
                credentialState: .signedIn,
                connectionState: .connected,
                loginAttemptID: nil
            )
        )
        let fieldNames = Set(
            Mirror(reflecting: result).children.compactMap(\.label)
        )

        XCTAssertEqual(
            fieldNames,
            Set([
                "capabilities",
                "cliProbes",
                "authStatus",
                "loginAttempt",
                "generatedText"
            ])
        )
        XCTAssertNil(result.generatedText)
        let encoded = try OAuthBridgeCodec.encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("XUNJIAN_OK"))
    }

    func testGenerationPolicyAcceptsOnlyBoundedSafeTypedPayloads() {
        XCTAssertTrue(OAuthBridgeGenerationPolicy.requestIsValid(
            provider: .codex,
            model: "gpt-5.6-sol",
            systemPrompt: "system",
            userPrompt: "user"
        ))
        XCTAssertTrue(OAuthBridgeGenerationPolicy.outputIsValid("answer"))

        let oversizedSegment = String(
            repeating: "a",
            count: OAuthBridgeGenerationPolicy.maximumPromptSegmentBytes + 1
        )
        let invalidRequests: [(OAuthBridgeProvider?, String?, String?, String?)] = [
            (nil, "gpt-5.6-sol", "system", "user"),
            (.codex, nil, "system", "user"),
            (.codex, "", "system", "user"),
            (.codex, "gpt 5", "system", "user"),
            (.codex, "gpt-5\0", "system", "user"),
            (.codex, "gpt-5.6-sol", nil, "user"),
            (.codex, "gpt-5.6-sol", "   ", "user"),
            (.codex, "gpt-5.6-sol", "sys\0tem", "user"),
            (.codex, "gpt-5.6-sol", oversizedSegment, "user"),
            (.grok, "grok-4.5", "system", nil),
            (.grok, "grok-4.5", "system", "\n"),
            (.grok, "grok-4.5", "system", "us\0er"),
            (.grok, "grok-4.5", "system", oversizedSegment)
        ]
        for (provider, model, systemPrompt, userPrompt) in invalidRequests {
            XCTAssertFalse(OAuthBridgeGenerationPolicy.requestIsValid(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            ))
        }

        XCTAssertFalse(OAuthBridgeGenerationPolicy.outputIsValid(nil))
        XCTAssertFalse(OAuthBridgeGenerationPolicy.outputIsValid(""))
        XCTAssertFalse(OAuthBridgeGenerationPolicy.outputIsValid(" \n"))
        XCTAssertFalse(OAuthBridgeGenerationPolicy.outputIsValid("bad\0answer"))
        XCTAssertFalse(OAuthBridgeGenerationPolicy.outputIsValid(String(
            repeating: "a",
            count: OAuthBridgeGenerationPolicy.maximumOutputBytes + 1
        )))
    }

    func testClientRejectsInvalidGenerationArgumentsBeforeConnecting() async {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }
        let invalidArguments: [OAuthBridgeRequestArguments?] = [
            nil,
            OAuthBridgeRequestArguments(
                provider: nil,
                model: "gpt-5.6-sol",
                systemPrompt: "system",
                userPrompt: "user"
            ),
            OAuthBridgeRequestArguments(
                provider: .codex,
                model: "gpt 5",
                systemPrompt: "system",
                userPrompt: "user"
            ),
            OAuthBridgeRequestArguments(
                provider: .grok,
                model: "grok-4.5",
                systemPrompt: "",
                userPrompt: "user"
            ),
            OAuthBridgeRequestArguments(
                provider: .grok,
                model: "grok-4.5",
                systemPrompt: "system",
                userPrompt: String(
                    repeating: "a",
                    count: OAuthBridgeGenerationPolicy.maximumPromptSegmentBytes + 1
                )
            ),
            OAuthBridgeRequestArguments(
                provider: .grok,
                loginAttemptID: UUID(),
                model: "grok-4.5",
                systemPrompt: "system",
                userPrompt: "user"
            )
        ]

        for arguments in invalidArguments {
            do {
                _ = try await client.perform(.generateText, arguments: arguments)
                XCTFail("Expected generation arguments to fail locally")
            } catch let error as OAuthBridgeClientError {
                XCTAssertEqual(error, .invalidRequest)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLogoutIPCRequiresProviderOnlyAndSignedOutResult() {
        XCTAssertTrue(OAuthBridgeClient.argumentsAreValid(
            OAuthBridgeRequestArguments(provider: .codex),
            for: .logoutProvider
        ))
        XCTAssertFalse(OAuthBridgeClient.argumentsAreValid(
            OAuthBridgeRequestArguments(
                provider: .codex,
                model: "gpt-5.6-sol"
            ),
            for: .logoutProvider
        ))

        let request = OAuthBridgeRequest(
            operation: .logoutProvider,
            arguments: OAuthBridgeRequestArguments(provider: .grok)
        )
        let signedOut = OAuthBridgeResult.authenticationStatus(status(
            provider: .grok,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))
        let stillSignedIn = OAuthBridgeResult.authenticationStatus(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .disconnected
        ))
        XCTAssertTrue(OAuthBridgeClient.resultIsValid(signedOut, for: request))
        XCTAssertFalse(OAuthBridgeClient.resultIsValid(stillSignedIn, for: request))
        XCTAssertGreaterThan(
            OAuthBridgeTiming.clientTimeoutSeconds(for: .logoutProvider),
            10
        )
    }

    func testNonGenerationOperationsRejectGenerationFieldsBeforeConnecting() async {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }
        let attemptID = UUID()
        let cases: [(OAuthBridgeOperation, OAuthBridgeRequestArguments?)] = [
            (
                .capabilities,
                OAuthBridgeRequestArguments(
                    provider: nil,
                    model: "gpt-5.6-sol",
                    systemPrompt: "system",
                    userPrompt: "user"
                )
            ),
            (
                .authenticationStatus,
                OAuthBridgeRequestArguments(
                    provider: .codex,
                    model: "gpt-5.6-sol",
                    systemPrompt: "system",
                    userPrompt: "user"
                )
            ),
            (
                .startLogin,
                OAuthBridgeRequestArguments(
                    provider: .codex,
                    loginAttemptID: attemptID,
                    loginMethod: .browser,
                    model: "gpt-5.6-sol",
                    systemPrompt: "system",
                    userPrompt: "user"
                )
            ),
            (
                .cancelLogin,
                OAuthBridgeRequestArguments(
                    provider: .grok,
                    loginAttemptID: attemptID,
                    model: "grok-4.5",
                    systemPrompt: "system",
                    userPrompt: "user"
                )
            ),
            (
                .verifyConnection,
                OAuthBridgeRequestArguments(
                    provider: .grok,
                    model: "grok-4.5",
                    systemPrompt: "system",
                    userPrompt: "user"
                )
            )
        ]

        for (operation, arguments) in cases {
            do {
                _ = try await client.perform(operation, arguments: arguments)
                XCTFail("Expected \(operation) to reject generation fields")
            } catch let error as OAuthBridgeClientError {
                XCTAssertEqual(error, .invalidRequest)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testClientResultValidationRejectsProviderMismatchMultiplePayloadsAndInvalidOutput() {
        let request = OAuthBridgeRequest(
            operation: .generateText,
            arguments: OAuthBridgeRequestArguments(
                provider: .codex,
                model: "gpt-5.6-sol",
                systemPrompt: "system",
                userPrompt: "user"
            )
        )
        XCTAssertTrue(OAuthBridgeClient.resultIsValid(
            .generatedText(OAuthBridgeGeneratedText(provider: .codex, text: "answer")),
            for: request
        ))
        XCTAssertFalse(OAuthBridgeClient.resultIsValid(
            .generatedText(OAuthBridgeGeneratedText(provider: .codex, text: "")),
            for: request
        ))
        XCTAssertFalse(OAuthBridgeClient.resultIsValid(
            .generatedText(OAuthBridgeGeneratedText(
                provider: .codex,
                text: String(
                    repeating: "a",
                    count: OAuthBridgeGenerationPolicy.maximumOutputBytes + 1
                )
            )),
            for: request
        ))

        let mismatchedProvider = OAuthBridgeResult.generatedText(
            OAuthBridgeGeneratedText(provider: .grok, text: "answer")
        )
        XCTAssertFalse(OAuthBridgeClient.resultIsValid(mismatchedProvider, for: request))

        let multiplePayloads = OAuthBridgeResult(
            capabilities: nil,
            cliProbes: nil,
            authStatus: OAuthBridgeAuthStatus(
                provider: .codex,
                cliStatus: .available,
                credentialState: .signedIn,
                connectionState: .connected,
                loginAttemptID: nil
            ),
            loginAttempt: nil,
            generatedText: OAuthBridgeGeneratedText(provider: .codex, text: "answer")
        )
        XCTAssertFalse(OAuthBridgeClient.resultIsValid(multiplePayloads, for: request))
    }

    func testCodecRejectsOversizedPayloadBeforeDecoding() {
        let data = Data(repeating: 0, count: OAuthBridgeConstants.maximumPayloadBytes + 1)

        XCTAssertThrowsError(
            try OAuthBridgeCodec.decode(OAuthBridgeRequest.self, from: data)
        ) { error in
            XCTAssertEqual(error as? OAuthBridgeCodecError, .payloadTooLarge)
        }
    }

    func testOfficialOAuthRuntimeNoticeIsBundledWithSourceIdentifiers() throws {
        let noticeURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "OAuthRuntimeNOTICE",
                withExtension: "txt"
            )
        )
        let noticeData = try Data(contentsOf: noticeURL)
        XCTAssertFalse(noticeData.isEmpty)
        XCTAssertLessThanOrEqual(noticeData.count, 1_048_576)
        let notice = String(decoding: noticeData, as: UTF8.self)
        for requiredSource in [
            "OpenAI Codex",
            "https://raw.githubusercontent.com/openai/codex/rust-v0.147.0/",
            "GROK BUILD",
            "https://raw.githubusercontent.com/xai-org/grok-build/"
        ] {
            XCTAssertTrue(notice.contains(requiredSource), requiredSource)
        }
    }

    func testEmbeddedBridgeAdvertisesOnlyBoundedOperations() async throws {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }

        let capabilities = try await client.capabilities()

        XCTAssertEqual(capabilities.protocolVersion, OAuthBridgeConstants.protocolVersion)
        XCTAssertEqual(Set(capabilities.supportedProviders), Set(OAuthBridgeProvider.allCases))
        XCTAssertEqual(
            Set(capabilities.supportedOperations),
            Set([
                .capabilities,
                .probeOfficialCLIs,
                .authenticationStatus,
                .startLogin,
                .cancelLogin,
                .verifyConnection,
                .generateText,
                .disconnectProvider,
                .logoutProvider
            ])
        )
        XCTAssertFalse(capabilities.storesCredentials)
    }

    func testEmbeddedBridgeProbesOfficialCLIsWithoutReturningPaths() async throws {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }

        let probes = try await client.probeOfficialCLIs()

        XCTAssertEqual(Set(probes.map(\.provider)), Set(OAuthBridgeProvider.allCases))
        for probe in probes {
            XCTAssertFalse(probe.version?.contains("/") == true)
        }
    }

    func testEmbeddedBridgeRejectsIncompatibleProtocolVersion() async throws {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }

        do {
            _ = try await client.perform(.capabilities, protocolVersion: 999)
            XCTFail("Expected protocol mismatch")
        } catch let OAuthBridgeClientError.service(error) {
            XCTAssertEqual(error.code, .protocolMismatch)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexVerificationOperationIsValidWithoutExecutingRealModelRequest() {
        XCTAssertTrue(OAuthBridgeClient.argumentsAreValid(
            OAuthBridgeRequestArguments(provider: .codex),
            for: .verifyConnection
        ))
    }

    func testBridgeRestoresOnlyProviderRuntimeCredentialBoundVerificationProof() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "XunJianOAuthBridge/main.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for requiredBinding in [
            "let provider: OAuthBridgeProvider",
            "let runtimeVersion: String",
            "let runtimeSHA256: String",
            "let credentialIdentity: CredentialIdentity",
            "let inode: UInt64",
            "let modificationSeconds: Int64",
            "let changeSeconds: Int64"
        ] {
            XCTAssertTrue(source.contains(requiredBinding), requiredBinding)
        }
        XCTAssertTrue(source.contains("restoreStoredVerification("))
        XCTAssertTrue(source.contains("persistStoredVerification("))
        XCTAssertTrue(source.contains("clearStoredVerification(for:"))
        XCTAssertTrue(source.contains("static let maximumCredentialBytes = 1_048_576"))
        XCTAssertTrue(source.contains("O_RDONLY | O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertTrue(source.contains("openedInformation.st_dev == linkInformation.st_dev"))
        XCTAssertTrue(source.contains("openedInformation.st_ino == linkInformation.st_ino"))
        XCTAssertTrue(source.contains("openedInformation.st_nlink == 1"))
        XCTAssertTrue(source.contains("openedInformation.st_mode & 0o077 == 0"))
        XCTAssertTrue(source.contains("rename(temporary.path, destination.path)"))
        XCTAssertFalse(source.contains("unlink(destination.path)"))
        let metadataStart = try XCTUnwrap(
            source.range(of: "private static func credentialIdentity(")?.lowerBound
        )
        let metadataEnd = try XCTUnwrap(
            source.range(
                of: "private static func readRegularFile(",
                range: metadataStart..<source.endIndex
            )?.lowerBound
        )
        XCTAssertFalse(
            source[metadataStart..<metadataEnd].contains("FileHandle"),
            "Credential identity must not read token bytes."
        )
        XCTAssertFalse(
            source.contains("credentialSHA256"),
            "Verification restoration must not read or hash credential contents."
        )
        XCTAssertFalse(
            source.contains("restoreStoredVerificationByGeneratingText"),
            "Restoring a prior verification must never send a model request."
        )
    }

    func testClientRejectsBridgeWithWrongCodeSigningRequirement() async {
        let client = OAuthBridgeClient(
            codeSigningRequirement: #"identifier "com.example.NotXunJian""#
        )
        defer { Task { await client.invalidate() } }

        do {
            _ = try await client.capabilities()
            XCTFail("Expected code signing rejection")
        } catch let OAuthBridgeClientError.connectionFailed(code) {
            XCTAssertEqual(code, NSXPCConnectionCodeSigningRequirementFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultClientTrustRejectsActualWrongSignedHelperBundle() async {
        let productsURL = Bundle.main.bundleURL.deletingLastPathComponent()
        let helperURL = productsURL.appending(path: "XunJianUntrustedOAuthBridge.xpc")
        XCTAssertEqual(
            Bundle(url: helperURL)?.object(forInfoDictionaryKey: "CFBundlePackageType")
                as? String,
            "XPC!"
        )
        XCTAssertEqual(
            Bundle(url: helperURL)?.bundleIdentifier,
            "com.example.XunJianUntrustedOAuthBridge"
        )

        let client = OAuthBridgeClient(helperURL: helperURL)
        defer { Task { await client.invalidate() } }
        do {
            _ = try await client.capabilities()
            XCTFail("Expected default helper trust to fail closed")
        } catch OAuthBridgeClientError.signingRequirementUnavailable {
            // Expected: no caller-provided requirement override was used.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBridgeRejectsWrongContainingApplicationBeforeExecutingRequest() async throws {
        let authorizedClient = OAuthBridgeClient()
        defer { Task { await authorizedClient.invalidate() } }
        _ = try await authorizedClient.capabilities()

        let productsURL = Bundle.main.bundleURL.deletingLastPathComponent()
        let executableURL = productsURL.appending(
            path: "XunJianUnauthorizedClient.app/Contents/MacOS/XunJianUnauthorizedClient"
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertEqual(output, "rejected")
    }

    func testProbeClientTimeoutExceedsServerWorstCaseBudget() {
        XCTAssertGreaterThan(
            OAuthBridgeTiming.clientTimeoutSeconds(for: .probeOfficialCLIs),
            OAuthBridgeTiming.maximumProbeServiceSeconds
        )
        XCTAssertEqual(
            OAuthBridgeTiming.clientTimeoutSeconds(for: .capabilities),
            OAuthBridgeTiming.requestOverheadSeconds
        )
        XCTAssertGreaterThanOrEqual(
            OAuthBridgeTiming.clientTimeoutSeconds(for: .verifyConnection),
            45
        )
    }

    func testVerificationIPCRequiresProviderOnlyAndAdvertisesSafeUnavailable() async {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }

        for invalidArguments in [
            nil,
            OAuthBridgeRequestArguments(
                provider: .grok,
                loginAttemptID: UUID()
            )
        ] {
            do {
                _ = try await client.perform(
                    .verifyConnection,
                    arguments: invalidArguments
                )
                XCTFail("Expected verification arguments to be rejected")
            } catch let error as OAuthBridgeClientError {
                XCTAssertEqual(error, .invalidRequest)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            OAuthBridgeErrorCode.safeVerificationUnavailable.rawValue,
            "safeVerificationUnavailable"
        )
    }

    func testStartLoginIPCRequiresProviderAttemptAndMethodOwnership() async {
        let client = OAuthBridgeClient()
        defer { Task { await client.invalidate() } }
        let attemptID = UUID(uuidString: "6C704741-A048-45C1-9BF0-63A1E6342107")!
        let invalidArguments: [OAuthBridgeRequestArguments?] = [
            nil,
            OAuthBridgeRequestArguments(
                provider: .codex,
                loginAttemptID: attemptID
            ),
            OAuthBridgeRequestArguments(
                provider: .codex,
                loginMethod: .deviceCode
            ),
            OAuthBridgeRequestArguments(
                provider: nil,
                loginAttemptID: attemptID,
                loginMethod: .deviceCode
            ),
            OAuthBridgeRequestArguments(
                provider: .grok,
                loginAttemptID: attemptID,
                loginMethod: .browser
            )
        ]

        for arguments in invalidArguments {
            do {
                _ = try await client.perform(.startLogin, arguments: arguments)
                XCTFail("Expected incomplete login ownership to be rejected")
            } catch let error as OAuthBridgeClientError {
                XCTAssertEqual(error, .invalidRequest)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await client.startLogin(for: .grok, method: .deviceCode)
            XCTFail("Expected Grok device-code login to be rejected locally")
        } catch let error as OAuthBridgeClientError {
            XCTAssertEqual(error, .invalidRequest)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testAppModelInitialOAuthStatesAreUnknownForBothProviders() {
        let model = AppModel(oauthBridgeService: FakeOAuthBridgeService())

        XCTAssertEqual(model.aiOAuthStates[.codex], .statusUnknown)
        XCTAssertEqual(model.aiOAuthStates[.grok], .statusUnknown)
        XCTAssertTrue(model.aiOAuthVerificationsInFlight.isEmpty)
    }

    @MainActor
    func testStatusRefreshNeverImplicitlyRunsModelVerification() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))

        await model.refreshOAuthStatus(for: .grok)

        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInUnverified)
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.grok)])
    }

    @MainActor
    func testExplicitGrokVerificationAloneCanPublishConnected() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await model.refreshOAuthStatus(for: .grok)

        await model.verifyOAuthConnection(for: .grok)

        XCTAssertEqual(model.aiOAuthStates[.grok], .connected)
        XCTAssertFalse(model.aiOAuthVerificationsInFlight.contains(.grok))
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.grok), .verify(.grok)])
    }

    @MainActor
    func testExplicitCodexVerificationCanPublishConnected() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await model.refreshOAuthStatus(for: .codex)

        await model.verifyOAuthConnection(for: .codex)

        XCTAssertEqual(model.aiOAuthStates[.codex], .connected)
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.codex), .verify(.codex)])
    }

    @MainActor
    func testVerificationFailureNeverPublishesConnected() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.failure(.forcedFailure))
        await model.refreshOAuthStatus(for: .grok)

        await model.verifyOAuthConnection(for: .grok)

        XCTAssertEqual(model.aiOAuthStates[.grok], .failed("Fake OAuth bridge failure."))
        XCTAssertFalse(model.aiOAuthVerificationsInFlight.contains(.grok))
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.grok), .verify(.grok)])
    }

    @MainActor
    func testCancelledVerificationCannotPublishLateConnectedResult() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let verificationGate = OAuthStatusGate()
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )), gate: verificationGate)
        await model.refreshOAuthStatus(for: .grok)

        let verification = Task { await model.verifyOAuthConnection(for: .grok) }
        await waitForCallCount(2, fake: fake)
        verification.cancel()
        await verificationGate.open()
        await verification.value

        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInUnverified)
        XCTAssertFalse(model.aiOAuthVerificationsInFlight.contains(.grok))
    }

    @MainActor
    func testDisconnectSupersedesLateVerificationResult() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let verificationGate = OAuthStatusGate()
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )), gate: verificationGate)
        await fake.configureDisconnectStatus(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .disconnected
        ))
        await model.refreshOAuthStatus(for: .grok)

        let verification = Task { await model.verifyOAuthConnection(for: .grok) }
        await waitForCallCount(2, fake: fake)
        let pendingDisconnect = Task { await model.disconnectOAuthProvider(.grok) }
        for _ in 0..<20 { await Task.yield() }
        let callsWhileVerificationIsPending = await fake.calls()
        XCTAssertEqual(
            callsWhileVerificationIsPending,
            [.status(.grok), .verify(.grok)]
        )
        await verificationGate.open()
        await verification.value
        await pendingDisconnect.value

        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInDisconnected)
        let calls = await fake.calls()
        XCTAssertEqual(
            calls,
            [.status(.grok), .verify(.grok), .disconnect(.grok)]
        )
    }

    @MainActor
    func testPendingStatusCompletesBeforeStartingLoginExactlyOnce() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let statusGate = OAuthStatusGate()
        let attemptID = UUID(uuidString: "3F4ACB6F-6B9F-4A91-A75E-76D115CA7582")!
        let authorizationURL = URL(string: "https://auth.openai.com/authorize")!
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .disconnected
        )), gate: statusGate)
        await fake.configureLoginAttempt(OAuthBridgeLoginAttempt(
            provider: .codex,
            attemptID: attemptID,
            authorizationURL: authorizationURL
        ))

        let pendingStatus = Task { await model.refreshOAuthStatus(for: .codex) }
        await waitForCallCount(1, fake: fake)
        let pendingStart = Task { await model.beginOAuthLogin(for: .codex) }
        for _ in 0..<20 { await Task.yield() }
        let callsBeforeStarting = await fake.calls()
        XCTAssertEqual(callsBeforeStarting, [.status(.codex)])

        await statusGate.open()
        await pendingStatus.value
        let returnedURL = await pendingStart.value

        XCTAssertEqual(returnedURL, authorizationURL)
        let callsAfterStarting = await fake.calls()
        XCTAssertEqual(
            callsAfterStarting,
            [.status(.codex), .start(.codex, .browser)]
        )
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(attemptID: attemptID, authorizationURL: authorizationURL)
        )
    }

    @MainActor
    func testPendingStatusCompletesBeforeCancellingLoginExactlyOnce() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let statusGate = OAuthStatusGate()
        let attemptID = UUID(uuidString: "33FE5473-631A-40E3-905D-E3614A4ACEC5")!
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedOut,
            connectionState: .authorizing,
            loginAttemptID: attemptID
        )), gate: statusGate)
        await fake.configureCancelStatus(status(
            provider: .grok,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))

        let pendingStatus = Task { await model.refreshOAuthStatus(for: .grok) }
        await waitForCallCount(1, fake: fake)
        let pendingCancel = Task { await model.cancelOAuthLogin(for: .grok) }
        for _ in 0..<20 { await Task.yield() }
        let callsBeforeCancelling = await fake.calls()
        XCTAssertEqual(callsBeforeCancelling, [.status(.grok)])

        await statusGate.open()
        await pendingStatus.value
        await pendingCancel.value

        let callsAfterCancelling = await fake.calls()
        XCTAssertEqual(callsAfterCancelling, [.status(.grok), .cancel(.grok, attemptID)])
        XCTAssertEqual(model.aiOAuthStates[.grok], .disconnected)
    }

    @MainActor
    func testPendingStatusCompletesBeforeDisconnectingExactlyOnce() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let statusGate = OAuthStatusGate()
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .connected
        )), gate: statusGate)
        await fake.configureDisconnectStatus(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .disconnected
        ))

        let pendingStatus = Task { await model.refreshOAuthStatus(for: .codex) }
        await waitForCallCount(1, fake: fake)
        let pendingDisconnect = Task { await model.disconnectOAuthProvider(.codex) }
        for _ in 0..<20 { await Task.yield() }
        let callsBeforeDisconnecting = await fake.calls()
        XCTAssertEqual(callsBeforeDisconnecting, [.status(.codex)])

        await statusGate.open()
        await pendingStatus.value
        await pendingDisconnect.value

        let callsAfterDisconnecting = await fake.calls()
        XCTAssertEqual(callsAfterDisconnecting, [.status(.codex), .disconnect(.codex)])
        XCTAssertEqual(model.aiOAuthStates[.codex], .signedInDisconnected)
    }

    @MainActor
    func testAppModelPublishesLoginAndCancelStateForCodex() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let attemptID = UUID(uuidString: "9E3CDDF4-3E0C-466A-89F9-26265B59B8F7")!
        let authorizationURL = URL(string: "https://auth.openai.com/authorize")!
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .codex,
                attemptID: attemptID,
                authorizationURL: authorizationURL
            )
        )
        await fake.configureCancelStatus(
            OAuthBridgeAuthStatus(
                provider: .codex,
                cliStatus: .available,
                credentialState: .signedOut,
                connectionState: .disconnected,
                loginAttemptID: nil
            )
        )

        let returnedURL = await model.beginOAuthLogin(for: .codex)
        XCTAssertEqual(returnedURL, authorizationURL)
        XCTAssertTrue(model.aiOAuthDeviceCodePresentations.isEmpty)
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(attemptID: attemptID, authorizationURL: authorizationURL)
        )

        await model.cancelOAuthLogin(for: .codex)
        XCTAssertEqual(model.aiOAuthStates[.codex], .disconnected)
        let calls = await fake.calls()
        XCTAssertEqual(
            calls,
            [.start(.codex, .browser), .cancel(.codex, attemptID)]
        )
    }

    @MainActor
    func testAppModelPublishesOwnedDeviceCodeAndCancelsExactAttempt() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let attemptID = UUID(uuidString: "4D95D8B5-1840-4770-B38F-B618A9799537")!
        let verificationURL = URL(string: "https://auth.openai.com/device")!
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .codex,
                attemptID: attemptID,
                authorizationURL: verificationURL,
                userCode: "ABCD-EFGH"
            )
        )
        await fake.configureCancelStatus(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))

        await model.beginOAuthDeviceCodeLogin(for: .codex)

        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(
                attemptID: attemptID,
                authorizationURL: verificationURL
            )
        )
        XCTAssertEqual(
            model.aiOAuthDeviceCodePresentations[.codex],
            AIOAuthDeviceCodePresentation(
                attemptID: attemptID,
                verificationURL: verificationURL,
                userCode: "ABCD-EFGH"
            )
        )
        var calls = await fake.calls()
        XCTAssertEqual(calls, [.start(.codex, .deviceCode)])

        await model.cancelOAuthLogin(for: .codex)

        XCTAssertEqual(model.aiOAuthStates[.codex], .disconnected)
        XCTAssertNil(model.aiOAuthDeviceCodePresentations[.codex])
        calls = await fake.calls()
        XCTAssertEqual(
            calls,
            [.start(.codex, .deviceCode), .cancel(.codex, attemptID)]
        )
    }

    @MainActor
    func testAppModelRejectsDeviceCodeAttemptFromWrongProvider() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .grok,
                attemptID: UUID(uuidString: "B5FE6F1E-D820-47C0-86D9-B44EB30F11CE")!,
                authorizationURL: URL(string: "https://auth.openai.com/device")!,
                userCode: "ABCD-EFGH"
            )
        )

        await model.beginOAuthDeviceCodeLogin(for: .codex)

        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .failed("OAuth 伴随服务返回了不匹配的 AI 提供商。")
        )
        XCTAssertNil(model.aiOAuthDeviceCodePresentations[.codex])
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.start(.codex, .deviceCode)])
    }

    @MainActor
    func testAppModelKeepsDeviceCodeOnlyForSameLoginAttempt() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let firstAttemptID = UUID(uuidString: "0CBA9A3A-EFD4-4DBB-B593-D230217618C4")!
        let nextAttemptID = UUID(uuidString: "2B38DA5E-3B4A-4235-9B6D-C9F22FEA0404")!
        let verificationURL = URL(string: "https://auth.openai.com/device")!
        await fake.configureLoginAttempt(OAuthBridgeLoginAttempt(
            provider: .codex,
            attemptID: firstAttemptID,
            authorizationURL: verificationURL,
            userCode: "WXYZ-1234"
        ))
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .authorizing,
            loginAttemptID: firstAttemptID
        )))
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .authorizing,
            loginAttemptID: nextAttemptID
        )))

        await model.beginOAuthDeviceCodeLogin(for: .codex)
        await model.refreshOAuthStatus(for: .codex)
        XCTAssertEqual(
            model.aiOAuthDeviceCodePresentations[.codex]?.attemptID,
            firstAttemptID
        )

        await model.refreshOAuthStatus(for: .codex)
        XCTAssertNil(model.aiOAuthDeviceCodePresentations[.codex])
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(attemptID: nextAttemptID, authorizationURL: nil)
        )
    }

    @MainActor
    func testAppModelPublishesStartingAndCanCancelBeforeAttemptArrives() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let gate = OAuthStatusGate()
        let attemptID = UUID(uuidString: "10A4A653-A01C-4212-89ED-985C622351A7")!
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .codex,
                attemptID: attemptID,
                authorizationURL: URL(string: "https://auth.openai.com/authorize")!
            ),
            gate: gate
        )
        await fake.configureCancelStatus(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))

        let pendingLogin = Task { await model.beginOAuthLogin(for: .codex) }
        await waitForCallCount(1, fake: fake)
        XCTAssertEqual(model.aiOAuthStates[.codex], .starting)
        XCTAssertTrue(model.aiOAuthStates[.codex]?.shouldPoll == true)

        await model.cancelOAuthLogin(for: .codex)
        XCTAssertEqual(model.aiOAuthStates[.codex], .disconnected)
        await gate.open()
        let returnedURL = await pendingLogin.value

        XCTAssertNil(returnedURL)
        await waitForCallCount(2, fake: fake)
        let calls = await fake.calls()
        XCTAssertEqual(
            calls,
            [.start(.codex, .browser), .cancel(.codex, attemptID)]
        )
    }

    @MainActor
    func testAppModelRefreshPreservesURLOnlyForSameLoginAttempt() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let firstAttemptID = UUID(uuidString: "B93C2386-0DDF-4BD2-B7D4-37836F797994")!
        let nextAttemptID = UUID(uuidString: "FCB06F16-10EB-49F4-A14A-4ABEA50F2178")!
        let authorizationURL = URL(string: "https://auth.openai.com/authorize")!
        await fake.configureLoginAttempt(OAuthBridgeLoginAttempt(
            provider: .codex,
            attemptID: firstAttemptID,
            authorizationURL: authorizationURL
        ))
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .authorizing,
            loginAttemptID: firstAttemptID
        )))
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .authorizing,
            loginAttemptID: nextAttemptID
        )))

        _ = await model.beginOAuthLogin(for: .codex)
        await model.refreshOAuthStatus(for: .codex)
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(
                attemptID: firstAttemptID,
                authorizationURL: authorizationURL
            )
        )

        await model.refreshOAuthStatus(for: .codex)
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(attemptID: nextAttemptID, authorizationURL: nil)
        )
    }

    func testOAuthPollingIsLimitedToStartingAndAuthenticating() {
        let attemptID = UUID(uuidString: "15F26F60-CF66-46A4-9CB9-3243D62A1665")!
        let pollingStates: [AIOAuthState] = [
            .starting,
            .authenticating(attemptID: attemptID, authorizationURL: nil)
        ]
        let terminalStates: [AIOAuthState] = [
            .unavailable(.missing),
            .statusUnknown,
            .disconnected,
            .signedInDisconnected,
            .signedInUnverified,
            .connected,
            .failed("failure")
        ]

        XCTAssertTrue(pollingStates.allSatisfy(\.shouldPoll))
        XCTAssertTrue(terminalStates.allSatisfy { !$0.shouldPoll })
    }

    @MainActor
    func testOAuthPresentationAndRuntimeErrorsFollowSelectedLanguage() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppLanguage.storageKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppLanguage.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.storageKey)
            }
        }

        defaults.set(
            AppLanguage.simplifiedChinese.rawValue,
            forKey: AppLanguage.storageKey
        )
        let chineseUnverifiedTitle = AIOAuthState.signedInUnverified.localizedTitle
        let chineseConnectedTitle = AIOAuthState.connected.localizedTitle
        XCTAssertNotEqual(chineseUnverifiedTitle, chineseConnectedTitle)
        XCTAssertEqual(chineseUnverifiedTitle, "已登录，尚未验证")
        XCTAssertEqual(chineseConnectedTitle, "账号连接已验证")
        XCTAssertEqual(
            AIOAuthState.unavailable(.incompatible).localizedDetail,
            "运行组件版本或能力不在已审计范围内，请使用受支持的官方版本。"
        )
        XCTAssertEqual(
            AIOAuthState.unavailable(.untrusted).localizedDetail,
            "内置运行组件已损坏或未通过官方签名校验，请重新安装寻简。"
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "OAuth bridge protocol version is incompatible."
            ),
            "OAuth 伴随服务版本不兼容，请更新寻简。"
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "XunJian's private Grok login storage is unavailable or unsafe."
            ),
            "寻简专属 Grok 登录目录不可用或不安全。"
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "Grok's isolated runtime safety inspection failed."
            ),
            "Grok 隔离运行环境安全检查未通过，已停止连接。"
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "Grok verification rejected [post.user.outer-meta]."
            ),
            "Grok 验证在安全检查阶段被拒绝（post.user.outer-meta）。"
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "Grok verification rejected [secret/token]."
            ),
            "OAuth 操作没有完成，请稍后重试。"
        )
        for invalidCode in [
            "",
            "550e8400-e29b-41d4-a716-446655440000",
            "post.uſer.outer-meta"
        ] {
            XCTAssertEqual(
                AppLanguage.localizedRuntimeMessage(
                    "Grok verification rejected [\(invalidCode)]."
                ),
                "OAuth 操作没有完成，请稍后重试。",
                invalidCode
            )
        }
        XCTAssertTrue(
            AIProviderKind.grok.localizedConnectionNote.contains(
                "寻简内置并验证官方 Grok Runtime"
            )
        )

        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        let englishUnverifiedTitle = AIOAuthState.signedInUnverified.localizedTitle
        let englishConnectedTitle = AIOAuthState.connected.localizedTitle
        XCTAssertNotEqual(englishUnverifiedTitle, englishConnectedTitle)
        XCTAssertEqual(englishUnverifiedTitle, "Signed In, Not Yet Verified")
        XCTAssertEqual(englishConnectedTitle, "Account Connection Verified")
        XCTAssertEqual(
            AIOAuthState.unavailable(.incompatible).localizedDetail,
            "The runtime version or capabilities are outside the audited range. Use a supported official version."
        )
        XCTAssertEqual(
            AIOAuthState.unavailable(.untrusted).localizedDetail,
            "The bundled runtime is damaged or failed official signature verification. Reinstall XunJian."
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                OAuthBridgeClientError.requestTimedOut.errorDescription!
            ),
            "The OAuth companion service timed out."
        )
        XCTAssertEqual(
            AppLanguage.localizedRuntimeMessage(
                "Grok verification rejected [post.user.outer-meta]."
            ),
            "Grok verification rejected [post.user.outer-meta]."
        )
        for malformedDiagnostic in [
            "Grok verification rejected [post.reply]. secret=hidden",
            "Grok verification rejected [post.reply]",
            "Grok verification rejected [secret-token]."
        ] {
            XCTAssertEqual(
                AppLanguage.localizedRuntimeMessage(malformedDiagnostic),
                "The OAuth operation didn’t complete. Try again later.",
                malformedDiagnostic
            )
        }
        for invalidCode in [
            "",
            "550e8400-e29b-41d4-a716-446655440000",
            "post.uſer.outer-meta"
        ] {
            XCTAssertEqual(
                AppLanguage.localizedRuntimeMessage(
                    "Grok verification rejected [\(invalidCode)]."
                ),
                "The OAuth operation didn’t complete. Try again later.",
                invalidCode
            )
        }
        XCTAssertTrue(
            AIProviderKind.grok.localizedConnectionNote.contains(
                "XunJian includes and verifies the official Grok Runtime"
            )
        )
    }

    @MainActor
    func testAppModelSerializesPendingLoginAgainstRefreshAndRepeatedStart() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let gate = OAuthStatusGate()
        let attemptID = UUID(uuidString: "8DAD2235-55B0-4BB9-9E2B-2CD338792AE7")!
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .codex,
                attemptID: attemptID,
                authorizationURL: URL(string: "https://auth.openai.com/authorize")!
            ),
            gate: gate
        )

        let pendingLogin = Task { await model.beginOAuthLogin(for: .codex) }
        await waitForCallCount(1, fake: fake)
        await model.refreshOAuthStatus(for: .codex)
        await model.beginOAuthLogin(for: .codex)
        let pendingCalls = await fake.calls()
        XCTAssertEqual(pendingCalls, [.start(.codex, .browser)])

        await gate.open()
        await pendingLogin.value
        await model.beginOAuthLogin(for: .codex)
        let completedCalls = await fake.calls()
        XCTAssertEqual(completedCalls, [.start(.codex, .browser)])
        XCTAssertEqual(
            model.aiOAuthStates[.codex],
            .authenticating(
                attemptID: attemptID,
                authorizationURL: URL(string: "https://auth.openai.com/authorize")!
            )
        )
    }

    @MainActor
    func testStaleLoginResponseIsCancelledAfterNewerDisconnect() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let gate = OAuthStatusGate()
        let attemptID = UUID(uuidString: "DE95A296-A3FE-45D4-8515-E5AF46F3A86D")!
        await fake.configureLoginAttempt(
            OAuthBridgeLoginAttempt(
                provider: .grok,
                attemptID: attemptID,
                authorizationURL: nil
            ),
            gate: gate
        )
        await fake.configureCancelStatus(status(
            provider: .grok,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))

        let pendingLogin = Task { await model.beginOAuthLogin(for: .grok) }
        await waitForCallCount(1, fake: fake)
        await model.disconnectOAuthProvider(.grok)
        await gate.open()
        await pendingLogin.value

        XCTAssertEqual(model.aiOAuthStates[.grok], .disconnected)
        let calls = await fake.calls()
        XCTAssertEqual(
            calls,
            [.start(.grok, .browser), .cancel(.grok, attemptID)]
        )
    }

    @MainActor
    func testAppModelSerializesCancelAgainstRefreshAndRepeatedCancel() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let attemptID = UUID(uuidString: "60CB3349-91D3-470D-B1DD-A1F35DCDA08B")!
        let gate = OAuthStatusGate()
        await fake.configureLoginAttempt(OAuthBridgeLoginAttempt(
            provider: .codex,
            attemptID: attemptID,
            authorizationURL: URL(string: "https://auth.openai.com/authorize")!
        ))
        await fake.configureCancelStatus(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .disconnected
        ), gate: gate)
        await model.beginOAuthLogin(for: .codex)

        let pendingCancel = Task { await model.cancelOAuthLogin(for: .codex) }
        await waitForCallCount(2, fake: fake)
        await model.refreshOAuthStatus(for: .codex)
        await model.cancelOAuthLogin(for: .codex)
        let pendingCalls = await fake.calls()
        XCTAssertEqual(
            pendingCalls,
            [.start(.codex, .browser), .cancel(.codex, attemptID)]
        )

        await gate.open()
        await pendingCancel.value
        XCTAssertEqual(model.aiOAuthStates[.codex], .disconnected)
    }

    @MainActor
    func testAppModelSerializesDisconnectAgainstRefreshAndRepeatedDisconnect() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let gate = OAuthStatusGate()
        await fake.configureDisconnectStatus(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .disconnected
        ), gate: gate)

        let pendingDisconnect = Task { await model.disconnectOAuthProvider(.grok) }
        await waitForCallCount(1, fake: fake)
        await model.refreshOAuthStatus(for: .grok)
        await model.disconnectOAuthProvider(.grok)
        let pendingCalls = await fake.calls()
        XCTAssertEqual(pendingCalls, [.disconnect(.grok)])

        await gate.open()
        await pendingDisconnect.value
        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInDisconnected)
    }

    @MainActor
    func testAppModelMapsUnavailableUnknownDisconnectedUnverifiedAndConnectedStatus() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            cliStatus: .missing,
            credentialState: .unknown,
            connectionState: .disconnected
        )))
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .unknown,
            connectionState: .disconnected
        )))
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .disconnected
        )))
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )))

        await model.refreshOAuthStatus(for: .grok)
        XCTAssertEqual(model.aiOAuthStates[.grok], .unavailable(.missing))
        await model.refreshOAuthStatus(for: .grok)
        XCTAssertEqual(model.aiOAuthStates[.grok], .statusUnknown)
        await model.refreshOAuthStatus(for: .grok)
        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInDisconnected)
        await model.refreshOAuthStatus(for: .grok)
        XCTAssertEqual(model.aiOAuthStates[.grok], .signedInUnverified)
        await model.refreshOAuthStatus(for: .grok)
        XCTAssertEqual(model.aiOAuthStates[.grok], .connected)
    }

    @MainActor
    func testAppModelDisconnectKeepsSharedCredentialSignedIn() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.configureDisconnectStatus(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .disconnected
        ))

        await model.disconnectOAuthProvider(.codex)

        XCTAssertEqual(model.aiOAuthStates[.codex], .signedInDisconnected)
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.disconnect(.codex)])
    }

    @MainActor
    func testRepeatedOAuthRefreshWhileStatusIsPendingIsCoalesced() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        let gate = OAuthStatusGate()
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedOut,
            connectionState: .disconnected
        )), gate: gate)

        let pendingRefresh = Task { await model.refreshOAuthStatus(for: .codex) }
        await waitForCallCount(1, fake: fake)
        await model.refreshOAuthStatus(for: .codex)
        let callsWhilePending = await fake.calls()
        XCTAssertEqual(callsWhilePending, [.status(.codex)])
        XCTAssertEqual(model.aiOAuthStates[.codex], .statusUnknown)

        await gate.open()
        await pendingRefresh.value
        let completedCalls = await fake.calls()
        XCTAssertEqual(completedCalls, [.status(.codex)])
        XCTAssertEqual(model.aiOAuthStates[.codex], .disconnected)
    }

    @MainActor
    func testOAuthFailureIsPublishedPerProviderAndUnsupportedProviderSkipsBridge() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.failure(.forcedFailure))

        await model.refreshOAuthStatus(for: .codex)

        XCTAssertEqual(model.aiOAuthStates[.codex], .failed("Fake OAuth bridge failure."))
        XCTAssertEqual(model.errorMessage, "Fake OAuth bridge failure.")
        await model.refreshOAuthStatus(for: .deepSeek)
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.codex)])
    }

    func testOAuthAIProviderRoutesExactSystemAndUserMessagesThroughBridge() async throws {
        let fake = FakeOAuthBridgeService()
        await fake.configureGeneration(.success("  OAuth result  "))
        let provider = try OAuthAIProvider(
            kind: .codex,
            model: "gpt-5.3-codex",
            bridge: fake
        )

        let response = try await provider.chat([
            AIMessage(role: .system, content: "system instruction"),
            AIMessage(role: .user, content: "user request")
        ])

        XCTAssertEqual(response, "OAuth result")
        let calls = await fake.calls()
        XCTAssertEqual(calls, [
            .generate(
                .codex,
                "gpt-5.6-sol",
                "system instruction",
                "user request"
            )
        ])
    }

    func testOAuthAIProviderRejectsUnsupportedConversationShapeLocally() async throws {
        let fake = FakeOAuthBridgeService()
        let provider = try OAuthAIProvider(
            kind: .grok,
            model: "grok-4.5",
            bridge: fake
        )

        do {
            _ = try await provider.chat([
                AIMessage(role: .user, content: "missing system")
            ])
            XCTFail("Expected invalid OAuth conversation to be rejected")
        } catch let error as AIServiceError {
            guard case .invalidConversation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let calls = await fake.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testAppModelUsesVerifiedOAuthForAISearchWithoutAPIKey() async throws {
        let fake = FakeOAuthBridgeService()
        let suiteName = "XunJianTests.OAuthSearch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            oauthBridgeService: fake,
            aiConfigurationStore: AIConfigurationStore(defaults: defaults)
        )
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))
        await fake.configureVerification(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await fake.configureGeneration(.success(
            #"{"keywords":[],"fileKinds":[],"modifiedAfter":null,"modifiedBefore":null}"#
        ))

        await model.refreshOAuthStatus(for: .codex)
        await model.verifyOAuthConnection(for: .codex)
        model.setActiveOAuthAIProvider(.codex)
        try await model.performAISearch("合同")

        XCTAssertEqual(model.activeAIProviderKind, .codex)
        XCTAssertEqual(model.activeAIAuthenticationMode, .oauth)
        XCTAssertEqual(model.aiSearchPlan?.keywords, [])
        XCTAssertEqual(model.aiOAuthStates[.codex], .connected)
        let calls = await fake.calls()
        XCTAssertEqual(calls.count, 3)
        guard case let .generate(provider, modelID, systemPrompt, userPrompt) = calls[2] else {
            return XCTFail("Expected OAuth generation call")
        }
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(modelID, "gpt-5.6-sol")
        XCTAssertTrue(systemPrompt.contains("JSON"))
        XCTAssertEqual(userPrompt, "合同")
    }

    @MainActor
    func testUnverifiedOAuthCannotBecomeCurrentAI() async {
        let fake = FakeOAuthBridgeService()
        let suiteName = "XunJianTests.OAuthUnverifiedCurrent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            oauthBridgeService: fake,
            aiConfigurationStore: AIConfigurationStore(defaults: defaults)
        )
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .authenticated
        )))

        await model.refreshOAuthStatus(for: .codex)
        model.setActiveOAuthAIProvider(.codex)

        XCTAssertEqual(model.aiOAuthStates[.codex], .signedInUnverified)
        XCTAssertNil(model.activeAIProviderKind)
        XCTAssertNil(model.activeAIAuthenticationMode)
    }

    @MainActor
    func testTypingNaturalLanguageSearchNeverImplicitlyCallsOAuthGeneration() async {
        let fake = FakeOAuthBridgeService()
        let model = AppModel(oauthBridgeService: fake)
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await model.refreshOAuthStatus(for: .codex)
        model.setActiveOAuthAIProvider(.codex)

        model.searchText = "帮我找出上周修改过的合同"
        try? await Task.sleep(for: .milliseconds(250))

        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.codex)])
    }

    @MainActor
    func testOAuthLogoutClearsActiveSelectionAndPublishesSignedOut() async {
        let fake = FakeOAuthBridgeService()
        let suiteName = "XunJianTests.OAuthLogout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            oauthBridgeService: fake,
            aiConfigurationStore: AIConfigurationStore(defaults: defaults)
        )
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await fake.configureLogoutStatus(status(
            provider: .grok,
            credentialState: .signedOut,
            connectionState: .disconnected
        ))
        await model.refreshOAuthStatus(for: .grok)
        model.setActiveOAuthAIProvider(.grok)

        await model.logoutOAuthProvider(for: .grok)

        XCTAssertEqual(model.aiOAuthStates[.grok], .disconnected)
        XCTAssertNil(model.activeAIProviderKind)
        XCTAssertNil(model.activeAIAuthenticationMode)
        let calls = await fake.calls()
        XCTAssertEqual(calls, [.status(.grok), .logout(.grok)])
    }

    @MainActor
    func testOAuthDisconnectClearsOnlyActiveOAuthSelection() async {
        let fake = FakeOAuthBridgeService()
        let suiteName = "XunJianTests.OAuthDisconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            oauthBridgeService: fake,
            aiConfigurationStore: AIConfigurationStore(defaults: defaults)
        )
        await fake.enqueueStatus(.success(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .connected
        )))
        await fake.configureDisconnectStatus(status(
            provider: .grok,
            credentialState: .signedIn,
            connectionState: .disconnected
        ))

        await model.refreshOAuthStatus(for: .grok)
        model.setActiveOAuthAIProvider(.grok)
        XCTAssertEqual(model.activeAIAuthenticationMode, .oauth)

        await model.disconnectOAuthProvider(.grok)

        XCTAssertNil(model.activeAIProviderKind)
        XCTAssertNil(model.activeAIAuthenticationMode)
    }

    func testAIConfigurationStorePersistsAuthenticationModeSeparately() {
        let suiteName = "XunJianTests.AIMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIConfigurationStore(defaults: defaults)

        store.activeKind = .grok
        store.activeAuthenticationMode = .oauth

        let relaunched = AIConfigurationStore(defaults: defaults)
        XCTAssertEqual(relaunched.activeKind, .grok)
        XCTAssertEqual(relaunched.activeAuthenticationMode, .oauth)
    }

    func testAIConfigurationStorePersistsProviderScopedVerificationFingerprints() {
        let suiteName = "XunJianTests.AIVerificationFingerprint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIConfigurationStore(defaults: defaults)

        store.setAPIKeyVerificationFingerprint("codex-proof", for: .codex)
        store.setAPIKeyVerificationFingerprint("grok-proof", for: .grok)

        let relaunched = AIConfigurationStore(defaults: defaults)
        XCTAssertEqual(relaunched.apiKeyVerificationFingerprint(for: .codex), "codex-proof")
        XCTAssertEqual(relaunched.apiKeyVerificationFingerprint(for: .grok), "grok-proof")

        store.setAPIKeyVerificationFingerprint(nil, for: .codex)
        XCTAssertNil(relaunched.apiKeyVerificationFingerprint(for: .codex))
        XCTAssertEqual(relaunched.apiKeyVerificationFingerprint(for: .grok), "grok-proof")
    }

    func testAPIKeyVerificationFingerprintBindsSettingsAndSecretWithoutPersistingSecret() {
        let settings = AIProviderSettings(
            kind: .codex,
            baseURL: "https://api.example.com/v1",
            model: "model-a",
            hasAPIKey: true
        )
        let proof = AIConfigurationStore.apiKeyVerificationFingerprint(
            settings: settings,
            secret: "private-api-key"
        )

        XCTAssertEqual(proof.count, 64)
        XCTAssertFalse(proof.contains("private-api-key"))
        XCTAssertNotEqual(
            proof,
            AIConfigurationStore.apiKeyVerificationFingerprint(
                settings: settings,
                secret: "replacement-api-key"
            )
        )
        var changedSettings = settings
        changedSettings.model = "model-b"
        XCTAssertNotEqual(
            proof,
            AIConfigurationStore.apiKeyVerificationFingerprint(
                settings: changedSettings,
                secret: "private-api-key"
            )
        )
    }

    @MainActor
    func testRelaunchRestoresPersistedOAuthOnlyAfterConnectedStatus() async {
        let fake = FakeOAuthBridgeService()
        let suiteName = "XunJianTests.AIRelaunchOAuth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIConfigurationStore(defaults: defaults)
        store.activeKind = .codex
        store.activeAuthenticationMode = .oauth
        await fake.enqueueStatus(.success(status(
            provider: .codex,
            credentialState: .signedIn,
            connectionState: .connected
        )))

        let model = AppModel(
            oauthBridgeService: fake,
            aiConfigurationStore: store
        )
        XCTAssertNil(model.activeAIProviderKind)

        await model.refreshOAuthStatus(for: .codex)

        XCTAssertEqual(model.activeAIProviderKind, .codex)
        XCTAssertEqual(model.activeAIAuthenticationMode, .oauth)
        XCTAssertEqual(store.activeKind, .codex)
        XCTAssertEqual(store.activeAuthenticationMode, .oauth)
    }

    private func status(
        provider: OAuthBridgeProvider,
        cliStatus: OAuthCLIProbe.Status = .available,
        credentialState: OAuthCredentialState,
        connectionState: OAuthConnectionState,
        loginAttemptID: UUID? = nil
    ) -> OAuthBridgeAuthStatus {
        OAuthBridgeAuthStatus(
            provider: provider,
            cliStatus: cliStatus,
            credentialState: credentialState,
            connectionState: connectionState,
            loginAttemptID: loginAttemptID
        )
    }

    @MainActor
    private func waitForCallCount(
        _ expectedCount: Int,
        fake: FakeOAuthBridgeService
    ) async {
        for _ in 0..<1_000 {
            if await fake.calls().count >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for fake OAuth bridge call")
    }
}
#endif
