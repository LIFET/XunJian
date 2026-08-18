import Foundation
import Darwin
import CryptoKit

enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case grok
    case deepSeek
    case qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .grok: "Grok"
        case .deepSeek: "DeepSeek"
        case .qwen: "Qwen / 千问"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .codex: "https://api.openai.com/v1"
        case .grok: "https://api.x.ai/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .codex: "gpt-5.3-codex"
        case .grok: "grok-4.6"
        case .deepSeek: "deepseek-v4-flash"
        case .qwen: "qwen3.7-plus"
        }
    }

}

enum AIAuthenticationMode: String, Codable, Equatable, Sendable {
    case apiKey
    case oauth

    var localizedTitle: String {
        switch self {
        case .apiKey: AppLanguage.localized("API 密钥", english: "API Key")
        case .oauth: "OAuth"
        }
    }
}

struct AIProviderSettings: Identifiable, Equatable, Sendable {
    let kind: AIProviderKind
    var baseURL: String
    var model: String
    var hasAPIKey: Bool

    var id: AIProviderKind { kind }
}

enum AIConnectionState: Equatable, Sendable {
    case notConfigured
    case saved
    case testing
    case verified
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: AppLanguage.localized("未配置", english: "Not Configured")
        case .saved: AppLanguage.localized("密钥已保存", english: "Key Saved")
        case .testing: AppLanguage.localized("正在验证", english: "Testing")
        case .verified: AppLanguage.localized("连接已验证", english: "Connection Verified")
        case .failed: AppLanguage.localized("验证失败", english: "Verification Failed")
        }
    }
}

enum LocalCredentialStoreError: LocalizedError, Sendable {
    case invalidSecret
    case invalidData
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            AppLanguage.localized("API Key 不能为空。", english: "The API key cannot be empty.")
        case .invalidData:
            AppLanguage.localized(
                "本地 API Key 文件内容无效。原文件已保留，请恢复有效文件后重试。",
                english: "The local API key file is invalid. The original file was preserved; restore a valid file and try again."
            )
        case .unavailable:
            AppLanguage.localized(
                "无法安全访问本地 API Key 文件。原文件已保留，请检查文件所有权与权限后重试。",
                english: "The local API key file cannot be accessed safely. Check its ownership and permissions, then try again."
            )
        }
    }
}

struct LocalCredentialStore: Sendable {
    private struct Payload: Codable {
        let version: Int
        var apiKeys: [String: String]
    }

    private static let schemaVersion = 1
    private static let maximumFileBytes = 131_072
    private static let maximumSecretBytes = 32_768

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL.standardizedFileURL
    }

    func save(_ secret: String, account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validAccounts.contains(account),
              !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumSecretBytes else {
            throw LocalCredentialStoreError.invalidSecret
        }
        var payload = try loadPayload()
        payload.apiKeys[account] = trimmed
        try write(payload)
    }

    func read(account: String) throws -> String? {
        guard Self.validAccounts.contains(account) else {
            throw LocalCredentialStoreError.invalidSecret
        }
        return try loadPayload().apiKeys[account]
    }

    func delete(account: String) throws {
        guard Self.validAccounts.contains(account) else {
            throw LocalCredentialStoreError.invalidSecret
        }
        var payload = try loadPayload()
        payload.apiKeys.removeValue(forKey: account)
        try write(payload)
    }

    private static var validAccounts: Set<String> {
        Set(AIProviderKind.allCases.map(\.rawValue))
    }

    private static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("XunJian", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
            .appendingPathComponent("ai-credentials.plist", isDirectory: false)
    }

    private func loadPayload() throws -> Payload {
        try prepareDirectory()
        guard try pathExists(fileURL) else {
            let payload = Payload(version: Self.schemaVersion, apiKeys: [:])
            try write(payload)
            return payload
        }

        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalCredentialStoreError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validateFileDescriptor(descriptor)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= Self.maximumFileBytes,
              let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              payload.version == Self.schemaVersion,
              Set(payload.apiKeys.keys).isSubset(of: Self.validAccounts),
              payload.apiKeys.values.allSatisfy({ value in
                  !value.isEmpty
                      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                      && value.utf8.count <= Self.maximumSecretBytes
              }) else {
            throw LocalCredentialStoreError.invalidData
        }
        return payload
    }

    private func write(_ payload: Payload) throws {
        try prepareDirectory()
        if try pathExists(fileURL) {
            try validateFile(at: fileURL)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumFileBytes else {
            throw LocalCredentialStoreError.invalidData
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".ai-credentials-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw LocalCredentialStoreError.unavailable }
        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlink(temporaryURL.path)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var writtenBytes = 0
                while writtenBytes < rawBuffer.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: writtenBytes),
                        rawBuffer.count - writtenBytes
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw LocalCredentialStoreError.unavailable }
                    writtenBytes += result
                }
            }
            guard fsync(descriptor) == 0,
                  fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  rename(temporaryURL.path, fileURL.path) == 0 else {
                throw LocalCredentialStoreError.unavailable
            }
            shouldRemoveTemporaryFile = false
            try validateFile(at: fileURL)
            try excludeFromBackup(fileURL)
        } catch let error as LocalCredentialStoreError {
            throw error
        } catch {
            throw LocalCredentialStoreError.unavailable
        }
    }

    private func prepareDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let parentURL = directoryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            if try pathExists(directoryURL) {
                try validateDirectory(at: directoryURL)
            } else {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard chmod(directoryURL.path, S_IRWXU) == 0 else {
                throw LocalCredentialStoreError.unavailable
            }
            try validateDirectory(at: directoryURL)
            try excludeFromBackup(directoryURL)
        } catch let error as LocalCredentialStoreError {
            throw error
        } catch {
            throw LocalCredentialStoreError.unavailable
        }
    }

    private func validateDirectory(at url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_uid == geteuid(),
              information.st_mode & S_IFMT == S_IFDIR else {
            throw LocalCredentialStoreError.unavailable
        }
    }

    private func validateFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalCredentialStoreError.unavailable }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)
    }

    private func validateFileDescriptor(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_mode & 0o077 == 0 else {
            throw LocalCredentialStoreError.unavailable
        }
    }

    private func pathExists(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw LocalCredentialStoreError.unavailable
        }
        return false
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

struct AIConfigurationStore {
    private let defaults: UserDefaults
    private let prefix = "ai.provider."
    private let apiKeyVerificationPrefix = "ai.verification.apiKey."
    private let oauthModelPrefix = "ai.oauth.model."
    private let activeKey = "ai.activeProvider"
    private let activeAuthenticationModeKey = "ai.activeAuthenticationMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(for kind: AIProviderKind, hasAPIKey: Bool) -> AIProviderSettings {
        AIProviderSettings(
            kind: kind,
            baseURL: defaults.string(forKey: prefix + kind.rawValue + ".baseURL")
                ?? kind.defaultBaseURL,
            model: defaults.string(forKey: prefix + kind.rawValue + ".model")
                ?? kind.defaultModel,
            hasAPIKey: hasAPIKey
        )
    }

    func save(_ settings: AIProviderSettings) {
        defaults.set(settings.baseURL, forKey: prefix + settings.kind.rawValue + ".baseURL")
        defaults.set(settings.model, forKey: prefix + settings.kind.rawValue + ".model")
    }

    func apiKeyVerificationFingerprint(for kind: AIProviderKind) -> String? {
        defaults.string(forKey: apiKeyVerificationPrefix + kind.rawValue)
    }

    func setAPIKeyVerificationFingerprint(_ fingerprint: String?, for kind: AIProviderKind) {
        defaults.set(fingerprint, forKey: apiKeyVerificationPrefix + kind.rawValue)
    }

    func oauthModel(for kind: AIProviderKind) -> String? {
        defaults.string(forKey: oauthModelPrefix + kind.rawValue)
    }

    func setOAuthModel(_ model: String, for kind: AIProviderKind) {
        defaults.set(model, forKey: oauthModelPrefix + kind.rawValue)
    }

    static func apiKeyVerificationFingerprint(
        settings: AIProviderSettings,
        secret: String
    ) -> String {
        let material = [
            settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
            secret
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var activeKind: AIProviderKind? {
        get {
            defaults.string(forKey: activeKey).flatMap(AIProviderKind.init(rawValue:))
        }
        nonmutating set {
            defaults.set(newValue?.rawValue, forKey: activeKey)
        }
    }

    var activeAuthenticationMode: AIAuthenticationMode? {
        get {
            defaults.string(forKey: activeAuthenticationModeKey)
                .flatMap(AIAuthenticationMode.init(rawValue:))
        }
        nonmutating set {
            defaults.set(newValue?.rawValue, forKey: activeAuthenticationModeKey)
        }
    }
}

struct AIMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    /// Upper bound for one prompt segment on this provider's transport.
    /// The embedded OAuth bridge has a stricter IPC boundary than HTTP APIs.
    var maximumPromptSegmentBytes: Int { get }
    func chat(_ messages: [AIMessage]) async throws -> String
    func chatStream(
        _ messages: [AIMessage]
    ) async throws -> AsyncThrowingStream<String, any Error>
}

extension AIProvider {
    var maximumPromptSegmentBytes: Int { 262_144 }

    /// Providers without a streaming wire protocol (the embedded OAuth
    /// runtimes) still conform by yielding their verified complete reply once.
    func chatStream(
        _ messages: [AIMessage]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let response = try await chat(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}

protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol AIStreamingHTTPTransport: AIHTTPTransport {
    func lines(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse)
}

enum AIResponseLimits {
    static let maximumJSONBytes = 262_144
    static let maximumStreamBytes = 1_048_576
    static let maximumStreamLineBytes = 262_144
    static let maximumGeneratedTextBytes = 131_072
}

struct URLSessionAITransport: AIHTTPTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 90
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(AIResponseLimits.maximumJSONBytes) else {
            throw AIServiceError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(
            min(max(Int(response.expectedContentLength), 0), AIResponseLimits.maximumJSONBytes)
        )
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < AIResponseLimits.maximumJSONBytes else {
                throw AIServiceError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

extension URLSessionAITransport: AIStreamingHTTPTransport {
    func lines(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let producer = Task {
                do {
                    var totalBytes = 0
                    var lineBytes = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        totalBytes += 1
                        guard totalBytes <= AIResponseLimits.maximumStreamBytes else {
                            throw AIServiceError.responseTooLarge
                        }
                        if byte == 0x0A {
                            if lineBytes.last == 0x0D { lineBytes.removeLast() }
                            guard let line = String(data: lineBytes, encoding: .utf8) else {
                                throw AIServiceError.invalidResponse
                            }
                            continuation.yield(line)
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            guard lineBytes.count < AIResponseLimits.maximumStreamLineBytes else {
                                throw AIServiceError.responseTooLarge
                            }
                            lineBytes.append(byte)
                        }
                    }
                    if !lineBytes.isEmpty {
                        if lineBytes.last == 0x0D { lineBytes.removeLast() }
                        guard let line = String(data: lineBytes, encoding: .utf8) else {
                            throw AIServiceError.invalidResponse
                        }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
        return (stream, response)
    }
}

enum AIServiceError: LocalizedError, Sendable {
    case notConfigured
    case invalidBaseURL
    case invalidModel
    case invalidResponse
    case requestFailed(String)
    case missingFileText
    case invalidQuestion
    case invalidSearchQuery
    case invalidSelection
    case invalidConversation
    case noCategories
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .notConfigured: AppLanguage.localized("请先登录 OAuth 或保存 API Key，并设为当前 AI。", english: "Sign in with OAuth or save an API key, then set it as the current AI.")
        case .invalidBaseURL: AppLanguage.localized("Base URL 必须是有效的 HTTPS 地址。", english: "The Base URL must be a valid HTTPS address.")
        case .invalidModel: AppLanguage.localized("模型名称不能为空。", english: "The model name cannot be empty.")
        case .invalidResponse: AppLanguage.localized("AI 返回了无法识别的响应。", english: "The AI returned an unrecognized response.")
        case let .requestFailed(message): AppLanguage.localized("AI 请求失败：\(message)", english: "AI request failed: \(message)")
        case .missingFileText: AppLanguage.localized("这个文件没有可供 AI 阅读的文本内容。", english: "This file has no text that the AI can read.")
        case .invalidQuestion: AppLanguage.localized("请输入要询问的问题。", english: "Enter a question.")
        case .invalidSearchQuery: AppLanguage.localized("请输入要查找的文件描述。", english: "Describe the files you want to find.")
        case .invalidSelection: AppLanguage.localized("请选择 1 到 50 个文件。", english: "Select 1 to 50 files.")
        case .invalidConversation: AppLanguage.localized("AI 请求必须包含一条系统指令和一条用户消息。", english: "An AI request must contain one system instruction and one user message.")
        case .noCategories: AppLanguage.localized("请先创建至少一个分类，再使用 AI 分类。", english: "Create at least one category before using AI classification.")
        case .responseTooLarge: AppLanguage.localized("AI 响应超过安全大小限制。", english: "The AI response exceeded the safe size limit.")
        }
    }
}

private struct OpenAICompatibleProvider: Sendable {
    let kind: AIProviderKind
    let apiKey: String
    let baseURL: URL
    let model: String
    let transport: any AIHTTPTransport

    func chat(_ messages: [AIMessage]) async throws -> String {
        let endpoint: URL
        if baseURL.path.hasSuffix("/chat/completions") {
            endpoint = baseURL
        } else {
            endpoint = baseURL.appending(path: "chat/completions")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(model: model, messages: messages, stream: false)
        )

        // F23: transient failures get one retry with exponential backoff.
        // Non-transient errors (bad key, bad model, 4xx) surface immediately.
        var attempt = 0
        while true {
            do {
                let (data, response) = try await transport.data(for: request)
                try Task.checkCancellation()
                guard (200..<300).contains(response.statusCode) else {
                    let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
                    let message = envelope?.error.message
                        ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                    throw AIServiceError.requestFailed(message)
                }

                guard let content = try JSONDecoder()
                    .decode(ChatCompletionResponse.self, from: data)
                    .choices.first?.message.content?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else {
                    throw AIServiceError.invalidResponse
                }
                guard content.utf8.count <= AIResponseLimits.maximumGeneratedTextBytes else {
                    throw AIServiceError.responseTooLarge
                }
                return content
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIServiceError {
                guard Self.isTransient(error) else { throw error }
                if attempt >= Self.maxRetries { throw error }
                attempt += 1
                try await Task.sleep(for: Self.retryDelays[attempt - 1])
            } catch {
                // Cancellation must never be retried.
                if Task.isCancelled { throw CancellationError() }
                // Network-level errors (timeouts, dropped connections).
                if attempt >= Self.maxRetries { throw error }
                attempt += 1
                try await Task.sleep(for: Self.retryDelays[attempt - 1])
            }
        }
    }

    func chatStream(
        _ messages: [AIMessage]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        guard let streamingTransport = transport as? any AIStreamingHTTPTransport else {
            let response = try await chat(messages)
            return AsyncThrowingStream { continuation in
                continuation.yield(response)
                continuation.finish()
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(model: model, messages: messages, stream: true)
        )

        var connectionAttempt = 0
        var openedLines: AsyncThrowingStream<String, any Error>?
        while openedLines == nil {
            do {
                let (lines, response) = try await streamingTransport.lines(for: request)
                guard (200..<300).contains(response.statusCode) else {
                    throw AIServiceError.requestFailed(
                        "\(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
                    )
                }
                openedLines = lines
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIServiceError {
                guard Self.isTransient(error), connectionAttempt < Self.maxRetries else {
                    throw error
                }
                connectionAttempt += 1
                try await Task.sleep(for: Self.retryDelays[connectionAttempt - 1])
            } catch {
                guard connectionAttempt < Self.maxRetries else { throw error }
                connectionAttempt += 1
                try await Task.sleep(for: Self.retryDelays[connectionAttempt - 1])
            }
        }
        guard let lines = openedLines else { throw AIServiceError.invalidResponse }

        return AsyncThrowingStream { continuation in
            let parser = Task {
                var receivedContent = false
                var receivedContentBytes = 0
                do {
                    for try await line in lines {
                        try Task.checkCancellation()
                        switch try AIStreamParser.event(from: line) {
                        case .none:
                            continue
                        case .done:
                            guard receivedContent else {
                                throw AIServiceError.invalidResponse
                            }
                            continuation.finish()
                            return
                        case let .content(content):
                            let contentBytes = content.utf8.count
                            guard contentBytes
                                    <= AIResponseLimits.maximumGeneratedTextBytes
                                        - receivedContentBytes else {
                                throw AIServiceError.responseTooLarge
                            }
                            receivedContentBytes += contentBytes
                            receivedContent = true
                            continuation.yield(content)
                        }
                    }
                    // A clean stream must end with the protocol sentinel.
                    // EOF after partial content is a truncated response, not success.
                    throw AIServiceError.invalidResponse
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in parser.cancel() }
        }
    }

    private var endpoint: URL {
        if baseURL.path.hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL.appending(path: "chat/completions")
    }

    /// Errors worth retrying: rate limits and server faults. 4xx client
    /// errors (bad key, bad model, bad request) fail fast instead.
    private static func isTransient(_ error: AIServiceError) -> Bool {
        guard case let .requestFailed(message) = error else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("429")
            || lowercased.contains("too many")
            || lowercased.contains("rate limit")
            || lowercased.contains("server error")
            || lowercased.contains("500")
            || lowercased.contains("502")
            || lowercased.contains("503")
            || lowercased.contains("504")
            || lowercased.contains("overloaded")
            || lowercased.contains("internal error")
    }

    private static let maxRetries = 2
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2)]
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [AIMessage]
    let stream: Bool
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ChatCompletionStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

enum AIStreamEvent: Equatable {
    case content(String)
    case done
}

enum AIStreamParser {
    static func event(from line: String) throws -> AIStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else {
            throw AIServiceError.invalidResponse
        }
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        guard let content = chunk.choices.first?.delta.content, !content.isEmpty else {
            return nil
        }
        return .content(content)
    }
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

/// All API-key providers are OpenAI-compatible; they differ only by `kind`.
/// F22 collapsed four copy-pasted wrapper structs into this single type.
struct OpenAICompatibleAIProvider: AIProvider {
    let kind: AIProviderKind
    private let provider: OpenAICompatibleProvider

    init(
        kind: AIProviderKind,
        apiKey: String,
        baseURL: URL,
        model: String,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) {
        self.kind = kind
        self.provider = OpenAICompatibleProvider(
            kind: kind, apiKey: apiKey, baseURL: baseURL, model: model, transport: transport
        )
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await provider.chat(messages)
    }

    func chatStream(
        _ messages: [AIMessage]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await provider.chatStream(messages)
    }
}

struct OAuthAIProvider: AIProvider {
    let kind: AIProviderKind
    private let bridge: any OAuthBridgeServicing
    private let model: String

    var maximumPromptSegmentBytes: Int {
        OAuthBridgeGenerationPolicy.maximumPromptSegmentBytes
    }

    init(
        kind: AIProviderKind,
        model: String,
        bridge: any OAuthBridgeServicing
    ) throws {
        guard kind == .codex || kind == .grok else {
            throw AIServiceError.notConfigured
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIServiceError.invalidModel }
        self.kind = kind
        self.model = kind == .codex && model == "gpt-5.3-codex"
            ? "gpt-5.6-sol"
            : model
        self.bridge = bridge
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        guard messages.count == 2,
              messages[0].role == .system,
              messages[1].role == .user,
              !messages[0].content.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !messages[1].content.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw AIServiceError.invalidConversation
        }
        let provider: OAuthBridgeProvider = switch kind {
        case .codex: .codex
        case .grok: .grok
        case .deepSeek, .qwen:
            throw AIServiceError.notConfigured
        }
        let response = try await bridge.generateText(
            provider: provider,
            model: model,
            systemPrompt: messages[0].content,
            userPrompt: messages[1].content
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { throw AIServiceError.invalidResponse }
        return response
    }
}

enum AIProviderFactory {
    static func make(
        settings: AIProviderSettings,
        credentialStore: LocalCredentialStore,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) throws -> any AIProvider {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIServiceError.invalidModel }
        guard let baseURL = validatedBaseURL(settings.baseURL) else {
            throw AIServiceError.invalidBaseURL
        }
        guard let apiKey = try credentialStore.read(account: settings.kind.rawValue),
              !apiKey.isEmpty else {
            throw AIServiceError.notConfigured
        }

        return OpenAICompatibleAIProvider(
            kind: settings.kind,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            transport: transport
        )
    }

    static func validatedBaseURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    static func makeOAuth(
        settings: AIProviderSettings,
        bridge: any OAuthBridgeServicing
    ) throws -> any AIProvider {
        try OAuthAIProvider(
            kind: settings.kind,
            model: settings.model,
            bridge: bridge
        )
    }
}

enum AIJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String

        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3 else { throw AIServiceError.invalidResponse }
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        } else if let first = trimmed.firstIndex(of: "{"),
                  let last = trimmed.lastIndex(of: "}"), first <= last {
            json = String(trimmed[first...last])
        } else {
            throw AIServiceError.invalidResponse
        }

        guard let data = json.data(using: .utf8) else {
            throw AIServiceError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIServiceError.invalidResponse
        }
    }
}

struct AISearchPlanPayload: Decodable, Sendable {
    let keywords: [String]
    let fileKinds: [String]
    let modifiedAfter: String?
    let modifiedBefore: String?

    init(
        keywords: [String],
        fileKinds: [String],
        modifiedAfter: String? = nil,
        modifiedBefore: String? = nil
    ) {
        self.keywords = keywords
        self.fileKinds = fileKinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }
}

enum AISearchQueryClassifier {
    private static let naturalLanguageMarkers = [
        "找我", "找一下", "帮我找", "查一下", "我想找",
        "哪些文件", "哪个文件", "最近的", "上个月", "上周", "去年", "今年"
    ]

    static func shouldUseAI(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 5 else { return false }
        return naturalLanguageMarkers.contains { normalized.localizedCaseInsensitiveContains($0) }
    }
}

struct AISearchPlan: Equatable, Sendable {
    let keywords: [String]
    let fileKinds: Set<FileKind>
    let modifiedAfter: Date?
    let modifiedBefore: Date?

    init(
        keywords: [String],
        fileKinds: Set<FileKind>,
        modifiedAfter: Date?,
        modifiedBefore: Date?
    ) {
        self.keywords = keywords
        self.fileKinds = fileKinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }

    init(payload: AISearchPlanPayload) {
        keywords = Array(
            payload.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(12)
        )
        fileKinds = Set(payload.fileKinds.compactMap(FileKind.init(rawValue:)))
        modifiedAfter = Self.date(from: payload.modifiedAfter)
        if let endDate = Self.date(from: payload.modifiedBefore) {
            modifiedBefore = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 1, to: endDate)?
                .addingTimeInterval(-1)
        } else {
            modifiedBefore = nil
        }
    }

    func filter(_ files: [IndexedFile]) -> [IndexedFile] {
        files.filter { file in
            if !fileKinds.isEmpty, !fileKinds.contains(file.kind) { return false }
            if let modifiedAfter,
               file.modifiedAt.map({ $0 < modifiedAfter }) ?? true { return false }
            if let modifiedBefore,
               file.modifiedAt.map({ $0 > modifiedBefore }) ?? true { return false }
            return true
        }
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

struct AIFileContext: Equatable, Sendable {
    let promptText: String
    let includedCharacterCount: Int
    let totalCharacterCount: Int
    let isTruncated: Bool

    init(
        file: IndexedFile,
        maximumCharacterCount: Int = 40_000,
        maximumUTF8Bytes: Int = 120_000,
        textOverride: String? = nil,
        usesEnglish: Bool = AppLanguage.selected.usesEnglish
    ) throws {
        guard maximumCharacterCount > 0, maximumUTF8Bytes > 0,
              let text = (textOverride ?? file.textContent)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AIServiceError.missingFileText
        }
        let heading = usesEnglish
            ? "File name: \(file.name)\nFile type: \(file.kind.localizedTitle)\nContent:\n"
            : "文件名：\(file.name)\n文件类型：\(file.kind.localizedTitle)\n内容：\n"
        let contentBudget = max(1, maximumUTF8Bytes - heading.utf8.count)
        let characterLimited = String(text.prefix(maximumCharacterCount))
        let excerpt = Self.prefix(characterLimited, maximumUTF8Bytes: contentBudget)
        includedCharacterCount = excerpt.count
        totalCharacterCount = text.count
        isTruncated = excerpt.count < text.count
        promptText = usesEnglish
            ? """
              File name: \(file.name)
              File type: \(file.kind.localizedTitle)
              Content:
              \(excerpt)
              """
            : """
              文件名：\(file.name)
              文件类型：\(file.kind.localizedTitle)
              内容：
              \(excerpt)
              """
    }

    private static func prefix(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        result.reserveCapacity(min(text.count, maximumUTF8Bytes))
        var usedBytes = 0
        for character in text {
            let value = String(character)
            let byteCount = value.utf8.count
            guard usedBytes + byteCount <= maximumUTF8Bytes else { break }
            result.append(character)
            usedBytes += byteCount
        }
        return result
    }
}

private enum AIRelevantTextSelector {
    private struct RankedChunk {
        let index: Int
        let text: String
        let score: Int
    }

    static func excerpts(
        from text: String,
        question: String,
        maximumCharacterCount: Int = 40_000
    ) -> String {
        let chunks = makeChunks(text)
        guard chunks.count > 1 else { return text }
        let terms = searchTerms(question)
        guard !terms.isEmpty else { return String(text.prefix(maximumCharacterCount)) }

        let ranked = chunks.enumerated().map { index, chunk in
            let folded = chunk.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let score = terms.reduce(into: 0) { partial, term in
                var searchRange = folded.startIndex..<folded.endIndex
                while let range = folded.range(of: term, options: [], range: searchRange) {
                    partial += max(1, term.count)
                    searchRange = range.upperBound..<folded.endIndex
                }
            }
            return RankedChunk(index: index, text: chunk, score: score)
        }
        let selected = ranked
            .sorted {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            .prefix(6)
            .sorted { $0.index < $1.index }

        var result = ""
        for item in selected where item.score > 0 || result.isEmpty {
            let marker = "[Excerpt \(item.index + 1)]\n"
            guard result.count + marker.count < maximumCharacterCount else { break }
            let remaining = maximumCharacterCount - result.count - marker.count
            result += marker + String(item.text.prefix(remaining)) + "\n\n"
        }
        return result.isEmpty ? String(text.prefix(maximumCharacterCount)) : result
    }

    private static func makeChunks(_ text: String) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            let value = String(paragraph)
            if current.count + value.count > 1_800, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current.append("\n") }
            current.append(contentsOf: value)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func searchTerms(_ question: String) -> [String] {
        let folded = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var terms = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let chinese = folded.filter { $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }
        if chinese.count >= 2 {
            let values = Array(chinese)
            for index in 0..<(values.count - 1) {
                terms.append(String(values[index...index + 1]))
            }
        }
        return Array(Set(terms))
    }
}

struct AIClassificationSuggestion: Identifiable, Equatable, Sendable {
    let fileID: String
    let fileName: String
    var categoryIDs: [UUID]
    var categoryNames: [String]
    let confidence: Double
    let reason: String
    let source: Source

    enum Source: String, Equatable, Sendable {
        case local
        case ai
    }

    init(
        fileID: String,
        fileName: String,
        categoryIDs: [UUID],
        categoryNames: [String],
        confidence: Double = 0.5,
        reason: String = "",
        source: Source = .ai
    ) {
        self.fileID = fileID
        self.fileName = fileName
        self.categoryIDs = categoryIDs
        self.categoryNames = categoryNames
        self.confidence = confidence
        self.reason = reason
        self.source = source
    }

    var id: String { fileID }
}

struct AIClassificationChange: Equatable, Sendable {
    let fileID: String
    let categoryID: UUID
}

private struct AIClassificationPayload: Decodable {
    struct Suggestion: Decodable {
        let token: String
        let categoryIDs: [String]
        let confidence: Double?
        let reason: String?
    }

    let suggestions: [Suggestion]
}

struct AIService: Sendable {
    let provider: any AIProvider

    private var filePromptBudget: Int {
        max(4_096, provider.maximumPromptSegmentBytes - 4_096)
    }

    private func scopeNotice(for context: AIFileContext, usesEnglish: Bool) -> String {
        guard context.isTruncated else { return "" }
        return usesEnglish
            ? "Analysis scope: \(context.includedCharacterCount) of \(context.totalCharacterCount) characters were included.\n\n"
            : "分析范围：已读取 \(context.includedCharacterCount) / \(context.totalCharacterCount) 个字符。\n\n"
    }

    private func stream(
        _ source: AsyncThrowingStream<String, any Error>,
        prefixedBy prefix: String
    ) -> AsyncThrowingStream<String, any Error> {
        guard !prefix.isEmpty else { return source }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(prefix)
                    for try await chunk in source {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func searchPlan(for query: String, now: Date = Date()) async throws -> AISearchPlan {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw AIServiceError.invalidSearchQuery }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let usesEnglish = AppLanguage.selected.usesEnglish
        let systemPrompt = usesEnglish
            ? """
              Convert natural-language file searches to JSON only; never access files. Today is \(dateFormatter.string(from: now)).
              Output only: {"keywords":["keyword"],"fileKinds":["document|image|video|audio|archive|code|other"],"modifiedAfter":"yyyy-MM-dd or null","modifiedBefore":"yyyy-MM-dd or null"}.
              Keep only concrete terms suitable for local filename, path, category, or indexed-text search. Use empty arrays or null for uncertain conditions.
              """
            : """
              你只负责把自然语言文件查找请求转换为 JSON，不接触任何文件。今天是 \(dateFormatter.string(from: now))。
              仅输出：{"keywords":["关键词"],"fileKinds":["document|image|video|audio|archive|code|other"],"modifiedAfter":"yyyy-MM-dd 或 null","modifiedBefore":"yyyy-MM-dd 或 null"}。
              keywords 只保留适合本地文件名、路径、分类或正文检索的实词；不能确定的条件使用空数组或 null。
              """
        let response = try await provider.chat([
            AIMessage(
                role: .system,
                content: systemPrompt
            ),
            AIMessage(role: .user, content: query)
        ])
        return AISearchPlan(payload: try AIJSON.decode(AISearchPlanPayload.self, from: response))
    }

    func explain(file: IndexedFile) async throws -> String {
        let usesEnglish = AppLanguage.selected.usesEnglish
        let context = try AIFileContext(
            file: file,
            maximumUTF8Bytes: filePromptBudget,
            usesEnglish: usesEnglish
        )
        let response = try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Briefly explain only the supplied file excerpt. Return concise Markdown with: Summary, Key facts, Dates and people, Risks or uncertainties, and Action items. Cite excerpt markers when present. Never invent missing information or perform file operations."
                    : "只分析提供的当前文件片段。用简洁 Markdown 输出：摘要、关键事实、日期与人物、风险或不确定项、待办事项；存在片段标记时引用标记。不要虚构缺失信息，不要执行文件操作。"
            ),
            AIMessage(role: .user, content: context.promptText)
        ])
        return scopeNotice(for: context, usesEnglish: usesEnglish) + response
    }

    func explainStream(
        file: IndexedFile
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let usesEnglish = AppLanguage.selected.usesEnglish
        let context = try AIFileContext(
            file: file,
            maximumUTF8Bytes: filePromptBudget,
            usesEnglish: usesEnglish
        )
        let source = try await provider.chatStream([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Briefly explain only the supplied file excerpt. Return concise Markdown with: Summary, Key facts, Dates and people, Risks or uncertainties, and Action items. Cite excerpt markers when present. Never invent missing information or perform file operations."
                    : "只分析提供的当前文件片段。用简洁 Markdown 输出：摘要、关键事实、日期与人物、风险或不确定项、待办事项；存在片段标记时引用标记。不要虚构缺失信息，不要执行文件操作。"
            ),
            AIMessage(role: .user, content: context.promptText)
        ])
        return stream(source, prefixedBy: scopeNotice(for: context, usesEnglish: usesEnglish))
    }

    func answer(question: String, about file: IndexedFile) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AIServiceError.invalidQuestion }
        let usesEnglish = AppLanguage.selected.usesEnglish
        guard let text = file.textContent else { throw AIServiceError.missingFileText }
        let relevantText = AIRelevantTextSelector.excerpts(from: text, question: question)
        let context = try AIFileContext(
            file: file,
            maximumUTF8Bytes: filePromptBudget - min(question.utf8.count, 2_048),
            textOverride: relevantText,
            usesEnglish: usesEnglish
        )
        let response = try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Answer in English using only the retrieved excerpts from the current file. Cite [Excerpt N] for every factual claim. If unsupported, say the file contains no relevant information. Do not perform file operations."
                    : "只能根据从当前文件检索出的片段回答；每个事实结论都引用 [Excerpt N]。找不到依据时明确说文件中没有相关信息；不要执行文件操作。"
            ),
            AIMessage(
                role: .user,
                content: "\(context.promptText)\n\n\(usesEnglish ? "Question" : "问题")：\(String(question.prefix(1_000)))"
            )
        ])
        return scopeNotice(for: context, usesEnglish: usesEnglish) + response
    }

    func answerStream(
        question: String,
        about file: IndexedFile
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AIServiceError.invalidQuestion }
        let usesEnglish = AppLanguage.selected.usesEnglish
        guard let text = file.textContent else { throw AIServiceError.missingFileText }
        let relevantText = AIRelevantTextSelector.excerpts(from: text, question: question)
        let context = try AIFileContext(
            file: file,
            maximumUTF8Bytes: filePromptBudget - min(question.utf8.count, 2_048),
            textOverride: relevantText,
            usesEnglish: usesEnglish
        )
        let source = try await provider.chatStream([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Answer in English using only the retrieved excerpts from the current file. Cite [Excerpt N] for every factual claim. If unsupported, say the file contains no relevant information. Do not perform file operations."
                    : "只能根据从当前文件检索出的片段回答；每个事实结论都引用 [Excerpt N]。找不到依据时明确说文件中没有相关信息；不要执行文件操作。"
            ),
            AIMessage(
                role: .user,
                content: "\(context.promptText)\n\n\(usesEnglish ? "Question" : "问题")：\(String(question.prefix(1_000)))"
            )
        ])
        return stream(source, prefixedBy: scopeNotice(for: context, usesEnglish: usesEnglish))
    }

    func classify(
        files: [IndexedFile],
        categories: [FileCategory],
        includesFileContent: Bool = true
    ) async throws -> [AIClassificationSuggestion] {
        guard (1...50).contains(files.count) else { throw AIServiceError.invalidSelection }
        guard !categories.isEmpty else { throw AIServiceError.noCategories }

        var results: [AIClassificationSuggestion] = []
        for batch in files.chunked(into: 8) {
            try Task.checkCancellation()
            do {
                results.append(contentsOf: try await classifyBatch(
                    batch,
                    categories: categories,
                    includesFileContent: includesFileContent
                ))
            } catch {
                let local = localClassificationSuggestions(files: batch, categories: categories)
                guard !local.isEmpty else { throw error }
                results.append(contentsOf: local)
            }
        }
        return results
    }

    private func classifyBatch(
        _ files: [IndexedFile],
        categories: [FileCategory],
        includesFileContent: Bool
    ) async throws -> [AIClassificationSuggestion] {

        let usesEnglish = AppLanguage.selected.usesEnglish
        var fileByToken: [String: IndexedFile] = [:]
        let fileDescriptions = files.enumerated().map { index, file in
            let token = "F\(index + 1)"
            fileByToken[token] = file
            let text = includesFileContent ? file.textContent?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(provider.maximumPromptSegmentBytes <= 65_536 ? 1_500 : 6_000) : nil
            return usesEnglish
                ? """
                  [\(token)]
                  File name: \(file.name)
                  File type: \(file.kind.localizedTitle)
                  Content: \(text.map(String.init) ?? "No extractable text; use only the filename and type")
                  """
                : """
                  [\(token)]
                  文件名：\(file.name)
                  文件类型：\(file.kind.localizedTitle)
                  内容：\(text.map(String.init) ?? "无可提取文本，仅根据文件名和类型判断")
                  """
        }
        let allowedCategories = categories.map { "\($0.id.uuidString)=\($0.name)" }
        let response = try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? """
                      Suggest 0 to 3 existing categories for each file. Return stable category IDs, confidence from 0 to 1, and a short reason. Never create categories. Output JSON only:
                      {"suggestions":[{"token":"F1","categoryIDs":["UUID"],"confidence":0.8,"reason":"short evidence"}]}
                      Available categories (ID=name): \(allowedCategories.joined(separator: ", "))
                      """
                    : """
                      为每个文件从现有分类中建议 0 到 3 个分类，返回稳定分类 ID、0 到 1 的置信度和简短依据；不得创建分类。仅输出 JSON：
                      {"suggestions":[{"token":"F1","categoryIDs":["UUID"],"confidence":0.8,"reason":"简短依据"}]}
                      可用分类（ID=名称）：\(allowedCategories.joined(separator: "、"))
                      """
            ),
            AIMessage(role: .user, content: fileDescriptions.joined(separator: "\n\n"))
        ])
        let payload = try AIJSON.decode(AIClassificationPayload.self, from: response)
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        return payload.suggestions.compactMap { suggestion in
            guard let file = fileByToken[suggestion.token] else { return nil }
            let matched = Array(
                suggestion.categoryIDs
                    .compactMap(UUID.init(uuidString:))
                    .compactMap { categoryByID[$0] }
                    .reduce(into: [UUID: FileCategory]()) { $0[$1.id] = $1 }
                    .values
                    .prefix(3)
            )
            return AIClassificationSuggestion(
                fileID: file.id,
                fileName: file.name,
                categoryIDs: matched.map(\.id),
                categoryNames: matched.map(\.name),
                confidence: min(max(suggestion.confidence ?? 0.5, 0), 1),
                reason: String((suggestion.reason ?? "").prefix(240)),
                source: .ai
            )
        }
    }

    private func localClassificationSuggestions(
        files: [IndexedFile],
        categories: [FileCategory]
    ) -> [AIClassificationSuggestion] {
        files.compactMap { file in
            let searchable = "\(file.name) \(file.fileExtension) \(file.kind.localizedTitle)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let matched = categories.filter { category in
                let name = category.name
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return name.count >= 2 && searchable.contains(name)
            }.prefix(3)
            guard !matched.isEmpty else { return nil }
            return AIClassificationSuggestion(
                fileID: file.id,
                fileName: file.name,
                categoryIDs: matched.map(\.id),
                categoryNames: matched.map(\.name),
                confidence: 0.55,
                reason: AppLanguage.localized(
                    "根据文件名、类型与现有分类在本地匹配。",
                    english: "Matched locally from the file name, type, and existing categories."
                ),
                source: .local
            )
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
