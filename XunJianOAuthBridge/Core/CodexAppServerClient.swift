import Foundation

enum CodexAccountState: Equatable, Sendable {
    case signedOut(requiresOpenAIAuth: Bool)
    case signedIn(type: String, requiresOpenAIAuth: Bool, planType: String?)
}

struct CodexLoginAttempt: Equatable, Sendable {
    let loginID: String
    let authorizationURL: URL
    let userCode: String?

    init(
        loginID: String,
        authorizationURL: URL,
        userCode: String? = nil
    ) {
        self.loginID = loginID
        self.authorizationURL = authorizationURL
        self.userCode = userCode
    }
}

enum CodexAuthEvent: Equatable, Sendable {
    case loginCompleted(loginID: String, success: Bool)
    case accountUpdated(authMode: String?, planType: String?)
}

struct CodexModel: Equatable, Sendable {
    let id: String
    let isDefault: Bool
}

enum CodexEvent: Equatable, Sendable {
    case agentMessage(String)
    case agentMessageDelta(String)
    case turnCompleted(status: String)
}

enum CodexAppServerError: Error, Equatable, Sendable {
    case notInitialized
    case restrictedReadUnavailable
    case invalidResponse
    case loginAlreadyActive
    case unknownLogin
    case unknownThread
    case unknownTurn
    case disallowedItem
}

enum CodexRestrictedReadSupport: Sendable {
    case unsupported
    case supported
}

actor CodexAppServerClient {
    private static let maximumGeneratedTextBytes = 131_072
    static let optedOutNotifications: Set<String> = [
        "account/rateLimits/updated",
        "app/list/updated",
        "command/exec/outputDelta",
        "configWarning",
        "deprecationNotice",
        "error",
        "externalAgentConfig/import/completed",
        "externalAgentConfig/import/progress",
        "fs/changed",
        "fuzzyFileSearch/sessionCompleted",
        "fuzzyFileSearch/sessionUpdated",
        "guardianWarning",
        "hook/completed",
        "hook/started",
        "item/autoApprovalReview/completed",
        "item/autoApprovalReview/started",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "item/plan/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "mcpServer/oauthLogin/completed",
        "mcpServer/startupStatus/updated",
        "model/rerouted",
        "model/safetyBuffering/updated",
        "model/verification",
        "process/exited",
        "process/outputDelta",
        "remoteControl/status/changed",
        "serverRequest/resolved",
        "skills/changed",
        "thread/archived",
        "thread/closed",
        "thread/compacted",
        "thread/deleted",
        "thread/environment/connected",
        "thread/environment/disconnected",
        "thread/goal/cleared",
        "thread/goal/updated",
        "thread/name/updated",
        "thread/realtime/closed",
        "thread/realtime/error",
        "thread/realtime/itemAdded",
        "thread/realtime/outputAudio/delta",
        "thread/realtime/sdp",
        "thread/realtime/started",
        "thread/realtime/transcript/delta",
        "thread/realtime/transcript/done",
        "thread/settings/updated",
        "thread/tokenUsage/updated",
        "thread/unarchived",
        "turn/diff/updated",
        "turn/moderationMetadata",
        "turn/plan/updated",
        "warning",
        "windows/worldWritableWarning",
        "windowsSandbox/setupCompleted"
    ]

    static let allowedNotifications: Set<String> = [
        "account/login/completed",
        "account/updated",
        "thread/started",
        "thread/status/changed",
        "turn/started",
        "turn/completed",
        "item/started",
        "item/completed",
        "item/agentMessage/delta"
    ]

    private static let safeItemTypes: Set<String> = [
        "agentMessage",
        "reasoning",
        "userMessage"
    ]

    private let peer: JSONLineRPCPeer
    private let workingDirectoryURL: URL
    private let restrictedReadSupport: CodexRestrictedReadSupport
    private var isInitialized = false
    private var activeLoginID: String?
    private var listedModelIDs = Set<String>()
    private var ownedThreadIDs = Set<String>()
    private var turnThreadIDs: [String: String] = [:]

    init(
        peer: JSONLineRPCPeer,
        workingDirectoryURL: URL,
        restrictedReadSupport: CodexRestrictedReadSupport = .unsupported
    ) {
        self.peer = peer
        self.workingDirectoryURL = workingDirectoryURL
        self.restrictedReadSupport = restrictedReadSupport
    }

    func initialize() async throws {
        guard !isInitialized else { return }
        _ = try await peer.request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("xunjian"),
                    "title": .string("XunJian"),
                    "version": .string("0.1.0")
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(false),
                    "optOutNotificationMethods": .array(
                        Self.optedOutNotifications.sorted().map(JSONValue.string)
                    )
                ])
            ])
        )
        try await peer.notify(method: "initialized")
        isInitialized = true
    }

    func readAccount() async throws -> CodexAccountState {
        try requireInitialized()
        let result = try await peer.request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        guard let object = result.objectValue,
              let requiresOpenAIAuth = object["requiresOpenaiAuth"]?.boolValue,
              let account = object["account"] else {
            return try await fail(.invalidResponse)
        }
        if account == .null {
            return .signedOut(requiresOpenAIAuth: requiresOpenAIAuth)
        }
        guard let accountObject = account.objectValue,
              let type = accountObject["type"]?.stringValue,
              !type.isEmpty else {
            return try await fail(.invalidResponse)
        }
        let planType: String?
        if let value = accountObject["planType"], value != .null {
            guard let parsedPlanType = value.stringValue,
                  !parsedPlanType.isEmpty else {
                return try await fail(.invalidResponse)
            }
            planType = parsedPlanType
        } else {
            planType = nil
        }
        return .signedIn(
            type: type,
            requiresOpenAIAuth: requiresOpenAIAuth,
            planType: planType
        )
    }

    func logout() async throws {
        try requireInitialized()
        let result = try await peer.request(
            method: "account/logout",
            params: .null
        )
        guard result == .object([:]) || result == .null else {
            return try await fail(.invalidResponse)
        }
    }

    func startChatGPTLogin() async throws -> CodexLoginAttempt {
        try requireInitialized()
        guard activeLoginID == nil else {
            throw CodexAppServerError.loginAlreadyActive
        }
        let result = try await peer.request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("chatgpt")
            ])
        )
        guard let object = result.objectValue,
              object["type"]?.stringValue == "chatgpt",
              let loginID = object["loginId"]?.stringValue,
              Self.validIdentifier(loginID, maximumBytes: 256),
              let authorizationURLString = object["authUrl"]?.stringValue,
              let authorizationURL = Self.validHTTPSURL(authorizationURLString),
              object["verificationUrl"] == nil,
              object["userCode"] == nil else {
            return try await fail(.invalidResponse)
        }
        activeLoginID = loginID
        return CodexLoginAttempt(
            loginID: loginID,
            authorizationURL: authorizationURL
        )
    }

    func startChatGPTDeviceCodeLogin() async throws -> CodexLoginAttempt {
        try requireInitialized()
        guard activeLoginID == nil else {
            throw CodexAppServerError.loginAlreadyActive
        }
        let result = try await peer.request(
            method: "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")])
        )
        guard let object = result.objectValue,
              object["type"]?.stringValue == "chatgptDeviceCode",
              let loginID = object["loginId"]?.stringValue,
              Self.validIdentifier(loginID, maximumBytes: 256),
              let verificationURLString = object["verificationUrl"]?.stringValue,
              let verificationURL = Self.validHTTPSURL(verificationURLString),
              let userCode = object["userCode"]?.stringValue,
              Self.validUserCode(userCode),
              object["authUrl"] == nil else {
            return try await fail(.invalidResponse)
        }
        activeLoginID = loginID
        return CodexLoginAttempt(
            loginID: loginID,
            authorizationURL: verificationURL,
            userCode: userCode
        )
    }

    func cancelLogin(loginID: String) async throws {
        try requireInitialized()
        guard !loginID.isEmpty, activeLoginID == loginID else {
            return try await fail(.unknownLogin)
        }
        _ = try await peer.request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)])
        )
    }

    func nextAuthEvent() async throws -> CodexAuthEvent {
        try requireInitialized()
        let notification = try await peer.nextNotification()
        guard let params = notification.params?.objectValue else {
            return try await fail(.invalidResponse)
        }

        switch notification.method {
        case "account/login/completed":
            guard let loginID = params["loginId"]?.stringValue,
                  !loginID.isEmpty else {
                return try await fail(.invalidResponse)
            }
            guard activeLoginID == loginID else {
                return try await fail(.unknownLogin)
            }
            guard let success = params["success"]?.boolValue else {
                return try await fail(.invalidResponse)
            }
            activeLoginID = nil
            return .loginCompleted(loginID: loginID, success: success)

        case "account/updated":
            let authMode: String?
            if let value = params["authMode"], value != .null {
                guard let parsedAuthMode = value.stringValue,
                      !parsedAuthMode.isEmpty else {
                    return try await fail(.invalidResponse)
                }
                authMode = parsedAuthMode
            } else {
                authMode = nil
            }

            let planType: String?
            if let value = params["planType"], value != .null {
                guard let parsedPlanType = value.stringValue,
                      !parsedPlanType.isEmpty else {
                    return try await fail(.invalidResponse)
                }
                planType = parsedPlanType
            } else {
                planType = nil
            }
            return .accountUpdated(authMode: authMode, planType: planType)

        default:
            return try await fail(.invalidResponse)
        }
    }

    func listModels() async throws -> [CodexModel] {
        try requireInitialized()
        var models: [CodexModel] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var seenModelIDs = Set<String>()

        for _ in 0..<20 {
            var params: [String: JSONValue] = ["limit": .integer(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await peer.request(
                method: "model/list",
                params: .object(params)
            )
            guard let resultObject = result.objectValue,
                  let values = resultObject["data"]?.arrayValue else {
                return try await fail(.invalidResponse)
            }

            for value in values {
                guard let object = value.objectValue,
                      let identifier = object["id"]?.stringValue
                        ?? object["model"]?.stringValue,
                      !identifier.isEmpty,
                      seenModelIDs.insert(identifier).inserted else {
                    return try await fail(.invalidResponse)
                }
                models.append(
                    CodexModel(
                        id: identifier,
                        isDefault: object["isDefault"]?.boolValue ?? false
                    )
                )
            }

            guard let nextCursorValue = resultObject["nextCursor"],
                  nextCursorValue != .null else {
                cursor = nil
                break
            }
            guard let nextCursor = nextCursorValue.stringValue,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                return try await fail(.invalidResponse)
            }
            cursor = nextCursor
        }
        if cursor != nil {
            return try await fail(.invalidResponse)
        }
        listedModelIDs = Set(models.map(\.id))
        return models
    }

    func startEphemeralThread(model: String?) async throws -> String {
        try requireInitialized()
        let disabledToolFeatures = [
            "apps",
            "browser_use",
            "code_mode_host",
            "computer_use",
            "image_generation",
            "in_app_browser",
            "multi_agent",
            "plugins",
            "remote_plugin",
            "shell_snapshot",
            "shell_tool",
            "tool_suggest",
            "unified_exec",
            "view_image"
        ]
        var params: [String: JSONValue] = [
            "ephemeral": .bool(true),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "cwd": .string(workingDirectoryURL.path),
            "serviceName": .string("xunjian"),
            "baseInstructions": .string(
                "Return only the requested text. Never use tools, commands, files, apps, plugins, or web search."
            ),
            "developerInstructions": .string(
                "This is a text-only request. Do not inspect the filesystem or invoke any tool."
            ),
            "config": .object([
                "web_search": .string("disabled"),
                "features": .object(
                    Dictionary(uniqueKeysWithValues: disabledToolFeatures.map { ($0, .bool(false)) })
                )
            ])
        ]
        if let model, listedModelIDs.contains(model) {
            params["model"] = .string(model)
        }

        let result = try await peer.request(
            method: "thread/start",
            params: .object(params)
        )
        guard let threadID = result.objectValue?["thread"]?
            .objectValue?["id"]?.stringValue,
              !threadID.isEmpty else {
            return try await fail(.invalidResponse)
        }
        ownedThreadIDs.insert(threadID)
        return threadID
    }

    func startTextTurn(threadID: String, text: String) async throws -> String {
        try requireInitialized()
        guard case .supported = restrictedReadSupport else {
            return try await fail(.restrictedReadUnavailable)
        }
        guard ownedThreadIDs.contains(threadID) else {
            return try await fail(.unknownThread)
        }
        guard !text.isEmpty else { return try await fail(.invalidResponse) }
        let result = try await peer.request(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "cwd": .string(workingDirectoryURL.path),
                "approvalPolicy": .string("never"),
                "sandboxPolicy": .object([
                    "type": .string("readOnly"),
                    "networkAccess": .bool(false)
                ]),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            ])
        )
        guard let turnID = result.objectValue?["turn"]?
            .objectValue?["id"]?.stringValue,
              !turnID.isEmpty else {
            return try await fail(.invalidResponse)
        }
        turnThreadIDs[turnID] = threadID
        return turnID
    }

    func generateText(model: String?, prompt: String) async throws -> String {
        try requireInitialized()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maximumGeneratedTextBytes,
              !prompt.contains("\0") else {
            throw CodexAppServerError.invalidResponse
        }

        let models = try await listModels()
        if let model, !models.contains(where: { $0.id == model }) {
            throw CodexAppServerError.invalidResponse
        }

        let threadID = try await startEphemeralThread(model: model)
        var turnID: String?
        var didComplete = false
        do {
            let startedTurnID = try await startTextTurn(
                threadID: threadID,
                text: prompt
            )
            turnID = startedTurnID

            var deltas = ""
            var finalMessage: String?
            while true {
                switch try await nextEvent() {
                case let .agentMessageDelta(delta):
                    guard finalMessage == nil,
                          deltas.utf8.count + delta.utf8.count
                            <= Self.maximumGeneratedTextBytes else {
                        throw CodexAppServerError.invalidResponse
                    }
                    deltas += delta

                case let .agentMessage(message):
                    guard finalMessage == nil,
                          Self.generatedTextIsValid(message),
                          deltas.isEmpty || deltas == message else {
                        throw CodexAppServerError.invalidResponse
                    }
                    finalMessage = message

                case let .turnCompleted(status):
                    guard status == "completed",
                          let finalMessage,
                          deltas.isEmpty || deltas == finalMessage else {
                        throw CodexAppServerError.invalidResponse
                    }
                    didComplete = true
                    return finalMessage
                }
            }
        } catch {
            if !didComplete, let turnID {
                try? await interrupt(threadID: threadID, turnID: turnID)
            }
            throw error
        }
    }

    func nextEvent() async throws -> CodexEvent {
        try requireInitialized()
        while true {
            let notification = try await peer.nextNotification()
            switch notification.method {
            case "item/agentMessage/delta":
                let params = try await requireOwnedTurnEvent(notification.params)
                guard let delta = params["delta"]?.stringValue else {
                    return try await fail(.invalidResponse)
                }
                return .agentMessageDelta(delta)

            case "item/started":
                let params = try await requireOwnedTurnEvent(notification.params)
                guard let item = params["item"]?.objectValue,
                      let type = item["type"]?.stringValue else {
                    return try await fail(.invalidResponse)
                }
                guard Self.safeItemTypes.contains(type) else {
                    return try await fail(.disallowedItem)
                }

            case "item/completed":
                let params = try await requireOwnedTurnEvent(notification.params)
                guard let item = params["item"]?.objectValue,
                      let type = item["type"]?.stringValue else {
                    return try await fail(.invalidResponse)
                }
                guard Self.safeItemTypes.contains(type) else {
                    return try await fail(.disallowedItem)
                }
                if type == "agentMessage", let text = Self.agentMessageText(from: item) {
                    return .agentMessage(text)
                }

            case "turn/completed":
                let params = try await requireOwnedTurnEvent(notification.params)
                guard let turn = params["turn"]?.objectValue,
                      let turnID = turn["id"]?.stringValue,
                      let status = turn["status"]?.stringValue else {
                    return try await fail(.invalidResponse)
                }
                turnThreadIDs.removeValue(forKey: turnID)
                return .turnCompleted(status: status)

            case "thread/started", "thread/status/changed":
                _ = try await requireOwnedThreadEvent(notification.params)
                continue

            case "turn/started":
                _ = try await requireOwnedTurnEvent(notification.params)
                continue

            default:
                return try await fail(.invalidResponse)
            }
        }
    }

    func interrupt(threadID: String, turnID: String) async throws {
        try requireInitialized()
        guard ownedThreadIDs.contains(threadID) else {
            return try await fail(.unknownThread)
        }
        guard turnThreadIDs[turnID] == threadID else {
            return try await fail(.unknownTurn)
        }
        _ = try await peer.request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    func close() async {
        isInitialized = false
        activeLoginID = nil
        listedModelIDs.removeAll()
        ownedThreadIDs.removeAll()
        turnThreadIDs.removeAll()
        await peer.close()
    }

    private static func generatedTextIsValid(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= maximumGeneratedTextBytes
            && !text.contains("\0")
    }

    private func requireInitialized() throws {
        guard isInitialized else { throw CodexAppServerError.notInitialized }
    }

    private func requireOwnedThreadEvent(
        _ value: JSONValue?
    ) async throws -> [String: JSONValue] {
        guard let params = value?.objectValue else {
            return try await fail(.invalidResponse)
        }
        let threadID = params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue
        guard let threadID, ownedThreadIDs.contains(threadID) else {
            return try await fail(.unknownThread)
        }
        return params
    }

    private func requireOwnedTurnEvent(
        _ value: JSONValue?
    ) async throws -> [String: JSONValue] {
        let params = try await requireOwnedThreadEvent(value)
        let turnID = params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
        guard let turnID,
              let threadID = params["threadId"]?.stringValue
                ?? params["thread"]?.objectValue?["id"]?.stringValue,
              turnThreadIDs[turnID] == threadID else {
            return try await fail(.unknownTurn)
        }
        return params
    }

    private func fail<T>(_ error: CodexAppServerError) async throws -> T {
        activeLoginID = nil
        await peer.close()
        throw error
    }

    private static func validHTTPSURL(_ rawValue: String) -> URL? {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 2_048,
              rawValue.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              ["auth.openai.com", "chatgpt.com"].contains(host.lowercased()),
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                $0.value >= 0x21 && $0.value <= 0x7E
            }
    }

    private static func validUserCode(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        return (4...64).contains(byteCount)
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 0x30 && $0.value <= 0x39)
                    || ($0.value >= 0x41 && $0.value <= 0x5A)
                    || $0.value == 0x2D
            }
    }

    private static func agentMessageText(from item: [String: JSONValue]) -> String? {
        if let text = item["text"]?.stringValue {
            return text
        }
        guard let content = item["content"]?.arrayValue else { return nil }
        let parts = content.compactMap { value -> String? in
            guard let object = value.objectValue,
                  object["type"]?.stringValue == "text" else {
                return nil
            }
            return object["text"]?.stringValue
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
