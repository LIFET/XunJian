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
        case .grok: "grok-4.5"
        case .deepSeek: "deepseek-v4-flash"
        case .qwen: "qwen3.7-plus"
        }
    }

}

enum AIAuthenticationMode: String, Codable, Equatable, Sendable {
    case apiKey
    case oauth
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
        case .notConfigured: "未配置"
        case .saved: "密钥已保存"
        case .testing: "正在验证"
        case .verified: "连接已验证"
        case .failed: "验证失败"
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
            "API Key 不能为空。"
        case .invalidData:
            "本地 API Key 文件内容无效。原文件已保留，请恢复有效文件后重试。"
        case .unavailable:
            "无法安全访问本地 API Key 文件。原文件已保留，请检查文件所有权与权限后重试。"
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
    func chat(_ messages: [AIMessage]) async throws -> String
}

protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        return (data, response)
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

    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先登录 OAuth 或保存 API Key，并设为当前 AI。"
        case .invalidBaseURL: "Base URL 必须是有效的 HTTPS 地址。"
        case .invalidModel: "模型名称不能为空。"
        case .invalidResponse: "AI 返回了无法识别的响应。"
        case let .requestFailed(message): "AI 请求失败：\(message)"
        case .missingFileText: "这个文件没有可供 AI 阅读的文本内容。"
        case .invalidQuestion: "请输入要询问的问题。"
        case .invalidSearchQuery: "请输入要查找的文件描述。"
        case .invalidSelection: "请选择 1 到 8 个文件。"
        case .invalidConversation: "AI 请求必须包含一条系统指令和一条用户消息。"
        case .noCategories: "请先创建至少一个分类，再使用 AI 分类。"
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

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            let message = envelope?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw AIServiceError.requestFailed(message)
        }

        guard let content = try JSONDecoder()
            .decode(ChatCompletionResponse.self, from: data)
            .choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIServiceError.invalidResponse
        }
        return content
    }
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

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

struct CodexProvider: AIProvider {
    let kind = AIProviderKind.codex
    private let provider: OpenAICompatibleProvider

    init(
        apiKey: String,
        baseURL: URL,
        model: String,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) {
        provider = OpenAICompatibleProvider(
            kind: kind, apiKey: apiKey, baseURL: baseURL, model: model, transport: transport
        )
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await provider.chat(messages)
    }
}

struct GrokProvider: AIProvider {
    let kind = AIProviderKind.grok
    private let provider: OpenAICompatibleProvider

    init(
        apiKey: String,
        baseURL: URL,
        model: String,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) {
        provider = OpenAICompatibleProvider(
            kind: kind, apiKey: apiKey, baseURL: baseURL, model: model, transport: transport
        )
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await provider.chat(messages)
    }
}

struct DeepSeekProvider: AIProvider {
    let kind = AIProviderKind.deepSeek
    private let provider: OpenAICompatibleProvider

    init(
        apiKey: String,
        baseURL: URL,
        model: String,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) {
        provider = OpenAICompatibleProvider(
            kind: kind, apiKey: apiKey, baseURL: baseURL, model: model, transport: transport
        )
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await provider.chat(messages)
    }
}

struct QwenProvider: AIProvider {
    let kind = AIProviderKind.qwen
    private let provider: OpenAICompatibleProvider

    init(
        apiKey: String,
        baseURL: URL,
        model: String,
        transport: any AIHTTPTransport = URLSessionAITransport()
    ) {
        provider = OpenAICompatibleProvider(
            kind: kind, apiKey: apiKey, baseURL: baseURL, model: model, transport: transport
        )
    }

    func chat(_ messages: [AIMessage]) async throws -> String {
        try await provider.chat(messages)
    }
}

struct OAuthAIProvider: AIProvider {
    let kind: AIProviderKind
    private let bridge: any OAuthBridgeServicing
    private let model: String

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

        switch settings.kind {
        case .codex:
            return CodexProvider(apiKey: apiKey, baseURL: baseURL, model: model, transport: transport)
        case .grok:
            return GrokProvider(apiKey: apiKey, baseURL: baseURL, model: model, transport: transport)
        case .deepSeek:
            return DeepSeekProvider(apiKey: apiKey, baseURL: baseURL, model: model, transport: transport)
        case .qwen:
            return QwenProvider(apiKey: apiKey, baseURL: baseURL, model: model, transport: transport)
        }
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

    init(
        file: IndexedFile,
        maximumCharacterCount: Int = 40_000,
        usesEnglish: Bool = AppLanguage.selected.usesEnglish
    ) throws {
        guard maximumCharacterCount > 0,
              let text = file.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AIServiceError.missingFileText
        }
        promptText = usesEnglish
            ? """
              File name: \(file.name)
              File type: \(file.kind.localizedTitle)
              Content:
              \(String(text.prefix(maximumCharacterCount)))
              """
            : """
              文件名：\(file.name)
              文件类型：\(file.kind.localizedTitle)
              内容：
              \(String(text.prefix(maximumCharacterCount)))
              """
    }
}

struct AIClassificationSuggestion: Identifiable, Equatable, Sendable {
    let fileID: String
    let fileName: String
    let categoryIDs: [UUID]
    let categoryNames: [String]

    var id: String { fileID }
}

struct AIClassificationChange: Equatable, Sendable {
    let fileID: String
    let categoryID: UUID
}

private struct AIClassificationPayload: Decodable {
    struct Suggestion: Decodable {
        let token: String
        let categoryNames: [String]
    }

    let suggestions: [Suggestion]
}

struct AIService: Sendable {
    let provider: any AIProvider

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
        let context = try AIFileContext(file: file, usesEnglish: usesEnglish)
        return try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Briefly explain what the file is, its main content, and likely use in English. Do not perform file operations or invent missing information."
                    : "用简体中文简短说明文件是什么、主要内容和可能用途。不要执行文件操作，不要虚构缺失信息。"
            ),
            AIMessage(role: .user, content: context.promptText)
        ])
    }

    func answer(question: String, about file: IndexedFile) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AIServiceError.invalidQuestion }
        let usesEnglish = AppLanguage.selected.usesEnglish
        let context = try AIFileContext(file: file, usesEnglish: usesEnglish)
        return try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? "Answer in English using only the provided file content. If the answer is not supported, say that the file contains no relevant information. Do not perform file operations."
                    : "只能根据提供的当前文件内容回答。找不到依据时明确说文件中没有相关信息；不要执行文件操作。"
            ),
            AIMessage(
                role: .user,
                content: "\(context.promptText)\n\n\(usesEnglish ? "Question" : "问题")：\(String(question.prefix(1_000)))"
            )
        ])
    }

    func classify(
        files: [IndexedFile],
        categories: [FileCategory]
    ) async throws -> [AIClassificationSuggestion] {
        guard (1...8).contains(files.count) else { throw AIServiceError.invalidSelection }
        guard !categories.isEmpty else { throw AIServiceError.noCategories }

        let usesEnglish = AppLanguage.selected.usesEnglish
        var fileByToken: [String: IndexedFile] = [:]
        let fileDescriptions = files.enumerated().map { index, file in
            let token = "F\(index + 1)"
            fileByToken[token] = file
            let text = file.textContent?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(6_000)
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
        let allowedNames = categories.map(\.name)
        let response = try await provider.chat([
            AIMessage(
                role: .system,
                content: usesEnglish
                    ? """
                      Suggest 0 to 3 existing categories for each file. Never create categories. Output JSON only:
                      {"suggestions":[{"token":"F1","categoryNames":["exact existing category name"]}]}
                      Available category names: \(allowedNames.joined(separator: ", "))
                      """
                    : """
                      为每个文件从现有分类中建议 0 到 3 个分类，不创建新分类。仅输出 JSON：
                      {"suggestions":[{"token":"F1","categoryNames":["分类名"]}]}
                      可用分类：\(allowedNames.joined(separator: "、"))
                      """
            ),
            AIMessage(role: .user, content: fileDescriptions.joined(separator: "\n\n"))
        ])
        let payload = try AIJSON.decode(AIClassificationPayload.self, from: response)
        let categoryByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0) })

        return payload.suggestions.compactMap { suggestion in
            guard let file = fileByToken[suggestion.token] else { return nil }
            let matched = Array(
                suggestion.categoryNames
                    .compactMap { categoryByName[$0] }
                    .reduce(into: [UUID: FileCategory]()) { $0[$1.id] = $1 }
                    .values
                    .prefix(3)
            )
            return AIClassificationSuggestion(
                fileID: file.id,
                fileName: file.name,
                categoryIDs: matched.map(\.id),
                categoryNames: matched.map(\.name)
            )
        }
    }
}
