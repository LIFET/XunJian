import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    static var selected: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh_CN")
        case .english: Locale(identifier: "en_US")
        }
    }

    var usesEnglish: Bool {
        switch self {
        case .system:
            Locale.preferredLanguages.first?.hasPrefix("en") == true
        case .simplifiedChinese:
            false
        case .english:
            true
        }
    }

    var title: String {
        switch self {
        case .system:
            Self.localized("跟随系统", english: "System Default")
        case .simplifiedChinese:
            Self.localized("简体中文", english: "Simplified Chinese")
        case .english:
            "English"
        }
    }

    static func localized(_ chinese: String, english: String) -> String {
        selected.usesEnglish ? english : chinese
    }

    static func fileCount(_ count: Int) -> String {
        guard selected.usesEnglish else { return "\(count) 个文件" }
        return count == 1 ? "1 file" : "\(count) files"
    }

    /// VoiceOver list separator. English uses a comma; Chinese uses a dunhao.
    static var listSeparator: String {
        selected.usesEnglish ? ", " : "、"
    }

    static func joinedForAccessibility(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: listSeparator)
    }

    static func localizedRuntimeMessage(_ message: String) -> String {
        let codexDiagnosticPrefix = "Codex verification rejected ["
        if message.hasPrefix(codexDiagnosticPrefix), message.hasSuffix("].") {
            let code = String(message.dropFirst(codexDiagnosticPrefix.count).dropLast(2))
            guard codexVerificationDiagnosticCodes.contains(code) else {
                return selected.usesEnglish
                    ? "The OAuth operation didn’t complete. Try again later."
                    : "OAuth 操作没有完成，请稍后重试。"
            }
            return selected.usesEnglish
                ? message
                : "Codex 验证在安全检查阶段被拒绝（\(code)）。"
        }
        let grokDiagnosticMarker = "Grok verification rejected"
        let grokDiagnosticPrefix = "Grok verification rejected ["
        if message.hasPrefix(grokDiagnosticMarker) {
            let genericMessage = selected.usesEnglish
                ? "The OAuth operation didn’t complete. Try again later."
                : "OAuth 操作没有完成，请稍后重试。"
            guard message.hasPrefix(grokDiagnosticPrefix), message.hasSuffix("].") else {
                return genericMessage
            }
            let code = String(
                message
                    .dropFirst(grokDiagnosticPrefix.count)
                    .dropLast(2)
            )
            guard grokVerificationDiagnosticCodes.contains(code) else {
                return genericMessage
            }
            return selected.usesEnglish
                ? message
                : "Grok 验证在安全检查阶段被拒绝（\(code)）。"
        }

        guard selected.usesEnglish else {
            switch message {
            case "OAuth bridge request is too large.":
                return "OAuth 请求过大。"
            case "OAuth bridge request is malformed.":
                return "OAuth 请求格式无效。"
            case "OAuth bridge protocol version is incompatible.":
                return "OAuth 伴随服务版本不兼容，请更新寻简。"
            case "OAuth bridge connection is unavailable.":
                return "OAuth 伴随服务当前不可用。"
            case "OAuth bridge request arguments are invalid.":
                return "OAuth 请求参数无效。"
            case "An OAuth operation is already in progress.":
                return "已有 OAuth 操作正在进行。"
            case "OAuth authentication operation failed.":
                return "OAuth 认证操作失败，请重试。"
            case "XunJian's bundled Codex App Server is unavailable.":
                return "寻简内置 Codex App Server 不可用。"
            case "XunJian's bundled Codex App Server is missing, damaged, or untrusted.":
                return "寻简内置 Codex App Server 缺失、损坏或未通过签名校验。"
            case "XunJian's bundled Codex App Server changed unexpectedly.":
                return "寻简内置 Codex App Server 发生了异常变化。"
            case "XunJian's private Codex login storage is unavailable or unsafe.":
                return "寻简专属 ChatGPT 登录目录不可用或不安全。"
            case "XunJian's private Codex login is already in use.":
                return "寻简专属 ChatGPT 登录正在被另一个连接使用。"
            case "This Mac does not support XunJian's bundled Codex App Server.":
                return "这台 Mac 暂不支持寻简内置的 Codex App Server。"
            case "XunJian's bundled Grok Runtime is unavailable.":
                return "寻简内置 Grok Runtime 不可用。"
            case "XunJian's bundled Grok Runtime is missing, damaged, or untrusted.":
                return "寻简内置 Grok Runtime 缺失、损坏或未通过签名校验。"
            case "This Mac does not support XunJian's bundled Grok Runtime.":
                return "这台 Mac 暂不支持寻简内置的 Grok Runtime。"
            case "XunJian's private Grok login storage is unavailable or unsafe.":
                return "寻简专属 Grok 登录目录不可用或不安全。"
            case "XunJian's private Grok login is already in use.":
                return "寻简专属 Grok 登录正在被另一个连接使用。"
            case "XunJian's private Grok login directory changed unexpectedly.":
                return "寻简专属 Grok 登录目录发生了异常变化。"
            case "Grok reported unsafe hooks, tools, or session capabilities.":
                return "Grok 报告了不安全的 Hook、工具或会话能力，已停止验证。"
            case "Grok's isolated runtime safety inspection failed.":
                return "Grok 隔离运行环境安全检查未通过，已停止连接。"
            case "Codex OAuth login could not be started.":
                return "无法启动 Codex OAuth 登录。"
            case "OAuth bridge was closed.":
                return "OAuth 伴随服务已关闭，请重试。"
            case "OAuth login attempt does not match.":
                return "OAuth 登录请求已失效，请重新开始。"
            default:
                if message.localizedCaseInsensitiveContains("oauth")
                    || message.localizedCaseInsensitiveContains("codex")
                    || message.localizedCaseInsensitiveContains("grok") {
                    return "OAuth 操作没有完成，请稍后重试。"
                }
                return message
            }
        }

        switch message {
        case "文件已经不存在，索引将在重新扫描后更新。":
            return "The file no longer exists. The index will update after the next rescan."
        case "文件名不能为空，也不能包含“/”或“:”。":
            return "The file name can’t be empty or contain “/” or “:”."
        case "当前位置不可写，无法完成这个文件操作。":
            return "This location isn’t writable, so the file operation couldn’t be completed."
        case "无法保存这个文件夹的访问权限，请重新选择。":
            return "Couldn’t save access to this folder. Select it again."
        case "macOS 已取消这个文件夹的访问权限，请重新授权。":
            return "macOS no longer grants access to this folder. Reauthorize it."
        case "分类名称不能为空，且最多使用 80 个字符。":
            return "The category name can’t be empty and must contain no more than 80 characters."
        case "已经存在同名分类，请换一个名称。":
            return "A category with this name already exists. Choose another name."
        case "API Key 不能为空。":
            return "The API key can’t be empty."
        case "无法读取本地 API Key 文件。":
            return "Couldn’t read the local API key file."
        case "无法访问本地 API Key 存储。":
            return "Couldn’t access the local API key storage."
        case "请先在设置中保存 API Key，并设为当前 AI。",
             "请先登录 OAuth 或保存 API Key，并设为当前 AI。":
            return "Sign in with OAuth or save an API key in Settings, then set it as the current AI."
        case "Base URL 必须是有效的 HTTPS 地址。":
            return "The Base URL must be a valid HTTPS address."
        case "模型名称不能为空。":
            return "The model name can’t be empty."
        case "AI 返回了无法识别的响应。":
            return "The AI returned an unrecognized response."
        case "这个文件没有可供 AI 阅读的文本内容。":
            return "This file has no text available for AI to read."
        case "请输入要询问的问题。":
            return "Enter a question."
        case "请输入要查找的文件描述。":
            return "Enter a description of the files you want to find."
        case "请选择 1 到 8 个文件。":
            return "Select between 1 and 8 files."
        case "请先创建至少一个分类，再使用 AI 分类。":
            return "Create at least one category before using AI classification."
        case "操作没有完成，请稍后重试。":
            return "The operation couldn’t be completed. Try again later."
        case "无法验证 OAuth 伴随服务签名。":
            return "Couldn’t verify the OAuth companion service signature."
        case "OAuth 伴随服务请求参数无效。":
            return "The OAuth companion service request is invalid."
        case "OAuth 伴随服务响应超时。":
            return "The OAuth companion service timed out."
        case "OAuth 伴随服务返回了无法识别的响应。":
            return "The OAuth companion service returned an unrecognized response."
        case "OAuth 伴随服务版本不兼容，请更新寻简。":
            return "The OAuth companion service is incompatible. Update XunJian."
        case "OAuth 伴随服务响应与请求不匹配。":
            return "The OAuth companion service response didn’t match the request."
        case "OAuth 伴随服务返回了不匹配的 AI 提供商。":
            return "The OAuth companion service returned the wrong AI provider."
        default:
            break
        }

        if let name = value(in: message, prefix: "目标位置已经存在“", suffix: "”，请换一个名称或位置。") {
            return "“\(name)” already exists at the destination. Choose another name or location."
        }
        if let detail = value(in: message, prefix: "文件操作失败：") {
            return "The file operation failed: \(detail)"
        }
        if let detail = value(in: message, prefix: "无法访问本地文件索引：") {
            return "Couldn’t access the local file index: \(detail)"
        }
        if let name = value(in: message, prefix: "无法读取文件夹“", suffix: "”，请检查它是否存在以及当前权限。") {
            return "Couldn’t read the folder “\(name)”. Check that it exists and that you have access."
        }
        if let detail = value(in: message, prefix: "AI 请求失败：") {
            return "The AI request failed: \(detail)"
        }
        if let name = value(in: message, prefix: "请选择原文件夹“", suffix: "”以恢复授权。") {
            return "Select the original folder “\(name)” to restore access."
        }
        if let code = value(
            in: message,
            prefix: "OAuth 伴随服务连接失败（错误码 ",
            suffix: "）。"
        ) {
            return "Couldn’t connect to the OAuth companion service (error \(code))."
        }

        return message
    }

    private static let grokVerificationDiagnosticCodes: Set<String> = [
        "runtime.start",
        "runtime.cleanup",
        "AvailableCommandsUpdate",
        "Reply exactly XUNJIAN_OK. Do not use tools.",
        "XUNJIAN_OK",
        "_x.ai/mcp/servers_updated",
        "_x.ai/mcp_initialized",
        "_x.ai/queue/changed",
        "_x.ai/session/prompt_complete",
        "_x.ai/sessions/changed",
        "agent_message_chunk",
        "available_commands_update",
        "close.notification-count",
        "close.sessions-changed",
        "close.transport",
        "end_turn",
        "grok-4.6",
        "high",
        "model_changed",
        "post.agent.content",
        "post.agent.outer-meta",
        "post.agent.update",
        "post.envelope",
        "post.lifecycle.response-completed",
        "post.lifecycle.turn-completed",
        "post.prompt-complete.agent-result",
        "post.prompt-complete.duplicate",
        "post.prompt-complete.keys",
        "post.prompt-complete.mismatch",
        "post.prompt-complete.prompt-id",
        "post.prompt-complete.session-id",
        "post.prompt-complete.stop-reason",
        "post.prompt-complete.turn-id",
        "post.prompt-echo",
        "post.queue-changed",
        "post.reasoning-completed",
        "post.reply",
        "post.response-completed.duplicate",
        "post.response-completed.envelope",
        "post.response-completed.keys",
        "post.response-completed.message-id",
        "post.response-completed.reply",
        "post.response-completed.signature",
        "post.response-completed.stop-reason",
        "post.response-completed.stop-sequence",
        "post.response-completed.usage",
        "post.response-started",
        "post.sessions-changed",
        "post.thought.byte-budget",
        "post.thought.content",
        "post.thought.outer-meta",
        "post.thought.update",
        "post.turn-completed.agent-result",
        "post.turn-completed.envelope",
        "post.turn-completed.keys",
        "post.turn-completed.metadata",
        "post.turn-completed.phase",
        "post.turn-completed.prompt-id",
        "post.turn-completed.stop-reason",
        "post.turn-completed.usage.keys",
        "post.turn-completed.usage.model.envelope",
        "post.turn-completed.usage.model.keys",
        "post.turn-completed.usage.model.values",
        "post.turn-completed.usage.type",
        "post.turn-completed.usage.values",
        "post.unexpected-update",
        "post.unexpected.available-commands",
        "post.unexpected.configuration",
        "post.unexpected.extension",
        "post.unexpected.mode",
        "post.unexpected.model",
        "post.unexpected.plan",
        "post.unexpected.standard",
        "post.user.content",
        "post.user.outer-meta",
        "post.user.update",
        "prompt",
        "prompt.cancelled",
        "prompt.closed",
        "prompt.io",
        "prompt.process-exit-1",
        "prompt.process-exit-2",
        "prompt.process-exit-zero",
        "prompt.process-signal",
        "prompt.process-reap-timeout",
        "prompt.notification-overflow",
        "prompt.protocol",
        "prompt.remote-error",
        "prompt.stop-reason",
        "prompt.timeout",
        "prompt.transport",
        "prompt.unknown-notification",
        "session/update",
        "setup.commands-1",
        "setup.commands-2",
        "setup.commands-catalog",
        "setup.commands-count",
        "setup.commands-envelope",
        "setup.commands-event-id",
        "setup.commands-inner-meta",
        "setup.commands-metadata",
        "setup.commands-mismatch",
        "setup.commands-outer-keys",
        "setup.commands-outer-values",
        "setup.commands-timestamp",
        "setup.commands-tools",
        "setup.commands-total-tokens",
        "setup.commands-update-type",
        "setup.mcp-initialized",
        "setup.mcp-servers",
        "setup.model",
        "setup.notification-count",
        "setup.session",
        "setup.transport",
        "text",
    ]

    private static let codexVerificationDiagnosticCodes: Set<String> = [
        "codex.runtime-start",
        "codex.account-read",
        "codex.account-request",
        "codex.account-remote-error",
        "codex.account-notification",
        "codex.account-transport",
        "codex.account-process-exit",
        "codex.account-process-exit-1",
        "codex.account-process-exit-2",
        "codex.account-process-reap-timeout",
        "codex.account-process-exit-zero",
        "codex.account-process-signal",
        "codex.account-envelope",
        "codex.account-auth-requirement",
        "codex.account-identity",
        "codex.account-signed-out",
        "codex.model-list",
        "codex.model-unavailable",
        "codex.thread-start",
        "codex.turn-start",
        "codex.event-transport",
        "codex.event-envelope",
        "codex.event-disallowed-item",
        "codex.event-error-item",
        "codex.event-unexpected",
        "codex.transcript",
        "codex.runtime-cleanup",
        "unexpected_reply"
    ]

    private static func value(
        in message: String,
        prefix: String,
        suffix: String = ""
    ) -> String? {
        guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return nil }
        return String(message.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

extension FileCategory {
    var localizedDisplayName: String {
        switch (id.uuidString.uppercased(), name) {
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A01", "工作"):
            AppLanguage.localized("工作", english: "Work")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A02", "项目"):
            AppLanguage.localized("项目", english: "Projects")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A03", "设计"):
            AppLanguage.localized("设计", english: "Design")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A04", "资料"):
            AppLanguage.localized("资料", english: "Reference")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A05", "合同"):
            AppLanguage.localized("合同", english: "Contracts")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A06", "财务"):
            AppLanguage.localized("财务", english: "Finance")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A07", "个人"):
            AppLanguage.localized("个人", english: "Personal")
        case ("B2D19E64-0184-4B30-9364-0C05DD2A2A08", "归档"):
            AppLanguage.localized("归档", english: "Archive")
        default:
            name
        }
    }

    var localizedForDisplay: FileCategory {
        FileCategory(
            id: id,
            name: localizedDisplayName,
            symbolName: symbolName,
            createdAt: createdAt
        )
    }
}

extension AIProviderKind {
    var localizedConnectionNote: String {
        switch self {
        case .codex:
            AppLanguage.localized(
                "寻简内置并验证官方 Codex App Server，用它为寻简单独登录 ChatGPT；凭据只写入寻简专属本地目录，不会复用或影响其他应用中的账号。OpenAI API Key 保持为独立回退。",
                english: "XunJian includes and verifies the official Codex App Server to sign in to ChatGPT separately. Credentials are written only to XunJian's private local directory and do not reuse or affect accounts in other apps. The OpenAI API key remains an independent fallback."
            )
        case .grok:
            AppLanguage.localized(
                "寻简内置并验证官方 Grok Runtime，用它为寻简单独登录 xAI；凭据只写入寻简专属本地目录，不会复用或影响其他应用中的账号。xAI API Key 保持为独立回退。",
                english: "XunJian includes and verifies the official Grok Runtime to sign in to xAI separately. Credentials are written only to XunJian's private local directory and do not reuse or affect accounts in other apps. The xAI API key remains an independent fallback."
            )
        case .deepSeek:
            AppLanguage.localized(
                "使用 DeepSeek 官方 OpenAI 兼容接口。",
                english: "Uses DeepSeek’s official OpenAI-compatible API."
            )
        case .qwen:
            AppLanguage.localized(
                "使用阿里云百炼 OpenAI 兼容接口；新工作区请填写对应地域的 Workspace Base URL。",
                english: "Uses Alibaba Cloud Model Studio’s OpenAI-compatible API. For a new workspace, enter the Workspace Base URL for its region."
            )
        }
    }

}

extension AIOAuthState {
    var localizedTitle: String {
        switch self {
        case .unavailable:
            AppLanguage.localized(
                "官方运行组件不可用",
                english: "Official Runtime Unavailable"
            )
        case .statusUnknown:
            AppLanguage.localized("状态未知", english: "Status Unknown")
        case .starting:
            AppLanguage.localized(
                "正在启动登录",
                english: "Starting Sign-In"
            )
        case .disconnected:
            AppLanguage.localized("未登录", english: "Signed Out")
        case .authenticating:
            AppLanguage.localized("等待授权", english: "Waiting for Authorization")
        case .signedInDisconnected:
            AppLanguage.localized(
                "已登录，连接未建立",
                english: "Signed In, Not Connected"
            )
        case .signedInUnverified:
            AppLanguage.localized(
                "已登录，尚未验证",
                english: "Signed In, Not Yet Verified"
            )
        case .connected:
            AppLanguage.localized(
                "账号连接已验证",
                english: "Account Connection Verified"
            )
        case .failed:
            AppLanguage.localized("操作失败", english: "Operation Failed")
        }
    }

    var localizedDetail: String {
        switch self {
        case let .unavailable(status):
            unavailableDetail(for: status)
        case .statusUnknown:
            AppLanguage.localized(
                "尚未检测官方运行组件与账号状态。",
                english: "The official runtime and account status haven’t been checked yet."
            )
        case .starting:
            AppLanguage.localized(
                "正在准备官方运行组件并启动登录流程。",
                english: "Preparing the official runtime and starting the sign-in flow."
            )
        case .disconnected:
            AppLanguage.localized(
                "官方运行组件可用，当前未检测到已登录账号。",
                english: "The official runtime is available, but no signed-in account was detected."
            )
        case let .authenticating(_, authorizationURL):
            if authorizationURL == nil {
                AppLanguage.localized(
                    "官方运行组件已启动浏览器授权；完成后寻简会自动刷新状态。",
                    english: "The official runtime started browser authorization. XunJian will refresh the status automatically after you finish."
                )
            } else {
                AppLanguage.localized(
                    "请在浏览器中完成授权；完成后寻简会自动刷新状态。",
                    english: "Finish authorization in your browser. XunJian will refresh the status automatically afterward."
                )
            }
        case .signedInDisconnected:
            AppLanguage.localized(
                "已检测到登录账号，但官方运行组件当前尚未建立可用连接。",
                english: "A signed-in account was detected, but the official runtime doesn’t currently report a usable connection."
            )
        case .signedInUnverified:
            AppLanguage.localized(
                "已检测到登录账号；通过最小真实请求前不会标记为连接成功。",
                english: "A signed-in account was detected. It won’t be marked connected until a minimal real request succeeds."
            )
        case .connected:
            AppLanguage.localized(
                "官方账号状态与最小真实请求均已验证。",
                english: "The official account status and a minimal real request have both been verified."
            )
        case let .failed(message):
            AppLanguage.localizedRuntimeMessage(message)
        }
    }

    var statusColor: Color {
        switch self {
        case .connected:
            XunJianUI.Semantic.success
        case .starting, .authenticating, .signedInDisconnected, .signedInUnverified:
            XunJianUI.Semantic.warning
        case .unavailable, .failed:
            XunJianUI.Semantic.danger
        case .statusUnknown, .disconnected:
            XunJianUI.Semantic.neutral
        }
    }

    private func unavailableDetail(for status: OAuthCLIProbe.Status) -> String {
        switch status {
        case .missing:
            AppLanguage.localized(
                "内置运行组件缺失，请重新安装完整的寻简应用。",
                english: "The bundled runtime is missing. Reinstall the complete XunJian app."
            )
        case .untrusted:
            AppLanguage.localized(
                "内置运行组件已损坏或未通过官方签名校验，请重新安装寻简。",
                english: "The bundled runtime is damaged or failed official signature verification. Reinstall XunJian."
            )
        case .incompatible:
            AppLanguage.localized(
                "运行组件版本或能力不在已审计范围内，请使用受支持的官方版本。",
                english: "The runtime version or capabilities are outside the audited range. Use a supported official version."
            )
        case .launchFailed:
            AppLanguage.localized(
                "官方运行组件无法安全启动，请重新打开寻简后重试。",
                english: "The official runtime couldn’t be started safely. Reopen XunJian and try again."
            )
        case .available:
            AppLanguage.localized(
                "官方运行组件状态异常，请重新检测。",
                english: "The official runtime returned an unexpected status. Check again."
            )
        }
    }
}

extension AIConnectionState {
    var localizedTitle: String {
        switch self {
        case .notConfigured:
            AppLanguage.localized("未配置", english: "Not Configured")
        case .saved:
            AppLanguage.localized("密钥已保存", english: "API Key Saved")
        case .testing:
            AppLanguage.localized("正在验证", english: "Verifying")
        case .verified:
            AppLanguage.localized("连接已验证", english: "Connection Verified")
        case .failed:
            AppLanguage.localized("验证失败", english: "Verification Failed")
        }
    }
}

extension FileKind {
    var localizedTitle: String {
        switch self {
        case .document: AppLanguage.localized("文档", english: "Document")
        case .image: AppLanguage.localized("图片", english: "Image")
        case .video: AppLanguage.localized("视频", english: "Video")
        case .audio: AppLanguage.localized("音频", english: "Audio")
        case .archive: AppLanguage.localized("压缩包", english: "Archive")
        case .code: AppLanguage.localized("代码", english: "Code")
        case .other: AppLanguage.localized("其他", english: "Other")
        }
    }
}

extension FileSortOrder {
    var localizedTitle: String {
        switch self {
        case .relevance: AppLanguage.localized("相关度", english: "Relevance")
        case .name: AppLanguage.localized("名称", english: "Name")
        case .modifiedAt: AppLanguage.localized("修改时间", english: "Date Modified")
        case .createdAt: AppLanguage.localized("创建时间", english: "Date Created")
        case .size: AppLanguage.localized("大小", english: "Size")
        case .kind: AppLanguage.localized("类型", english: "Kind")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: AppLanguage.localized("跟随系统", english: "System Default")
        case .light: AppLanguage.localized("浅色", english: "Light")
        case .dark: AppLanguage.localized("深色", english: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
@MainActor
struct XunJianApp: App {
    @NSApplicationDelegateAdaptor(XunJianAppDelegate.self)
    private var appDelegate
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    // Menu bar quick search is an `NSStatusItem` owned by the app delegate
    // rather than a `MenuBarExtra` scene, which hangs the XCTest runner.
    //
    // Settings are a page inside the main window (NavigationDestination
    // `.settings`), not a separate Settings scene: a second window doubled
    // environment wiring and split the user's attention.
    var body: some Scene {
        mainWindow
    }

    private var mainWindow: some Scene {
        Window(AppLanguage.localized("寻简", english: "XunJian"), id: "main") {
            AppShellView()
                .environmentObject(appModel)
                .environmentObject(appModel.oauth)
                .environmentObject(appModel.ai)
                .environmentObject(appModel.index.categoryIndexStore)
                .preferredColorScheme(
                    AppAppearance(rawValue: appearance)?.colorScheme
                )
                .environment(
                    \.locale,
                    AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
                )
                .frame(minWidth: 360, minHeight: 600)
                .task { appDelegate.attachMenuBarSearch(appModel: appModel) }
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    switch newPhase {
                    case .active:
                        appModel.applicationBecameActive()
                    case .inactive, .background:
                        appModel.applicationResignedActive()
                    @unknown default:
                        appModel.applicationResignedActive()
                    }
                }
        }
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            // `XunJianCommands` supplies its own `.newItem` group; replacing it
            // here as well would drop those items.
            XunJianCommands(appModel: appModel, undo: appModel.undo)
            CommandGroup(replacing: .appSettings) {
                Button(AppLanguage.localized("设置…", english: "Settings…")) {
                    NotificationCenter.default.post(
                        name: .xunJianOpenSettings,
                        object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
