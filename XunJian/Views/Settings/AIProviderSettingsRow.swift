import AppKit
import SwiftUI

struct AIProviderSettingsRow: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var oauth: OAuthCoordinator
    @EnvironmentObject private var ai: AISessionCoordinator
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: AIProviderKind

    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var showsDeleteConfirmation = false
    @State private var showsOAuthVerificationConfirmation = false
    @State private var showsOAuthLogoutConfirmation = false
    @State private var copiedDeviceCodeAttemptID: UUID?
    @State private var isExpanded = false
    @State private var didApplyInitialExpansion = false
    @State private var showsSavedConfirmation = false

    var body: some View {
        let _ = locale.identifier
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if supportsOAuth {
                    oauthAccountSection

                    Divider()

                    Text(
                        verbatim: AppLanguage.localized(
                            "API Key 回退",
                            english: "API Key Fallback"
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                }

                Text(verbatim: kind.localizedConnectionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                responsiveField(AppLanguage.localized("接口地址", english: "Base URL")) {
                    TextField("https://…", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                responsiveField(AppLanguage.localized("模型", english: "Model")) {
                    TextField(
                        AppLanguage.localized("模型名称", english: "Model name"),
                        text: $model
                    )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                if hasUnsavedConfigurationChanges {
                    Label(
                        AppLanguage.localized(
                            "配置已修改，请先保存后重新测试连接。",
                            english: "Configuration changed. Save it before testing again."
                        ),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.warning)
                }

                responsiveField(AppLanguage.localized("API 密钥", english: "API Key")) {
                    SecureField(
                        AppLanguage.localized(
                            settings.hasAPIKey ? "已保存在本机；留空则保持不变" : "输入 API Key",
                            english: settings.hasAPIKey
                                ? "Saved on this Mac; leave blank to keep it"
                                : "Enter API Key"
                        ),
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                ViewThatFits(in: .horizontal) {
                    HStack { apiKeyActionItems }
                    VStack(alignment: .leading, spacing: 8) {
                        apiKeyActionItems
                    }
                }

                if case let .failed(message) = connectionState {
                    ErrorMessageRow(message: message)
                }
                if showsSavedConfirmation {
                    Label(
                        AppLanguage.localized("已保存", english: "Saved"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.success)
                    .transition(.opacity)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: providerTitle)
                    .font(XunJianUI.Typography.itemTitle)
                    .layoutPriority(1)
                Spacer()
                if ai.activeProviderKind == kind {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                if !isExpanded {
                    Label {
                        Text(verbatim: providerStatusTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: providerStatusPresentation.tone.symbolName)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(providerStatusColor)
                    .font(XunJianUI.Typography.status)
                    .help(providerStatusTitle)
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .onAppear(perform: synchronizeFields)
        .onAppear {
            guard !didApplyInitialExpansion else { return }
            didApplyInitialExpansion = true
            isExpanded = ai.activeProviderKind == kind
                || (ai.activeProviderKind == nil && kind == .codex)
        }
        .onChange(of: ai.providerSettings) { _, _ in
            guard !hasUnsavedConfigurationChanges else { return }
            synchronizeFields()
        }
        .onChange(of: activeExpansionID) { _, newValue in
            guard let newValue else { return }
            withAnimation(XunJianUI.motion(.easeInOut(duration: 0.16), reduceMotion: reduceMotion)) {
                isExpanded = newValue == kind
            }
        }
        .onChange(of: currentOAuthState) { oldValue, newValue in
            guard oldValue != newValue else { return }
            announceAccessibility("\(providerTitle)：\(newValue.localizedTitle)")
        }
        .background { providerConfirmationDialogs }
    }

    @ViewBuilder
    private var providerConfirmationDialogs: some View {
        Color.clear
            .confirmationDialog(
                deleteAPIKeyTitle,
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(deleteAPIKeyActionTitle, role: .destructive) {
                    appModel.deleteAIKey(for: kind)
                }
                Button(cancelTitle, role: .cancel) {}
            } message: {
                Text(verbatim: deleteAPIKeyMessage)
            }

        Color.clear
            .confirmationDialog(
                verifyOAuthTitle,
                isPresented: $showsOAuthVerificationConfirmation,
                titleVisibility: .visible
            ) {
                Button(verifyOAuthActionTitle) {
                    Task { await appModel.verifyOAuthConnection(for: kind) }
                }
                Button(cancelTitle, role: .cancel) {}
            } message: {
                Text(verbatim: verifyOAuthMessage)
            }

        Color.clear
            .confirmationDialog(
                signOutOAuthTitle,
                isPresented: $showsOAuthLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button(signOutOAuthActionTitle, role: .destructive) {
                    Task { await appModel.logoutOAuthProvider(for: kind) }
                }
                Button(cancelTitle, role: .cancel) {}
            } message: {
                Text(verbatim: signOutOAuthMessage)
            }
    }

    private var cancelTitle: String {
        AppLanguage.localized("取消", english: "Cancel")
    }

    private var deleteAPIKeyActionTitle: String {
        AppLanguage.localized("移除 API Key", english: "Remove API Key")
    }

    private var verifyOAuthActionTitle: String {
        AppLanguage.localized("验证连接", english: "Verify Connection")
    }

    private var signOutOAuthActionTitle: String {
        AppLanguage.localized("退出账号", english: "Sign Out")
    }

    private var deleteAPIKeyTitle: String {
        AppLanguage.localized(
            "移除 \(providerTitle) 的 API Key？",
            english: "Remove \(providerTitle) API Key?"
        )
    }

    private var deleteAPIKeyMessage: String {
        AppLanguage.localized(
            "密钥会从寻简的本地凭据文件中删除；Base URL 和模型名称会保留。",
            english: "The key will be removed from XunJian's local credential file; the Base URL and model name will be kept."
        )
    }

    private var verifyOAuthTitle: String {
        AppLanguage.localized(
            "验证 \(providerTitle) 连接？",
            english: "Verify \(providerTitle) Connection?"
        )
    }

    private var verifyOAuthMessage: String {
        AppLanguage.localized(
            "将向 \(providerTitle) 发送固定且禁用工具的最小提示，可能计入模型用量。不会发送文件名、路径或文件内容；完成后会立即关闭并清理本次验证会话。",
            english: "XunJian will send \(providerTitle) a fixed minimal prompt with tools disabled, which may count toward model usage. No file names, paths, or file contents are sent. The verification session is closed and cleaned up immediately afterward."
        )
    }

    private var signOutOAuthTitle: String {
        AppLanguage.localized(
            "退出 \(providerTitle) 账号？",
            english: "Sign Out of \(providerTitle)?"
        )
    }

    private var signOutOAuthMessage: String {
        AppLanguage.localized(
            "只会清除寻简专属的 \(providerTitle) 登录，不会影响其他应用中的账号。之后如需使用 OAuth，必须重新登录。",
            english: "This clears only XunJian's private \(providerTitle) sign-in and does not affect accounts in other apps. You must sign in again to use OAuth."
        )
    }

    private var settings: AIProviderSettings {
        ai.settings(for: kind)
    }

    @ViewBuilder
    private var oauthAccountSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        oauthStatusBadge
                        Spacer(minLength: 0)
                    }

                    oauthStatusBadge
                }

                Text(verbatim: currentOAuthState.localizedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isOAuthVerificationInFlight {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            verbatim: AppLanguage.localized(
                                "正在验证…",
                                english: "Verifying…"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                oauthActions
            }
            // GroupBox's content inset is intentionally compact on macOS.
            // Status dots and multi-line failure details otherwise sit on the
            // rounded border, especially when the label scrolls out of view.
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } label: {
            Label(
                AppLanguage.localized("官方账号", english: "Official Account"),
                systemImage: "person.crop.circle.badge.checkmark"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(currentOAuthState.statusColor)
                .frame(width: 7, height: 7)
            Text(verbatim: currentOAuthState.localizedTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(currentOAuthState.statusColor)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var oauthActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { oauthActionItems }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                oauthActionItems
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var oauthActionItems: some View {
            switch currentOAuthState {
            case .unavailable:
                Button(
                    AppLanguage.localized(
                        "重新检测",
                        english: "Check Again"
                    )
                ) {
                    Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
                }

            case .statusUnknown, .failed:
                Button(
                    AppLanguage.localized(
                        "重新检测",
                        english: "Check Again"
                    )
                ) {
                    Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
                }

            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text(
                    verbatim: AppLanguage.localized(
                        "正在启动…",
                        english: "Starting…"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(
                    AppLanguage.localized(
                        "取消登录",
                        english: "Cancel Sign-In"
                    ),
                    role: .cancel
                ) {
                    Task { await appModel.cancelOAuthLogin(for: kind) }
                }

            case .disconnected:
                Button(loginButtonTitle) {
                    startOAuthLogin()
                }
                if kind == .codex {
                    deviceCodeLoginButton
                }
                Button(
                    AppLanguage.localized(
                        "刷新状态",
                        english: "Refresh Status"
                    )
                ) {
                    Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
                }

            case let .authenticating(_, authorizationURL):
                if let deviceCode = currentDeviceCodePresentation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            verbatim: AppLanguage.localized(
                                "请在验证页面输入以下一次性设备码：",
                                english: "Enter this one-time device code on the verification page:"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { deviceCodeActions(deviceCode) }
                            VStack(alignment: .leading, spacing: 8) {
                                deviceCodeActions(deviceCode)
                            }
                        }
                    }
                } else if let authorizationURL {
                    Button(
                        AppLanguage.localized(
                            "在浏览器中继续",
                            english: "Continue in Browser"
                        )
                    ) {
                        openAuthorizationURL(authorizationURL)
                    }
                }
                Button(
                    AppLanguage.localized(
                        "取消登录",
                        english: "Cancel Sign-In"
                    ),
                    role: .cancel
                ) {
                    Task { await appModel.cancelOAuthLogin(for: kind) }
                }

            case .signedInDisconnected:
                Button(
                    AppLanguage.localized(
                        "检查连接",
                        english: "Check Connection"
                    )
                ) {
                    Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
                }
                logoutOAuthButton

            case .signedInUnverified:
                if !isOAuthVerificationInFlight {
                    Button(
                        AppLanguage.localized(
                            "先验证连接",
                            english: "Verify Before Use"
                        )
                    ) {
                        showsOAuthVerificationConfirmation = true
                    }
                }
                refreshOAuthButton
                logoutOAuthButton

            case .connected:
                oauthSetCurrentButton
                refreshOAuthButton
                logoutOAuthButton
            }
    }

    private var refreshOAuthButton: some View {
        Button(
            AppLanguage.localized(
                "刷新状态",
                english: "Refresh Status"
            )
        ) {
            Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
        }
        .disabled(isOAuthVerificationInFlight)
    }

    @ViewBuilder
    private var apiKeyActionItems: some View {
            Button(AppLanguage.localized("保存", english: "Save")) {
                guard appModel.saveAIProvider(
                    kind,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                ) else { return }
                apiKey = ""
                withAnimation(XunJianUI.motion(reduceMotion: reduceMotion)) { showsSavedConfirmation = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(XunJianUI.motion(reduceMotion: reduceMotion)) { showsSavedConfirmation = false }
                }
            }
            if connectionState == .testing {
                Button(
                    AppLanguage.localized("停止测试", english: "Stop Test"),
                    role: .cancel
                ) { appModel.cancelAIProviderTest(kind) }
            } else {
                Button(AppLanguage.localized("测试连接", english: "Test Connection")) {
                    appModel.testAIProvider(kind)
                }
                    .disabled(!settings.hasAPIKey || hasUnsavedConfigurationChanges)
            }
            Button(
                AppLanguage.localized(
                    isActiveAPIKey
                        ? "当前 AI（API Key）"
                        : canSetCurrentAPIKey
                            ? "设为当前 AI（API Key）"
                            : "验证后可设为当前 AI（API Key）",
                    english: isActiveAPIKey
                        ? "Current AI (API Key)"
                        : canSetCurrentAPIKey
                            ? "Use API Key as Current AI"
                            : "Verify Before Using API Key"
                )
            ) { appModel.setActiveAIProvider(kind) }
                .disabled(!canSetCurrentAPIKey || isActiveAPIKey)
            if settings.hasAPIKey {
                Button(
                    AppLanguage.localized("移除 API Key…", english: "Remove API Key…"),
                    role: .destructive
                ) {
                    showsDeleteConfirmation = true
                }
            }
    }

    private var oauthSetCurrentButton: some View {
        Button(
            AppLanguage.localized(
                isActiveOAuth ? "当前 AI（OAuth）" : "设为当前 AI（OAuth）",
                english: isActiveOAuth
                    ? "Current AI (OAuth)"
                    : "Use OAuth as Current AI"
            )
        ) {
            appModel.setActiveOAuthAIProvider(kind)
        }
        .disabled(isActiveOAuth || currentOAuthState != .connected)
    }

    private var logoutOAuthButton: some View {
        Button(
            AppLanguage.localized("退出账号…", english: "Sign Out…"),
            role: .destructive
        ) {
            showsOAuthLogoutConfirmation = true
        }
        .disabled(isOAuthVerificationInFlight)
    }

    private var deviceCodeLoginButton: some View {
        Button(
            AppLanguage.localized(
                "使用设备码登录",
                english: "Sign In with Device Code"
            )
        ) {
            startDeviceCodeLogin()
        }
    }

    private var currentOAuthState: AIOAuthState {
        oauth.states[kind] ?? .statusUnknown
    }

    private var currentDeviceCodePresentation: AIOAuthDeviceCodePresentation? {
        guard kind == .codex,
              case let .authenticating(attemptID, authorizationURL) = currentOAuthState,
              let presentation = oauth.deviceCodePresentations[kind],
              presentation.attemptID == attemptID,
              presentation.verificationURL == authorizationURL else {
            return nil
        }
        return presentation
    }

    private var isOAuthVerificationInFlight: Bool {
        oauth.verificationsInFlight.contains(kind)
    }

    private var supportsOAuth: Bool {
        kind == .codex || kind == .grok
    }

    private var loginButtonTitle: String {
        switch kind {
        case .codex:
            AppLanguage.localized(
                "使用 ChatGPT 登录",
                english: "Sign In with ChatGPT"
            )
        case .grok:
            AppLanguage.localized(
                "使用 Grok 账号登录",
                english: "Sign In with Grok"
            )
        case .deepSeek, .qwen:
            AppLanguage.localized("登录", english: "Sign In")
        }
    }

    private func openAuthorizationURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard kind == .codex,
              url.absoluteString.utf8.count <= 2_048,
              components?.scheme?.lowercased() == "https",
              ["auth.openai.com", "chatgpt.com"].contains(
                components?.host?.lowercased() ?? ""
              ),
              components?.port == nil || components?.port == 443,
              components?.user == nil,
              components?.password == nil,
              components?.fragment == nil else { return }
        openURL(url)
    }

    private func startOAuthLogin() {
        Task {
            let authorizationURL = await appModel.beginOAuthLogin(for: kind)
            guard kind == .codex,
                  let authorizationURL,
                  case let .authenticating(_, currentURL) = oauth.states[kind],
                  currentURL == authorizationURL,
                  oauth.deviceCodePresentations[kind] == nil else { return }
            openAuthorizationURL(authorizationURL)
        }
    }

    private func startDeviceCodeLogin() {
        Task {
            _ = await appModel.beginOAuthDeviceCodeLogin(for: kind)
        }
    }

    private func copyDeviceCode(_ presentation: AIOAuthDeviceCodePresentation) {
        guard currentDeviceCodePresentation == presentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(presentation.userCode, forType: .string) else { return }
        copiedDeviceCodeAttemptID = presentation.attemptID
    }

    private func openDeviceCodeVerification(
        _ presentation: AIOAuthDeviceCodePresentation
    ) {
        guard currentDeviceCodePresentation == presentation else { return }
        openAuthorizationURL(presentation.verificationURL)
    }

    @ViewBuilder
    private func deviceCodeActions(_ presentation: AIOAuthDeviceCodePresentation) -> some View {
        Text(verbatim: presentation.userCode)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .textSelection(.enabled)
        Button(
            copiedDeviceCodeAttemptID == presentation.attemptID
                ? AppLanguage.localized("已复制", english: "Copied")
                : AppLanguage.localized("复制设备码", english: "Copy Code")
        ) { copyDeviceCode(presentation) }
        Button(AppLanguage.localized("打开验证页面", english: "Open Verification Page")) {
            openDeviceCodeVerification(presentation)
        }
    }

    private var connectionState: AIConnectionState {
        ai.connectionState(for: kind)
    }

    private var hasUnsavedConfigurationChanges: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            != settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || model.trimmingCharacters(in: .whitespacesAndNewlines)
            != settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSetCurrentAPIKey: Bool {
        settings.hasAPIKey
            && connectionState == .verified
            && !hasUnsavedConfigurationChanges
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isActiveAPIKey: Bool {
        ai.activeProviderKind == kind
            && ai.activeAuthenticationMode == .apiKey
    }

    private var isActiveOAuth: Bool {
        ai.activeProviderKind == kind
            && ai.activeAuthenticationMode == .oauth
    }

    private var activeExpansionID: AIProviderKind? {
        ai.activeAuthenticationMode == nil ? nil : ai.activeProviderKind
    }

    private var providerStatusPresentation: AIProviderCollapsedStatusPresentation {
        AIProviderCollapsedStatusPresentation.make(
            supportsOAuth: supportsOAuth,
            isCurrentProvider: ai.activeProviderKind == kind,
            activeMode: ai.activeAuthenticationMode,
            hasAPIKey: settings.hasAPIKey,
            apiKeyState: connectionState,
            hasCredentialError: ai.credentialError(for: kind) != nil,
            hasUnsavedConfigurationChanges: hasUnsavedConfigurationChanges,
            oauthState: currentOAuthState
        )
    }

    private var providerStatusTitle: String {
        providerStatusPresentation.title
    }

    private var providerStatusColor: Color {
        providerStatusPresentation.tone.color
    }

    private func announceAccessibility(_ message: String) {
        guard let applicationElement = NSApp else { return }
        NSAccessibility.post(
            element: applicationElement,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private var providerTitle: String {
        guard kind == .qwen else { return kind.title }
        return AppLanguage.localized("Qwen / 千问", english: "Qwen")
    }

    private func synchronizeFields() {
        baseURL = settings.baseURL
        model = settings.model
    }

    private func responsiveField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: title)
                    .frame(minWidth: 72, alignment: .leading)
                content()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                content()
            }
        }
    }
}
