import Foundation

enum GrokEvent: Equatable, Sendable {
    case agentMessageChunk(String)
}

enum GrokACPError: Error, Equatable, Sendable {
    case notInitialized
    case notAuthenticated
    case incompatibleProtocol
    case cachedTokenUnavailable
    case sessionCloseUnavailable
    case unknownSession
    case invalidResponse
    case disallowedUpdate
}

enum GrokVerificationDiagnostic: String, Equatable, Sendable {
    case setupSession = "setup.session"
    case setupTransport = "setup.transport"
    case setupNotificationCount = "setup.notification-count"
    case setupMCPServers = "setup.mcp-servers"
    case setupMCPInitialized = "setup.mcp-initialized"
    case setupCommandsFirst = "setup.commands-1"
    case setupCommandsSecond = "setup.commands-2"
    case setupCommandsEnvelope = "setup.commands-envelope"
    case setupCommandsMetadata = "setup.commands-metadata"
    case setupCommandsOuterKeys = "setup.commands-outer-keys"
    case setupCommandsOuterValues = "setup.commands-outer-values"
    case setupCommandsTimestamp = "setup.commands-timestamp"
    case setupCommandsEventID = "setup.commands-event-id"
    case setupCommandsTotalTokens = "setup.commands-total-tokens"
    case setupCommandsUpdateType = "setup.commands-update-type"
    case setupCommandsCount = "setup.commands-count"
    case setupCommandsInnerMetadata = "setup.commands-inner-meta"
    case setupCommandsTools = "setup.commands-tools"
    case setupCommandsCatalog = "setup.commands-catalog"
    case setupCommandsMismatch = "setup.commands-mismatch"
    case setupModel = "setup.model"
    case promptTransport = "prompt.transport"
    case promptClosed = "prompt.closed"
    case promptIO = "prompt.io"
    case promptProcessExitOne = "prompt.process-exit-1"
    case promptProcessExitTwo = "prompt.process-exit-2"
    case promptProcessExitZero = "prompt.process-exit-zero"
    case promptProcessSignal = "prompt.process-signal"
    case promptProcessReapTimeout = "prompt.process-reap-timeout"
    case promptProtocol = "prompt.protocol"
    case promptTimeout = "prompt.timeout"
    case promptCancelled = "prompt.cancelled"
    case promptRemoteError = "prompt.remote-error"
    case promptUnknownNotification = "prompt.unknown-notification"
    case promptNotificationOverflow = "prompt.notification-overflow"
    case promptStopReason = "prompt.stop-reason"
    case postEnvelope = "post.envelope"
    case postQueueChanged = "post.queue-changed"
    case postPromptCompleteDuplicate = "post.prompt-complete.duplicate"
    case postPromptCompleteKeys = "post.prompt-complete.keys"
    case postPromptCompleteStopReason = "post.prompt-complete.stop-reason"
    case postPromptCompleteAgentResult = "post.prompt-complete.agent-result"
    case postPromptCompleteSessionID = "post.prompt-complete.session-id"
    case postPromptCompletePromptID = "post.prompt-complete.prompt-id"
    case postPromptCompleteTurnID = "post.prompt-complete.turn-id"
    case postPromptCompleteMismatch = "post.prompt-complete.mismatch"
    case postSessionsChanged = "post.sessions-changed"
    case postUserOuterMetadata = "post.user.outer-meta"
    case postUserUpdate = "post.user.update"
    case postUserContent = "post.user.content"
    case postAgentOuterMetadata = "post.agent.outer-meta"
    case postAgentUpdate = "post.agent.update"
    case postAgentContent = "post.agent.content"
    case postThoughtOuterMetadata = "post.thought.outer-meta"
    case postThoughtUpdate = "post.thought.update"
    case postThoughtContent = "post.thought.content"
    case postThoughtBudget = "post.thought.byte-budget"
    case postUnexpectedAvailableCommands = "post.unexpected.available-commands"
    case postUnexpectedConfiguration = "post.unexpected.configuration"
    case postUnexpectedMode = "post.unexpected.mode"
    case postUnexpectedPlan = "post.unexpected.plan"
    case postUnexpectedModel = "post.unexpected.model"
    case postUnexpectedStandard = "post.unexpected.standard"
    case postUnexpectedExtension = "post.unexpected.extension"
    case postResponseStarted = "post.response-started"
    case postReasoningCompleted = "post.reasoning-completed"
    case postResponseCompletedDuplicate = "post.response-completed.duplicate"
    case postResponseCompletedReply = "post.response-completed.reply"
    case postResponseCompletedEnvelope = "post.response-completed.envelope"
    case postResponseCompletedKeys = "post.response-completed.keys"
    case postResponseCompletedMessageID = "post.response-completed.message-id"
    case postResponseCompletedStopReason = "post.response-completed.stop-reason"
    case postResponseCompletedUsage = "post.response-completed.usage"
    case postResponseCompletedSignature = "post.response-completed.signature"
    case postResponseCompletedStopSequence = "post.response-completed.stop-sequence"
    case postTurnCompletedPhase = "post.turn-completed.phase"
    case postTurnCompletedEnvelope = "post.turn-completed.envelope"
    case postTurnCompletedMetadata = "post.turn-completed.metadata"
    case postTurnCompletedKeys = "post.turn-completed.keys"
    case postTurnCompletedPromptID = "post.turn-completed.prompt-id"
    case postTurnCompletedStopReason = "post.turn-completed.stop-reason"
    case postTurnCompletedAgentResult = "post.turn-completed.agent-result"
    case postTurnCompletedUsageType = "post.turn-completed.usage.type"
    case postTurnCompletedUsageKeys = "post.turn-completed.usage.keys"
    case postTurnCompletedUsageValues = "post.turn-completed.usage.values"
    case postTurnCompletedUsageModelEnvelope = "post.turn-completed.usage.model.envelope"
    case postTurnCompletedUsageModelKeys = "post.turn-completed.usage.model.keys"
    case postTurnCompletedUsageModelValues = "post.turn-completed.usage.model.values"
    case postLifecycleResponseCompleted = "post.lifecycle.response-completed"
    case postLifecycleTurnCompleted = "post.lifecycle.turn-completed"
    case postUnexpectedUpdate = "post.unexpected-update"
    case postReply = "post.reply"
    case postPromptEcho = "post.prompt-echo"
    case closeTransport = "close.transport"
    case closeNotificationCount = "close.notification-count"
    case closeSessionsChanged = "close.sessions-changed"
}

actor GrokACPClient {
    static let fixedModelID = "grok-4.6"
    private static let supportedModelIDs: Set<String> = [
        "grok-4.6",
        "grok-4.5"
    ]

    private struct PendingSessionCreation: Sendable {
        let token: UUID
        let task: Task<JSONValue, Error>
    }

    private enum VerificationPostPhase: Equatable {
        case awaitingPromptEcho
        case reasoning
        case awaitingAgentReply
        case receivingAgentReply
        case awaitingTurnCompletion
        case complete
    }

    private static let verificationPrompt = "Reply exactly XUNJIAN_OK. Do not use tools."
    private static let verificationReply = "XUNJIAN_OK"
    private static let maximumPromptBytes = 131_072
    private static let maximumGeneratedTextBytes = 131_072
    private static let maximumThoughtBytes = 65_536
    private static let maximumOpaqueMetadataBytes = 65_536
    private static let sessionCreationTimeoutNanoseconds: UInt64 = 5_000_000_000

    private static let verificationAvailableCommands: [JSONValue] = [
        (
            "compact",
            "Compress conversation history to save context window",
            JSONValue.object(["hint": .string("optional context about what to preserve")])
        ),
        (
            "always-approve",
            "Toggle always-approve mode (skip all permission prompts)",
            JSONValue.object(["hint": .string("on|off")])
        ),
        ("context", "Show context window usage and session stats", JSONValue.null),
        ("session-info", "Show session details (model, turns, context usage)", JSONValue.null),
        (
            "feedback",
            "Send feedback about the current session",
            JSONValue.object(["hint": .string("feedback text")])
        ),
        (
            "goal",
            "Set, manage, or check an autonomous goal",
            JSONValue.object([
                "hint": .string("<objective> [--budget <tokens>] | status | pause | resume | clear")
            ])
        )
    ].map { name, description, input in
        .object([
            "description": .string(description),
            "input": input,
            "name": .string(name)
        ])
    }

    private static let ambientPassiveNotifications: Set<String> = [
        "_x.ai/announcements/update",
        "_x.ai/models/update",
        "_x.ai/settings/update"
    ]

    private static let verificationLifecycleNotifications: Set<String> = [
        "_x.ai/mcp/servers_updated",
        "_x.ai/mcp_initialized",
        "_x.ai/session_notification",
        "x.ai/session_notification",
        "_x.ai/sessions/changed"
    ]

    private static let modelChangedNotificationMethods: Set<String> = [
        "_x.ai/session_notification",
        "x.ai/session_notification"
    ]

    static let allowedNotifications: Set<String> =
        ambientPassiveNotifications
            .union(verificationLifecycleNotifications)
            .union([
                "session/update",
                "x.ai/session/update",
                "_x.ai/session/update",
                "_x.ai/queue/changed",
                "_x.ai/session/prompt_complete"
            ])

    private static let ignoredUpdates: Set<String> = [
        "agent_thought_chunk",
        "config_option_update",
        "current_mode_update",
        "plan",
        "session_info_update",
        "usage_update"
    ]

    private let peer: JSONLineRPCPeer
    private let workingDirectoryURL: URL
    private var isInitialized = false
    private var isAuthenticated = false
    private var authMethodIDs = Set<String>()
    private var ownedSessionIDs = Set<String>()
    private var sessionHistoryIDs = Set<String>()
    private var pendingSessionCreation: PendingSessionCreation?
    private var supportsSessionClose = false
    private var verificationDiagnostic: GrokVerificationDiagnostic?

    init(peer: JSONLineRPCPeer, workingDirectoryURL: URL) {
        self.peer = peer
        self.workingDirectoryURL = workingDirectoryURL
    }

    func initialize() async throws {
        guard !isInitialized else { return }
        let result = try await peer.request(
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false)
                    ]),
                    "terminal": .bool(false)
                ])
            ])
        )
        guard result.objectValue?["protocolVersion"]?.integerValue == 1,
              let methods = result.objectValue?["authMethods"]?.arrayValue else {
            return try await fail(.incompatibleProtocol)
        }
        authMethodIDs = Set(
            methods.compactMap { $0.objectValue?["id"]?.stringValue }
        )
        supportsSessionClose = result.objectValue?["agentCapabilities"]?
            .objectValue?["sessionCapabilities"]?
            .objectValue?["close"]?.objectValue != nil
        isInitialized = true
    }

    func authenticateCachedToken() async throws {
        try requireInitialized()
        guard authMethodIDs.contains("cached_token") else {
            throw GrokACPError.cachedTokenUnavailable
        }
        _ = try await peer.request(
            method: "authenticate",
            params: .object([
                "methodId": .string("cached_token"),
                "_meta": .object(["headless": .bool(true)])
            ])
        )
        isAuthenticated = true
    }

    func newSession() async throws -> String {
        try requireInitialized()
        guard isAuthenticated else { throw GrokACPError.notAuthenticated }
        guard pendingSessionCreation == nil else {
            return try await fail(.invalidResponse)
        }

        let peer = peer
        let workingDirectoryPath = workingDirectoryURL.path
        let token = UUID()
        let requestTask = Task.detached(priority: .userInitiated) {
            try await peer.request(
                method: "session/new",
                params: .object([
                    "cwd": .string(workingDirectoryPath),
                    "mcpServers": .array([])
                ]),
                timeoutNanoseconds: Self.sessionCreationTimeoutNanoseconds
            )
        }
        pendingSessionCreation = PendingSessionCreation(
            token: token,
            task: requestTask
        )

        let result: JSONValue
        do {
            result = try await requestTask.value
        } catch {
            clearPendingSessionCreation(token: token)
            throw error
        }
        clearPendingSessionCreation(token: token)
        guard let sessionID = recordSession(from: result) else {
            return try await fail(.invalidResponse)
        }
        return sessionID
    }

    func prompt(sessionID: String, text: String) async throws -> String {
        try requireInitialized()
        guard ownedSessionIDs.contains(sessionID) else {
            return try await fail(.unknownSession)
        }
        guard !text.isEmpty else { return try await fail(.invalidResponse) }
        let result = try await peer.request(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            ])
        )
        guard let stopReason = result.objectValue?["stopReason"]?.stringValue,
              !stopReason.isEmpty else {
            return try await fail(.invalidResponse)
        }
        return stopReason
    }

    func generateText(prompt: String) async throws -> String {
        try await runStrictPrompt(prompt: prompt, exactReply: nil)
    }

    func verifyMinimalConnection() async throws {
        _ = try await runStrictPrompt(
            prompt: Self.verificationPrompt,
            exactReply: Self.verificationReply
        )
    }

    private func runStrictPrompt(
        prompt: String,
        exactReply: String?
    ) async throws -> String {
        try requireInitialized()
        guard isAuthenticated else { throw GrokACPError.notAuthenticated }
        guard supportsSessionClose else {
            throw GrokACPError.sessionCloseUnavailable
        }
        guard !prompt.isEmpty,
              prompt.utf8.count <= Self.maximumPromptBytes,
              exactReply == nil || (
                exactReply?.isEmpty == false
                    && (exactReply?.utf8.count ?? 0) <= Self.maximumGeneratedTextBytes
              ) else {
            return try await fail(.invalidResponse)
        }
        verificationDiagnostic = nil

        let sessionID: String
        do {
            sessionID = try await newSession()
        } catch {
            recordVerificationTransportFailure(.setupSession, error: error)
            throw error
        }
        do {
            let setupNotifications: [JSONRPCNotification]
            do {
                setupNotifications = try await peer
                    .drainQueuedNotificationsForVerification()
            } catch {
                recordVerificationTransportFailure(.setupTransport, error: error)
                throw error
            }
            let expectedModelID = try validateVerificationSetupNotifications(
                setupNotifications,
                sessionID: sessionID
            )
            let completion: JSONRPCRequestCompletion
            do {
                completion = try await peer.requestAndDrainQueuedNotifications(
                    method: "session/prompt",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "prompt": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(prompt)
                            ])
                        ])
                    ])
                )
            } catch {
                recordVerificationTransportFailure(.promptTransport, error: error)
                throw error
            }
            try Task.checkCancellation()
            guard completion.result.objectValue?["stopReason"]?.stringValue == "end_turn" else {
                try rejectVerification(.promptStopReason, as: .invalidResponse)
            }
            _ = try validateVerificationNotifications(
                completion.queuedNotifications,
                sessionID: sessionID,
                expectedPrompt: prompt,
                exactReply: exactReply,
                expectedModelID: expectedModelID,
                requireCompleteReply: false
            )
            try Task.checkCancellation()
            do {
                try await closeSession(sessionID)
            } catch {
                recordVerificationTransportFailure(.closeTransport, error: error)
                throw error
            }
            let trailingNotifications: [JSONRPCNotification]
            do {
                trailingNotifications = try await peer
                    .drainQueuedNotificationsForVerification()
            } catch {
                recordVerificationTransportFailure(.closeTransport, error: error)
                throw error
            }
            let trailingPostNotifications = try validateVerificationCloseNotifications(
                trailingNotifications,
                sessionID: sessionID
            )
            let completePostNotifications = completion.queuedNotifications
                + trailingPostNotifications
            return try validateVerificationNotifications(
                completePostNotifications,
                sessionID: sessionID,
                expectedPrompt: prompt,
                exactReply: exactReply,
                expectedModelID: expectedModelID,
                requireCompleteReply: true
            )
        } catch is CancellationError {
            // The caller owns runtime teardown from a non-cancelled context.
            throw CancellationError()
        } catch {
            await cleanUpFailedVerification(sessionID: sessionID)
            throw error
        }
    }

    func takeVerificationDiagnostic() -> GrokVerificationDiagnostic? {
        let diagnostic = verificationDiagnostic
        verificationDiagnostic = nil
        return diagnostic
    }

    func nextEvent() async throws -> GrokEvent {
        try requireInitialized()
        while true {
            let notification = try await peer.nextNotification()
            if Self.ambientPassiveNotifications.contains(notification.method) {
                continue
            }
            guard notification.method == "session/update",
                  let params = notification.params?.objectValue,
                  let update = params["update"]?.objectValue,
                  let updateType = update["sessionUpdate"]?.stringValue else {
                return try await fail(.invalidResponse)
            }

            if updateType == "agent_message_chunk" {
                guard let content = update["content"]?.objectValue,
                      content["type"]?.stringValue == "text",
                      let text = content["text"]?.stringValue else {
                    return try await fail(.disallowedUpdate)
                }
                guard let sessionID = params["sessionId"]?.stringValue,
                      ownedSessionIDs.contains(sessionID) else {
                    return try await fail(.unknownSession)
                }
                return .agentMessageChunk(text)
            }

            if Self.ignoredUpdates.contains(updateType) {
                guard let sessionID = params["sessionId"]?.stringValue,
                      ownedSessionIDs.contains(sessionID) else {
                    return try await fail(.unknownSession)
                }
                continue
            }
            return try await fail(.disallowedUpdate)
        }
    }

    func cancel(sessionID: String) async throws {
        try requireInitialized()
        guard ownedSessionIDs.contains(sessionID) else {
            return try await fail(.unknownSession)
        }
        try await peer.notify(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        )
    }

    func closeSession(_ sessionID: String) async throws {
        try requireInitialized()
        guard ownedSessionIDs.contains(sessionID) else {
            return try await fail(.unknownSession)
        }
        guard supportsSessionClose else {
            throw GrokACPError.sessionCloseUnavailable
        }
        _ = try await peer.request(
            method: "session/close",
            params: .object(["sessionId": .string(sessionID)])
        )
        ownedSessionIDs.remove(sessionID)
    }

    func close() async {
        if let pendingSessionCreation {
            if let result = try? await pendingSessionCreation.task.value {
                _ = recordSession(from: result)
            }
            clearPendingSessionCreation(token: pendingSessionCreation.token)
        }
        isInitialized = false
        isAuthenticated = false
        authMethodIDs.removeAll()
        ownedSessionIDs.removeAll()
        supportsSessionClose = false
        await peer.close()
    }

    func takeSessionHistoryIDs() -> [String] {
        let identifiers = sessionHistoryIDs.sorted()
        sessionHistoryIDs.removeAll()
        return identifiers
    }

    private func requireInitialized() throws {
        guard isInitialized else { throw GrokACPError.notInitialized }
    }

    private func clearPendingSessionCreation(token: UUID) {
        guard pendingSessionCreation?.token == token else { return }
        pendingSessionCreation = nil
    }

    private func recordSession(from result: JSONValue) -> String? {
        guard let sessionID = result.objectValue?["sessionId"]?.stringValue,
              !sessionID.isEmpty else {
            return nil
        }
        ownedSessionIDs.insert(sessionID)
        sessionHistoryIDs.insert(sessionID)
        return sessionID
    }

    private func validateVerificationSetupNotifications(
        _ notifications: [JSONRPCNotification],
        sessionID: String
    ) throws -> String {
        let lifecycle = notifications.filter {
            !Self.ambientPassiveNotifications.contains($0.method)
        }
        guard lifecycle.count == 5 else {
            try rejectVerification(.setupNotificationCount, as: .invalidResponse)
        }

        try validateEmptyMCPServers(
            lifecycle[0],
            diagnostic: .setupMCPServers
        )
        try validateMCPInitialized(
            lifecycle[1],
            sessionID: sessionID,
            diagnostic: .setupMCPInitialized
        )
        let firstCommands = try validateAvailableCommands(
            lifecycle[2],
            sessionID: sessionID,
            diagnostic: .setupCommandsFirst
        )
        let secondCommands = try validateAvailableCommands(
            lifecycle[3],
            sessionID: sessionID,
            diagnostic: .setupCommandsSecond
        )
        guard firstCommands == secondCommands else {
            try rejectVerification(.setupCommandsMismatch, as: .disallowedUpdate)
        }
        return try validateModelChanged(lifecycle[4], sessionID: sessionID)
    }

    private func validateVerificationCloseNotifications(
        _ notifications: [JSONRPCNotification],
        sessionID: String
    ) throws -> [JSONRPCNotification] {
        let lifecycle = notifications.filter {
            !Self.ambientPassiveNotifications.contains($0.method)
        }
        var closeNotificationCount = 0
        var trailingPostNotifications: [JSONRPCNotification] = []
        for notification in lifecycle {
            if notification.method == "_x.ai/sessions/changed",
               let removed = notification.params?.objectValue?["removed"]?.arrayValue,
               !removed.isEmpty {
                try validateSessionsChanged(notification, sessionID: sessionID)
                closeNotificationCount += 1
            } else {
                trailingPostNotifications.append(notification)
            }
        }
        guard closeNotificationCount == 1 else {
            try rejectVerification(.closeNotificationCount, as: .invalidResponse)
        }
        return trailingPostNotifications
    }

    private func validateEmptyMCPServers(
        _ notification: JSONRPCNotification,
        diagnostic: GrokVerificationDiagnostic
    ) throws {
        guard notification.method == "_x.ai/mcp/servers_updated",
              let params = notification.params?.objectValue,
              Set(params.keys) == ["mcpServers"],
              params["mcpServers"]?.arrayValue?.isEmpty == true else {
            try rejectVerification(diagnostic, as: .disallowedUpdate)
        }
    }

    private func validateMCPInitialized(
        _ notification: JSONRPCNotification,
        sessionID: String,
        diagnostic: GrokVerificationDiagnostic
    ) throws {
        guard notification.method == "_x.ai/mcp_initialized",
              let params = notification.params?.objectValue,
              Set(params.keys) == ["elapsedMs", "mcpToolCount", "sessionId"],
              params["sessionId"]?.stringValue == sessionID,
              params["mcpToolCount"]?.integerValue == 0,
              let elapsed = params["elapsedMs"],
              Self.isNonnegativeNumber(elapsed) else {
            try rejectVerification(diagnostic, as: .disallowedUpdate)
        }
    }

    private func validateAvailableCommands(
        _ notification: JSONRPCNotification,
        sessionID: String,
        diagnostic _: GrokVerificationDiagnostic,
        expectedPromptID: String? = nil
    ) throws -> [JSONValue] {
        guard notification.method == "session/update",
              let params = notification.params?.objectValue,
              Set(params.keys) == ["_meta", "sessionId", "update"],
              params["sessionId"]?.stringValue == sessionID,
              let update = params["update"]?.objectValue,
              Set(update.keys) == ["_meta", "availableCommands", "sessionUpdate"],
              update["sessionUpdate"]?.stringValue == "available_commands_update",
              let commands = update["availableCommands"]?.arrayValue else {
            try rejectVerification(.setupCommandsEnvelope, as: .disallowedUpdate)
        }
        let baseOuterKeys: Set<String> = [
            "agentTimestampMs",
            "eventId",
            "totalTokens",
            "updateParams",
            "updateType"
        ]
        let turnOuterKeys: Set<String> = ["promptId", "streamStartMs", "turnStartMs"]
        guard let outerMetadata = params["_meta"]?.objectValue else {
            try rejectVerification(.setupCommandsOuterKeys, as: .disallowedUpdate)
        }
        let actualOuterKeys = Set(outerMetadata.keys)
        let extraOuterKeys = actualOuterKeys.subtracting(baseOuterKeys)
        guard baseOuterKeys.isSubset(of: actualOuterKeys),
              extraOuterKeys.isSubset(of: turnOuterKeys),
              expectedPromptID == nil ? extraOuterKeys.isEmpty : true else {
            try rejectVerification(.setupCommandsOuterKeys, as: .disallowedUpdate)
        }
        if !extraOuterKeys.isEmpty {
            guard let expectedPromptID,
                  outerMetadata["promptId"]?.stringValue == expectedPromptID,
                  outerMetadata["streamStartMs"] == nil
                    || (outerMetadata["streamStartMs"]?.integerValue ?? 0) > 0,
                  outerMetadata["turnStartMs"] == nil
                    || (outerMetadata["turnStartMs"]?.integerValue ?? 0) > 0 else {
                try rejectVerification(.setupCommandsOuterValues, as: .disallowedUpdate)
            }
        }
        guard let timestamp = outerMetadata["agentTimestampMs"]?.integerValue,
              timestamp > 0 else {
            try rejectVerification(.setupCommandsTimestamp, as: .disallowedUpdate)
        }
        guard let eventID = outerMetadata["eventId"]?.stringValue,
              !eventID.isEmpty else {
            try rejectVerification(.setupCommandsEventID, as: .disallowedUpdate)
        }
        guard let totalTokens = outerMetadata["totalTokens"],
              Self.isNonnegativeNumber(totalTokens) else {
            try rejectVerification(.setupCommandsTotalTokens, as: .disallowedUpdate)
        }
        guard outerMetadata["updateType"]?.stringValue == "AvailableCommandsUpdate" else {
            try rejectVerification(.setupCommandsUpdateType, as: .disallowedUpdate)
        }
        guard let updateParams = outerMetadata["updateParams"]?.objectValue,
              Set(updateParams.keys) == ["commandsCount"],
              updateParams["commandsCount"]?.integerValue == Int64(commands.count) else {
            try rejectVerification(.setupCommandsCount, as: .disallowedUpdate)
        }
        guard let updateMetadata = update["_meta"]?.objectValue,
              Set(updateMetadata.keys) == ["tools"] else {
            try rejectVerification(.setupCommandsInnerMetadata, as: .disallowedUpdate)
        }
        guard updateMetadata["tools"]?.arrayValue?.isEmpty == true else {
            try rejectVerification(.setupCommandsTools, as: .disallowedUpdate)
        }
        guard commands == Self.verificationAvailableCommands else {
            try rejectVerification(.setupCommandsCatalog, as: .disallowedUpdate)
        }
        return commands
    }

    private func validateModelChanged(
        _ notification: JSONRPCNotification,
        sessionID: String
    ) throws -> String {
        guard Self.modelChangedNotificationMethods.contains(notification.method),
              let params = notification.params?.objectValue,
              Set(params.keys) == ["sessionId", "update"],
              params["sessionId"]?.stringValue == sessionID,
              let update = params["update"]?.objectValue,
              Set(update.keys) == ["model_id", "reasoning_effort", "sessionUpdate"],
              update["sessionUpdate"]?.stringValue == "model_changed",
              let modelID = update["model_id"]?.stringValue,
              Self.supportedModelIDs.contains(modelID),
              update["reasoning_effort"]?.stringValue == "high" else {
            try rejectVerification(.setupModel, as: .invalidResponse)
        }
        return modelID
    }

    private func validateSessionsChanged(
        _ notification: JSONRPCNotification,
        sessionID: String
    ) throws {
        guard notification.method == "_x.ai/sessions/changed",
              let params = notification.params?.objectValue,
              Set(params.keys) == ["removed", "upserted"],
              params["upserted"]?.arrayValue?.isEmpty == true,
              let removed = params["removed"]?.arrayValue,
              removed.count == 1,
              removed[0].stringValue == sessionID else {
            try rejectVerification(.closeSessionsChanged, as: .invalidResponse)
        }
    }

    private static func isNonnegativeNumber(_ value: JSONValue) -> Bool {
        switch value {
        case let .integer(number): number >= 0
        case let .number(number): number.isFinite && number >= 0
        case .object, .array, .string, .bool, .null: false
        }
    }

    private static func isValidSessionTitle(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if value == .null { return true }
        guard let title = value.stringValue else { return false }
        return !title.isEmpty && title.utf8.count <= 256
    }

    private func validateVerificationNotifications(
        _ notifications: [JSONRPCNotification],
        sessionID: String,
        expectedPrompt: String,
        exactReply: String?,
        expectedModelID: String,
        requireCompleteReply: Bool
    ) throws -> String {
        var reply = ""
        var replyBytes = 0
        let maximumReplyBytes = exactReply?.utf8.count
            ?? Self.maximumGeneratedTextBytes
        var echoedPrompt = ""
        var echoedPromptBytes = 0
        let maximumPromptBytes = expectedPrompt.utf8.count
        var thoughtBytes = 0
        var promptID: String?
        var responseMessageID: String?
        var promptCompleteAgentResult: String?
        var sawPromptComplete = false
        var sawResponseStarted = false
        var sawReasoningCompleted = false
        var sawResponseCompleted = false
        var sawTurnCompleted = false
        var phase = VerificationPostPhase.awaitingPromptEcho

        for notification in notifications {
            if Self.ambientPassiveNotifications.contains(notification.method) {
                continue
            }
            if notification.method == "_x.ai/session/prompt_complete" {
                guard !sawPromptComplete else {
                    try rejectVerification(.postPromptCompleteDuplicate, as: .disallowedUpdate)
                }
                let completed = try validatePromptCompleteNotification(
                    notification.params,
                    sessionID: sessionID
                )
                if let completedPromptID = completed.promptID {
                    try mergePromptID(completedPromptID, into: &promptID)
                }
                promptCompleteAgentResult = completed.agentResult
                sawPromptComplete = true
                continue
            }
            if notification.method == "_x.ai/queue/changed" {
                guard let params = notification.params?.objectValue,
                      params["sessionId"]?.stringValue == sessionID,
                      let entries = params["entries"]?.arrayValue else {
                    try rejectVerification(.postQueueChanged, as: .disallowedUpdate)
                }
                if Set(params.keys) == ["entries", "sessionId"] {
                    guard entries.count <= 1 else {
                        try rejectVerification(.postQueueChanged, as: .disallowedUpdate)
                    }
                } else if Set(params.keys) == [
                    "entries",
                    "runningKind",
                    "runningPromptId",
                    "runningText",
                    "sessionId"
                ] {
                    guard entries.isEmpty,
                          params["runningKind"]?.stringValue == "prompt",
                          let promptIdentifier = params["runningPromptId"]?.stringValue,
                          UUID(uuidString: promptIdentifier) != nil,
                          let runningText = params["runningText"]?.stringValue,
                          !runningText.isEmpty,
                          runningText.utf8.count <= Self.maximumPromptBytes else {
                        try rejectVerification(.postQueueChanged, as: .disallowedUpdate)
                    }
                } else {
                    try rejectVerification(.postQueueChanged, as: .disallowedUpdate)
                }
                if Set(params.keys) == ["entries", "sessionId"],
                   let entryValue = entries.first {
                    guard let entry = entryValue.objectValue,
                          Set(entry.keys) == [
                            "id", "kind", "position", "text", "version"
                          ],
                          let identifier = entry["id"]?.stringValue,
                          UUID(uuidString: identifier) != nil,
                          entry["kind"]?.stringValue == "prompt",
                          (entry["position"]?.integerValue ?? -1) >= 0,
                          let text = entry["text"]?.stringValue,
                          !text.isEmpty,
                          text.utf8.count <= Self.maximumPromptBytes,
                          (entry["version"]?.integerValue ?? -1) >= 0 else {
                        try rejectVerification(.postQueueChanged, as: .disallowedUpdate)
                    }
                }
                continue
            }
            if notification.method == "_x.ai/sessions/changed" {
                guard let params = notification.params?.objectValue,
                      Set(params.keys) == ["removed", "upserted"],
                      params["removed"]?.arrayValue?.isEmpty == true,
                      let upserted = params["upserted"]?.arrayValue,
                      upserted.count == 1,
                      let session = upserted[0].objectValue,
                      Set(session.keys) == [
                        "activity",
                        "cwd",
                        "isWorktree",
                        "lastChangeUnixMs",
                        "modelId",
                        "origin",
                        "reasoningEffort",
                        "resident",
                        "sessionId",
                        "title",
                        "yolo"
                      ],
                      session["sessionId"]?.stringValue == sessionID,
                      session["cwd"]?.stringValue == workingDirectoryURL.path,
                      session["modelId"]?.stringValue == expectedModelID,
                      session["reasoningEffort"]?.stringValue == "high",
                      session["isWorktree"]?.boolValue == false,
                      session["yolo"]?.boolValue == false,
                      session["resident"]?.boolValue != nil,
                      (session["lastChangeUnixMs"]?.integerValue ?? -1) >= 0,
                      let activity = session["activity"]?.stringValue,
                      !activity.isEmpty,
                      activity.utf8.count <= 32,
                      let origin = session["origin"]?.objectValue,
                      Set(origin.keys) == ["kind"],
                      let originKind = origin["kind"]?.stringValue,
                      !originKind.isEmpty,
                      originKind.utf8.count <= 32,
                      Self.isValidSessionTitle(session["title"]) else {
                    try rejectVerification(.postSessionsChanged, as: .disallowedUpdate)
                }
                continue
            }
            if ["session/update", "x.ai/session/update", "_x.ai/session/update"]
                .contains(notification.method) {
                guard let params = notification.params?.objectValue,
                      params["sessionId"]?.stringValue == sessionID,
                      let update = params["update"]?.objectValue,
                      let updateType = update["sessionUpdate"]?.stringValue else {
                    try rejectVerification(.postEnvelope, as: .invalidResponse)
                }
                switch updateType {
                case "available_commands_update":
                    _ = try validateAvailableCommands(
                        notification,
                        sessionID: sessionID,
                        diagnostic: .postUnexpectedAvailableCommands,
                        expectedPromptID: promptID
                    )
                case "usage_update":
                    try validateUsageUpdate(params: params, update: update)
                case "session_info_update":
                    try validateSessionInfoUpdate(params: params, update: update)
                case "agent_message_chunk":
                    let chunk = try validateAgentChunk(
                        params: params,
                        update: update,
                        expectedUpdateType: "AgentMessageChunk",
                        updateDiagnostic: .postAgentUpdate,
                        contentDiagnostic: .postAgentContent,
                        metadataDiagnostic: .postAgentOuterMetadata,
                        requireChunkIdentifier: false
                    )
                    guard phase == .awaitingPromptEcho
                            || phase == .reasoning
                            || phase == .awaitingAgentReply
                            || phase == .receivingAgentReply else {
                        try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
                    }
                    try mergePromptID(chunk.promptID, into: &promptID)
                    let chunkBytes = chunk.text.utf8.count
                    guard chunkBytes <= maximumReplyBytes - replyBytes else {
                        try rejectVerification(.postReply, as: .invalidResponse)
                    }
                    reply.append(chunk.text)
                    replyBytes += chunkBytes
                    if let exactReply, !exactReply.hasPrefix(reply) {
                        try rejectVerification(.postReply, as: .invalidResponse)
                    }
                    if phase == .awaitingAgentReply {
                        phase = .receivingAgentReply
                    }
                case "user_message_chunk":
                    let text = try validateUserMessageChunk(
                        params: params,
                        update: update,
                        expectedModelID: expectedModelID
                    )
                    guard phase == .awaitingPromptEcho else {
                        try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
                    }
                    let chunkBytes = text.utf8.count
                    guard chunkBytes <= maximumPromptBytes - echoedPromptBytes else {
                        try rejectVerification(.postPromptEcho, as: .invalidResponse)
                    }
                    echoedPrompt.append(text)
                    echoedPromptBytes += chunkBytes
                    guard expectedPrompt.hasPrefix(echoedPrompt) else {
                        try rejectVerification(.postPromptEcho, as: .invalidResponse)
                    }
                case "agent_thought_chunk":
                    let chunk = try validateAgentChunk(
                        params: params,
                        update: update,
                        expectedUpdateType: "AgentThoughtChunk",
                        updateDiagnostic: .postThoughtUpdate,
                        contentDiagnostic: .postThoughtContent,
                        metadataDiagnostic: .postThoughtOuterMetadata,
                        requireChunkIdentifier: true
                    )
                    guard [
                        .awaitingPromptEcho,
                        .reasoning,
                        .awaitingAgentReply,
                        .receivingAgentReply,
                        .awaitingTurnCompletion,
                        .complete
                    ].contains(phase) else {
                        try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
                    }
                    try mergePromptID(chunk.promptID, into: &promptID)
                    guard chunk.text.utf8.count <= Self.maximumThoughtBytes - thoughtBytes else {
                        try rejectVerification(.postThoughtBudget, as: .invalidResponse)
                    }
                    thoughtBytes += chunk.text.utf8.count
                default:
                    let diagnostic: GrokVerificationDiagnostic = switch updateType {
                    case "available_commands_update": .postUnexpectedAvailableCommands
                    case "config_option_update": .postUnexpectedConfiguration
                    case "current_mode_update": .postUnexpectedMode
                    case "plan": .postUnexpectedPlan
                    default: .postUnexpectedStandard
                    }
                    try rejectVerification(diagnostic, as: .disallowedUpdate)
                }
                continue
            }

            guard ["_x.ai/session_notification", "x.ai/session_notification"]
                    .contains(notification.method),
                  let params = notification.params?.objectValue,
                  params["sessionId"]?.stringValue == sessionID,
                  let update = params["update"]?.objectValue,
                  let updateType = update["sessionUpdate"]?.stringValue else {
                try rejectVerification(.postEnvelope, as: .invalidResponse)
            }
            switch updateType {
            case "session_summary_generated":
                guard Set(params.keys) == ["sessionId", "update"],
                      Set(update.keys) == ["sessionUpdate", "session_summary"],
                      let summary = update["session_summary"]?.stringValue,
                      !summary.isEmpty,
                      summary.utf8.count <= 512 else {
                    try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
                }
            case "last_turn_summary":
                let requiredKeys: Set<String> = ["sessionUpdate", "summary"]
                let allowedKeys = requiredKeys.union(["prompt_id"])
                guard Set(params.keys) == ["sessionId", "update"],
                      requiredKeys.isSubset(of: Set(update.keys)),
                      Set(update.keys).isSubset(of: allowedKeys),
                      let summary = update["summary"]?.stringValue,
                      !summary.isEmpty,
                      summary.utf8.count <= 512,
                      update["prompt_id"] == nil
                        || (promptID != nil
                            && update["prompt_id"]?.stringValue == promptID) else {
                    try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
                }
            case "response_started":
                guard !sawResponseStarted,
                      echoedPrompt == expectedPrompt else {
                    try rejectVerification(.postResponseStarted, as: .disallowedUpdate)
                }
                responseMessageID = try validateResponseStarted(
                    params: params,
                    update: update,
                    expectedModelID: expectedModelID,
                    existingMessageID: responseMessageID
                )
                sawResponseStarted = true
                if !sawResponseCompleted && !sawTurnCompleted {
                    phase = reply.isEmpty ? .reasoning : .receivingAgentReply
                }
            case "reasoning_completed":
                guard !sawReasoningCompleted,
                      echoedPrompt == expectedPrompt else {
                    try rejectVerification(.postReasoningCompleted, as: .disallowedUpdate)
                }
                try validateReasoningCompleted(params: params, update: update)
                sawReasoningCompleted = true
                if !sawResponseCompleted && !sawTurnCompleted {
                    phase = reply.isEmpty ? .awaitingAgentReply : .receivingAgentReply
                }
            case "response_completed":
                guard !sawResponseCompleted else {
                    try rejectVerification(.postResponseCompletedDuplicate, as: .disallowedUpdate)
                }
                guard !reply.isEmpty,
                      exactReply == nil || reply == exactReply else {
                    try rejectVerification(.postResponseCompletedReply, as: .disallowedUpdate)
                }
                responseMessageID = try validateResponseCompleted(
                    params: params,
                    update: update,
                    existingMessageID: responseMessageID
                )
                sawResponseCompleted = true
                if !sawTurnCompleted {
                    phase = .awaitingTurnCompletion
                }
            case "turn_completed":
                guard !sawTurnCompleted,
                      !reply.isEmpty,
                      exactReply == nil || reply == exactReply,
                      let streamedPromptID = promptID else {
                    try rejectVerification(.postTurnCompletedPhase, as: .disallowedUpdate)
                }
                let completedPromptID = try validateTurnCompleted(
                    params: params,
                    update: update,
                    expectedAgentResult: reply
                )
                guard completedPromptID == streamedPromptID else {
                    try rejectVerification(.postTurnCompletedPromptID, as: .disallowedUpdate)
                }
                sawTurnCompleted = true
                phase = .complete
            default:
                let diagnostic: GrokVerificationDiagnostic = switch updateType {
                case "model_changed", "model_auto_switched": .postUnexpectedModel
                default: .postUnexpectedExtension
                }
                try rejectVerification(diagnostic, as: .disallowedUpdate)
            }
        }

        if requireCompleteReply {
            guard echoedPrompt == expectedPrompt else {
                try rejectVerification(.postPromptEcho, as: .invalidResponse)
            }
            guard !reply.isEmpty,
                  exactReply == nil || reply == exactReply else {
                try rejectVerification(.postReply, as: .invalidResponse)
            }
            guard sawResponseCompleted else {
                try rejectVerification(.postLifecycleResponseCompleted, as: .invalidResponse)
            }
            guard sawTurnCompleted, phase == .complete else {
                try rejectVerification(.postLifecycleTurnCompleted, as: .invalidResponse)
            }
            if let promptCompleteAgentResult {
                guard promptCompleteAgentResult == reply else {
                    try rejectVerification(.postPromptCompleteMismatch, as: .invalidResponse)
                }
            }
        }
        return reply
    }

    private func validatePromptCompleteNotification(
        _ value: JSONValue?,
        sessionID: String
    ) throws -> (promptID: String?, agentResult: String?) {
        let requiredKeys: Set<String> = ["agentResult", "stopReason"]
        let allowedKeys = requiredKeys.union(["promptId", "sessionId", "turnId"])
        guard let params = value?.objectValue,
              requiredKeys.isSubset(of: Set(params.keys)),
              Set(params.keys).isSubset(of: allowedKeys) else {
            try rejectVerification(.postPromptCompleteKeys, as: .disallowedUpdate)
        }
        guard params["stopReason"]?.stringValue == "end_turn" else {
            try rejectVerification(.postPromptCompleteStopReason, as: .disallowedUpdate)
        }
        let agentResult: String?
        if params["agentResult"] == .null {
            agentResult = nil
        } else {
            guard let text = params["agentResult"]?.stringValue,
                  !text.isEmpty,
                  text.utf8.count <= Self.maximumGeneratedTextBytes else {
                try rejectVerification(.postPromptCompleteAgentResult, as: .disallowedUpdate)
            }
            agentResult = text
        }
        if let reportedSessionID = params["sessionId"] {
            guard reportedSessionID.stringValue == sessionID else {
                try rejectVerification(.postPromptCompleteSessionID, as: .disallowedUpdate)
            }
        }
        let promptID = params["promptId"]?.stringValue
        if params["promptId"] != nil {
            guard let promptID,
                  !promptID.isEmpty,
                  promptID.utf8.count <= 256 else {
                try rejectVerification(.postPromptCompletePromptID, as: .disallowedUpdate)
            }
        }
        if let turnID = params["turnId"] {
            guard let identifier = turnID.stringValue,
                  !identifier.isEmpty,
                  identifier.utf8.count <= 256 else {
                try rejectVerification(.postPromptCompleteTurnID, as: .disallowedUpdate)
            }
        }
        return (promptID, agentResult)
    }

    private func validateUserMessageChunk(
        params: [String: JSONValue],
        update: [String: JSONValue],
        expectedModelID: String
    ) throws -> String {
        guard Set(params.keys) == ["_meta", "sessionId", "update"],
              let outerMetadata = params["_meta"]?.objectValue,
              Set(outerMetadata.keys) == ["agentTimestampMs", "eventId"],
              let timestamp = outerMetadata["agentTimestampMs"]?.integerValue,
              timestamp > 0,
              let eventID = outerMetadata["eventId"]?.stringValue,
              !eventID.isEmpty else {
            try rejectVerification(.postUserOuterMetadata, as: .disallowedUpdate)
        }
        guard Set(update.keys) == ["_meta", "content", "sessionUpdate"],
              let chunkMetadata = update["_meta"]?.objectValue,
              Set(chunkMetadata.keys) == ["modelId", "promptIndex"],
              chunkMetadata["modelId"]?.stringValue == expectedModelID,
              let promptIndex = chunkMetadata["promptIndex"]?.integerValue,
              promptIndex >= 0 else {
            try rejectVerification(.postUserUpdate, as: .disallowedUpdate)
        }
        guard let content = update["content"]?.objectValue,
              Set(content.keys) == ["text", "type"],
              content["type"]?.stringValue == "text",
              let text = content["text"]?.stringValue else {
            try rejectVerification(.postUserContent, as: .disallowedUpdate)
        }
        return text
    }

    private func validateUsageUpdate(
        params: [String: JSONValue],
        update: [String: JSONValue]
    ) throws {
        let requiredKeys: Set<String> = ["sessionUpdate", "size", "used"]
        let allowedKeys = requiredKeys.union(["cost"])
        guard Set(params.keys) == ["sessionId", "update"],
              requiredKeys.isSubset(of: Set(update.keys)),
              Set(update.keys).isSubset(of: allowedKeys),
              let used = update["used"]?.integerValue,
              let size = update["size"]?.integerValue,
              used >= 0,
              size > 0,
              used <= size else {
            try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
        }
        guard let costValue = update["cost"] else { return }
        guard let cost = costValue.objectValue,
              Set(cost.keys) == ["amount", "currency"],
              let amount = cost["amount"],
              Self.isNonnegativeNumber(amount),
              let currency = cost["currency"]?.stringValue,
              currency.utf8.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
        }
    }

    private func validateSessionInfoUpdate(
        params: [String: JSONValue],
        update: [String: JSONValue]
    ) throws {
        let requiredKeys: Set<String> = ["sessionUpdate", "title"]
        let allowedKeys = requiredKeys.union(["updatedAt"])
        guard Set(params.keys) == ["sessionId", "update"],
              requiredKeys.isSubset(of: Set(update.keys)),
              Set(update.keys).isSubset(of: allowedKeys),
              let title = update["title"]?.stringValue,
              !title.isEmpty,
              title.utf8.count <= 256 else {
            try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
        }
        guard let updatedAt = update["updatedAt"] else { return }
        guard let timestamp = updatedAt.stringValue,
              !timestamp.isEmpty,
              timestamp.utf8.count <= 64,
              ISO8601DateFormatter().date(from: timestamp) != nil else {
            try rejectVerification(.postUnexpectedUpdate, as: .disallowedUpdate)
        }
    }

    private func validateAgentChunk(
        params: [String: JSONValue],
        update: [String: JSONValue],
        expectedUpdateType: String,
        updateDiagnostic: GrokVerificationDiagnostic,
        contentDiagnostic: GrokVerificationDiagnostic,
        metadataDiagnostic: GrokVerificationDiagnostic,
        requireChunkIdentifier: Bool
    ) throws -> (text: String, promptID: String) {
        guard Set(params.keys) == ["_meta", "sessionId", "update"],
              let metadata = params["_meta"]?.objectValue,
              let promptID = validateStreamingMetadata(
                metadata,
                expectedUpdateType: expectedUpdateType,
                requireChunkIdentifier: requireChunkIdentifier
              ) else {
            try rejectVerification(metadataDiagnostic, as: .disallowedUpdate)
        }
        guard Set(update.keys) == ["content", "sessionUpdate"] else {
            try rejectVerification(updateDiagnostic, as: .disallowedUpdate)
        }
        guard let content = update["content"]?.objectValue,
              Set(content.keys) == ["text", "type"],
              content["type"]?.stringValue == "text",
              let text = content["text"]?.stringValue else {
            try rejectVerification(contentDiagnostic, as: .disallowedUpdate)
        }
        return (text, promptID)
    }

    private func validateStreamingMetadata(
        _ metadata: [String: JSONValue],
        expectedUpdateType: String,
        requireChunkIdentifier: Bool
    ) -> String? {
        let baseKeys: Set<String> = [
            "agentTimestampMs",
            "eventId",
            "promptId",
            "streamStartMs",
            "totalTokens",
            "turnStartMs",
            "updateType"
        ]
        let extraKeys = Set(metadata.keys).subtracting(baseKeys)
        let hasValidChunkIdentifier: Bool
        if extraKeys == ["chunkId"] {
            hasValidChunkIdentifier = (metadata["chunkId"]?.integerValue ?? -1) >= 0
        } else if extraKeys == ["chunkIdRange"] {
            hasValidChunkIdentifier = Self.isValidChunkIDRange(metadata["chunkIdRange"])
        } else {
            hasValidChunkIdentifier = extraKeys.isEmpty && !requireChunkIdentifier
        }
        guard hasValidChunkIdentifier,
              let timestamp = metadata["agentTimestampMs"]?.integerValue,
              timestamp > 0,
              let eventID = metadata["eventId"]?.stringValue,
              !eventID.isEmpty,
              let promptID = metadata["promptId"]?.stringValue,
              !promptID.isEmpty,
              let streamStart = metadata["streamStartMs"]?.integerValue,
              streamStart > 0,
              let turnStart = metadata["turnStartMs"]?.integerValue,
              turnStart > 0,
              let totalTokens = metadata["totalTokens"]?.integerValue,
              totalTokens >= 0,
              metadata["updateType"]?.stringValue == expectedUpdateType else {
            return nil
        }
        return promptID
    }

    private static func isValidChunkIDRange(_ value: JSONValue?) -> Bool {
        guard let values = value?.arrayValue, !values.isEmpty else { return false }
        return values.allSatisfy { item in
            if let identifier = item.integerValue {
                return identifier >= 0
            }
            guard let pair = item.arrayValue,
                  pair.count == 2,
                  let lower = pair[0].integerValue,
                  let upper = pair[1].integerValue else {
                return false
            }
            return lower >= 0 && upper >= lower
        }
    }

    private func validateResponseStarted(
        params: [String: JSONValue],
        update: [String: JSONValue],
        expectedModelID: String,
        existingMessageID: String?
    ) throws -> String {
        guard Set(params.keys) == ["sessionId", "update"],
              Set(update.keys) == [
                "cache_creation_input_tokens",
                "cache_read_input_tokens",
                "input_tokens",
                "message_id",
                "model",
                "sessionUpdate"
              ],
              let messageID = update["message_id"]?.stringValue,
              !messageID.isEmpty,
              existingMessageID == nil || existingMessageID == messageID,
              update["model"]?.stringValue == expectedModelID,
              Self.hasNonnegativeIntegers(
                update,
                keys: [
                    "cache_creation_input_tokens",
                    "cache_read_input_tokens",
                    "input_tokens"
                ]
              ) else {
            try rejectVerification(.postResponseStarted, as: .disallowedUpdate)
        }
        return messageID
    }

    private func validateReasoningCompleted(
        params: [String: JSONValue],
        update: [String: JSONValue]
    ) throws {
        guard Set(params.keys) == ["sessionId", "update"],
              Set(update.keys) == ["sessionUpdate", "signature"],
              let signature = update["signature"]?.stringValue,
              !signature.isEmpty,
              signature.utf8.count <= Self.maximumOpaqueMetadataBytes else {
            try rejectVerification(.postReasoningCompleted, as: .disallowedUpdate)
        }
    }

    private func validateResponseCompleted(
        params: [String: JSONValue],
        update: [String: JSONValue],
        existingMessageID: String?
    ) throws -> String? {
        let requiredKeys: Set<String> = ["sessionUpdate"]
        let allowedKeys = requiredKeys.union([
            "message_id", "signature", "stop_reason", "stop_sequence", "usage"
        ])
        guard Set(params.keys) == ["sessionId", "update"] else {
            try rejectVerification(.postResponseCompletedEnvelope, as: .disallowedUpdate)
        }
        guard requiredKeys.isSubset(of: Set(update.keys)),
              Set(update.keys).isSubset(of: allowedKeys) else {
            try rejectVerification(.postResponseCompletedKeys, as: .disallowedUpdate)
        }
        var messageID = existingMessageID
        if let messageIDValue = update["message_id"] {
            guard let completedMessageID = messageIDValue.stringValue,
                  !completedMessageID.isEmpty,
                  existingMessageID == nil || existingMessageID == completedMessageID else {
                try rejectVerification(.postResponseCompletedMessageID, as: .disallowedUpdate)
            }
            messageID = completedMessageID
        }
        if let stopReason = update["stop_reason"] {
            guard stopReason.stringValue == "end_turn" else {
                try rejectVerification(.postResponseCompletedStopReason, as: .disallowedUpdate)
            }
        }
        guard Self.isValidResponseUsage(update["usage"]) else {
            try rejectVerification(.postResponseCompletedUsage, as: .disallowedUpdate)
        }
        guard Self.isValidOptionalOpaqueString(update["signature"]) else {
            try rejectVerification(.postResponseCompletedSignature, as: .disallowedUpdate)
        }
        guard update["stop_sequence"] == nil
                || update["stop_sequence"] == .null
                || Self.isValidOptionalOpaqueString(update["stop_sequence"]) else {
            try rejectVerification(.postResponseCompletedStopSequence, as: .disallowedUpdate)
        }
        return messageID
    }

    private func validateTurnCompleted(
        params: [String: JSONValue],
        update: [String: JSONValue],
        expectedAgentResult: String
    ) throws -> String {
        let requiredKeys: Set<String> = ["prompt_id", "sessionUpdate", "stop_reason"]
        let allowedKeys = requiredKeys.union(["agent_result", "usage"])
        let requiredParamKeys: Set<String> = ["sessionId", "update"]
        let allowedParamKeys = requiredParamKeys.union(["_meta"])
        guard requiredParamKeys.isSubset(of: Set(params.keys)),
              Set(params.keys).isSubset(of: allowedParamKeys) else {
            try rejectVerification(.postTurnCompletedEnvelope, as: .disallowedUpdate)
        }
        guard requiredKeys.isSubset(of: Set(update.keys)),
              Set(update.keys).isSubset(of: allowedKeys) else {
            try rejectVerification(.postTurnCompletedKeys, as: .disallowedUpdate)
        }
        guard let promptID = update["prompt_id"]?.stringValue,
              !promptID.isEmpty else {
            try rejectVerification(.postTurnCompletedPromptID, as: .disallowedUpdate)
        }
        guard update["stop_reason"]?.stringValue == "end_turn" else {
            try rejectVerification(.postTurnCompletedStopReason, as: .disallowedUpdate)
        }
        guard update["agent_result"] == nil
                || update["agent_result"]?.stringValue == expectedAgentResult else {
            try rejectVerification(.postTurnCompletedAgentResult, as: .disallowedUpdate)
        }
        try validateTurnUsage(update["usage"])
        if let metadataValue = params["_meta"] {
            guard let metadata = metadataValue.objectValue,
                  Set(metadata.keys) == ["agentTimestampMs", "eventId"],
                  let timestamp = metadata["agentTimestampMs"]?.integerValue,
                  timestamp > 0,
                  let eventID = metadata["eventId"]?.stringValue,
                  !eventID.isEmpty else {
                try rejectVerification(.postTurnCompletedMetadata, as: .disallowedUpdate)
            }
        }
        return promptID
    }

    private func validateTurnUsage(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let usage = value.objectValue else {
            try rejectVerification(.postTurnCompletedUsageType, as: .disallowedUpdate)
        }
        let responseComponentKeys: Set<String> = [
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
            "input_tokens",
            "output_tokens",
            "reasoning_tokens"
        ]
        let actualKeys = Set(usage.keys)
        if responseComponentKeys.isSubset(of: actualKeys) {
            guard Self.isValidResponseUsage(value) else {
                try rejectVerification(.postTurnCompletedUsageValues, as: .disallowedUpdate)
            }
            return
        }
        let promptNumericKeys: Set<String> = [
            "apiDurationMs",
            "cacheCreationTokens",
            "cachedReadTokens",
            "inputTokens",
            "modelCalls",
            "numTurns",
            "outputTokens",
            "reasoningTokens",
            "totalTokens"
        ]
        let promptAllowedKeys = promptNumericKeys.union([
            "costIsPartial",
            "costUsdTicks",
            "modelUsage",
            "usageIsIncomplete"
        ])
        guard promptNumericKeys.isSubset(of: actualKeys),
              actualKeys.isSubset(of: promptAllowedKeys) else {
            try rejectVerification(.postTurnCompletedUsageKeys, as: .disallowedUpdate)
        }
        if usage["modelUsage"] != nil {
            var usageWithoutModel = usage
            usageWithoutModel.removeValue(forKey: "modelUsage")
            guard Self.isValidPromptUsage(.object(usageWithoutModel)) else {
                try rejectVerification(.postTurnCompletedUsageValues, as: .disallowedUpdate)
            }
            guard let modelUsage = usage["modelUsage"]?.objectValue,
                  modelUsage.count == 1,
                  let modelEntry = modelUsage.first,
                  !modelEntry.key.isEmpty,
                  modelEntry.key.utf8.count <= 128,
                  let model = modelEntry.value.objectValue else {
                try rejectVerification(.postTurnCompletedUsageModelEnvelope, as: .disallowedUpdate)
            }
            let fullNumericKeys = promptNumericKeys.subtracting(["numTurns"])
            let fullAllowedKeys = fullNumericKeys.union(["costIsPartial", "costUsdTicks"])
            let reducedNumericKeys: Set<String> = [
                "cacheCreationInputTokens",
                "cacheReadInputTokens",
                "inputTokens",
                "modelCalls",
                "outputTokens"
            ]
            let reducedAllowedKeys = reducedNumericKeys.union(["costUSD"])
            let modelKeys = Set(model.keys)
            let isFullShape = fullNumericKeys.isSubset(of: modelKeys)
                && modelKeys.isSubset(of: fullAllowedKeys)
            let isReducedShape = reducedNumericKeys.isSubset(of: modelKeys)
                && modelKeys.isSubset(of: reducedAllowedKeys)
            guard isFullShape || isReducedShape else {
                try rejectVerification(.postTurnCompletedUsageModelKeys, as: .disallowedUpdate)
            }
            guard Self.isValidPromptUsage(value) else {
                try rejectVerification(.postTurnCompletedUsageModelValues, as: .disallowedUpdate)
            }
            return
        }
        guard Self.isValidPromptUsage(value) else {
            try rejectVerification(.postTurnCompletedUsageValues, as: .disallowedUpdate)
        }
    }

    private static func isValidResponseUsage(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard let usage = value.objectValue else { return false }
        let componentKeys: Set<String> = [
                "cache_creation_input_tokens",
                "cache_read_input_tokens",
                "input_tokens",
                "output_tokens",
                "reasoning_tokens"
        ]
        // Sanity bound instead of exact key-set and sum equality: real
        // accounting conventions differ on whether reasoning/cache tokens
        // are included in total_tokens (and extra keys appear), and strict
        // equality made verification reject valid traffic whenever the
        // server's reporting drifted. Every present component must be a
        // non-negative integer, and the components may never exceed the
        // total; anything else is accepted.
        guard hasNonnegativeIntegers(usage, keys: componentKeys) else {
            return false
        }
        guard let totalTokens = usage["total_tokens"]?.integerValue else {
            return usage["total_tokens"] == nil
        }
        guard totalTokens >= 0 else { return false }
        var sum: Int64 = 0
        for key in componentKeys {
            guard let value = usage[key]?.integerValue, value >= 0 else { continue }
            let (result, overflow) = sum.addingReportingOverflow(value)
            guard !overflow else { return false }
            sum = result
        }
        return sum <= totalTokens
    }

    private static func isValidPromptUsage(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard let usage = value.objectValue else { return false }
        let numericKeys: Set<String> = [
            "apiDurationMs",
            "cacheCreationTokens",
            "cachedReadTokens",
            "inputTokens",
            "modelCalls",
            "numTurns",
            "outputTokens",
            "reasoningTokens",
            "totalTokens"
        ]
        let allowedKeys = numericKeys.union([
            "costIsPartial",
            "costUsdTicks",
            "modelUsage",
            "usageIsIncomplete"
        ])
        guard numericKeys.isSubset(of: Set(usage.keys)),
              Set(usage.keys).isSubset(of: allowedKeys),
              hasNonnegativeIntegers(usage, keys: numericKeys),
              usage["costUsdTicks"] == nil
                || (usage["costUsdTicks"]?.integerValue ?? -1) >= 0,
              usage["costIsPartial"] == nil || usage["costIsPartial"]?.boolValue != nil,
              usage["usageIsIncomplete"] == nil
                || usage["usageIsIncomplete"]?.boolValue != nil else {
            return false
        }
        guard let modelUsageValue = usage["modelUsage"] else { return true }
        guard let modelUsage = modelUsageValue.objectValue,
              modelUsage.count == 1,
              let modelEntry = modelUsage.first,
              !modelEntry.key.isEmpty,
              modelEntry.key.utf8.count <= 128,
              let model = modelEntry.value.objectValue else {
            return false
        }
        let modelNumericKeys = numericKeys.subtracting(["numTurns"])
        let modelAllowedKeys = modelNumericKeys.union(["costIsPartial", "costUsdTicks"])
        let isValidFullModel = modelNumericKeys.isSubset(of: Set(model.keys))
            && Set(model.keys).isSubset(of: modelAllowedKeys)
            && hasNonnegativeIntegers(model, keys: modelNumericKeys)
            && (model["costUsdTicks"] == nil
                || (model["costUsdTicks"]?.integerValue ?? -1) >= 0)
            && (model["costIsPartial"] == nil || model["costIsPartial"]?.boolValue != nil)
        if isValidFullModel { return true }
        let reducedNumericKeys: Set<String> = [
            "cacheCreationInputTokens",
            "cacheReadInputTokens",
            "inputTokens",
            "modelCalls",
            "outputTokens"
        ]
        let reducedAllowedKeys = reducedNumericKeys.union(["costUSD"])
        return reducedNumericKeys.isSubset(of: Set(model.keys))
            && Set(model.keys).isSubset(of: reducedAllowedKeys)
            && hasNonnegativeIntegers(model, keys: reducedNumericKeys)
            && isValidOptionalNonnegativeNumber(model["costUSD"])
    }

    private static func isValidOptionalNonnegativeNumber(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        switch value {
        case let .integer(number): return number >= 0
        case let .number(number): return number.isFinite && number >= 0
        case .object, .array, .string, .bool, .null: return false
        }
    }

    private static func hasNonnegativeIntegers(
        _ object: [String: JSONValue],
        keys: Set<String>
    ) -> Bool {
        keys.allSatisfy { (object[$0]?.integerValue ?? -1) >= 0 }
    }

    private static func isValidOptionalOpaqueString(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard let text = value.stringValue else { return false }
        return !text.isEmpty && text.utf8.count <= maximumOpaqueMetadataBytes
    }

    private func mergePromptID(_ candidate: String, into promptID: inout String?) throws {
        guard promptID == nil || promptID == candidate else {
            try rejectVerification(.postEnvelope, as: .invalidResponse)
        }
        promptID = candidate
    }

    private func recordVerificationTransportFailure(
        _ diagnostic: GrokVerificationDiagnostic,
        error: Error
    ) {
        guard !(error is CancellationError) else { return }
        if diagnostic == .promptTransport,
           let transportError = error as? JSONLineRPCError {
            verificationDiagnostic = switch transportError {
            case .closed: .promptClosed
            case .transportFailure: .promptIO
            case let .transportProcessExited(code):
                if code == -1 {
                    .promptProcessReapTimeout
                } else if code == 0 {
                    .promptProcessExitZero
                } else if code == 1 {
                    .promptProcessExitOne
                } else if code == 2 {
                    .promptProcessExitTwo
                } else if code >= 128 {
                    .promptProcessSignal
                } else {
                    .promptIO
                }
            case .requestTimedOut: .promptTimeout
            case .requestCancelled: .promptCancelled
            case .remoteError: .promptRemoteError
            case .unknownNotification: .promptUnknownNotification
            case .notificationOverflow: .promptNotificationOverflow
            case .malformedMessage,
                 .messageTooLarge,
                 .invalidDialect,
                 .invalidEnvelope,
                 .invalidState,
                 .serverRequestRejected,
                 .unknownResponseIdentifier,
                 .duplicateResponseIdentifier: .promptProtocol
            }
            return
        }
        verificationDiagnostic = diagnostic
    }

    private func rejectVerification(
        _ diagnostic: GrokVerificationDiagnostic,
        as error: GrokACPError
    ) throws -> Never {
        verificationDiagnostic = diagnostic
        throw error
    }

    private func cleanUpFailedVerification(sessionID: String) async {
        guard !Task.isCancelled else { return }
        try? await cancel(sessionID: sessionID)
        try? await closeSession(sessionID)
    }

    private func fail<T>(_ error: GrokACPError) async throws -> T {
        await peer.close()
        throw error
    }
}
