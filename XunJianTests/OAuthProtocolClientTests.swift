#if XUNJIAN_FAKE_JSONL_SERVER
import Darwin
import Foundation

@main
private enum FakeJSONLServerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.dropFirst().first ?? "echo"

        switch mode {
        case "crash":
            exit(17)
        case "ignore-term":
            signal(SIGTERM, SIG_IGN)
            while true { pause() }
        case "leader-exits-child-holds-pipes":
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--mode", "ignore-term"]
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.standardError
            do {
                try child.run()
            } catch {
                exit(71)
            }
            let payload = "{\"childPID\":\(child.processIdentifier)}\n"
            FileHandle.standardOutput.write(Data(payload.utf8))
            exit(0)
        case "leader-exits-double-fork":
            let intermediate = Process()
            intermediate.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            intermediate.arguments = ["--mode", "double-fork-middle"]
            intermediate.standardOutput = FileHandle.standardOutput
            intermediate.standardError = FileHandle.standardError
            do {
                try intermediate.run()
            } catch {
                exit(71)
            }
            exit(0)
        case "double-fork-middle":
            guard let grandchildPID = spawnDetachedGrandchild() else { exit(71) }
            let payload = "{\"childPID\":\(grandchildPID)}\n"
            FileHandle.standardOutput.write(Data(payload.utf8))
            exit(0)
        case "stderr-flood":
            FileHandle.standardError.write(Data(repeating: 88, count: 2_000_000))
            runEcho(fragmented: false)
        case "fragmented":
            runEcho(fragmented: true)
        default:
            runEcho(fragmented: false)
        }
    }

    private static func runEcho(fragmented: Bool) {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let identifier = object["id"] else {
                continue
            }
            let response: [String: Any] = ["id": identifier, "result": ["ok": true]]
            guard var encoded = try? JSONSerialization.data(withJSONObject: response) else {
                continue
            }
            encoded.append(0x0A)
            if fragmented, encoded.count > 2 {
                let midpoint = encoded.count / 2
                FileHandle.standardOutput.write(encoded.prefix(midpoint))
                usleep(20_000)
                FileHandle.standardOutput.write(encoded.suffix(from: midpoint))
            } else {
                FileHandle.standardOutput.write(encoded)
            }
        }
    }

    private static func spawnDetachedGrandchild() -> pid_t? {
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else { return nil }

        let path = CommandLine.arguments[0]
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup(path),
            strdup("--mode"),
            strdup("ignore-term"),
            nil
        ]
        defer {
            for argument in arguments.dropLast() { free(argument) }
        }
        var identifier = pid_t()
        let result = path.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                posix_spawn(
                    &identifier,
                    executable,
                    nil,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environ
                )
            }
        }
        return result == 0 ? identifier : nil
    }
}
#else
import Darwin
import Foundation
import XCTest
@testable import XunJian

private actor ScriptedLineTransport: JSONLineTransport {
    private var incoming: [Data?] = []
    private var incomingWaiters: [CheckedContinuation<Data?, Never>] = []
    private var outgoing: [Data] = []
    private var outgoingWaiters: [CheckedContinuation<Data, Never>] = []
    private(set) var isClosed = false

    func writeLine(_ data: Data) async throws {
        if let waiter = outgoingWaiters.first {
            outgoingWaiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            outgoing.append(data)
        }
    }

    func readLine() async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { incomingWaiters.append($0) }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let waiters = incomingWaiters
        incomingWaiters.removeAll()
        waiters.forEach { $0.resume(returning: nil) }
    }

    func nextClientObject() async throws -> JSONValue {
        let data: Data
        if !outgoing.isEmpty {
            data = outgoing.removeFirst()
        } else {
            data = await withCheckedContinuation { outgoingWaiters.append($0) }
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func sendServerObject(_ value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        sendServerData(data)
    }

    func sendServerData(_ data: Data) {
        if let waiter = incomingWaiters.first {
            incomingWaiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }

    func queuedOutgoingCount() -> Int {
        outgoing.count
    }
}

private actor AsyncSignal {
    private var didFire = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if didFire { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        guard !didFire else { return }
        didFire = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }

    func hasFired() -> Bool {
        didFire
    }
}

private func serveGrokHandshake(
    on transport: ScriptedLineTransport,
    supportsSessionClose: Bool = true
) async throws {
    let initialize = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(initialize["method"], .string("initialize"))
    var result: [String: JSONValue] = [
        "protocolVersion": .integer(1),
        "authMethods": .array([.object(["id": .string("cached_token")])])
    ]
    if supportsSessionClose {
        result["agentCapabilities"] = .object([
            "sessionCapabilities": .object(["close": .object([:])])
        ])
    }
    try await transport.sendServerObject(.object([
        "jsonrpc": .string("2.0"),
        "id": initialize["id"]!,
        "result": .object(result)
    ]))

    let authenticate = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(authenticate["method"], .string("authenticate"))
    try await transport.sendServerObject(.object([
        "jsonrpc": .string("2.0"),
        "id": authenticate["id"]!,
        "result": .object([:])
    ]))
}

private func sendGrokSessionUpdate(
    on transport: ScriptedLineTransport,
    sessionID: String,
    type: String,
    text: String,
    promptID: String = "verification-prompt"
) async throws {
    try await transport.sendServerObject(.object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": .object(makeGrokSessionUpdateParams(
            sessionID: sessionID,
            type: type,
            text: text,
            promptID: promptID
        ))
    ]))
}

private func makeGrokSessionUpdateParams(
    sessionID: String,
    type: String,
    text: String,
    promptID: String = "verification-prompt"
) -> [String: JSONValue] {
    if type == "user_message_chunk" {
        return [
            "_meta": .object([
                "agentTimestampMs": .integer(1_786_356_200_000),
                "eventId": .string("verification-user-message")
            ]),
            "sessionId": .string(sessionID),
            "update": .object([
                "_meta": .object([
                    "modelId": .string("grok-4.5"),
                    "promptIndex": .integer(0)
                ]),
                "sessionUpdate": .string(type),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ]
    }
    return [
        "_meta": .object([
            "agentTimestampMs": .integer(1_786_356_200_001),
            "chunkId": .integer(0),
            "eventId": .string("verification-\(type)"),
            "promptId": .string(promptID),
            "streamStartMs": .integer(1_786_356_199_900),
            "totalTokens": .integer(0),
            "turnStartMs": .integer(1_786_356_199_800),
            "updateType": .string(
                type == "agent_thought_chunk"
                    ? "AgentThoughtChunk"
                    : "AgentMessageChunk"
            )
        ]),
        "sessionId": .string(sessionID),
        "update": .object([
            "sessionUpdate": .string(type),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    ]
}

private func sendGrokResponseLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String,
    messageID: String = "verification-message",
    thoughtPromptID: String = "verification-prompt"
) async throws {
    try await sendGrokResponseStarted(
        on: transport,
        sessionID: sessionID,
        messageID: messageID
    )
    try await sendGrokSessionUpdate(
        on: transport,
        sessionID: sessionID,
        type: "agent_thought_chunk",
        text: "discarded reasoning",
        promptID: thoughtPromptID
    )
    try await sendGrokReasoningCompleted(on: transport, sessionID: sessionID)
}

private func sendGrokResponseStarted(
    on transport: ScriptedLineTransport,
    sessionID: String,
    messageID: String = "verification-message"
) async throws {
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/session_notification",
        params: .object([
            "sessionId": .string(sessionID),
            "update": .object([
                "cache_creation_input_tokens": .integer(0),
                "cache_read_input_tokens": .integer(0),
                "input_tokens": .integer(1),
                "message_id": .string(messageID),
                "model": .string("grok-4.5"),
                "sessionUpdate": .string("response_started")
            ])
        ])
    )
}

private func sendGrokReasoningCompleted(
    on transport: ScriptedLineTransport,
    sessionID: String
) async throws {
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/session_notification",
        params: .object([
            "sessionId": .string(sessionID),
            "update": .object([
                "sessionUpdate": .string("reasoning_completed"),
                "signature": .string("opaque-signature")
            ])
        ])
    )
}

private func sendGrokResponseCompletionLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String,
    messageID: String = "verification-message",
    promptID: String = "verification-prompt"
) async throws {
    try await sendGrokResponseCompleted(
        on: transport,
        sessionID: sessionID,
        messageID: messageID
    )
    try await sendGrokTurnCompleted(
        on: transport,
        sessionID: sessionID,
        promptID: promptID
    )
}

private func sendGrokResponseCompleted(
    on transport: ScriptedLineTransport,
    sessionID: String,
    messageID: String? = "verification-message",
    stopReason: String? = "end_turn"
) async throws {
    var update: [String: JSONValue] = [
        "sessionUpdate": .string("response_completed"),
        "signature": .string("opaque-signature"),
        "stop_sequence": .null,
        "usage": .object([
            "cache_creation_input_tokens": .integer(0),
            "cache_read_input_tokens": .integer(0),
            "input_tokens": .integer(1),
            "output_tokens": .integer(1),
            "reasoning_tokens": .integer(1)
        ])
    ]
    if let messageID {
        update["message_id"] = .string(messageID)
    }
    if let stopReason {
        update["stop_reason"] = .string(stopReason)
    }
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/session_notification",
        params: .object([
            "sessionId": .string(sessionID),
            "update": .object(update)
        ])
    )
}

private func sendGrokTurnCompleted(
    on transport: ScriptedLineTransport,
    sessionID: String,
    promptID: String = "verification-prompt",
    agentResult: String = "XUNJIAN_OK",
    includeMetadata: Bool = true,
    usage: JSONValue? = nil
) async throws {
    var update: [String: JSONValue] = [
        "agent_result": .string(agentResult),
        "prompt_id": .string(promptID),
        "sessionUpdate": .string("turn_completed"),
        "stop_reason": .string("end_turn")
    ]
    if let usage {
        update["usage"] = usage
    }
    var params: [String: JSONValue] = [
        "sessionId": .string(sessionID),
        "update": .object(update)
    ]
    if includeMetadata {
        params["_meta"] = .object([
            "agentTimestampMs": .integer(1_786_356_200_010),
            "eventId": .string("verification-turn-completed")
        ])
    }
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/session_notification",
        params: .object(params)
    )
}

private enum GrokVerificationPostEvent: Sendable {
    case promptEcho
    case responseStarted(messageID: String = "verification-message")
    case thought(promptID: String = "verification-prompt")
    case reasoningCompleted
    case agentReply(promptID: String = "verification-prompt")
    case responseCompleted(
        messageID: String? = "verification-message",
        stopReason: String? = "end_turn"
    )
    case turnCompleted(
        promptID: String = "verification-prompt",
        includeMetadata: Bool = true,
        usage: JSONValue? = nil
    )
}

private func sendGrokVerificationPostEvents(
    _ events: [GrokVerificationPostEvent],
    on transport: ScriptedLineTransport,
    sessionID: String
) async throws {
    for event in events {
        switch event {
        case .promptEcho:
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: sessionID,
                type: "user_message_chunk",
                text: "Reply exactly XUNJIAN_OK. Do not use tools."
            )
        case let .responseStarted(messageID):
            try await sendGrokResponseStarted(
                on: transport,
                sessionID: sessionID,
                messageID: messageID
            )
        case let .thought(promptID):
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: sessionID,
                type: "agent_thought_chunk",
                text: "discarded reasoning",
                promptID: promptID
            )
        case .reasoningCompleted:
            try await sendGrokReasoningCompleted(on: transport, sessionID: sessionID)
        case let .agentReply(promptID):
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: sessionID,
                type: "agent_message_chunk",
                text: "XUNJIAN_OK",
                promptID: promptID
            )
        case let .responseCompleted(messageID, stopReason):
            try await sendGrokResponseCompleted(
                on: transport,
                sessionID: sessionID,
                messageID: messageID,
                stopReason: stopReason
            )
        case let .turnCompleted(promptID, includeMetadata, usage):
            try await sendGrokTurnCompleted(
                on: transport,
                sessionID: sessionID,
                promptID: promptID,
                includeMetadata: includeMetadata,
                usage: usage
            )
        }
    }
}

private let exactGrokVerificationPostEvents: [GrokVerificationPostEvent] = [
    .promptEcho,
    .responseStarted(),
    .thought(),
    .reasoningCompleted,
    .agentReply(),
    .responseCompleted(),
    .turnCompleted()
]

private func sendGrokCompleteVerificationPostLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String
) async throws {
    try await sendGrokVerificationPostEvents(
        exactGrokVerificationPostEvents,
        on: transport,
        sessionID: sessionID
    )
}

private func sendGrokNotification(
    on transport: ScriptedLineTransport,
    method: String,
    params: JSONValue
) async throws {
    try await transport.sendServerObject(.object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": params
    ]))
}

private let exactGrokDisallowedToolIdentifiers = [
    "run_terminal_command",
    "read_file",
    "search_replace",
    "list_dir",
    "grep",
    "kill_command_or_subagent",
    "todo_write",
    "get_command_or_subagent_output",
    "spawn_subagent",
    "scheduler_create",
    "scheduler_delete",
    "scheduler_list",
    "monitor",
    "search_tool",
    "use_tool",
    "workflow",
    "enter_plan_mode",
    "exit_plan_mode",
    "ask_user_question",
    "image_gen",
    "image_edit",
    "image_to_video",
    "reference_to_video",
    "write",
    "Agent"
]

private let exactGrokLiveToolIdentifiers = Array(
    exactGrokDisallowedToolIdentifiers.dropLast()
)

private func makeExactGrokAvailableCommands() -> [JSONValue] {
    let declarations: [(name: String, description: String, input: JSONValue)] = [
        (
            "compact",
            "Compress conversation history to save context window",
            .object(["hint": .string("optional context about what to preserve")])
        ),
        (
            "always-approve",
            "Toggle always-approve mode (skip all permission prompts)",
            .object(["hint": .string("on|off")])
        ),
        ("context", "Show context window usage and session stats", .null),
        ("session-info", "Show session details (model, turns, context usage)", .null),
        (
            "feedback",
            "Send feedback about the current session",
            .object(["hint": .string("feedback text")])
        ),
        (
            "goal",
            "Set, manage, or check an autonomous goal",
            .object([
                "hint": .string("<objective> [--budget <tokens>] | status | pause | resume | clear")
            ])
        )
    ]
    return declarations.map { name, description, input in
        .object([
            "description": .string(description),
            "input": input,
            "name": .string(name)
        ])
    }
}

private func makeExactGrokAvailableOuterMetadata(
    timestampMilliseconds: Int64 = 1_786_356_000_000,
    eventID: String = "verification-available-commands-1"
) -> [String: JSONValue] {
    [
        "agentTimestampMs": .integer(timestampMilliseconds),
        "eventId": .string(eventID),
        "totalTokens": .integer(0),
        "updateParams": .object(["commandsCount": .integer(6)]),
        "updateType": .string("AvailableCommandsUpdate")
    ]
}

private let exactGrokVerificationAgentProfileContents = """
---
name: xunjian-connection-verifier
description: Connection verification with no executable tools.
permissionMode: dontAsk
tools:
  - read_file
disallowedTools:
  - read_file
  - search_tool
  - use_tool
discoverSkills: false
inheritSkills: false
injectDefaultTools: false
---
Connection verification only.
""" + "\n"

private func sendGrokVerificationSetupLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String,
    lifecycleSessionID: String? = nil,
    mcpServers: [JSONValue] = [],
    mcpToolCount: Int64 = 0,
    firstAvailableCommands: [JSONValue] = makeExactGrokAvailableCommands(),
    secondAvailableCommands: [JSONValue]? = nil,
    availableTools: [JSONValue] = [],
    firstAvailableOuterMetadata: [String: JSONValue] = makeExactGrokAvailableOuterMetadata(),
    secondAvailableOuterMetadata: [String: JSONValue]? = nil,
    injectedHookEventName: String? = nil,
    hookRuns: [JSONValue] = [],
    modelID: String = "grok-4.5",
    modelChangedMethod: String = "_x.ai/session_notification"
) async throws {
    let scopedSessionID = lifecycleSessionID ?? sessionID
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/mcp/servers_updated",
        params: .object(["mcpServers": .array(mcpServers)])
    )
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/mcp_initialized",
        params: .object([
            "elapsedMs": .integer(0),
            "mcpToolCount": .integer(mcpToolCount),
            "sessionId": .string(scopedSessionID)
        ])
    )
    let commandDeclarations = [
        firstAvailableCommands,
        secondAvailableCommands ?? firstAvailableCommands
    ]
    let outerMetadata = [
        firstAvailableOuterMetadata,
        secondAvailableOuterMetadata ?? makeExactGrokAvailableOuterMetadata(
            timestampMilliseconds: 1_786_356_000_001,
            eventID: "verification-available-commands-2"
        )
    ]
    for (commands, metadata) in zip(commandDeclarations, outerMetadata) {
        try await sendGrokNotification(
            on: transport,
            method: "session/update",
            params: .object([
                "_meta": .object(metadata),
                "sessionId": .string(scopedSessionID),
                "update": .object([
                    "_meta": .object(["tools": .array(availableTools)]),
                    "availableCommands": .array(commands),
                    "sessionUpdate": .string("available_commands_update")
                ])
            ])
        )
    }
    if let injectedHookEventName {
        try await sendGrokHookLifecycle(
            on: transport,
            sessionID: scopedSessionID,
            eventName: injectedHookEventName,
            runs: hookRuns
        )
    }
    try await sendGrokNotification(
        on: transport,
        method: modelChangedMethod,
        params: .object([
            "sessionId": .string(scopedSessionID),
            "update": .object([
                "model_id": .string(modelID),
                "reasoning_effort": .string("high"),
                "sessionUpdate": .string("model_changed")
            ])
        ])
    )
}

private func sendGrokVerificationCloseLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String,
    lifecycleSessionID: String? = nil,
    removedAsObject: Bool = false,
    conflictingRemovedIdentifiers: Bool = false,
    injectedHookEventName: String? = nil,
    hookRuns: [JSONValue] = []
) async throws {
    let scopedSessionID = lifecycleSessionID ?? sessionID
    let removedValue: JSONValue
    if conflictingRemovedIdentifiers {
        removedValue = .object([
            "id": .string(scopedSessionID),
            "sessionId": .string("foreign-session")
        ])
    } else if removedAsObject {
        removedValue = .object(["id": .string(scopedSessionID)])
    } else {
        removedValue = .string(scopedSessionID)
    }
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/sessions/changed",
        params: .object([
            "removed": .array([removedValue]),
            "upserted": .array([])
        ])
    )
    if let injectedHookEventName {
        try await sendGrokHookLifecycle(
            on: transport,
            sessionID: scopedSessionID,
            eventName: injectedHookEventName,
            runs: hookRuns
        )
    }
}

private func sendGrokHookLifecycle(
    on transport: ScriptedLineTransport,
    sessionID: String,
    eventName: String,
    runs: [JSONValue],
    outerMetadata: [String: JSONValue] = [:]
) async throws {
    try await sendGrokNotification(
        on: transport,
        method: "_x.ai/session_notification",
        params: .object([
            "_meta": .object(outerMetadata),
            "sessionId": .string(sessionID),
            "update": .object([
                "event_name": .string(eventName),
                "runs": .array(runs),
                "sessionUpdate": .string("hook_execution")
            ])
        ])
    )
}

private func makeGrokClient(on transport: ScriptedLineTransport) -> GrokACPClient {
    let peer = JSONLineRPCPeer(
        transport: transport,
        dialect: .jsonRPC2,
        allowedNotifications: GrokACPClient.allowedNotifications
    )
    return GrokACPClient(
        peer: peer,
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
    )
}

private func assertCodexTextOnlyThreadConfiguration(
    _ params: [String: JSONValue]?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        params?["baseInstructions"],
        .string("Return only the requested text. Never use tools, commands, files, apps, plugins, or web search."),
        file: file,
        line: line
    )
    XCTAssertEqual(
        params?["developerInstructions"],
        .string("This is a text-only request. Do not inspect the filesystem or invoke any tool."),
        file: file,
        line: line
    )
    let config = params?["config"]?.objectValue
    XCTAssertEqual(config?["web_search"], .string("disabled"), file: file, line: line)
    let features = config?["features"]?.objectValue
    let expectedFeatures = Set([
        "apps", "browser_use", "code_mode_host", "computer_use", "image_generation",
        "in_app_browser", "multi_agent", "plugins", "remote_plugin", "shell_snapshot",
        "shell_tool", "tool_suggest", "unified_exec", "view_image"
    ])
    XCTAssertEqual(Set(features?.keys.map { $0 } ?? []), expectedFeatures, file: file, line: line)
    for feature in expectedFeatures {
        XCTAssertEqual(features?[feature], .bool(false), file: file, line: line)
    }
}

private func serveCodexGenerationPrelude(
    on transport: ScriptedLineTransport,
    model: String = "gpt-5.6-sol",
    prompt: String = "system\nuser",
    threadID: String = "generation-thread",
    turnID: String = "generation-turn"
) async throws {
    let initialize = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(initialize["method"], .string("initialize"))
    try await transport.sendServerObject(.object([
        "id": initialize["id"]!,
        "result": .object([:])
    ]))
    let initialized = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(initialized["method"], .string("initialized"))

    let listModels = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(listModels["method"], .string("model/list"))
    try await transport.sendServerObject(.object([
        "id": listModels["id"]!,
        "result": .object([
            "data": .array([
                .object(["id": .string(model), "isDefault": .bool(true)])
            ]),
            "nextCursor": .null
        ])
    ]))

    let thread = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(thread["method"], .string("thread/start"))
    XCTAssertEqual(thread["params"]?.objectValue?["model"], .string(model))
    XCTAssertEqual(thread["params"]?.objectValue?["ephemeral"], .bool(true))
    XCTAssertEqual(thread["params"]?.objectValue?["approvalPolicy"], .string("never"))
    XCTAssertEqual(thread["params"]?.objectValue?["sandbox"], .string("read-only"))
    assertCodexTextOnlyThreadConfiguration(thread["params"]?.objectValue)
    try await transport.sendServerObject(.object([
        "id": thread["id"]!,
        "result": .object(["thread": .object(["id": .string(threadID)])])
    ]))

    let turn = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(turn["method"], .string("turn/start"))
    XCTAssertEqual(turn["params"]?.objectValue?["threadId"], .string(threadID))
    XCTAssertEqual(
        turn["params"]?.objectValue?["input"]?.arrayValue?
            .first?.objectValue?["text"],
        .string(prompt)
    )
    try await transport.sendServerObject(.object([
        "id": turn["id"]!,
        "result": .object(["turn": .object(["id": .string(turnID)])])
    ]))
}

private func sendCodexDelta(
    _ text: String,
    on transport: ScriptedLineTransport,
    threadID: String = "generation-thread",
    turnID: String = "generation-turn"
) async throws {
    try await transport.sendServerObject(.object([
        "method": .string("item/agentMessage/delta"),
        "params": .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "delta": .string(text)
        ])
    ]))
}

private func sendCodexFinal(
    _ text: String,
    on transport: ScriptedLineTransport,
    threadID: String = "generation-thread",
    turnID: String = "generation-turn",
    itemType: String = "agentMessage"
) async throws {
    try await transport.sendServerObject(.object([
        "method": .string("item/completed"),
        "params": .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "item": .object([
                "type": .string(itemType),
                "text": .string(text)
            ])
        ])
    ]))
}

private func sendCodexTurnCompleted(
    on transport: ScriptedLineTransport,
    threadID: String = "generation-thread",
    turnID: String = "generation-turn",
    status: String = "completed"
) async throws {
    try await transport.sendServerObject(.object([
        "method": .string("turn/completed"),
        "params": .object([
            "threadId": .string(threadID),
            "turn": .object([
                "id": .string(turnID),
                "status": .string(status)
            ])
        ])
    ]))
}

private func serveCodexOwnedTurnInterrupt(
    on transport: ScriptedLineTransport,
    threadID: String = "generation-thread",
    turnID: String = "generation-turn"
) async throws {
    let interrupt = try await transport.nextClientObject().objectValue!
    XCTAssertEqual(interrupt["method"], .string("turn/interrupt"))
    XCTAssertEqual(interrupt["params"]?.objectValue?["threadId"], .string(threadID))
    XCTAssertEqual(interrupt["params"]?.objectValue?["turnId"], .string(turnID))
    try await transport.sendServerObject(.object([
        "id": interrupt["id"]!,
        "result": .object([:])
    ]))
}

private func makeExactGrokSafetyInspectionValue() -> JSONValue {
    let expectedCells: [(vendor: String, surface: String)] = [
        ("cursor", "skills"),
        ("cursor", "rules"),
        ("cursor", "agents"),
        ("cursor", "mcps"),
        ("cursor", "hooks"),
        ("cursor", "sessions"),
        ("claude", "skills"),
        ("claude", "rules"),
        ("claude", "agents"),
        ("claude", "mcps"),
        ("claude", "hooks"),
        ("claude", "sessions"),
        ("codex", "sessions")
    ]
    let cells = expectedCells.map { cell in
        JSONValue.object([
            "enabled": .bool(false),
            "source": .string("env"),
            "surface": .string(cell.surface),
            "vendor": .string(cell.vendor)
        ])
    }
    let builtinAgents: [JSONValue] = [
        .object([
            "description": .string("General purpose agent for multi-step tasks."),
            "name": .string("general-purpose"),
            "source": .object(["type": .string("builtin")])
        ]),
        .object([
            "description": .string(
                "Fast, read-only agent specialized for codebase exploration."
            ),
            "name": .string("explore"),
            "source": .object(["type": .string("builtin")])
        ]),
        .object([
            "description": .string(
                "Software architect for planning implementation strategies."
            ),
            "name": .string("plan"),
            "source": .object(["type": .string("builtin")])
        ])
    ]
    return .object([
        "agents": .array(builtinAgents),
        "channel": .string("unknown"),
        "configSources": .object([
            "layers": .array([
                .object([
                    "path": .string(
                        exactGrokSafetyInspectionHomeURL()
                            .appending(path: "config.toml")
                            .path
                    ),
                    "role": .string("user")
                ])
            ])
        ]),
        "cwd": .string(exactGrokSafetyInspectionWorkingDirectoryURL().path),
        "externalCompat": .object([
            "cells": .array(cells),
            "remoteSettingsLoaded": .bool(false)
        ]),
        "grokVersion": .string("1.0.0"),
        "hooks": .array([]),
        "loginPolicy": .object([
            "apiKeyAuthDisabled": .bool(false),
            "disableApiKeyAuth": .null,
            "forceLoginTeamUuid": .null
        ]),
        "lspServers": .array([]),
        "marketplaces": .array([]),
        "mcpServers": .array([]),
        "permissions": .object([
            "loaded": .integer(0),
            "managedSettingsActive": .bool(false),
            "managedSettingsExists": .bool(false),
            "managedSettingsPath": .string(
                "/Library/Application Support/ClaudeCode/managed-settings.json"
            ),
            "marketplaceAllowlist": .array([]),
            "mcpServerAllowlist": .array([]),
            "skipped": .array([]),
            "sources": .array([])
        ]),
        "plugins": .array([]),
        "projectInstructions": .array([]),
        "projectRoot": .null,
        "projectTrusted": .bool(true),
        "skills": .array([])
    ])
}

private func encodeGrokSafetyInspection(_ value: JSONValue) throws -> Data {
    try JSONEncoder().encode(value)
}

private func exactGrokSafetyInspectionWorkingDirectoryURL() -> URL {
    URL(
        fileURLWithPath: "/private/tmp/xunjian-inspection-empty",
        isDirectory: true
    )
}

private func exactGrokSafetyInspectionHomeURL() -> URL {
    URL(
        fileURLWithPath: "/private/tmp/xunjian-inspection-grok-home",
        isDirectory: true
    )
}

private func isExactGrokSafetyInspectionSafe(_ data: Data) -> Bool {
    GrokSafetyInspectionPolicy.isSafe(
        data,
        expectedWorkingDirectoryURL: exactGrokSafetyInspectionWorkingDirectoryURL(),
        expectedGrokHomeDirectoryURL: exactGrokSafetyInspectionHomeURL()
    )
}

final class OAuthProtocolClientTests: XCTestCase {
    func testFramerReassemblesSplitCRLFAndGluedLines() throws {
        var framer = JSONLineFramer(maximumLineBytes: 64)

        XCTAssertEqual(try framer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(
            try framer.append(Data("1}\r\n{\"b\":2}\npartial".utf8)),
            [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)]
        )
        XCTAssertEqual(try framer.finish(), Data("partial".utf8))
    }

    func testFramerRejectsOversizedLineBeforeNewline() throws {
        var framer = JSONLineFramer(maximumLineBytes: 8)
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: 9))) { error in
            XCTAssertEqual(error as? JSONLineFramingError, .lineTooLarge)
        }
    }

    func testPeerMatchesOutOfOrderResponses() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: []
        )

        async let first = peer.request(method: "one", params: nil)
        async let second = peer.request(method: "two", params: nil)
        let firstRequest = try await transport.nextClientObject().objectValue!
        let secondRequest = try await transport.nextClientObject().objectValue!
        let firstID = firstRequest["id"]!
        let secondID = secondRequest["id"]!
        try await transport.sendServerObject(.object(["id": secondID, "result": .string("B")]))
        try await transport.sendServerObject(.object(["id": firstID, "result": .string("A")]))

        let values = [try await first, try await second]
        XCTAssertEqual(Set(values.compactMap(\.stringValue)), Set(["A", "B"]))
        await peer.close()
    }

    func testPeerRejectsServerInitiatedRequestAndCloses() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: []
        )
        let request = Task { try await peer.request(method: "safe", params: nil) }
        _ = try await transport.nextClientObject()
        try await transport.sendServerObject(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(99),
            "method": .string("session/request_permission"),
            "params": .object([:])
        ]))

        do {
            _ = try await request.value
            XCTFail("Expected fail-closed rejection")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .serverRequestRejected)
        }
        let rejection = try await transport.nextClientObject().objectValue
        XCTAssertEqual(rejection?["id"], .integer(99))
        XCTAssertEqual(rejection?["error"]?.objectValue?["code"], .integer(-32601))
        let serverRequestClosed = await transport.isClosed
        XCTAssertTrue(serverRequestClosed)
    }

    func testPeerTimeoutAndRemoteErrorsDoNotExposePayloads() async throws {
        let timeoutTransport = ScriptedLineTransport()
        let timeoutPeer = JSONLineRPCPeer(
            transport: timeoutTransport,
            dialect: .codex,
            allowedNotifications: [],
            requestTimeoutNanoseconds: 20_000_000
        )
        let timeoutRequest = Task { try await timeoutPeer.request(method: "timeout", params: nil) }
        _ = try await timeoutTransport.nextClientObject()
        do {
            _ = try await timeoutRequest.value
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is JSONLineRPCError)
        }
        await timeoutPeer.close()

        let remoteTransport = ScriptedLineTransport()
        let remotePeer = JSONLineRPCPeer(
            transport: remoteTransport,
            dialect: .codex,
            allowedNotifications: []
        )
        let remoteRequest = Task { try await remotePeer.request(method: "remote", params: nil) }
        let request = try await remoteTransport.nextClientObject().objectValue!
        try await remoteTransport.sendServerObject(.object([
            "id": request["id"]!,
            "error": .object([
                "code": .integer(401),
                "message": .string("token=secret-token email=secret@example.com")
            ])
        ]))
        do {
            _ = try await remoteRequest.value
            XCTFail("Expected remote error")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("secret-token"))
            XCTAssertFalse(description.contains("secret@example.com"))
        }
        await remotePeer.close()
    }

    func testPeerCancellationClosesTransportWithoutLeakingPendingRequest() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: []
        )
        let request = Task { try await peer.request(method: "cancel", params: nil) }
        _ = try await transport.nextClientObject()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cancellationClosed = await transport.isClosed
        XCTAssertTrue(cancellationClosed)
        await peer.close()
    }

    func testPeerRejectsMalformedAndUnknownNotifications() async throws {
        for line in [
            Data("{not-json}".utf8),
            try JSONEncoder().encode(JSONValue.object(["method": .string("unknown/event")]))
        ] {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .codex,
                allowedNotifications: []
            )
            let request = Task { try await peer.request(method: "safe", params: nil) }
            _ = try await transport.nextClientObject()
            await transport.sendServerData(line)
            do {
                _ = try await request.value
                XCTFail("Expected protocol rejection")
            } catch {
                XCTAssertTrue(error is JSONLineRPCError)
            }
            let rejectedClosed = await transport.isClosed
            XCTAssertTrue(rejectedClosed)
        }
    }

    func testPeerFailClosesNotificationExplicitlyOptedOutByCodexClient() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let request = Task { try await peer.request(method: "safe", params: nil) }
        _ = try await transport.nextClientObject()
        try await transport.sendServerObject(.object([
            "method": .string("item/reasoning/textDelta"),
            "params": .object(["delta": .string("must-not-be-accepted")])
        ]))

        do {
            _ = try await request.value
            XCTFail("Expected opted-out notification rejection")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .unknownNotification)
        }
        let rejectedConnectionClosed = await transport.isClosed
        XCTAssertTrue(rejectedConnectionClosed)
    }

    func testGrokSafetyInspectionPolicyAcceptsOnlyExactIsolatedReport() throws {
        let exactValue = makeExactGrokSafetyInspectionValue()
        let exactData = try encodeGrokSafetyInspection(exactValue)

        XCTAssertTrue(isExactGrokSafetyInspectionSafe(exactData))
    }

    func testGrokSafetyInspectionPolicyRejectsUnsafeIntegrationAndConfigurationSources() throws {
        let nonemptyArrayKeys = [
            "hooks", "plugins", "mcpServers", "lspServers",
            "marketplaces", "skills", "projectInstructions"
        ]
        for key in nonemptyArrayKeys {
            var root = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
            root[key] = .array([.object(["name": .string("must-not-load")])])
            XCTAssertFalse(
                isExactGrokSafetyInspectionSafe(
                    try encodeGrokSafetyInspection(.object(root))
                ),
                key
            )
        }

        var layeredRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        layeredRoot["configSources"] = .object([
            "layers": .array([.string("user")])
        ])
        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(
                try encodeGrokSafetyInspection(.object(layeredRoot))
            )
        )

        let expectedConfigurationPath = exactGrokSafetyInspectionHomeURL()
            .appending(path: "config.toml")
            .path
        let unsafeLayers: [[JSONValue]] = [
            [],
            [.object([
                "path": .string("/private/tmp/foreign/config.toml"),
                "role": .string("user")
            ])],
            [.object([
                "path": .string(expectedConfigurationPath),
                "role": .string("system")
            ])],
            [.object([
                "extra": .bool(true),
                "path": .string(expectedConfigurationPath),
                "role": .string("user")
            ])]
        ]
        for layers in unsafeLayers {
            var root = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
            root["configSources"] = .object(["layers": .array(layers)])
            XCTAssertFalse(
                isExactGrokSafetyInspectionSafe(
                    try encodeGrokSafetyInspection(.object(root))
                )
            )
        }

        var remoteRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        var remoteExternalCompat = try XCTUnwrap(
            remoteRoot["externalCompat"]?.objectValue
        )
        remoteExternalCompat["remoteSettingsLoaded"] = .bool(true)
        remoteRoot["externalCompat"] = .object(remoteExternalCompat)
        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(
                try encodeGrokSafetyInspection(.object(remoteRoot))
            )
        )

        var secretRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        secretRoot["token"] = .string("must-not-be-accepted")
        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(
                try encodeGrokSafetyInspection(.object(secretRoot))
            )
        )
    }

    func testGrokSafetyInspectionPolicyRejectsAgentCWDAndManagedSettingsDrift() throws {
        let exactRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        let exactAgents = try XCTUnwrap(exactRoot["agents"]?.arrayValue)
        XCTAssertEqual(exactAgents.count, 3)

        var externalAgents = exactAgents
        externalAgents[0] = .object([
            "description": .string("External agent."),
            "name": .string("external"),
            "source": .object(["type": .string("external")])
        ])

        var changedDescription = try XCTUnwrap(exactAgents[0].objectValue)
        changedDescription["description"] = .string("Drifted description.")
        var descriptionAgents = exactAgents
        descriptionAgents[0] = .object(changedDescription)

        var changedSource = try XCTUnwrap(exactAgents[0].objectValue)
        changedSource["source"] = .object(["type": .string("external")])
        var sourceAgents = exactAgents
        sourceAgents[0] = .object(changedSource)

        for scenario in [
            ("external", externalAgents),
            ("description", descriptionAgents),
            ("source", sourceAgents)
        ] {
            var root = exactRoot
            root["agents"] = .array(scenario.1)
            XCTAssertFalse(
                isExactGrokSafetyInspectionSafe(
                    try encodeGrokSafetyInspection(.object(root))
                ),
                scenario.0
            )
        }

        let exactData = try encodeGrokSafetyInspection(.object(exactRoot))
        XCTAssertFalse(
            GrokSafetyInspectionPolicy.isSafe(
                exactData,
                expectedWorkingDirectoryURL: URL(
                    fileURLWithPath: "/private/tmp/foreign-working-directory",
                    isDirectory: true
                ),
                expectedGrokHomeDirectoryURL: exactGrokSafetyInspectionHomeURL()
            )
        )

        var managedPathRoot = exactRoot
        var permissions = try XCTUnwrap(managedPathRoot["permissions"]?.objectValue)
        permissions["managedSettingsPath"] = .string("/tmp/untrusted-settings.json")
        managedPathRoot["permissions"] = .object(permissions)
        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(
                try encodeGrokSafetyInspection(.object(managedPathRoot))
            )
        )
    }

    func testGrokSafetyInspectionPolicyRejectsExternalCompatibilityCellDrift() throws {
        let exactRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        let exactExternalCompat = try XCTUnwrap(exactRoot["externalCompat"]?.objectValue)
        let exactCells = try XCTUnwrap(exactExternalCompat["cells"]?.arrayValue)
        XCTAssertEqual(exactCells.count, 13)

        var enabledCell = try XCTUnwrap(exactCells[0].objectValue)
        enabledCell["enabled"] = .bool(true)
        var enabledCells = exactCells
        enabledCells[0] = .object(enabledCell)

        var sourceCell = try XCTUnwrap(exactCells[0].objectValue)
        sourceCell["source"] = .string("settings")
        var sourceCells = exactCells
        sourceCells[0] = .object(sourceCell)

        var duplicateCells = Array(exactCells.dropLast())
        duplicateCells.append(exactCells[0])

        var extraCells = Array(exactCells.dropLast())
        extraCells.append(.object([
            "enabled": .bool(false),
            "source": .string("env"),
            "surface": .string("hooks"),
            "vendor": .string("unknown")
        ]))

        let scenarios: [(name: String, cells: [JSONValue])] = [
            ("missing", Array(exactCells.dropLast())),
            ("duplicate", duplicateCells),
            ("extra", extraCells),
            ("enabled", enabledCells),
            ("source", sourceCells)
        ]
        for scenario in scenarios {
            var root = exactRoot
            var externalCompat = exactExternalCompat
            externalCompat["cells"] = .array(scenario.cells)
            root["externalCompat"] = .object(externalCompat)
            XCTAssertFalse(
                isExactGrokSafetyInspectionSafe(
                    try encodeGrokSafetyInspection(.object(root))
                ),
                scenario.name
            )
        }
    }

    func testGrokSafetyInspectionPolicyRejectsVersionMalformedAndOversizedReports() throws {
        var versionRoot = try XCTUnwrap(makeExactGrokSafetyInspectionValue().objectValue)
        versionRoot["grokVersion"] = .string("1.0.1")
        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(
                try encodeGrokSafetyInspection(.object(versionRoot))
            )
        )

        XCTAssertFalse(
            isExactGrokSafetyInspectionSafe(Data("{\"grokVersion\":".utf8))
        )

        var oversized = try encodeGrokSafetyInspection(
            makeExactGrokSafetyInspectionValue()
        )
        XCTAssertLessThan(oversized.count, 262_145)
        oversized.append(
            Data(repeating: 0x20, count: 262_145 - oversized.count)
        )
        XCTAssertNoThrow(try JSONDecoder().decode(JSONValue.self, from: oversized))
        XCTAssertFalse(isExactGrokSafetyInspectionSafe(oversized))
    }

    func testProviderConfigurationUsesDedicatedProviderHomesAndIsolatedProcessHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "xunjian-security-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let home = root.appending(path: "user-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sharedGrokDirectory = home.appending(path: ".grok", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sharedGrokDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sharedAuthURL = sharedGrokDirectory.appending(path: "auth.json")
        let sharedAuthBytes = Data("{\"sentinel\":\"shared-cli-auth\"}".utf8)
        try sharedAuthBytes.write(to: sharedAuthURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sharedAuthURL.path
        )
        let sharedAuthModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sharedAuthURL.path)[.modificationDate]
                as? Date
        )
        let sharedCodexDirectory = home.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sharedCodexDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sharedCodexAuthURL = sharedCodexDirectory.appending(path: "auth.json")
        let sharedCodexAuthBytes = Data("{\"sentinel\":\"shared-codex-auth\"}".utf8)
        try sharedCodexAuthBytes.write(to: sharedCodexAuthURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sharedCodexAuthURL.path
        )
        let codexHome = try CodexAppServerHome.prepare(userHomeDirectoryURL: home)
        let grokHome = try GrokCLIHome.prepare(userHomeDirectoryURL: home)
        let executable = URL(fileURLWithPath: "/Users/test/.grok/bin/grok")
        let codex = try OAuthCLIProcessSecurity.makeConfiguration(
            provider: .codex,
            executableURL: URL(fileURLWithPath: "/Applications/XunJian/codex-app-server"),
            homeDirectoryURL: home,
            codexHomeDirectoryURL: codexHome.rootURL,
            temporaryRootURL: root.appending(path: "codex", directoryHint: .isDirectory)
        )
        let runtime = try OAuthCLIProcessSecurity.makeConfiguration(
            provider: .grok,
            executableURL: executable,
            homeDirectoryURL: home,
            grokHomeDirectoryURL: grokHome.rootURL,
            temporaryRootURL: root.appending(path: "runtime", directoryHint: .isDirectory)
        )
        let login = try OAuthCLIProcessSecurity.makeGrokLoginConfiguration(
            executableURL: executable,
            grokHomeDirectoryURL: grokHome.rootURL,
            temporaryRootURL: root.appending(path: "login", directoryHint: .isDirectory)
        )
        let logout = try OAuthCLIProcessSecurity.makeGrokLogoutConfiguration(
            executableURL: executable,
            grokHomeDirectoryURL: grokHome.rootURL,
            temporaryRootURL: root.appending(path: "logout", directoryHint: .isDirectory)
        )
        let sessionID = "550e8400-e29b-41d4-a716-446655440000"
        let deletion = try OAuthCLIProcessSecurity.makeGrokSessionDeletionConfiguration(
            executableURL: executable,
            grokHomeDirectoryURL: grokHome.rootURL,
            sessionID: sessionID,
            temporaryRootURL: root.appending(path: "deletion", directoryHint: .isDirectory)
        )
        let profileFlagIndex = try XCTUnwrap(
            runtime.arguments.firstIndex(of: "--agent-profile")
        )
        let profilePath = try XCTUnwrap(
            runtime.arguments.dropFirst(profileFlagIndex + 1).first
        )
        let profileURL = URL(fileURLWithPath: profilePath).standardizedFileURL

        XCTAssertEqual(
            codex.arguments,
            [
                "--config", "skills.bundled.enabled=false",
                "--config", "features.plugins=false",
                "--listen", "stdio://"
            ]
        )
        XCTAssertFalse(codex.arguments.contains("--stdio"))
        XCTAssertEqual(
            runtime.arguments,
            [
                "--no-auto-update", "--permission-mode", "dontAsk", "--deny", "*",
                "--disallowed-tools", exactGrokDisallowedToolIdentifiers.joined(separator: ","),
                "--disable-web-search", "--no-memory", "--no-subagents",
                "--sandbox", "strict", "--cwd", runtime.currentDirectoryURL.path,
                "agent", "--no-leader", "--model", "grok-4.5",
                "--reasoning-effort", "high",
                "--agent-profile", profileURL.path, "stdio"
            ]
        )
        XCTAssertFalse(runtime.arguments.contains("--tools"))
        XCTAssertEqual(exactGrokDisallowedToolIdentifiers.count, 25)
        XCTAssertEqual(Set(exactGrokDisallowedToolIdentifiers).count, 25)
        XCTAssertEqual(profileURL.lastPathComponent, "xunjian-connection-verifier.md")
        XCTAssertEqual(
            profileURL.deletingLastPathComponent().standardizedFileURL,
            runtime.currentDirectoryURL.standardizedFileURL
        )
        let profileBytes = try Data(contentsOf: profileURL)
        XCTAssertEqual(
            profileBytes,
            Data(exactGrokVerificationAgentProfileContents.utf8)
        )
        XCTAssertFalse(exactGrokVerificationAgentProfileContents.contains("toolConfig"))
        let profileAttributes = try FileManager.default.attributesOfItem(
            atPath: profileURL.path
        )
        XCTAssertEqual(profileAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(
            (profileAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(
            (profileAttributes[.referenceCount] as? NSNumber)?.intValue,
            1
        )
        XCTAssertEqual(
            (profileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            getuid()
        )
        XCTAssertEqual(login.arguments, ["--no-auto-update", "login", "--oauth"])
        XCTAssertEqual(logout.arguments, ["--no-auto-update", "logout"])
        XCTAssertEqual(
            deletion.arguments,
            ["--no-auto-update", "sessions", "delete", sessionID]
        )
        XCTAssertNil(codex.environment["OPENAI_API_KEY"])
        XCTAssertNil(runtime.environment["XAI_API_KEY"])
        XCTAssertNil(codex.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(
            Set(codex.environment.keys),
            Set(["HOME", "CODEX_HOME", "PATH", "LANG", "LC_ALL", "TMPDIR"])
        )
        XCTAssertEqual(codex.environment["CODEX_HOME"], codexHome.rootURL.path)
        XCTAssertNotEqual(codex.environment["HOME"], home.path)
        XCTAssertNotEqual(codex.environment["HOME"], codexHome.rootURL.path)
        for directory in [
            codex.currentDirectoryURL,
            URL(fileURLWithPath: try XCTUnwrap(codex.environment["HOME"])),
            URL(fileURLWithPath: try XCTUnwrap(codex.environment["TMPDIR"]))
        ] {
            let permissions = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
        let isolationKeys = Set([
            "GROK_CURSOR_SKILLS_ENABLED", "GROK_CURSOR_RULES_ENABLED",
            "GROK_CURSOR_AGENTS_ENABLED", "GROK_CURSOR_MCPS_ENABLED",
            "GROK_CURSOR_HOOKS_ENABLED", "GROK_CURSOR_SESSIONS_ENABLED",
            "GROK_CLAUDE_SKILLS_ENABLED", "GROK_CLAUDE_RULES_ENABLED",
            "GROK_CLAUDE_AGENTS_ENABLED", "GROK_CLAUDE_MCPS_ENABLED",
            "GROK_CLAUDE_HOOKS_ENABLED", "GROK_CLAUDE_SESSIONS_ENABLED",
            "GROK_CODEX_SESSIONS_ENABLED"
        ])
        let baselineKeys = Set(["HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "GROK_HOME"])
        let grokConfigurations = [runtime, login, logout, deletion]
        for configuration in grokConfigurations {
            XCTAssertEqual(Set(configuration.environment.keys), baselineKeys.union(isolationKeys))
            XCTAssertEqual(configuration.environment["GROK_HOME"], grokHome.rootURL.path)
            XCTAssertNotEqual(configuration.environment["HOME"], home.path)
            XCTAssertNotEqual(configuration.environment["HOME"], grokHome.rootURL.path)
            for key in isolationKeys {
                XCTAssertEqual(configuration.environment[key], "0", key)
            }
            let directories = [
                configuration.currentDirectoryURL,
                URL(fileURLWithPath: try XCTUnwrap(configuration.environment["HOME"])),
                URL(fileURLWithPath: try XCTUnwrap(configuration.environment["TMPDIR"]))
            ]
            XCTAssertEqual(Set(directories.map(\.standardizedFileURL)).count, 3)
            for directory in directories {
                let permissions = try FileManager.default.attributesOfItem(
                    atPath: directory.path
                )[.posixPermissions] as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o700)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
                if directory.standardizedFileURL == runtime.currentDirectoryURL.standardizedFileURL {
                    XCTAssertEqual(contents.map(\.standardizedFileURL), [profileURL])
                } else {
                    XCTAssertTrue(contents.isEmpty)
                }
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: grokHome.rootURL.appending(path: "auth.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: codexHome.rootURL.appending(path: "auth.json").path
            )
        )
        XCTAssertEqual(try Data(contentsOf: sharedCodexAuthURL), sharedCodexAuthBytes)
        XCTAssertEqual(try Data(contentsOf: sharedAuthURL), sharedAuthBytes)
        XCTAssertEqual(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: sharedAuthURL.path)[.modificationDate]
                    as? Date
            ),
            sharedAuthModificationDate
        )

        XCTAssertThrowsError(
            try OAuthCLIProcessSecurity.makeConfiguration(
                provider: .codex,
                executableURL: URL(fileURLWithPath: "/Applications/XunJian/codex-app-server"),
                homeDirectoryURL: home,
                codexHomeDirectoryURL: nil,
                temporaryRootURL: root.appending(path: "missing-codex-home")
            )
        ) { error in
            XCTAssertEqual(error as? SupervisedLineProcessError, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try OAuthCLIProcessSecurity.makeConfiguration(
                provider: .grok,
                executableURL: executable,
                homeDirectoryURL: home,
                grokHomeDirectoryURL: nil,
                temporaryRootURL: root.appending(path: "missing-home")
            )
        ) { error in
            XCTAssertEqual(error as? SupervisedLineProcessError, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try OAuthCLIProcessSecurity.makeGrokSessionDeletionConfiguration(
                executableURL: executable,
                grokHomeDirectoryURL: grokHome.rootURL,
                sessionID: "../auth.json",
                temporaryRootURL: root.appending(path: "unsafe-deletion")
            )
        ) { error in
            XCTAssertEqual(error as? SupervisedLineProcessError, .invalidConfiguration)
        }
    }

    func testCodexClientUsesBoundedReadOnlyEphemeralTranscript() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let workingDirectory = URL(fileURLWithPath: "/private/tmp/xunjian-empty", isDirectory: true)
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: workingDirectory,
            restrictedReadSupport: .supported
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(initialize["method"], .string("initialize"))
            let capabilities = initialize["params"]?.objectValue?["capabilities"]?.objectValue
            XCTAssertEqual(capabilities?["experimentalApi"], .bool(false))
            let optOutValues = capabilities?["optOutNotificationMethods"]?.arrayValue ?? []
            let optOutMethods = optOutValues.compactMap(\.stringValue)
            let optOutSet = Set(optOutMethods)
            XCTAssertEqual(optOutMethods.count, 61)
            XCTAssertEqual(optOutSet.count, 61)
            XCTAssertEqual(optOutMethods, optOutMethods.sorted())
            XCTAssertTrue(optOutSet.isDisjoint(with: CodexAppServerClient.allowedNotifications))
            XCTAssertFalse(optOutSet.contains("account/login/completed"))
            XCTAssertFalse(optOutSet.contains("account/updated"))
            XCTAssertTrue(
                Set(["account/login/completed", "account/updated"])
                    .isSubset(of: CodexAppServerClient.allowedNotifications)
            )
            XCTAssertTrue(
                Set([
                    "item/reasoning/summaryPartAdded",
                    "item/reasoning/summaryTextDelta",
                    "item/reasoning/textDelta",
                    "thread/tokenUsage/updated"
                ]).isSubset(of: optOutSet)
            )
            try await transport.sendServerObject(.object(["id": initialize["id"]!, "result": .object([:])]))
            let initialized = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(initialized["method"], .string("initialized"))
            XCTAssertNil(initialized["params"])

            let account = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(account["method"], .string("account/read"))
            XCTAssertEqual(account["params"]?.objectValue?["refreshToken"], .bool(false))
            try await transport.sendServerObject(.object([
                "id": account["id"]!,
                "result": .object([
                    "account": .object([
                        "type": .string("chatgpt"),
                        "email": .string("secret@example.com"),
                        "planType": .string("plus")
                    ]),
                    "requiresOpenaiAuth": .bool(true)
                ])
            ]))

            let firstModelsPage = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(firstModelsPage["method"], .string("model/list"))
            XCTAssertEqual(firstModelsPage["params"]?.objectValue?["limit"], .integer(100))
            XCTAssertNil(firstModelsPage["params"]?.objectValue?["cursor"])
            try await transport.sendServerObject(.object([
                "id": firstModelsPage["id"]!,
                "result": .object([
                    "data": .array([
                        .object(["id": .string("gpt-5.3-codex"), "isDefault": .bool(false)])
                    ]),
                    "nextCursor": .string("page-2")
                ])
            ]))

            let secondModelsPage = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(secondModelsPage["method"], .string("model/list"))
            XCTAssertEqual(secondModelsPage["params"]?.objectValue?["limit"], .integer(100))
            XCTAssertEqual(secondModelsPage["params"]?.objectValue?["cursor"], .string("page-2"))
            try await transport.sendServerObject(.object([
                "id": secondModelsPage["id"]!,
                "result": .object([
                    "data": .array([
                        .object(["id": .string("gpt-5.6-sol"), "isDefault": .bool(true)])
                    ]),
                    "nextCursor": .null
                ])
            ]))

            let thread = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(thread["method"], .string("thread/start"))
            let threadParams = thread["params"]?.objectValue
            XCTAssertEqual(threadParams?["ephemeral"], .bool(true))
            XCTAssertEqual(threadParams?["approvalPolicy"], .string("never"))
            XCTAssertEqual(threadParams?["sandbox"], .string("read-only"))
            XCTAssertEqual(threadParams?["cwd"], .string(workingDirectory.path))
            XCTAssertEqual(threadParams?["model"], .string("gpt-5.6-sol"))
            assertCodexTextOnlyThreadConfiguration(threadParams)
            try await transport.sendServerObject(.object([
                "id": thread["id"]!, "result": .object(["thread": .object(["id": .string("thread-1")])])
            ]))

            let turn = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(turn["method"], .string("turn/start"))
            XCTAssertEqual(
                turn["params"]?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"],
                .string("hello")
            )
            let turnParams = turn["params"]?.objectValue
            XCTAssertEqual(turnParams?["cwd"], .string(workingDirectory.path))
            XCTAssertEqual(turnParams?["approvalPolicy"], .string("never"))
            let sandboxPolicy = turnParams?["sandboxPolicy"]?.objectValue
            XCTAssertEqual(
                Set(sandboxPolicy?.keys.map { $0 } ?? []),
                Set(["networkAccess", "type"])
            )
            XCTAssertEqual(sandboxPolicy?["type"], .string("readOnly"))
            XCTAssertEqual(sandboxPolicy?["networkAccess"], .bool(false))
            try await transport.sendServerObject(.object([
                "id": turn["id"]!, "result": .object(["turn": .object(["id": .string("turn-1")])])
            ]))

            let interrupt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(interrupt["method"], .string("turn/interrupt"))
            XCTAssertEqual(interrupt["params"]?.objectValue?["threadId"], .string("thread-1"))
            XCTAssertEqual(interrupt["params"]?.objectValue?["turnId"], .string("turn-1"))
            try await transport.sendServerObject(.object([
                "id": interrupt["id"]!, "result": .object([:])
            ]))
            try await transport.sendServerObject(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "item": .object(["type": .string("agentMessage"), "text": .string("safe reply")])
                ])
            ]))
        }

        try await client.initialize()
        let accountState = try await client.readAccount()
        XCTAssertEqual(
            accountState,
            .signedIn(type: "chatgpt", requiresOpenAIAuth: true, planType: "plus")
        )
        let models = try await client.listModels()
        XCTAssertEqual(
            models,
            [
                CodexModel(id: "gpt-5.3-codex", isDefault: false),
                CodexModel(id: "gpt-5.6-sol", isDefault: true)
            ]
        )
        let threadID = try await client.startEphemeralThread(model: "gpt-5.6-sol")
        XCTAssertEqual(threadID, "thread-1")
        let turnID = try await client.startTextTurn(threadID: threadID, text: "hello")
        XCTAssertEqual(turnID, "turn-1")
        try await client.interrupt(threadID: threadID, turnID: turnID)
        let codexEvent = try await client.nextEvent()
        XCTAssertEqual(codexEvent, .agentMessage("safe reply"))
        try await server.value
        await client.close()
    }

    func testCodexGenerationRequiresConsistentDeltasOneFinalAndCompletedTurn() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty"),
            restrictedReadSupport: .supported
        )
        let server = Task {
            try await serveCodexGenerationPrelude(on: transport)
            try await sendCodexDelta("safe ", on: transport)
            try await sendCodexDelta("reply", on: transport)
            try await sendCodexFinal("safe reply", on: transport)
            try await sendCodexTurnCompleted(on: transport)
        }

        try await client.initialize()
        let text = try await client.generateText(
            model: "gpt-5.6-sol",
            prompt: "system\nuser"
        )

        XCTAssertEqual(text, "safe reply")
        try await server.value
        let outgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingCount, 0)
        await client.close()
    }

    func testCodexGenerationRejectsAggregateTranscriptDriftAndInterruptsExactTurn() async throws {
        enum Scenario: String, CaseIterable, Sendable {
            case deltaMismatch
            case duplicateFinal
            case oversizedDelta
        }

        for scenario in Scenario.allCases {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .codex,
                allowedNotifications: CodexAppServerClient.allowedNotifications
            )
            let client = CodexAppServerClient(
                peer: peer,
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty"),
                restrictedReadSupport: .supported
            )
            let server = Task {
                try await serveCodexGenerationPrelude(on: transport)
                switch scenario {
                case .deltaMismatch:
                    try await sendCodexDelta("streamed", on: transport)
                    try await sendCodexFinal("different", on: transport)
                case .duplicateFinal:
                    try await sendCodexFinal("first", on: transport)
                    try await sendCodexFinal("second", on: transport)
                case .oversizedDelta:
                    try await sendCodexDelta(
                        String(repeating: "a", count: 131_073),
                        on: transport
                    )
                }
                try await serveCodexOwnedTurnInterrupt(on: transport)
            }

            try await client.initialize()
            do {
                _ = try await client.generateText(
                    model: "gpt-5.6-sol",
                    prompt: "system\nuser"
                )
                XCTFail("Expected aggregate transcript rejection: \(scenario.rawValue)")
            } catch let error as CodexAppServerError {
                XCTAssertEqual(error, .invalidResponse, scenario.rawValue)
            } catch {
                XCTFail("Unexpected error for \(scenario.rawValue): \(error)")
            }
            try await server.value
            await client.close()
        }
    }

    func testCodexGenerationRejectsMissingFinalOnCompletedTurn() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty"),
            restrictedReadSupport: .supported
        )
        let server = Task {
            try await serveCodexGenerationPrelude(on: transport)
            try await sendCodexDelta("orphaned", on: transport)
            try await sendCodexTurnCompleted(on: transport)
        }

        try await client.initialize()
        do {
            _ = try await client.generateText(
                model: "gpt-5.6-sol",
                prompt: "system\nuser"
            )
            XCTFail("Expected missing final rejection")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try await server.value
        let missingFinalClosed = await transport.isClosed
        XCTAssertTrue(missingFinalClosed)
    }

    func testCodexGenerationFailsClosedForToolAndForeignTranscriptEvents() async throws {
        enum Scenario: String, CaseIterable, Sendable {
            case tool
            case foreign

            var expectedError: CodexAppServerError {
                switch self {
                case .tool: .disallowedItem
                case .foreign: .unknownThread
                }
            }
        }

        for scenario in Scenario.allCases {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .codex,
                allowedNotifications: CodexAppServerClient.allowedNotifications
            )
            let client = CodexAppServerClient(
                peer: peer,
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty"),
                restrictedReadSupport: .supported
            )
            let server = Task {
                try await serveCodexGenerationPrelude(on: transport)
                switch scenario {
                case .tool:
                    try await sendCodexFinal(
                        "",
                        on: transport,
                        itemType: "commandExecution"
                    )
                case .foreign:
                    try await sendCodexFinal(
                        "foreign",
                        on: transport,
                        threadID: "foreign-thread"
                    )
                }
            }

            try await client.initialize()
            do {
                _ = try await client.generateText(
                    model: "gpt-5.6-sol",
                    prompt: "system\nuser"
                )
                XCTFail("Expected fail-closed transcript rejection: \(scenario.rawValue)")
            } catch let error as CodexAppServerError {
                XCTAssertEqual(error, scenario.expectedError, scenario.rawValue)
            } catch {
                XCTFail("Unexpected error for \(scenario.rawValue): \(error)")
            }
            try await server.value
            let rejectedTranscriptClosed = await transport.isClosed
            XCTAssertTrue(rejectedTranscriptClosed)
        }
    }

    func testCodexAccountStatePreservesSignedOutAuthRequirement() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()

            let account = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(account["method"], .string("account/read"))
            try await transport.sendServerObject(.object([
                "id": account["id"]!,
                "result": .object([
                    "account": .null,
                    "requiresOpenaiAuth": .bool(true)
                ])
            ]))
        }

        try await client.initialize()
        let state = try await client.readAccount()
        XCTAssertEqual(state, .signedOut(requiresOpenAIAuth: true))
        try await server.value
        await client.close()
    }

    func testCodexClientUsesPinnedAccountLogoutContract() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()

            let logout = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(logout["method"], .string("account/logout"))
            XCTAssertEqual(logout["params"], .null)
            try await transport.sendServerObject(.object([
                "id": logout["id"]!, "result": .object([:])
            ]))
        }

        try await client.initialize()
        try await client.logout()
        try await server.value
        await client.close()
    }

    func testCodexClientStartsChatGPTLoginAndConsumesOwnedAuthEvents() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()

            let login = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(login["method"], .string("account/login/start"))
            let params = login["params"]?.objectValue
            XCTAssertEqual(params?["type"], .string("chatgpt"))
            XCTAssertEqual(params?["useHostedLoginSuccessPage"], .bool(true))
            XCTAssertEqual(params?["appBrand"], .string("chatgpt"))
            try await transport.sendServerObject(.object([
                "id": login["id"]!,
                "result": .object([
                    "type": .string("chatgpt"),
                    "loginId": .string("login-owned"),
                    "authUrl": .string("https://chatgpt.com/auth/authorize")
                ])
            ]))
            try await transport.sendServerObject(.object([
                "method": .string("account/login/completed"),
                "params": .object([
                    "loginId": .string("login-owned"),
                    "success": .bool(true),
                    "error": .null
                ])
            ]))
            try await transport.sendServerObject(.object([
                "method": .string("account/updated"),
                "params": .object([
                    "authMode": .string("chatgpt"),
                    "planType": .string("plus")
                ])
            ]))
        }

        try await client.initialize()
        let attempt = try await client.startChatGPTLogin()
        XCTAssertEqual(attempt.loginID, "login-owned")
        XCTAssertNil(attempt.userCode)
        XCTAssertEqual(
            attempt.authorizationURL,
            URL(string: "https://chatgpt.com/auth/authorize")!
        )
        let completedEvent = try await client.nextAuthEvent()
        XCTAssertEqual(
            completedEvent,
            .loginCompleted(loginID: "login-owned", success: true)
        )
        let updatedEvent = try await client.nextAuthEvent()
        XCTAssertEqual(
            updatedEvent,
            .accountUpdated(authMode: "chatgpt", planType: "plus")
        )
        try await server.value

        await client.close()
        let outgoingAfterDisconnect = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingAfterDisconnect, 0)
    }

    func testCodexClientStartsDeviceCodeLoginWithExactBoundedPresentation() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()

            let login = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(login["method"], .string("account/login/start"))
            XCTAssertEqual(
                login["params"],
                .object(["type": .string("chatgptDeviceCode")])
            )
            try await transport.sendServerObject(.object([
                "id": login["id"]!,
                "result": .object([
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login-owned"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ])
            ]))
            try await transport.sendServerObject(.object([
                "method": .string("account/login/completed"),
                "params": .object([
                    "loginId": .string("device-login-owned"),
                    "success": .bool(true),
                    "error": .null
                ])
            ]))
        }

        try await client.initialize()
        let attempt = try await client.startChatGPTDeviceCodeLogin()
        XCTAssertEqual(attempt.loginID, "device-login-owned")
        XCTAssertEqual(
            attempt.authorizationURL,
            URL(string: "https://auth.openai.com/device")!
        )
        XCTAssertEqual(attempt.userCode, "ABCD-EFGH")
        let completedEvent = try await client.nextAuthEvent()
        XCTAssertEqual(
            completedEvent,
            .loginCompleted(loginID: "device-login-owned", success: true)
        )
        try await server.value
        await client.close()
    }

    func testCodexClientRejectsInvalidDeviceCodeLoginPresentation() async throws {
        let scenarios: [(name: String, result: [String: JSONValue])] = [
            (
                "wrong-type",
                [
                    "type": .string("chatgpt"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "empty-login-id",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string(""),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "oversized-login-id",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string(String(repeating: "L", count: 257)),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "non-https-url",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("http://auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "untrusted-host",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://example.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "url-userinfo",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://user@auth.openai.com/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "url-nonstandard-port",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com:444/device"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "url-fragment",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device#secret"),
                    "userCode": .string("ABCD-EFGH")
                ]
            ),
            (
                "empty-code",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("")
                ]
            ),
            (
                "surrounding-whitespace",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string(" ABCD-EFGH ")
                ]
            ),
            (
                "control-character",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD" + String(UnicodeScalar(10)!) + "EFGH")
                ]
            ),
            (
                "too-short-code",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABC")
                ]
            ),
            (
                "lowercase-code",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("abcd-1234")
                ]
            ),
            (
                "punctuation-code",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("ABCD_1234")
                ]
            ),
            (
                "oversized-code",
                [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string(String(repeating: "A", count: 65))
                ]
            )
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .codex,
                allowedNotifications: CodexAppServerClient.allowedNotifications
            )
            let client = CodexAppServerClient(
                peer: peer,
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
            )
            let server = Task {
                let initialize = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "id": initialize["id"]!, "result": .object([:])
                ]))
                _ = try await transport.nextClientObject()
                let login = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "id": login["id"]!, "result": .object(scenario.result)
                ]))
            }

            try await client.initialize()
            do {
                _ = try await client.startChatGPTDeviceCodeLogin()
                XCTFail("Expected invalid device-code response: \(scenario.name)")
            } catch let error as CodexAppServerError {
                XCTAssertEqual(error, .invalidResponse, scenario.name)
            }
            try await server.value
            await client.close()
        }
    }

    func testCodexClientCancelsExactOwnedDeviceCodeLogin() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()
            let login = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": login["id"]!,
                "result": .object([
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("device-login-cancel"),
                    "verificationUrl": .string("https://auth.openai.com/device"),
                    "userCode": .string("WXYZ-1234")
                ])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("account/login/cancel"))
            XCTAssertEqual(
                cancel["params"],
                .object(["loginId": .string("device-login-cancel")])
            )
            try await transport.sendServerObject(.object([
                "id": cancel["id"]!, "result": .object([:])
            ]))
        }

        try await client.initialize()
        let attempt = try await client.startChatGPTDeviceCodeLogin()
        try await client.cancelLogin(loginID: attempt.loginID)
        try await server.value
        await client.close()
    }

    func testCodexClientCancelsOnlyItsLoginAndLocalDisconnectDoesNotLogout() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            _ = try await transport.nextClientObject()

            let login = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": login["id"]!,
                "result": .object([
                    "type": .string("chatgpt"),
                    "loginId": .string("login-cancel"),
                    "authUrl": .string("https://chatgpt.com/auth/cancel")
                ])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("account/login/cancel"))
            XCTAssertEqual(
                cancel["params"]?.objectValue?["loginId"],
                .string("login-cancel")
            )
            try await transport.sendServerObject(.object([
                "id": cancel["id"]!, "result": .object([:])
            ]))
            try await transport.sendServerObject(.object([
                "method": .string("account/login/completed"),
                "params": .object([
                    "loginId": .string("login-cancel"),
                    "success": .bool(false),
                    "error": .string("cancelled")
                ])
            ]))
        }

        try await client.initialize()
        let attempt = try await client.startChatGPTLogin()
        try await client.cancelLogin(loginID: attempt.loginID)
        let cancelledEvent = try await client.nextAuthEvent()
        XCTAssertEqual(
            cancelledEvent,
            .loginCompleted(loginID: "login-cancel", success: false)
        )
        try await server.value

        await client.close()
        let outgoingAfterDisconnect = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingAfterDisconnect, 0)
    }

    func testCodexClientRejectsToolItems() async throws {
        for itemType in ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall"] {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .codex,
                allowedNotifications: CodexAppServerClient.allowedNotifications
            )
            let client = CodexAppServerClient(
                peer: peer,
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty"),
                restrictedReadSupport: .supported
            )
            let server = Task {
                let initialize = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "id": initialize["id"]!, "result": .object([:])
                ]))
                _ = try await transport.nextClientObject()
                let thread = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "id": thread["id"]!,
                    "result": .object(["thread": .object(["id": .string("thread-tool")])])
                ]))
                let turn = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "id": turn["id"]!,
                    "result": .object(["turn": .object(["id": .string("turn-tool")])])
                ]))
                try await transport.sendServerObject(.object([
                    "method": .string("item/completed"),
                    "params": .object([
                        "threadId": .string("thread-tool"),
                        "turnId": .string("turn-tool"),
                        "item": .object(["type": .string(itemType)])
                    ])
                ]))
            }

            try await client.initialize()
            let threadID = try await client.startEphemeralThread(model: nil)
            _ = try await client.startTextTurn(threadID: threadID, text: "hello")
            do {
                _ = try await client.nextEvent()
                XCTFail("Expected tool rejection: \(itemType)")
            } catch let error as CodexAppServerError {
                XCTAssertEqual(error, .disallowedItem)
            }
            try await server.value
            let codexClosed = await transport.isClosed
            XCTAssertTrue(codexClosed)
        }
    }

    func testCodexClientWithoutVerifiedRestrictedReadRejectsTurnBeforeSendingIt() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .codex,
            allowedNotifications: CodexAppServerClient.allowedNotifications
        )
        let client = CodexAppServerClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "id": initialize["id"]!, "result": .object([:])
            ]))
            let initialized = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(initialized["method"], .string("initialized"))

            let thread = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(thread["method"], .string("thread/start"))
            try await transport.sendServerObject(.object([
                "id": thread["id"]!,
                "result": .object(["thread": .object(["id": .string("thread-unverified")])])
            ]))
        }

        try await client.initialize()
        let threadID = try await client.startEphemeralThread(model: nil)
        XCTAssertEqual(threadID, "thread-unverified")
        try await server.value

        do {
            _ = try await client.startTextTurn(threadID: threadID, text: "must not be sent")
            XCTFail("Expected restricted-read capability rejection")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .restrictedReadUnavailable)
        }
        let queuedOutgoingCount = await transport.queuedOutgoingCount()
        let unsupportedConnectionClosed = await transport.isClosed
        XCTAssertEqual(queuedOutgoingCount, 0)
        XCTAssertTrue(unsupportedConnectionClosed)
    }

    func testGrokClientIgnoresOnlyAuditedAmbientNotificationsBeforeSessionEvent() async throws {
        let ambientNotifications: Set<String> = [
            "_x.ai/announcements/update",
            "_x.ai/models/update",
            "_x.ai/settings/update"
        ]
        let verificationLifecycleNotifications: Set<String> = [
            "_x.ai/mcp/servers_updated",
            "_x.ai/mcp_initialized",
            "_x.ai/session_notification",
            "x.ai/session_notification",
            "_x.ai/sessions/changed",
            "_x.ai/queue/changed",
            "_x.ai/session/prompt_complete"
        ]
        XCTAssertEqual(
            GrokACPClient.allowedNotifications,
            ambientNotifications
                .union(verificationLifecycleNotifications)
                .union([
                    "session/update",
                    "x.ai/session/update",
                    "_x.ai/session/update"
                ])
        )

        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            let sessionParams = try XCTUnwrap(session["params"]?.objectValue)
            XCTAssertEqual(Set(sessionParams.keys), ["cwd", "mcpServers"])
            XCTAssertNil(sessionParams["_meta"])
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("session-passive")])
            ]))

            for method in ambientNotifications.sorted() {
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "method": .string(method),
                    "params": .object(["snapshot": .object([:])])
                ]))
            }
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string("session-passive"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string("after-passive")
                        ])
                    ])
                ])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        _ = try await client.newSession()
        let event = try await client.nextEvent()

        XCTAssertEqual(event, .agentMessageChunk("after-passive"))
        try await server.value
        await client.close()
    }

    func testGrokClientStillFailsClosedForUnknownNotification() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("session-unknown")])
            ]))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("_x.ai/unknown/update"),
                "params": .object([:])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        _ = try await client.newSession()
        do {
            _ = try await client.nextEvent()
            XCTFail("Expected unknown notification rejection")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .unknownNotification)
        }
        try await server.value
        let unknownNotificationClosed = await transport.isClosed
        XCTAssertTrue(unknownNotificationClosed)
    }

    func testGrokGenerationAcceptsArbitraryPromptAndReturnsNonemptyBoundedReply() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "generation-session"
        let promptText = "Classify invoice.pdf without tools."
        let replyText = "work"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID
            )

            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))
            XCTAssertEqual(
                prompt["params"]?.objectValue?["prompt"]?.arrayValue?
                    .first?.objectValue?["text"],
                .string(promptText)
            )
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: sessionID,
                type: "user_message_chunk",
                text: promptText
            )
            try await sendGrokResponseStarted(on: transport, sessionID: sessionID)
            try await sendGrokReasoningCompleted(on: transport, sessionID: sessionID)
            for chunk in ["wo", "rk"] {
                try await sendGrokSessionUpdate(
                    on: transport,
                    sessionID: sessionID,
                    type: "agent_message_chunk",
                    text: chunk
                )
            }
            try await sendGrokResponseCompleted(on: transport, sessionID: sessionID)
            try await sendGrokTurnCompleted(
                on: transport,
                sessionID: sessionID,
                agentResult: replyText
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(
                close["params"]?.objectValue?["sessionId"],
                .string(sessionID)
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationPostEvents(
                [.thought()],
                on: transport,
                sessionID: sessionID
            )
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: sessionID
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        let generated = try await client.generateText(prompt: promptText)

        XCTAssertEqual(generated, replyText)
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, [sessionID])
        await client.close()
    }

    func testGrokMinimalVerificationAcceptsDynamicSetupMetadataUsesFixedPromptAndClosesOwnedSession() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let workingDirectory = URL(
            fileURLWithPath: "/private/tmp/xunjian-verification-empty",
            isDirectory: true
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: workingDirectory
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(
                initialize["params"]?.objectValue?["clientCapabilities"]?
                    .objectValue?["fs"]?.objectValue?["readTextFile"],
                .bool(false)
            )
            XCTAssertEqual(
                initialize["params"]?.objectValue?["clientCapabilities"]?
                    .objectValue?["fs"]?.objectValue?["writeTextFile"],
                .bool(false)
            )
            XCTAssertEqual(
                initialize["params"]?.objectValue?["clientCapabilities"]?
                    .objectValue?["terminal"],
                .bool(false)
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))

            let authenticate = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(authenticate["method"], .string("authenticate"))
            XCTAssertEqual(
                authenticate["params"]?.objectValue?["methodId"],
                .string("cached_token")
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))

            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            let sessionParams = try XCTUnwrap(session["params"]?.objectValue)
            XCTAssertEqual(Set(sessionParams.keys), ["cwd", "mcpServers"])
            XCTAssertEqual(sessionParams["cwd"], .string(workingDirectory.path))
            XCTAssertEqual(sessionParams["mcpServers"], .array([]))
            XCTAssertNil(sessionParams["_meta"])
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("verification-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "verification-session",
                firstAvailableOuterMetadata: makeExactGrokAvailableOuterMetadata(
                    timestampMilliseconds: 1_786_356_100_000,
                    eventID: "verification-available-commands-first"
                ),
                secondAvailableOuterMetadata: makeExactGrokAvailableOuterMetadata(
                    timestampMilliseconds: 1_786_356_100_001,
                    eventID: "verification-available-commands-second"
                )
            )

            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))
            XCTAssertEqual(
                prompt["params"]?.objectValue?["prompt"]?.arrayValue?
                    .first?.objectValue?["text"],
                .string("Reply exactly XUNJIAN_OK. Do not use tools.")
            )
            for text in ["Reply exactly XUNJIAN_", "OK. Do not use tools."] {
                try await sendGrokSessionUpdate(
                    on: transport,
                    sessionID: "verification-session",
                    type: "user_message_chunk",
                    text: text
                )
            }
            try await sendGrokResponseStarted(
                on: transport,
                sessionID: "verification-session"
            )
            try await sendGrokReasoningCompleted(
                on: transport,
                sessionID: "verification-session"
            )
            for text in ["XUNJIAN_", "OK"] {
                try await sendGrokSessionUpdate(
                    on: transport,
                    sessionID: "verification-session",
                    type: "agent_message_chunk",
                    text: text
                )
            }
            try await sendGrokResponseCompletionLifecycle(
                on: transport,
                sessionID: "verification-session"
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(
                close["params"]?.objectValue?["sessionId"],
                .string("verification-session")
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "verification-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        try await client.verifyMinimalConnection()
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, ["verification-session"])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        let queuedOutgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(queuedOutgoingCount, 0)
        await client.close()
    }

    func testGrokVerificationReportsOnlyStaticDiagnosticCodeForSetupRejection() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "diagnostic-session"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID,
                mcpToolCount: 1
            )
            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: sessionID
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected setup rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .disallowedUpdate)
        }
        let diagnostic = await client.takeVerificationDiagnostic()
        XCTAssertEqual(diagnostic, .setupMCPInitialized)
        XCTAssertEqual(diagnostic?.rawValue, "setup.mcp-initialized")
        XCTAssertFalse(diagnostic?.rawValue.contains(sessionID) == true)
        let repeatedDiagnostic = await client.takeVerificationDiagnostic()
        XCTAssertNil(repeatedDiagnostic)
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationAcceptsExactCurrentModelChangedNotificationMethod() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "current-model-method-session"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID,
                modelChangedMethod: "x.ai/session_notification"
            )

            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))
            try await sendGrokCompleteVerificationPostLifecycle(
                on: transport,
                sessionID: sessionID
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: sessionID
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        try await client.verifyMinimalConnection()
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, [sessionID])
        await client.close()
    }

    func testGrokMinimalVerificationRejectsOtherModelChangedNotificationMethod() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "unknown-model-method-session"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID,
                modelChangedMethod: "x.ai/session-notification"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected unrecognized model_changed method rejection")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .unknownNotification)
        }
        try await server.value
        let isClosed = await transport.isClosed
        XCTAssertTrue(isClosed)
    }

    func testGrokVerificationTakesSetupSessionDiagnosticOnceForSessionCreationFailures() async throws {
        for scenarioName in ["remote-error", "malformed-result"] {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let server = Task {
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(session["method"], .string("session/new"), scenarioName)
                if scenarioName == "remote-error" {
                    try await transport.sendServerObject(.object([
                        "jsonrpc": .string("2.0"),
                        "id": session["id"]!,
                        "error": .object([
                            "code": .integer(-32_101),
                            "message": .string("sensitive remote detail")
                        ])
                    ]))
                } else {
                    try await transport.sendServerObject(.object([
                        "jsonrpc": .string("2.0"),
                        "id": session["id"]!,
                        "result": .object(["sessionId": .string("")])
                    ]))
                }
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected session creation failure: \(scenarioName)")
            } catch {
                if scenarioName == "remote-error" {
                    XCTAssertEqual(
                        error as? JSONLineRPCError,
                        .remoteError(code: -32_101),
                        scenarioName
                    )
                } else {
                    XCTAssertEqual(error as? GrokACPError, .invalidResponse, scenarioName)
                }
            }
            let diagnostic = await client.takeVerificationDiagnostic()
            XCTAssertEqual(diagnostic, .setupSession, scenarioName)
            XCTAssertEqual(diagnostic?.rawValue, "setup.session", scenarioName)
            XCTAssertFalse(
                diagnostic?.rawValue.contains("sensitive") == true,
                scenarioName
            )
            let repeatedDiagnostic = await client.takeVerificationDiagnostic()
            XCTAssertNil(repeatedDiagnostic, scenarioName)
            try await server.value
            await client.close()
        }
    }

    func testGrokVerificationRejectsPostPromptMetadataDriftWithStaticDiagnostics() async throws {
        let scenarios: [(
            name: String,
            error: GrokACPError,
            diagnostic: GrokVerificationDiagnostic
        )] = [
            ("response-extra-key", .disallowedUpdate, .postResponseStarted),
            ("thought-byte-budget", .invalidResponse, .postThoughtBudget),
            ("queue-foreign-session", .disallowedUpdate, .postQueueChanged),
            ("sessions-wrong-cwd", .disallowedUpdate, .postSessionsChanged),
            ("usage-invalid-size", .disallowedUpdate, .postUnexpectedUpdate),
            ("session-info-empty-title", .disallowedUpdate, .postUnexpectedUpdate),
            ("prompt-complete-extra-key", .disallowedUpdate, .postPromptCompleteKeys)
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let sessionID = "post-diagnostic-\(scenario.name)"
            let server = Task {
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                let prompt = try await transport.nextClientObject().objectValue!
                try await sendGrokSessionUpdate(
                    on: transport,
                    sessionID: sessionID,
                    type: "user_message_chunk",
                    text: "Reply exactly XUNJIAN_OK. Do not use tools."
                )

                if scenario.name == "response-extra-key" {
                    try await sendGrokNotification(
                        on: transport,
                        method: "_x.ai/session_notification",
                        params: .object([
                            "sessionId": .string(sessionID),
                            "update": .object([
                                "cache_creation_input_tokens": .integer(0),
                                "cache_read_input_tokens": .integer(0),
                                "input_tokens": .integer(1),
                                "message_id": .string("verification-message"),
                                "model": .string("grok-4.5"),
                                "sessionUpdate": .string("response_started"),
                                "tool": .string("must-not-run")
                            ])
                        ])
                    )
                } else if scenario.name == "thought-byte-budget" {
                    try await sendGrokResponseStarted(
                        on: transport,
                        sessionID: sessionID
                    )
                    try await sendGrokSessionUpdate(
                        on: transport,
                        sessionID: sessionID,
                        type: "agent_thought_chunk",
                        text: String(repeating: "x", count: 65_537)
                    )
                } else if scenario.name == "queue-foreign-session" {
                    try await sendGrokNotification(
                        on: transport,
                        method: "_x.ai/queue/changed",
                        params: .object([
                            "entries": .array([]),
                            "sessionId": .string("foreign-session")
                        ])
                    )
                } else if scenario.name == "sessions-wrong-cwd" {
                    try await sendGrokNotification(
                        on: transport,
                        method: "_x.ai/sessions/changed",
                        params: .object([
                            "removed": .array([]),
                            "upserted": .array([.object([
                                "activity": .string("running"),
                                "cwd": .string("/private/tmp/not-owned"),
                                "isWorktree": .bool(false),
                                "lastChangeUnixMs": .integer(1),
                                "modelId": .string("grok-4.5"),
                                "origin": .object(["kind": .string("acp")]),
                                "reasoningEffort": .string("high"),
                                "resident": .bool(false),
                                "sessionId": .string(sessionID),
                                "title": .null,
                                "yolo": .bool(false)
                            ])])
                        ])
                    )
                } else if scenario.name == "usage-invalid-size" {
                    try await sendGrokNotification(
                        on: transport,
                        method: "session/update",
                        params: .object([
                            "sessionId": .string(sessionID),
                            "update": .object([
                                "sessionUpdate": .string("usage_update"),
                                "size": .integer(10),
                                "used": .integer(11)
                            ])
                        ])
                    )
                } else if scenario.name == "session-info-empty-title" {
                    try await sendGrokNotification(
                        on: transport,
                        method: "session/update",
                        params: .object([
                            "sessionId": .string(sessionID),
                            "update": .object([
                                "sessionUpdate": .string("session_info_update"),
                                "title": .string("")
                            ])
                        ])
                    )
                } else {
                    try await sendGrokVerificationPostEvents(
                        Array(exactGrokVerificationPostEvents.dropFirst()),
                        on: transport,
                        sessionID: sessionID
                    )
                    try await sendGrokNotification(
                        on: transport,
                        method: "_x.ai/session/prompt_complete",
                        params: .object([
                            "agentResult": .string("XUNJIAN_OK"),
                            "extra": .bool(true),
                            "promptId": .string("verification-prompt"),
                            "sessionId": .string(sessionID),
                            "stopReason": .string("end_turn"),
                            "turnId": .string("verification-turn")
                        ])
                    )
                }
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": prompt["id"]!,
                    "result": .object(["stopReason": .string("end_turn")])
                ]))

                let cancel = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(cancel["method"], .string("session/cancel"), scenario.name)
                let close = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(close["method"], .string("session/close"), scenario.name)
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected post-prompt rejection: \(scenario.name)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, scenario.error, scenario.name)
            }
            let diagnostic = await client.takeVerificationDiagnostic()
            XCTAssertEqual(diagnostic, scenario.diagnostic, scenario.name)
            try await server.value
            await client.close()
        }
    }

    func testGrokVerificationRequiresOrderedCompletePostLifecycleWithStableIdentifiers() async throws {
        let prompt: GrokVerificationPostEvent = .promptEcho
        let started: GrokVerificationPostEvent = .responseStarted()
        let thought: GrokVerificationPostEvent = .thought()
        let reasoning: GrokVerificationPostEvent = .reasoningCompleted
        let reply: GrokVerificationPostEvent = .agentReply()
        let response: GrokVerificationPostEvent = .responseCompleted()
        let turn: GrokVerificationPostEvent = .turnCompleted()
        let scenarios: [(
            name: String,
            events: [GrokVerificationPostEvent],
            error: GrokACPError,
            diagnostic: GrokVerificationDiagnostic
        )] = [
            (
                "missing-prompt-echo",
                [started, thought, reasoning, reply, response, turn],
                .disallowedUpdate,
                .postResponseStarted
            ),
            (
                "missing-agent-reply",
                [prompt, started, thought, reasoning, response, turn],
                .disallowedUpdate,
                .postResponseCompletedReply
            ),
            (
                "missing-response-completed",
                [prompt, started, thought, reasoning, reply, turn],
                .invalidResponse,
                .postLifecycleResponseCompleted
            ),
            (
                "missing-turn-completed",
                [prompt, started, thought, reasoning, reply, response],
                .invalidResponse,
                .postLifecycleTurnCompleted
            ),
            (
                "duplicate-response-started",
                [prompt, started, started, thought, reasoning, reply, response, turn],
                .disallowedUpdate,
                .postResponseStarted
            ),
            (
                "duplicate-reasoning-completed",
                [prompt, started, thought, reasoning, reasoning, reply, response, turn],
                .disallowedUpdate,
                .postReasoningCompleted
            ),
            (
                "duplicate-response-completed",
                [prompt, started, thought, reasoning, reply, response, response, turn],
                .disallowedUpdate,
                .postResponseCompletedDuplicate
            ),
            (
                "duplicate-turn-completed",
                [prompt, started, thought, reasoning, reply, response, turn, turn],
                .disallowedUpdate,
                .postTurnCompletedPhase
            ),
            (
                "adjacent-agent-response-reordered",
                [prompt, started, thought, reasoning, response, reply, turn],
                .disallowedUpdate,
                .postResponseCompletedReply
            ),
            (
                "response-message-id-drift",
                [
                    prompt, started, thought, reasoning, reply,
                    .responseCompleted(messageID: "drifted-message"), turn
                ],
                .disallowedUpdate,
                .postResponseCompletedMessageID
            ),
            (
                "agent-prompt-id-drift",
                [
                    prompt, started, thought, reasoning,
                    .agentReply(promptID: "drifted-prompt"), response, turn
                ],
                .invalidResponse,
                .postEnvelope
            ),
            (
                "turn-prompt-id-drift",
                [
                    prompt, started, thought, reasoning, reply, response,
                    .turnCompleted(promptID: "drifted-prompt")
                ],
                .disallowedUpdate,
                .postTurnCompletedPromptID
            )
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let sessionID = "post-lifecycle-\(scenario.name)"
            let server = Task { () throws -> [String] in
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                let promptRequest = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(
                    promptRequest["method"],
                    .string("session/prompt"),
                    scenario.name
                )
                try await sendGrokVerificationPostEvents(
                    scenario.events,
                    on: transport,
                    sessionID: sessionID
                )
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": promptRequest["id"]!,
                    "result": .object(["stopReason": .string("end_turn")])
                ]))

                let firstCleanup = try await transport.nextClientObject().objectValue!
                let firstMethod = firstCleanup["method"]?.stringValue ?? ""
                let close: [String: JSONValue]
                if firstMethod == "session/close" {
                    close = firstCleanup
                } else {
                    XCTAssertEqual(
                        firstCleanup["method"],
                        .string("session/cancel"),
                        scenario.name
                    )
                    close = try await transport.nextClientObject().objectValue!
                }
                XCTAssertEqual(close["method"], .string("session/close"), scenario.name)
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                return firstMethod == "session/close"
                    ? [firstMethod]
                    : [firstMethod, "session/close"]
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected post lifecycle rejection: \(scenario.name)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, scenario.error, scenario.name)
            }
            let diagnostic = await client.takeVerificationDiagnostic()
            XCTAssertEqual(diagnostic, scenario.diagnostic, scenario.name)
            XCTAssertFalse(diagnostic?.rawValue.contains(sessionID) == true, scenario.name)
            let repeatedDiagnostic = await client.takeVerificationDiagnostic()
            XCTAssertNil(repeatedDiagnostic, scenario.name)
            let cleanupMethods = try await server.value
            let closesWithoutCancellation: Set<String> = [
                "missing-response-started",
                "missing-reasoning-completed",
                "missing-response-completed",
                "missing-turn-completed"
            ]
            XCTAssertEqual(
                cleanupMethods,
                closesWithoutCancellation.contains(scenario.name)
                    ? ["session/close"]
                    : ["session/cancel", "session/close"],
                scenario.name
            )
            await client.close()
        }
    }

    func testGrokVerificationAcceptsAuditedInterleavedLiveLifecycleNotifications() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "interleaved-live-session"
        let promptID = "verification-prompt"
        let queueID = UUID().uuidString
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            var firstMetadata = makeExactGrokAvailableOuterMetadata()
            firstMetadata["totalTokens"] = .number(0.5)
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID,
                firstAvailableOuterMetadata: firstMetadata
            )
            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))

            try await sendGrokNotification(
                on: transport,
                method: "_x.ai/queue/changed",
                params: .object([
                    "entries": .array([.object([
                        "id": .string(queueID),
                        "kind": .string("prompt"),
                        "position": .integer(0),
                        "text": .string("queued verification"),
                        "version": .integer(1)
                    ])]),
                    "sessionId": .string(sessionID)
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "_x.ai/sessions/changed",
                params: .object([
                    "removed": .array([]),
                    "upserted": .array([.object([
                        "activity": .string("running"),
                        "cwd": .string("/private/tmp/xunjian-empty"),
                        "isWorktree": .bool(false),
                        "lastChangeUnixMs": .integer(1_786_356_200_000),
                        "modelId": .string("grok-4.5"),
                        "origin": .object(["kind": .string("acp")]),
                        "reasoningEffort": .string("high"),
                        "resident": .bool(false),
                        "sessionId": .string(sessionID),
                        "title": .null,
                        "yolo": .bool(false)
                    ])])
                ])
            )
            try await sendGrokVerificationPostEvents(
                [
                    .promptEcho,
                    .thought(),
                    .agentReply(),
                    .responseCompleted(messageID: nil, stopReason: nil),
                    .turnCompleted(
                        includeMetadata: false,
                        usage: .object([
                            "apiDurationMs": .integer(1),
                            "cacheCreationTokens": .integer(0),
                            "cachedReadTokens": .integer(0),
                            "costIsPartial": .bool(true),
                            "inputTokens": .integer(1),
                            "modelCalls": .integer(1),
                            "modelUsage": .object([
                                "grok-4.5-backend": .object([
                                    "cacheCreationInputTokens": .integer(0),
                                    "cacheReadInputTokens": .integer(0),
                                    "costUSD": .number(0.01),
                                    "inputTokens": .integer(1),
                                    "modelCalls": .integer(1),
                                    "outputTokens": .integer(1)
                                ])
                            ]),
                            "numTurns": .integer(1),
                            "outputTokens": .integer(1),
                            "reasoningTokens": .integer(1),
                            "totalTokens": .integer(2)
                        ])
                    ),
                    .thought(),
                    .thought()
                ],
                on: transport,
                sessionID: sessionID
            )
            try await sendGrokNotification(
                on: transport,
                method: "session/update",
                params: .object([
                    "sessionId": .string(sessionID),
                    "update": .object([
                        "cost": .object([
                            "amount": .number(0.01),
                            "currency": .string("USD")
                        ]),
                        "sessionUpdate": .string("usage_update"),
                        "size": .integer(131_072),
                        "used": .integer(1_024)
                    ])
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "session/update",
                params: .object([
                    "_meta": .object({
                        var metadata = makeExactGrokAvailableOuterMetadata(
                            timestampMilliseconds: 1_786_356_200_020,
                            eventID: "verification-post-commands"
                        )
                        metadata["promptId"] = .string(promptID)
                        metadata["streamStartMs"] = .integer(1_786_356_200_001)
                        metadata["turnStartMs"] = .integer(1_786_356_200_000)
                        return metadata
                    }()),
                    "sessionId": .string(sessionID),
                    "update": .object([
                        "_meta": .object(["tools": .array([])]),
                        "availableCommands": .array(makeExactGrokAvailableCommands()),
                        "sessionUpdate": .string("available_commands_update")
                    ])
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "session/update",
                params: .object([
                    "sessionId": .string(sessionID),
                    "update": .object([
                        "sessionUpdate": .string("session_info_update"),
                        "title": .string("Connection verification"),
                        "updatedAt": .string("2026-08-11T15:00:00Z")
                    ])
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "_x.ai/session_notification",
                params: .object([
                    "sessionId": .string(sessionID),
                    "update": .object([
                        "sessionUpdate": .string("session_summary_generated"),
                        "session_summary": .string("Audited bounded summary")
                    ])
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "_x.ai/session_notification",
                params: .object([
                    "sessionId": .string(sessionID),
                    "update": .object([
                        "prompt_id": .string(promptID),
                        "sessionUpdate": .string("last_turn_summary"),
                        "summary": .string("Verified connection")
                    ])
                ])
            )
            try await sendGrokNotification(
                on: transport,
                method: "_x.ai/session/prompt_complete",
                params: .object([
                    "agentResult": .null,
                    "stopReason": .string("end_turn")
                ])
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: sessionID
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        try await client.verifyMinimalConnection()
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationRejectsUnsafeSetupLifecycleTranscripts() async throws {
        let exactCommands = makeExactGrokAvailableCommands()
        var extraCommands = exactCommands
        extraCommands.append(.object([
            "description": .string("Must not be available."),
            "input": .object(["hint": .string("")]),
            "name": .string("unsafe-extra-command")
        ]))
        var driftedCommands = exactCommands
        var driftedCommand = try XCTUnwrap(driftedCommands[0].objectValue)
        driftedCommand["description"] = .string("Drifted declaration")
        driftedCommands[0] = .object(driftedCommand)
        var renamedCommands = exactCommands
        var renamedCommand = try XCTUnwrap(renamedCommands[0].objectValue)
        renamedCommand["name"] = .string("compact-drifted")
        renamedCommands[0] = .object(renamedCommand)
        var inputDriftedCommands = exactCommands
        var inputDriftedCommand = try XCTUnwrap(inputDriftedCommands[2].objectValue)
        inputDriftedCommand["input"] = .object([
            "hint": .string("")
        ])
        inputDriftedCommands[2] = .object(inputDriftedCommand)
        var extraFieldCommands = exactCommands
        var extraFieldCommand = try XCTUnwrap(extraFieldCommands[0].objectValue)
        extraFieldCommand["permission"] = .string("granted")
        extraFieldCommands[0] = .object(extraFieldCommand)
        var missingFieldCommands = exactCommands
        var missingFieldCommand = try XCTUnwrap(missingFieldCommands[0].objectValue)
        missingFieldCommand.removeValue(forKey: "description")
        missingFieldCommands[0] = .object(missingFieldCommand)
        var reorderedCommands = exactCommands
        reorderedCommands.swapAt(0, 1)
        var extraOuterMetadata = makeExactGrokAvailableOuterMetadata()
        extraOuterMetadata["permission"] = .string("granted")
        var missingOuterMetadata = makeExactGrokAvailableOuterMetadata()
        missingOuterMetadata.removeValue(forKey: "eventId")
        var wrongCommandCountMetadata = makeExactGrokAvailableOuterMetadata()
        wrongCommandCountMetadata["updateParams"] = .object([
            "commandsCount": .integer(5)
        ])
        let outerMetadataTypeOverrides: [(
            name: String,
            metadata: [String: JSONValue]
        )] = [
            ("timestamp", ["agentTimestampMs": .string("not-an-integer")]),
            ("event-id", ["eventId": .integer(1)]),
            ("total-tokens", ["totalTokens": .string("zero")]),
            ("update-params", ["updateParams": .string("not-an-object")]),
            ("update-type", ["updateType": .integer(1)])
        ]
        let mistypedOuterMetadata = outerMetadataTypeOverrides.map { scenario in
            var metadata = makeExactGrokAvailableOuterMetadata()
            for (key, value) in scenario.metadata {
                metadata[key] = value
            }
            return (name: scenario.name, metadata: metadata)
        }

        let scenarios: [(
            name: String,
            lifecycleSessionID: String?,
            mcpServers: [JSONValue],
            mcpToolCount: Int64,
            firstAvailableCommands: [JSONValue],
            secondAvailableCommands: [JSONValue]?,
            availableOuterMetadata: [String: JSONValue],
            injectedHookEventName: String?,
            hookRuns: [JSONValue],
            modelID: String,
            expectedError: GrokACPError
        )] = [
            (
                "nonempty-mcp-servers",
                nil,
                [.object(["name": .string("unsafe-server")])],
                0,
                exactCommands,
                nil,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "nonzero-mcp-tool-count",
                nil,
                [],
                1,
                exactCommands,
                nil,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "any-hook",
                nil,
                [],
                0,
                exactCommands,
                nil,
                makeExactGrokAvailableOuterMetadata(),
                "session_start",
                [],
                "grok-4.5",
                .invalidResponse
            ),
            (
                "foreign-session",
                "foreign-session",
                [],
                0,
                exactCommands,
                nil,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-extra-outer-meta",
                nil,
                [],
                0,
                exactCommands,
                nil,
                extraOuterMetadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-missing-outer-meta",
                nil,
                [],
                0,
                exactCommands,
                nil,
                missingOuterMetadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "commands-count-not-six",
                nil,
                [],
                0,
                exactCommands,
                nil,
                wrongCommandCountMetadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-mistyped-outer-meta-\(mistypedOuterMetadata[0].name)",
                nil,
                [],
                0,
                exactCommands,
                nil,
                mistypedOuterMetadata[0].metadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-mistyped-outer-meta-\(mistypedOuterMetadata[1].name)",
                nil,
                [],
                0,
                exactCommands,
                nil,
                mistypedOuterMetadata[1].metadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-mistyped-outer-meta-\(mistypedOuterMetadata[2].name)",
                nil,
                [],
                0,
                exactCommands,
                nil,
                mistypedOuterMetadata[2].metadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-mistyped-outer-meta-\(mistypedOuterMetadata[3].name)",
                nil,
                [],
                0,
                exactCommands,
                nil,
                mistypedOuterMetadata[3].metadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "available-mistyped-outer-meta-\(mistypedOuterMetadata[4].name)",
                nil,
                [],
                0,
                exactCommands,
                nil,
                mistypedOuterMetadata[4].metadata,
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "extra-command",
                nil,
                [],
                0,
                extraCommands,
                extraCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "drifted-command",
                nil,
                [],
                0,
                driftedCommands,
                driftedCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "renamed-command",
                nil,
                [],
                0,
                renamedCommands,
                renamedCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "input-drifted-command",
                nil,
                [],
                0,
                inputDriftedCommands,
                inputDriftedCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "extra-field-command",
                nil,
                [],
                0,
                extraFieldCommands,
                extraFieldCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "missing-field-command",
                nil,
                [],
                0,
                missingFieldCommands,
                missingFieldCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "reordered-commands",
                nil,
                [],
                0,
                reorderedCommands,
                reorderedCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "nonidentical-command-updates",
                nil,
                [],
                0,
                exactCommands,
                driftedCommands,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-4.5",
                .disallowedUpdate
            ),
            (
                "other-model",
                nil,
                [],
                0,
                exactCommands,
                nil,
                makeExactGrokAvailableOuterMetadata(),
                nil,
                [],
                "grok-code-fast-1",
                .invalidResponse
            )
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let sessionID = "unsafe-setup-\(scenario.name)"
            let server = Task {
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(session["method"], .string("session/new"))
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: sessionID,
                    lifecycleSessionID: scenario.lifecycleSessionID,
                    mcpServers: scenario.mcpServers,
                    mcpToolCount: scenario.mcpToolCount,
                    firstAvailableCommands: scenario.firstAvailableCommands,
                    secondAvailableCommands: scenario.secondAvailableCommands,
                    firstAvailableOuterMetadata: scenario.availableOuterMetadata,
                    injectedHookEventName: scenario.injectedHookEventName,
                    hookRuns: scenario.hookRuns,
                    modelID: scenario.modelID
                )

                let cancel = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(cancel["method"], .string("session/cancel"), scenario.name)
                XCTAssertEqual(
                    cancel["params"]?.objectValue?["sessionId"],
                    .string(sessionID),
                    scenario.name
                )
                let close = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(close["method"], .string("session/close"), scenario.name)
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected setup lifecycle rejection: \(scenario.name)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, scenario.expectedError, scenario.name)
            }
            try await server.value
            await client.close()
        }
    }

    func testGrokMinimalVerificationRejectsExactLiveToolCatalogBeforePrompt() async throws {
        XCTAssertEqual(exactGrokLiveToolIdentifiers.count, 24)
        XCTAssertEqual(exactGrokDisallowedToolIdentifiers.last, "Agent")

        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionID = "unsafe-live-tool-catalog"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: sessionID,
                availableTools: exactGrokLiveToolIdentifiers.map(JSONValue.string)
            )

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            XCTAssertEqual(
                cancel["params"]?.objectValue?["sessionId"],
                .string(sessionID)
            )
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: sessionID
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected the live Grok tool catalog to be rejected before prompt")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .disallowedUpdate)
        }
        try await server.value
        let queuedOutgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(queuedOutgoingCount, 0)
        await client.close()
    }

    func testGrokMinimalVerificationRejectsUnsafeCloseLifecycleTranscripts() async throws {
        let scenarios: [(
            name: String,
            lifecycleSessionID: String?,
            removedAsObject: Bool,
            conflictingRemovedIdentifiers: Bool,
            injectedHookEventName: String?,
            hookRuns: [JSONValue],
            expectedError: GrokACPError
        )] = [
            (
                "any-hook",
                nil,
                false,
                false,
                "session_end",
                [],
                .disallowedUpdate
            ),
            ("foreign-session", "foreign-session", false, false, nil, [], .invalidResponse),
            ("owned-object", nil, true, false, nil, [], .invalidResponse),
            (
                "conflicting-removed-identifiers",
                nil,
                true,
                true,
                nil,
                [],
                .invalidResponse
            )
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let sessionID = "unsafe-close-\(scenario.name)"
            let server = Task {
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                let prompt = try await transport.nextClientObject().objectValue!
                try await sendGrokCompleteVerificationPostLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": prompt["id"]!,
                    "result": .object(["stopReason": .string("end_turn")])
                ]))

                let close = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(close["method"], .string("session/close"), scenario.name)
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: sessionID,
                    lifecycleSessionID: scenario.lifecycleSessionID,
                    removedAsObject: scenario.removedAsObject,
                    conflictingRemovedIdentifiers: scenario.conflictingRemovedIdentifiers,
                    injectedHookEventName: scenario.injectedHookEventName,
                    hookRuns: scenario.hookRuns
                )
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected close lifecycle rejection: \(scenario.name)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, scenario.expectedError, scenario.name)
            }
            try await server.value
            await client.close()
        }
    }

    func testGrokMinimalVerificationRejectsExtraKeysOnOtherwiseValidChunks() async throws {
        let scenarios: [(
            name: String,
            level: String,
            key: String,
            value: JSONValue,
            expectedError: GrokACPError,
            expectedDiagnostic: GrokVerificationDiagnostic
        )] = [
            (
                "params-permission",
                "params",
                "permission",
                .string("granted"),
                .disallowedUpdate,
                .postAgentOuterMetadata
            ),
            (
                "update-tool",
                "update",
                "tool",
                .string("must-not-run"),
                .disallowedUpdate,
                .postAgentUpdate
            ),
            (
                "content-input",
                "content",
                "input",
                .string("must-not-read"),
                .disallowedUpdate,
                .postAgentContent
            ),
            (
                "content-output",
                "content",
                "output",
                .string("must-not-write"),
                .disallowedUpdate,
                .postAgentContent
            )
        ]

        for scenario in scenarios {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let sessionID = "extra-key-\(scenario.name)"
            let server = Task {
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
                let prompt = try await transport.nextClientObject().objectValue!
                try await sendGrokVerificationPostEvents(
                    [.promptEcho, .responseStarted(), .thought(), .reasoningCompleted],
                    on: transport,
                    sessionID: sessionID
                )

                var params = makeGrokSessionUpdateParams(
                    sessionID: sessionID,
                    type: "agent_message_chunk",
                    text: "XUNJIAN_OK"
                )
                var update = try XCTUnwrap(params["update"]?.objectValue)
                var content = try XCTUnwrap(update["content"]?.objectValue)
                switch scenario.level {
                case "params":
                    params[scenario.key] = scenario.value
                case "update":
                    update[scenario.key] = scenario.value
                    params["update"] = .object(update)
                case "content":
                    content[scenario.key] = scenario.value
                    update["content"] = .object(content)
                    params["update"] = .object(update)
                default:
                    XCTFail("Unknown scenario level: \(scenario.level)")
                }
                try await sendGrokNotification(
                    on: transport,
                    method: "session/update",
                    params: .object(params)
                )
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": prompt["id"]!,
                    "result": .object(["stopReason": .string("end_turn")])
                ]))

                let cancel = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(cancel["method"], .string("session/cancel"), scenario.name)
                XCTAssertEqual(
                    cancel["params"]?.objectValue?["sessionId"],
                    .string(sessionID),
                    scenario.name
                )
                let close = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(close["method"], .string("session/close"), scenario.name)
                XCTAssertEqual(
                    close["params"]?.objectValue?["sessionId"],
                    .string(sessionID),
                    scenario.name
                )
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: sessionID
                )
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected strict chunk key rejection: \(scenario.name)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, scenario.expectedError, scenario.name)
            }
            let diagnostic = await client.takeVerificationDiagnostic()
            XCTAssertEqual(diagnostic, scenario.expectedDiagnostic, scenario.name)
            try await server.value
            await client.close()
        }
    }

    func testGrokMinimalVerificationAcceptsAgentReplyDelayedAfterPromptResponse() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("delayed-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "delayed-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            try await Task.sleep(nanoseconds: 200_000_000)
            let prematureOutgoingCount = await transport.queuedOutgoingCount()
            XCTAssertEqual(prematureOutgoingCount, 0)
            try await sendGrokCompleteVerificationPostLifecycle(
                on: transport,
                sessionID: "delayed-session"
            )

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "delayed-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        try await client.verifyMinimalConnection()
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationRejectsDelayedExtraTextAfterExactReply() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("delayed-extra-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "delayed-extra-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await sendGrokVerificationPostEvents(
                [.promptEcho, .responseStarted(), .thought(), .reasoningCompleted],
                on: transport,
                sessionID: "delayed-extra-session"
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            try await Task.sleep(nanoseconds: 100_000_000)
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: "delayed-extra-session",
                type: "agent_message_chunk",
                text: "XUNJIAN_OK"
            )
            try await Task.sleep(nanoseconds: 120_000_000)
            let prematureOutgoingCount = await transport.queuedOutgoingCount()
            XCTAssertEqual(prematureOutgoingCount, 0)
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: "delayed-extra-session",
                type: "agent_message_chunk",
                text: "EXTRA"
            )

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "delayed-extra-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected delayed extra verification text rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .invalidResponse)
        }
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationRejectsInvalidUserPromptEchoes() async throws {
        let fixedPrompt = "Reply exactly XUNJIAN_OK. Do not use tools."
        let scenarios: [(
            usesForeignSession: Bool,
            chunks: [String],
            expectedCleanupMethods: [String]
        )] = [
            (true, [fixedPrompt], ["session/cancel", "session/close"]),
            (false, [fixedPrompt, "EXTRA"], ["session/cancel", "session/close"]),
            (
                false,
                ["Reply exactly XUNJIAN_BAD. Do not use tools."],
                ["session/cancel", "session/close"]
            ),
            (false, ["Reply exactly XUNJIAN_"], ["session/close"])
        ]

        for (index, scenario) in scenarios.enumerated() {
            let transport = ScriptedLineTransport()
            let client = makeGrokClient(on: transport)
            let ownedSessionID = "user-echo-session-\(index)"
            let updateSessionID = scenario.usesForeignSession
                ? "foreign-session"
                : ownedSessionID
            let server = Task { () throws -> [String] in
                try await serveGrokHandshake(on: transport)
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(ownedSessionID)])
                ]))
                try await sendGrokVerificationSetupLifecycle(
                    on: transport,
                    sessionID: ownedSessionID
                )
                let prompt = try await transport.nextClientObject().objectValue!
                for chunk in scenario.chunks {
                    try await sendGrokSessionUpdate(
                        on: transport,
                        sessionID: updateSessionID,
                        type: "user_message_chunk",
                        text: chunk
                    )
                }
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": prompt["id"]!,
                    "result": .object(["stopReason": .string("end_turn")])
                ]))

                let firstCleanup = try await transport.nextClientObject().objectValue!
                let firstMethod = firstCleanup["method"]?.stringValue ?? ""
                if firstMethod == "session/close" {
                    try await transport.sendServerObject(.object([
                        "jsonrpc": .string("2.0"),
                        "id": firstCleanup["id"]!,
                        "result": .object([:])
                    ]))
                    try await sendGrokVerificationCloseLifecycle(
                        on: transport,
                        sessionID: ownedSessionID
                    )
                    return [firstMethod]
                }

                let close = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": close["id"]!,
                    "result": .object([:])
                ]))
                try await sendGrokVerificationCloseLifecycle(
                    on: transport,
                    sessionID: ownedSessionID
                )
                return [firstMethod, close["method"]?.stringValue ?? ""]
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            do {
                try await client.verifyMinimalConnection()
                XCTFail("Expected invalid user prompt echo rejection for scenario \(index)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, .invalidResponse, "Scenario \(index)")
            }
            let cleanupMethods = try await server.value
            XCTAssertEqual(
                cleanupMethods,
                scenario.expectedCleanupMethods,
                "Scenario \(index)"
            )
            await client.close()
        }
    }

    func testGrokMinimalVerificationRejectsExtraTextDelayedAfterCloseResponse() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("post-close-extra-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "post-close-extra-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await sendGrokCompleteVerificationPostLifecycle(
                on: transport,
                sessionID: "post-close-extra-session"
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "post-close-extra-session"
            )
            try await Task.sleep(nanoseconds: 100_000_000)
            try await sendGrokSessionUpdate(
                on: transport,
                sessionID: "post-close-extra-session",
                type: "agent_message_chunk",
                text: "EXTRA"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected post-close extra verification text rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .disallowedUpdate)
        }
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationRejectsUnknownNotificationDelayedAfterCloseResponse() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("post-close-unknown-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "post-close-unknown-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await sendGrokCompleteVerificationPostLifecycle(
                on: transport,
                sessionID: "post-close-unknown-session"
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let close = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "post-close-unknown-session"
            )
            try await Task.sleep(nanoseconds: 100_000_000)
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("unexpected/update"),
                "params": .object([:])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected post-close unknown notification rejection")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .unknownNotification)
        }
        let diagnostic = await client.takeVerificationDiagnostic()
        XCTAssertEqual(diagnostic, .closeTransport)
        try await server.value
        let transportClosed = await transport.isClosed
        XCTAssertTrue(transportClosed)
        await client.close()
    }

    func testGrokMinimalVerificationRequiresAdvertisedSessionCloseBeforeSessionCreation() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected session-close capability rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .sessionCloseUnavailable)
        }
        try await server.value
        let queuedOutgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(queuedOutgoingCount, 0)
        await client.close()
    }

    func testGrokMinimalVerificationRejectsExtraTextAndCancelsThenClosesSession() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("strict-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "strict-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await sendGrokVerificationPostEvents(
                [.promptEcho, .responseStarted(), .thought(), .reasoningCompleted],
                on: transport,
                sessionID: "strict-session"
            )
            for text in ["XUNJIAN_OK", "EXTRA"] {
                try await sendGrokSessionUpdate(
                    on: transport,
                    sessionID: "strict-session",
                    type: "agent_message_chunk",
                    text: text
                )
            }
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            XCTAssertNil(cancel["id"])
            XCTAssertEqual(
                cancel["params"]?.objectValue?["sessionId"],
                .string("strict-session")
            )
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(
                close["params"]?.objectValue?["sessionId"],
                .string("strict-session")
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "strict-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected strict verification text rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .invalidResponse)
        }
        try await server.value
        await client.close()
    }

    func testGrokMinimalVerificationRejectsNonEndTurnAndCancelsThenClosesSession() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": authenticate["id"]!,
                "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("non-end-turn-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "non-end-turn-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("cancelled")])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            XCTAssertNil(cancel["id"])
            XCTAssertEqual(
                cancel["params"]?.objectValue?["sessionId"],
                .string("non-end-turn-session")
            )
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(
                close["params"]?.objectValue?["sessionId"],
                .string("non-end-turn-session")
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "non-end-turn-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected non-end-turn verification rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .invalidResponse)
        }
        try await server.value
        await client.close()
    }

    func testGrokSessionHistoryIDsAreSortedAndTakenOnce() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            for sessionID in ["z-session", "a-session"] {
                let session = try await transport.nextClientObject().objectValue!
                XCTAssertEqual(session["method"], .string("session/new"))
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"),
                    "id": session["id"]!,
                    "result": .object(["sessionId": .string(sessionID)])
                ]))
            }
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        _ = try await client.newSession()
        _ = try await client.newSession()
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, ["a-session", "z-session"])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        await client.close()
    }

    func testGrokSessionHistorySurvivesPromptRemoteError() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("remote-error-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "remote-error-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "error": .object([
                    "code": .integer(-32_001),
                    "message": .string("remote failure")
                ])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(
                close["params"]?.objectValue?["sessionId"],
                .string("remote-error-session")
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": close["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "remote-error-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected prompt remote error")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .remoteError(code: -32_001))
        }
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, ["remote-error-session"])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        await client.close()
    }

    func testGrokSessionHistorySurvivesCloseFailure() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("close-failure-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "close-failure-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            try await sendGrokCompleteVerificationPostLifecycle(
                on: transport,
                sessionID: "close-failure-session"
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let failingClose = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(failingClose["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": failingClose["id"]!,
                "error": .object([
                    "code": .integer(-32_002),
                    "message": .string("close failure")
                ])
            ]))
            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            let cleanupClose = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cleanupClose["method"], .string("session/close"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": cleanupClose["id"]!,
                "result": .object([:])
            ]))
            try await sendGrokVerificationCloseLifecycle(
                on: transport,
                sessionID: "close-failure-session"
            )
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected session close remote error")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .remoteError(code: -32_002))
        }
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, ["close-failure-session"])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        await client.close()
    }

    func testGrokSessionHistorySurvivesVerificationCancellation() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let promptObserved = AsyncSignal()
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string("cancelled-session")])
            ]))
            try await sendGrokVerificationSetupLifecycle(
                on: transport,
                sessionID: "cancelled-session"
            )
            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))
            await promptObserved.fire()
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        let verification = Task {
            try await client.verifyMinimalConnection()
        }
        await promptObserved.wait()
        verification.cancel()
        do {
            try await verification.value
            XCTFail("Expected verification cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await server.value
        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, ["cancelled-session"])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        let transportClosed = await transport.isClosed
        XCTAssertTrue(transportClosed)
        await client.close()
    }

    func testGrokCloseWaitsForCancelledPendingSessionCreationAndRetainsLateSessionID() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let sessionRequestObserved = AsyncSignal()
        let allowSessionResponse = AsyncSignal()
        let closeStarted = AsyncSignal()
        let closeCompleted = AsyncSignal()
        let sessionID = "550e8400-e29b-41d4-a716-446655440000"
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            await sessionRequestObserved.fire()
            await allowSessionResponse.wait()
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "result": .object(["sessionId": .string(sessionID)])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        let verification = Task {
            try await client.verifyMinimalConnection()
        }
        await sessionRequestObserved.wait()
        verification.cancel()
        let closing = Task {
            await closeStarted.fire()
            await client.close()
            await closeCompleted.fire()
        }
        await closeStarted.wait()
        try await Task.sleep(nanoseconds: 50_000_000)
        let didCloseBeforeSessionResponse = await closeCompleted.hasFired()
        XCTAssertFalse(didCloseBeforeSessionResponse)

        await allowSessionResponse.fire()
        do {
            try await verification.value
            XCTFail("Expected verification cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await closing.value
        try await server.value

        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertEqual(historyIDs, [sessionID])
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        let outgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingCount, 0, "Cancellation must prevent session/prompt")
    }

    func testGrokSessionCreationRemoteErrorDoesNotCreateHistoryIDAfterClose() async throws {
        let transport = ScriptedLineTransport()
        let client = makeGrokClient(on: transport)
        let server = Task {
            try await serveGrokHandshake(on: transport)
            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": session["id"]!,
                "error": .object([
                    "code": .integer(-32_003),
                    "message": .string("session creation failed")
                ])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        do {
            try await client.verifyMinimalConnection()
            XCTFail("Expected session creation remote error")
        } catch let error as JSONLineRPCError {
            XCTAssertEqual(error, .remoteError(code: -32_003))
        }
        try await server.value
        await client.close()

        let historyIDs = await client.takeSessionHistoryIDs()
        let repeatedHistoryIDs = await client.takeSessionHistoryIDs()
        XCTAssertTrue(historyIDs.isEmpty)
        XCTAssertTrue(repeatedHistoryIDs.isEmpty)
        let outgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingCount, 0, "A failed session/new must not send session/prompt")
    }

    func testGrokClientUsesCachedTokenAndNoCapabilities() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty", isDirectory: true)
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            let capabilities = initialize["params"]?.objectValue?["clientCapabilities"]?.objectValue
            XCTAssertEqual(capabilities?["fs"]?.objectValue?["readTextFile"], .bool(false))
            XCTAssertEqual(capabilities?["fs"]?.objectValue?["writeTextFile"], .bool(false))
            XCTAssertEqual(capabilities?["terminal"], .bool(false))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([
                        .object(["id": .string("cached_token")]),
                        .object(["id": .string("xai.api_key")])
                    ]),
                    "agentCapabilities": .object([
                        "sessionCapabilities": .object(["close": .object([:])])
                    ])
                ])
            ]))

            let authenticate = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(authenticate["method"], .string("authenticate"))
            XCTAssertEqual(authenticate["params"]?.objectValue?["methodId"], .string("cached_token"))
            XCTAssertEqual(
                authenticate["params"]?.objectValue?["_meta"]?.objectValue?["headless"],
                .bool(true)
            )
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": authenticate["id"]!, "result": .object([:])
            ]))

            let session = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(session["method"], .string("session/new"))
            XCTAssertEqual(session["params"]?.objectValue?["mcpServers"], .array([]))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": session["id"]!,
                "result": .object(["sessionId": .string("session-1")])
            ]))

            let prompt = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(prompt["method"], .string("session/prompt"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string("session-1"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("answer")])
                    ])
                ])
            ]))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": prompt["id"]!,
                "result": .object(["stopReason": .string("end_turn")])
            ]))

            let cancel = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(cancel["method"], .string("session/cancel"))
            XCTAssertNil(cancel["id"])
            XCTAssertEqual(cancel["params"]?.objectValue?["sessionId"], .string("session-1"))

            let close = try await transport.nextClientObject().objectValue!
            XCTAssertEqual(close["method"], .string("session/close"))
            XCTAssertEqual(close["params"]?.objectValue?["sessionId"], .string("session-1"))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": close["id"]!, "result": .object([:])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        let sessionID = try await client.newSession()
        async let promptResult = client.prompt(sessionID: sessionID, text: "hello")
        let grokEvent = try await client.nextEvent()
        let stopReason = try await promptResult
        XCTAssertEqual(grokEvent, .agentMessageChunk("answer"))
        XCTAssertEqual(stopReason, "end_turn")
        try await client.cancel(sessionID: sessionID)
        try await client.closeSession(sessionID)
        try await server.value
        await client.close()
    }

    func testGrokClientNeverAuthenticatesUndocumentedGrokComMethod() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"),
                "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([
                        .object(["id": .string("grok.com")])
                    ])
                ])
            ]))
        }

        try await client.initialize()
        do {
            try await client.authenticateCachedToken()
            XCTFail("Expected cached token rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .cachedTokenUnavailable)
        }
        try await server.value
        let outgoingCount = await transport.queuedOutgoingCount()
        XCTAssertEqual(outgoingCount, 0)
        await client.close()
    }

    func testGrokClientRejectsPermissionAndToolUpdates() async throws {
        for update in [
            "tool_call", "tool_call_update", "available_commands_update", "terminal_output"
        ] {
            let transport = ScriptedLineTransport()
            let peer = JSONLineRPCPeer(
                transport: transport,
                dialect: .jsonRPC2,
                allowedNotifications: GrokACPClient.allowedNotifications
            )
            let client = GrokACPClient(
                peer: peer,
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp")
            )
            let server = Task {
                let initialize = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"), "id": initialize["id"]!,
                    "result": .object([
                        "protocolVersion": .integer(1),
                        "authMethods": .array([.object(["id": .string("cached_token")])])
                    ])
                ]))
                let authenticate = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"), "id": authenticate["id"]!, "result": .object([:])
                ]))
                let session = try await transport.nextClientObject().objectValue!
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"), "id": session["id"]!,
                    "result": .object(["sessionId": .string("session-guard")])
                ]))
                try await transport.sendServerObject(.object([
                    "jsonrpc": .string("2.0"), "method": .string("session/update"),
                    "params": .object([
                        "sessionId": .string("session-guard"),
                        "update": .object(["sessionUpdate": .string(update)])
                    ])
                ]))
            }

            try await client.initialize()
            try await client.authenticateCachedToken()
            _ = try await client.newSession()
            do {
                _ = try await client.nextEvent()
                XCTFail("Expected update rejection: \(update)")
            } catch let error as GrokACPError {
                XCTAssertEqual(error, .disallowedUpdate)
            }
            try await server.value
            let grokClosed = await transport.isClosed
            XCTAssertTrue(grokClosed)
        }
    }

    func testGrokClientGatesSessionCloseAndRejectsForeignSession() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": authenticate["id"]!, "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": session["id"]!,
                "result": .object(["sessionId": .string("owned-session")])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        let sessionID = try await client.newSession()
        do {
            try await client.closeSession(sessionID)
            XCTFail("Expected session close capability gate")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .sessionCloseUnavailable)
        }
        let stillOpen = await transport.isClosed
        XCTAssertFalse(stillOpen)
        do {
            _ = try await client.prompt(sessionID: "foreign-session", text: "hello")
            XCTFail("Expected foreign session rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .unknownSession)
        }
        try await server.value
        let foreignSessionClosed = await transport.isClosed
        XCTAssertTrue(foreignSessionClosed)
    }

    func testGrokClientRejectsEventFromForeignSession() async throws {
        let transport = ScriptedLineTransport()
        let peer = JSONLineRPCPeer(
            transport: transport,
            dialect: .jsonRPC2,
            allowedNotifications: GrokACPClient.allowedNotifications
        )
        let client = GrokACPClient(
            peer: peer,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/xunjian-empty")
        )
        let server = Task {
            let initialize = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": initialize["id"]!,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "authMethods": .array([.object(["id": .string("cached_token")])])
                ])
            ]))
            let authenticate = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": authenticate["id"]!, "result": .object([:])
            ]))
            let session = try await transport.nextClientObject().objectValue!
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "id": session["id"]!,
                "result": .object(["sessionId": .string("owned-session")])
            ]))
            try await transport.sendServerObject(.object([
                "jsonrpc": .string("2.0"), "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string("foreign-session"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("foreign")])
                    ])
                ])
            ]))
        }

        try await client.initialize()
        try await client.authenticateCachedToken()
        _ = try await client.newSession()
        do {
            _ = try await client.nextEvent()
            XCTFail("Expected foreign event rejection")
        } catch let error as GrokACPError {
            XCTAssertEqual(error, .unknownSession)
        }
        try await server.value
        let foreignEventClosed = await transport.isClosed
        XCTAssertTrue(foreignEventClosed)
    }
}
#endif
