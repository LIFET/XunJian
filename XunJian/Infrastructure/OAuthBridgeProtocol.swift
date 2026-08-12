import Foundation
import Security

enum OAuthBridgeConstants {
    static let protocolVersion = 6
    static let serviceName = "com.xingmingbo.XunJian.OAuthBridge"
    static let trustedApplicationIdentifier = "com.xingmingbo.XunJian"
    static let maximumPayloadBytes = 1_048_576
}

enum OAuthBridgeTiming {
    static let commandTimeoutSeconds: TimeInterval = 4
    static let commandTerminationGraceSeconds: TimeInterval = 1
    static let maximumProbeCommandCount = 5
    static let requestOverheadSeconds: TimeInterval = 5

    static var maximumProbeServiceSeconds: TimeInterval {
        (commandTimeoutSeconds + commandTerminationGraceSeconds)
            * TimeInterval(maximumProbeCommandCount)
    }

    static func clientTimeoutSeconds(for operation: OAuthBridgeOperation) -> TimeInterval {
        switch operation {
        case .capabilities:
            5
        case .probeOfficialCLIs:
            maximumProbeServiceSeconds + requestOverheadSeconds
        case .authenticationStatus:
            15
        case .startLogin:
            700
        case .verifyConnection:
            70
        case .generateText:
            100
        case .cancelLogin, .disconnectProvider:
            10
        case .logoutProvider:
            20
        }
    }
}

@objc(XunJianOAuthBridgeXPCProtocol)
protocol OAuthBridgeXPCProtocol: NSObjectProtocol {
    func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

enum OAuthBridgeProvider: String, CaseIterable, Codable, Sendable {
    case codex
    case grok
}

enum OAuthBridgeLoginMethod: String, Codable, Equatable, Sendable {
    case browser
    case deviceCode
}

enum OAuthBridgeOperation: String, CaseIterable, Codable, Sendable {
    case capabilities
    case probeOfficialCLIs
    case authenticationStatus
    case startLogin
    case cancelLogin
    case verifyConnection
    case generateText
    case disconnectProvider
    case logoutProvider

    static let safeOperations: [Self] = [
        .capabilities,
        .probeOfficialCLIs,
        .authenticationStatus,
        .startLogin,
        .cancelLogin,
        .verifyConnection,
        .generateText,
        .disconnectProvider,
        .logoutProvider
    ]
}

enum OAuthBridgeGenerationPolicy {
    static let maximumModelBytes = 160
    static let maximumPromptSegmentBytes = 65_536
    static let maximumPromptBytes = 131_072
    static let maximumOutputBytes = 131_072

    static func requestIsValid(
        provider: OAuthBridgeProvider?,
        model: String?,
        systemPrompt: String?,
        userPrompt: String?
    ) -> Bool {
        guard provider != nil,
              let model,
              let systemPrompt,
              let userPrompt,
              stringIsValid(model, maximumBytes: maximumModelBytes),
              model.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                      || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                      || [0x2D, 0x2E, 0x2F, 0x3A, 0x5F].contains(scalar.value)
              }),
              stringIsValid(
                  systemPrompt,
                  maximumBytes: maximumPromptSegmentBytes
              ),
              stringIsValid(
                  userPrompt,
                  maximumBytes: maximumPromptSegmentBytes
              ) else {
            return false
        }
        return makePrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        ).utf8.count <= maximumPromptBytes
    }

    static func outputIsValid(_ text: String?) -> Bool {
        guard let text else { return false }
        return stringIsValid(text, maximumBytes: maximumOutputBytes)
    }

    static func makePrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        Follow the system instructions and answer the user request below.
        Do not use tools, commands, files, network access, or external resources.
        <system_instructions>
        \(systemPrompt)
        </system_instructions>
        <user_request>
        \(userPrompt)
        </user_request>
        """
    }

    private static func stringIsValid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.contains("\0")
    }
}

struct OAuthBridgeRequestArguments: Codable, Equatable, Sendable {
    let provider: OAuthBridgeProvider?
    let loginAttemptID: UUID?
    let loginMethod: OAuthBridgeLoginMethod?
    let model: String?
    let systemPrompt: String?
    let userPrompt: String?

    init(
        provider: OAuthBridgeProvider?,
        loginAttemptID: UUID? = nil,
        loginMethod: OAuthBridgeLoginMethod? = nil,
        model: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String? = nil
    ) {
        self.provider = provider
        self.loginAttemptID = loginAttemptID
        self.loginMethod = loginMethod
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }
}

struct OAuthBridgeRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let operation: OAuthBridgeOperation
    let arguments: OAuthBridgeRequestArguments?

    init(
        operation: OAuthBridgeOperation,
        arguments: OAuthBridgeRequestArguments? = nil,
        protocolVersion: Int = OAuthBridgeConstants.protocolVersion,
        requestID: UUID = UUID()
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.arguments = arguments
    }
}

struct OAuthBridgeCapabilities: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let supportedOperations: [OAuthBridgeOperation]
    let supportedProviders: [OAuthBridgeProvider]
    let storesCredentials: Bool
}

struct OAuthCLIProbe: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case available
        case missing
        case untrusted
        case incompatible
        case launchFailed
    }

    let provider: OAuthBridgeProvider
    let status: Status
    let version: String?
}

enum OAuthCredentialState: String, Codable, Equatable, Sendable {
    case unknown
    case signedOut
    case signedIn
}

enum OAuthConnectionState: String, Codable, Equatable, Sendable {
    case disconnected
    case authorizing
    case authenticated
    case connected
}

struct OAuthBridgeAuthStatus: Codable, Equatable, Sendable {
    let provider: OAuthBridgeProvider
    let cliStatus: OAuthCLIProbe.Status
    let credentialState: OAuthCredentialState
    let connectionState: OAuthConnectionState
    let loginAttemptID: UUID?
}

struct OAuthBridgeLoginAttempt: Codable, Equatable, Sendable {
    let provider: OAuthBridgeProvider
    let attemptID: UUID
    let authorizationURL: URL?
    let userCode: String?

    init(
        provider: OAuthBridgeProvider,
        attemptID: UUID,
        authorizationURL: URL?,
        userCode: String? = nil
    ) {
        self.provider = provider
        self.attemptID = attemptID
        self.authorizationURL = authorizationURL
        self.userCode = userCode
    }
}

struct OAuthBridgeGeneratedText: Codable, Equatable, Sendable {
    let provider: OAuthBridgeProvider
    let text: String
}

protocol OAuthBridgeServicing: Sendable {
    func authenticationStatus(
        for provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus

    func startLogin(
        for provider: OAuthBridgeProvider,
        method: OAuthBridgeLoginMethod
    ) async throws -> OAuthBridgeLoginAttempt

    func cancelLogin(
        for provider: OAuthBridgeProvider,
        attemptID: UUID
    ) async throws -> OAuthBridgeAuthStatus

    func verifyConnection(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus

    func generateText(
        provider: OAuthBridgeProvider,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String

    func disconnect(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus

    func logout(
        _ provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeAuthStatus
}

extension OAuthBridgeServicing {
    func startLogin(
        for provider: OAuthBridgeProvider
    ) async throws -> OAuthBridgeLoginAttempt {
        try await startLogin(for: provider, method: .browser)
    }
}

struct OAuthBridgeResult: Codable, Equatable, Sendable {
    let capabilities: OAuthBridgeCapabilities?
    let cliProbes: [OAuthCLIProbe]?
    let authStatus: OAuthBridgeAuthStatus?
    let loginAttempt: OAuthBridgeLoginAttempt?
    let generatedText: OAuthBridgeGeneratedText?

    static func capabilities(_ value: OAuthBridgeCapabilities) -> Self {
        Self(
            capabilities: value,
            cliProbes: nil,
            authStatus: nil,
            loginAttempt: nil,
            generatedText: nil
        )
    }

    static func cliProbes(_ value: [OAuthCLIProbe]) -> Self {
        Self(
            capabilities: nil,
            cliProbes: value,
            authStatus: nil,
            loginAttempt: nil,
            generatedText: nil
        )
    }

    static func authenticationStatus(_ value: OAuthBridgeAuthStatus) -> Self {
        Self(
            capabilities: nil,
            cliProbes: nil,
            authStatus: value,
            loginAttempt: nil,
            generatedText: nil
        )
    }

    static func loginAttempt(_ value: OAuthBridgeLoginAttempt) -> Self {
        Self(
            capabilities: nil,
            cliProbes: nil,
            authStatus: nil,
            loginAttempt: value,
            generatedText: nil
        )
    }

    static func generatedText(_ value: OAuthBridgeGeneratedText) -> Self {
        Self(
            capabilities: nil,
            cliProbes: nil,
            authStatus: nil,
            loginAttempt: nil,
            generatedText: value
        )
    }
}

enum OAuthBridgeErrorCode: String, Codable, Sendable {
    case malformedRequest
    case payloadTooLarge
    case protocolMismatch
    case unsupportedOperation
    case invalidArguments
    case cliUnavailable
    case loginAlreadyInProgress
    case loginAttemptMismatch
    case safeVerificationUnavailable
    case authenticationFailed
    case generationFailed
    case internalFailure
}

struct OAuthBridgeErrorPayload: Codable, Equatable, Sendable {
    let code: OAuthBridgeErrorCode
    let message: String
}

struct OAuthBridgeResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: UUID?
    let result: OAuthBridgeResult?
    let error: OAuthBridgeErrorPayload?

    static func success(requestID: UUID, result: OAuthBridgeResult) -> Self {
        Self(
            protocolVersion: OAuthBridgeConstants.protocolVersion,
            requestID: requestID,
            result: result,
            error: nil
        )
    }

    static func failure(
        requestID: UUID?,
        code: OAuthBridgeErrorCode,
        message: String
    ) -> Self {
        Self(
            protocolVersion: OAuthBridgeConstants.protocolVersion,
            requestID: requestID,
            result: nil,
            error: OAuthBridgeErrorPayload(code: code, message: message)
        )
    }
}

enum OAuthBridgeCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= OAuthBridgeConstants.maximumPayloadBytes else {
            throw OAuthBridgeCodecError.payloadTooLarge
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= OAuthBridgeConstants.maximumPayloadBytes else {
            throw OAuthBridgeCodecError.payloadTooLarge
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

enum OAuthBridgeCodecError: Error, Equatable, Sendable {
    case payloadTooLarge
}

enum OAuthBridgeCodeSigning {
    static func designatedRequirement(forCodeAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url.standardizedFileURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement else {
            return nil
        }

        var requirementText: CFString?
        guard SecRequirementCopyString(
            requirement,
            [],
            &requirementText
        ) == errSecSuccess else {
            return nil
        }
        return requirementText as String?
    }

    static func trustedApplicationRequirement(
        forHelperAt helperURL: URL,
        debugContainingApplicationURL: URL?
    ) -> String? {
        guard Bundle(url: helperURL)?.bundleIdentifier == OAuthBridgeConstants.serviceName else {
            return nil
        }

        if let teamIdentifier = teamIdentifier(forCodeAt: helperURL) {
            return "anchor apple generic and identifier \"\(OAuthBridgeConstants.trustedApplicationIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }

#if DEBUG
        guard let debugContainingApplicationURL,
              Bundle(url: debugContainingApplicationURL)?.bundleIdentifier
                == OAuthBridgeConstants.trustedApplicationIdentifier else {
            return nil
        }
        return designatedRequirement(forCodeAt: debugContainingApplicationURL)
#else
        return nil
#endif
    }

    static func trustedHelperRequirement(
        forApplicationAt applicationURL: URL,
        debugHelperURL: URL?
    ) -> String? {
        guard Bundle(url: applicationURL)?.bundleIdentifier
                == OAuthBridgeConstants.trustedApplicationIdentifier else {
            return nil
        }

        if let teamIdentifier = teamIdentifier(forCodeAt: applicationURL) {
            return "anchor apple generic and identifier \"\(OAuthBridgeConstants.serviceName)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }

#if DEBUG
        guard let debugHelperURL,
              let helperBundle = Bundle(url: debugHelperURL),
              helperBundle.bundleIdentifier == OAuthBridgeConstants.serviceName,
              helperBundle.object(forInfoDictionaryKey: "CFBundlePackageType")
                as? String == "XPC!" else {
            return nil
        }
        return designatedRequirement(forCodeAt: debugHelperURL)
#else
        return nil
#endif
    }

    private static func teamIdentifier(forCodeAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url.standardizedFileURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                nil
              ) == errSecSuccess else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              teamIdentifier.count == 10,
              teamIdentifier.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (48...57).contains(byte)
              }) else {
            return nil
        }
        return teamIdentifier
    }
}
