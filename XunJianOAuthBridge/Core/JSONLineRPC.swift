import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Non-finite JSON number."
                    )
                )
            }
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum JSONLineFramingError: Error, Equatable, Sendable {
    case lineTooLarge
}

struct JSONLineFramer: Sendable {
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(maximumLineBytes: Int = 1_048_576) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard line.count <= maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw JSONLineFramingError.lineTooLarge
            }
            lines.append(line)
        }

        let permitsTrailingCarriageReturn = buffer.count == maximumLineBytes + 1
            && buffer.last == 0x0D
        guard buffer.count <= maximumLineBytes || permitsTrailingCarriageReturn else {
            buffer.removeAll(keepingCapacity: false)
            throw JSONLineFramingError.lineTooLarge
        }
        return lines
    }

    mutating func finish() throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        guard buffer.count <= maximumLineBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw JSONLineFramingError.lineTooLarge
        }
        let remainder = buffer
        buffer.removeAll(keepingCapacity: false)
        return remainder
    }
}

protocol JSONLineTransport: Sendable {
    func writeLine(_ data: Data) async throws
    func readLine() async throws -> Data?
    func close() async
}

enum JSONRPCDialect: Sendable {
    case codex
    case jsonRPC2
}

struct JSONRPCNotification: Equatable, Sendable {
    let method: String
    let params: JSONValue?
}

struct JSONRPCRequestCompletion: Equatable, Sendable {
    let result: JSONValue
    let queuedNotifications: [JSONRPCNotification]
}

enum JSONLineRPCError: Error, Equatable, Sendable {
    case closed
    case transportFailure
    case malformedMessage
    case messageTooLarge
    case invalidDialect
    case invalidEnvelope
    case invalidState
    case requestTimedOut
    case requestCancelled
    case remoteError(code: Int64)
    case serverRequestRejected
    case unknownResponseIdentifier
    case duplicateResponseIdentifier
    case unknownNotification
    case notificationOverflow
}

actor JSONLineRPCPeer {
    private struct PendingRequest {
        let gate: RPCOneShot<JSONValue>
        var timeoutTask: Task<Void, Never>?
    }

    private static let maximumMessageBytes = 1_048_576
    private static let maximumQueuedNotifications = 256
    private static let notificationQuiescenceNanoseconds: UInt64 = 150_000_000
    private static let requiredNotificationQuiescenceChecks = 2

    private let transport: any JSONLineTransport
    private let dialect: JSONRPCDialect
    private let allowedNotifications: Set<String>
    private let requestTimeoutNanoseconds: UInt64
    private var nextRequestIdentifier: Int64 = 1
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var queuedNotifications: [JSONRPCNotification] = []
    private var notificationWaiters: [RPCOneShot<JSONRPCNotification>] = []
    private var verificationDrainIsActive = false
    private var readerTask: Task<Void, Never>?
    private var terminalError: JSONLineRPCError?

    init(
        transport: any JSONLineTransport,
        dialect: JSONRPCDialect,
        allowedNotifications: Set<String>,
        requestTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.transport = transport
        self.dialect = dialect
        self.allowedNotifications = allowedNotifications
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    func request(
        method: String,
        params: JSONValue? = nil,
        timeoutNanoseconds requestedTimeoutNanoseconds: UInt64? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        try ensureOpen()
        let timeoutNanoseconds = min(
            requestedTimeoutNanoseconds ?? requestTimeoutNanoseconds,
            requestTimeoutNanoseconds
        )
        guard !method.isEmpty, timeoutNanoseconds > 0 else {
            throw JSONLineRPCError.invalidEnvelope
        }
        ensureReaderStarted()

        guard nextRequestIdentifier < Int64.max else {
            await failClosed(.invalidState)
            throw JSONLineRPCError.invalidState
        }
        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        let encoded = try encodeOutbound(
            method: method,
            params: params,
            identifier: .integer(identifier)
        )

        let gate = RPCOneShot<JSONValue>()
        pendingRequests[identifier] = PendingRequest(gate: gate, timeoutTask: nil)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.timeOutRequest(identifier, gate: gate)
        }
        pendingRequests[identifier]?.timeoutTask = timeoutTask

        do {
            try await transport.writeLine(encoded)
        } catch {
            await failClosed(.transportFailure)
            throw JSONLineRPCError.transportFailure
        }

        do {
            return try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                gate.resolve(.failure(CancellationError()))
            }
        } catch is CancellationError {
            await cancelRequest(identifier, gate: gate)
            throw CancellationError()
        } catch {
            throw error
        }
    }

    // Verification-only boundary: callers must not have a concurrent notification consumer.
    func requestAndDrainQueuedNotifications(
        method: String,
        params: JSONValue? = nil
    ) async throws -> JSONRPCRequestCompletion {
        guard !verificationDrainIsActive, notificationWaiters.isEmpty else {
            await failClosed(.invalidState)
            throw JSONLineRPCError.invalidState
        }
        verificationDrainIsActive = true
        defer { verificationDrainIsActive = false }

        let result = try await request(method: method, params: params)
        guard notificationWaiters.isEmpty else {
            await failClosed(.invalidState)
            throw JSONLineRPCError.invalidState
        }

        // The official Grok ACP example keeps observing streamed text after the
        // prompt response and requires two stable 150 ms checks. Mirror that
        // bounded quiescence window so buffered trailing chunks are validated.
        try await waitForNotificationQuiescence()

        let notifications = queuedNotifications
        queuedNotifications.removeAll(keepingCapacity: true)
        return JSONRPCRequestCompletion(
            result: result,
            queuedNotifications: notifications
        )
    }

    // Verification-only final seal. Call after session/close so any stream
    // chunks ordered before the close response are included in validation.
    func drainQueuedNotificationsForVerification() async throws
        -> [JSONRPCNotification] {
        try Task.checkCancellation()
        try ensureOpen()
        guard !verificationDrainIsActive, notificationWaiters.isEmpty else {
            await failClosed(.invalidState)
            throw JSONLineRPCError.invalidState
        }
        verificationDrainIsActive = true
        defer { verificationDrainIsActive = false }
        try await waitForNotificationQuiescence()
        let notifications = queuedNotifications
        queuedNotifications.removeAll(keepingCapacity: true)
        return notifications
    }

    func notify(method: String, params: JSONValue? = nil) async throws {
        try Task.checkCancellation()
        try ensureOpen()
        guard !method.isEmpty else { throw JSONLineRPCError.invalidEnvelope }
        ensureReaderStarted()
        let encoded = try encodeOutbound(method: method, params: params, identifier: nil)
        do {
            try await transport.writeLine(encoded)
        } catch {
            await failClosed(.transportFailure)
            throw JSONLineRPCError.transportFailure
        }
    }

    func nextNotification() async throws -> JSONRPCNotification {
        try Task.checkCancellation()
        try ensureOpen()
        guard !verificationDrainIsActive else {
            await failClosed(.invalidState)
            throw JSONLineRPCError.invalidState
        }
        ensureReaderStarted()
        if !queuedNotifications.isEmpty {
            return queuedNotifications.removeFirst()
        }

        let gate = RPCOneShot<JSONRPCNotification>()
        notificationWaiters.append(gate)
        do {
            return try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                gate.resolve(.failure(CancellationError()))
            }
        } catch is CancellationError {
            notificationWaiters.removeAll { $0 === gate }
            throw CancellationError()
        } catch {
            throw error
        }
    }

    func close() async {
        let task = readerTask
        if terminalError == nil {
            transitionToTerminal(.closed)
        }
        task?.cancel()
        await transport.close()
        if let task {
            await task.value
        }
    }

    private func ensureOpen() throws {
        if let terminalError {
            throw terminalError
        }
    }

    private func waitForNotificationQuiescence() async throws {
        var previousCount = queuedNotifications.count
        var stableChecks = 0
        while stableChecks < Self.requiredNotificationQuiescenceChecks {
            try Task.checkCancellation()
            try await Task.sleep(
                nanoseconds: Self.notificationQuiescenceNanoseconds
            )
            try ensureOpen()
            guard notificationWaiters.isEmpty else {
                await failClosed(.invalidState)
                throw JSONLineRPCError.invalidState
            }
            let currentCount = queuedNotifications.count
            if currentCount == previousCount {
                stableChecks += 1
            } else {
                previousCount = currentCount
                stableChecks = 0
            }
        }
    }

    private func ensureReaderStarted() {
        guard readerTask == nil, terminalError == nil else { return }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            let data: Data?
            do {
                data = try await transport.readLine()
            } catch is CancellationError {
                break
            } catch {
                await failClosed(.transportFailure)
                break
            }

            guard let data else {
                if terminalError == nil {
                    await failClosed(.transportFailure)
                }
                break
            }
            await receive(data)
            if terminalError != nil { break }
        }
        readerTask = nil
    }

    private func receive(_ data: Data) async {
        guard data.count <= Self.maximumMessageBytes else {
            await failClosed(.messageTooLarge)
            return
        }

        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            await failClosed(.malformedMessage)
            return
        }
        guard let object = value.objectValue else {
            await failClosed(.invalidEnvelope)
            return
        }
        guard validateDialect(in: object) else {
            await failClosed(.invalidDialect)
            return
        }

        if object.keys.contains("method") {
            await receiveMethodEnvelope(object)
        } else {
            await receiveResponseEnvelope(object)
        }
    }

    private func receiveMethodEnvelope(_ object: [String: JSONValue]) async {
        guard let method = object["method"]?.stringValue, !method.isEmpty else {
            await failClosed(.invalidEnvelope)
            return
        }

        if let identifier = object["id"] {
            guard isValidServerIdentifier(identifier) else {
                await failClosed(.invalidEnvelope)
                return
            }
            do {
                try await sendMethodNotFound(identifier: identifier)
            } catch {
                await failClosed(.transportFailure)
                return
            }
            await failClosed(.serverRequestRejected)
            return
        }

        guard object["result"] == nil,
              object["error"] == nil,
              allowedNotifications.contains(method) else {
            await failClosed(
                allowedNotifications.contains(method)
                    ? .invalidEnvelope
                    : .unknownNotification
            )
            return
        }
        let notification = JSONRPCNotification(method: method, params: object["params"])
        if let waiter = notificationWaiters.first {
            notificationWaiters.removeFirst()
            waiter.resolve(.success(notification))
        } else if queuedNotifications.count < Self.maximumQueuedNotifications {
            queuedNotifications.append(notification)
        } else {
            await failClosed(.notificationOverflow)
        }
    }

    private func receiveResponseEnvelope(_ object: [String: JSONValue]) async {
        guard let identifier = object["id"]?.integerValue else {
            await failClosed(.invalidEnvelope)
            return
        }
        guard let pending = pendingRequests.removeValue(forKey: identifier) else {
            await failClosed(
                identifier > 0 && identifier < nextRequestIdentifier
                    ? .duplicateResponseIdentifier
                    : .unknownResponseIdentifier
            )
            return
        }
        pending.timeoutTask?.cancel()

        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            pending.gate.resolve(.failure(JSONLineRPCError.invalidEnvelope))
            await failClosed(.invalidEnvelope)
            return
        }

        if hasResult, let result = object["result"] {
            pending.gate.resolve(.success(result))
            return
        }
        guard let errorObject = object["error"]?.objectValue,
              let code = errorObject["code"]?.integerValue else {
            pending.gate.resolve(.failure(JSONLineRPCError.invalidEnvelope))
            await failClosed(.invalidEnvelope)
            return
        }
        pending.gate.resolve(.failure(JSONLineRPCError.remoteError(code: code)))
    }

    private func validateDialect(in object: [String: JSONValue]) -> Bool {
        switch dialect {
        case .codex:
            return object["jsonrpc"] == nil
        case .jsonRPC2:
            return object["jsonrpc"] == .string("2.0")
        }
    }

    private func isValidServerIdentifier(_ value: JSONValue) -> Bool {
        switch value {
        case .integer, .string:
            true
        default:
            false
        }
    }

    private func encodeOutbound(
        method: String,
        params: JSONValue?,
        identifier: JSONValue?
    ) throws -> Data {
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params {
            object["params"] = params
        }
        if let identifier {
            object["id"] = identifier
        }
        if case .jsonRPC2 = dialect {
            object["jsonrpc"] = .string("2.0")
        }
        let encoded = try JSONEncoder().encode(JSONValue.object(object))
        guard encoded.count <= Self.maximumMessageBytes else {
            throw JSONLineRPCError.messageTooLarge
        }
        return encoded
    }

    private func sendMethodNotFound(identifier: JSONValue) async throws {
        var object: [String: JSONValue] = [
            "id": identifier,
            "error": .object([
                "code": .integer(-32_601),
                "message": .string("Method not found")
            ])
        ]
        if case .jsonRPC2 = dialect {
            object["jsonrpc"] = .string("2.0")
        }
        let encoded = try JSONEncoder().encode(JSONValue.object(object))
        guard encoded.count <= Self.maximumMessageBytes else {
            throw JSONLineRPCError.messageTooLarge
        }
        try await transport.writeLine(encoded)
    }

    private func timeOutRequest(_ identifier: Int64, gate: RPCOneShot<JSONValue>) async {
        guard let pending = pendingRequests[identifier], pending.gate === gate else { return }
        pendingRequests.removeValue(forKey: identifier)
        gate.resolve(.failure(JSONLineRPCError.requestTimedOut))
        await failClosed(.requestTimedOut)
    }

    private func cancelRequest(_ identifier: Int64, gate: RPCOneShot<JSONValue>) async {
        guard let pending = pendingRequests[identifier], pending.gate === gate else { return }
        pendingRequests.removeValue(forKey: identifier)
        pending.timeoutTask?.cancel()
        await failClosed(.requestCancelled)
    }

    private func failClosed(_ error: JSONLineRPCError) async {
        guard terminalError == nil else { return }
        transitionToTerminal(error)
        readerTask?.cancel()
        await transport.close()
    }

    private func transitionToTerminal(_ error: JSONLineRPCError) {
        guard terminalError == nil else { return }
        terminalError = error

        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.gate.resolve(.failure(error))
        }

        let waiters = notificationWaiters
        notificationWaiters.removeAll()
        queuedNotifications.removeAll()
        for waiter in waiters {
            waiter.resolve(.failure(error))
        }
    }
}

private final class RPCOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var isResolved = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
            } else if self.continuation != nil {
                lock.unlock()
                continuation.resume(throwing: JSONLineRPCError.invalidState)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
