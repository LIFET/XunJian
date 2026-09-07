import AppKit
import SwiftUI

struct AIProviderSettingsDraft: Equatable {
    let baseURL: String
    let model: String
    let apiKey: String
}

@MainActor
final class AIProviderSettingsDraftStore: ObservableObject {
    private var drafts: [AIProviderKind: AIProviderSettingsDraft] = [:]

    func draft(for kind: AIProviderKind) -> AIProviderSettingsDraft? {
        drafts[kind]
    }

    func save(_ draft: AIProviderSettingsDraft, for kind: AIProviderKind) {
        drafts[kind] = draft
    }

    func clear(for kind: AIProviderKind) {
        drafts.removeValue(forKey: kind)
    }
}

struct OAuthLoginActionPresentation: Equatable {
    let showsPrimaryLogin: Bool
    let showsDeviceCodeFallback: Bool
    let showsCopyCode: Bool
    let showsBrowserWaitingMessage: Bool

    static func make(
        state: AIOAuthState,
        hasDeviceCodePresentation: Bool,
        fallbackAvailable: Bool,
        browserLaunchMode: OAuthBrowserLaunchMode?
    ) -> Self {
        let isDisconnected = state == .disconnected
        let isFailed: Bool
        if case .failed = state {
            isFailed = true
        } else {
            isFailed = false
        }
        let isAuthenticating: Bool
        if case .authenticating = state {
            isAuthenticating = true
        } else {
            isAuthenticating = false
        }
        return Self(
            showsPrimaryLogin: isDisconnected || isFailed,
            showsDeviceCodeFallback: fallbackAvailable && !hasDeviceCodePresentation,
            showsCopyCode: hasDeviceCodePresentation,
            showsBrowserWaitingMessage: isAuthenticating
                && browserLaunchMode == .providerRuntime
                && !hasDeviceCodePresentation
        )
    }
}

struct AIProviderSettingsRow: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var oauth: OAuthCoordinator
    @EnvironmentObject private var ai: AISessionCoordinator
    @EnvironmentObject private var draftStore: AIProviderSettingsDraftStore
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: AIProviderKind
    var isDetail = false

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
    @State private var showsAPIKeyConfiguration = false

    var body: some View {
        let _ = locale.identifier
        Group {
            if isDetail {
                VStack(alignment: .leading, spacing: 16) {
                    providerHeading
                    providerConfiguration
                }
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    providerConfiguration.padding(.top, 10)
                } label: {
                    providerHeading
                }
                .disclosureGroupStyle(FullRowDisclosureGroupStyle())
            }
        }
        .onAppear(perform: restoreDraftOrSynchronizeFields)
        .onAppear {
            guard !didApplyInitialExpansion else { return }
            didApplyInitialExpansion = true
            isExpanded = ai.activeProviderKind == kind
                || (ai.activeProviderKind == nil && kind == .codex)
                || draftStore.draft(for: kind) != nil
            showsAPIKeyConfiguration = draftStore.draft(for: kind) != nil
                || (ai.activeProviderKind == kind && ai.activeAuthenticationMode == .apiKey)
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
        .task(id: canLoadOAuthModels) {
            guard canLoadOAuthModels else { return }
            await oauth.refreshModels(for: kind)
        }
        .onDisappear(perform: preserveDraftIfNeeded)
    }

    private var providerHeading: some View {
        HStack(spacing: 8) {
            Text(verbatim: providerTitle).font(.headline).layoutPriority(1)
            Spacer()
            if ai.activeProviderKind == kind {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
            if isDetail || !isExpanded {
                Label(providerStatusTitle, systemImage: providerStatusPresentation.tone.symbolName)
                    .font(.caption).foregroundStyle(providerStatusColor).lineLimit(1)
                    .help(providerStatusTitle)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var providerConfiguration: some View {
        VStack(alignment: .leading, spacing: 16) {
            if supportsOAuth {
                Picker(AppLanguage.localized("配置方式", english: "Configuration Method"), selection: $showsAPIKeyConfiguration) {
                    Text(AppLanguage.localized("官方账号", english: "Official Account")).tag(false)
                    Text("API Key").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .help(AppLanguage.localized("切换配置面板；验证后才可设为当前 AI。", english: "Switch configuration panels. Verify before using as the current AI."))
                if showsAPIKeyConfiguration { apiKeyConfiguration }
                else { oauthAccountSection }
            } else { apiKeyConfiguration }
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
            "会向 \(providerTitle) 发送一条测试消息，可能消耗模型额度。不会调用工具，也不会发送文件名、路径或正文。测试结束后会关闭并清理这次会话。",
            english: "A test message will be sent to \(providerTitle) and may use your model allowance. No tools are called, and no file names, paths or contents are sent. The test session is closed and cleaned up afterward."
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
            "只退出寻简中的 \(providerTitle) 账号，不影响其他应用。下次使用这个账号时需要重新登录。",
            english: "This signs out of \(providerTitle) in XunJian only, not in other apps. You'll need to sign in again to use this account."
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

                if canLoadOAuthModels {
                    oauthModelSelection
                }

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
    private var oauthModelSelection: some View {
        switch oauth.modelLoadStates[kind] ?? .idle {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    verbatim: AppLanguage.localized(
                        "正在加载可用模型…",
                        english: "Loading available models…"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        case .loaded:
            responsiveField(AppLanguage.localized("OAuth 模型", english: "OAuth Model")) {
                Picker(
                    AppLanguage.localized("OAuth 模型", english: "OAuth Model"),
                    selection: Binding(
                        get: { oauth.selectedModel(for: kind) },
                        set: { oauth.selectModel($0, for: kind) }
                    )
                ) {
                    ForEach(oauth.models[kind] ?? []) { model in
                        Text(verbatim: model.id).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppLanguage.localized("重新加载模型", english: "Reload Models")) {
                    Task {
                        await oauth.refreshModels(
                            for: kind,
                            force: true,
                            presentsFailure: true
                        )
                    }
                }
                .buttonStyle(.bordered)
            }
        }
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

            case .statusUnknown:
                Button(
                    AppLanguage.localized(
                        "重新检测",
                        english: "Check Again"
                    )
                ) {
                    Task { await appModel.refreshOAuthStatus(for: kind, presentsFailure: true) }
                }

            case .failed:
                if oauthLoginActionPresentation.showsPrimaryLogin {
                    Button(loginButtonTitle) {
                        startOAuthLogin()
                    }
                }
                if oauthLoginActionPresentation.showsDeviceCodeFallback {
                    deviceCodeFallbackButton
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
                if oauthLoginActionPresentation.showsPrimaryLogin {
                    Button(loginButtonTitle) {
                        startOAuthLogin()
                    }
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
                if oauthLoginActionPresentation.showsCopyCode,
                   let deviceCode = currentDeviceCodePresentation {
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
                } else if oauthLoginActionPresentation.showsBrowserWaitingMessage {
                    Label(
                        AppLanguage.localized(
                            "已在浏览器打开授权页，请完成授权",
                            english: "The authorization page is open in your browser. Complete sign-in there."
                        ),
                        systemImage: "safari"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                draftStore.clear(for: kind)
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
        .disabled(
            isActiveOAuth
                || currentOAuthState != .connected
                || !oauth.modelCatalogIsReady(for: kind)
        )
    }

    private var logoutOAuthButton: some View {
        Button(
            AppLanguage.localized("退出账号…", english: "Sign Out…"),
            role: .destructive
        ) {
            showsOAuthLogoutConfirmation = true
        }
        .disabled(isOAuthVerificationInFlight)
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

    private var deviceCodeFallbackButton: some View {
        Button(
            AppLanguage.localized(
                "改用设备码登录",
                english: "Use Device Code Instead"
            )
        ) {
            Task {
                _ = await appModel.switchToOAuthDeviceCodeLogin(for: kind)
            }
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

    private var currentOAuthLoginPresentation: AIOAuthLoginPresentation? {
        guard case let .authenticating(attemptID, _) = currentOAuthState,
              let presentation = oauth.loginPresentations[kind],
              presentation.attemptID == attemptID else {
            return nil
        }
        return presentation
    }

    private var oauthLoginActionPresentation: OAuthLoginActionPresentation {
        OAuthLoginActionPresentation.make(
            state: currentOAuthState,
            hasDeviceCodePresentation: currentDeviceCodePresentation != nil,
            fallbackAvailable: oauth.deviceCodeFallbacks.contains(kind),
            browserLaunchMode: currentOAuthLoginPresentation?.browserLaunchMode
        )
    }

    private var isOAuthVerificationInFlight: Bool {
        oauth.verificationsInFlight.contains(kind)
    }

    private var supportsOAuth: Bool {
        kind == .codex || kind == .grok
    }

    private var canLoadOAuthModels: Bool {
        switch currentOAuthState {
        case .signedInDisconnected, .signedInUnverified, .connected:
            true
        case .unavailable, .statusUnknown, .starting, .disconnected,
             .authenticating, .failed:
            false
        }
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

    private var apiKeyConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                TextField(AppLanguage.localized("模型名称", english: "Model name"), text: $model)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            if hasUnsavedConfigurationChanges {
                Label(AppLanguage.localized("配置已修改，请先保存后重新测试连接。", english: "Configuration changed. Save it before testing again."), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.warning)
            }
            responsiveField(AppLanguage.localized("API 密钥", english: "API Key")) {
                SecureField(AppLanguage.localized(settings.hasAPIKey ? "已保存在本机；留空则保持不变" : "输入 API Key",
                                                   english: settings.hasAPIKey ? "Saved on this Mac; leave blank to keep it" : "Enter API Key"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            ViewThatFits(in: .horizontal) {
                HStack { apiKeyActionItems }
                VStack(alignment: .leading, spacing: 8) { apiKeyActionItems }
            }
            if case let .failed(message) = connectionState {
                ErrorMessageRow(message: message)
            }
            if showsSavedConfirmation {
                Label(AppLanguage.localized("已保存", english: "Saved"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.success)
                    .transition(.opacity)
            }
        }
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

    private func restoreDraftOrSynchronizeFields() {
        guard let draft = draftStore.draft(for: kind) else {
            synchronizeFields()
            return
        }
        baseURL = draft.baseURL
        model = draft.model
        apiKey = draft.apiKey
    }

    private func preserveDraftIfNeeded() {
        let hasTypedAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUnsavedConfigurationChanges || hasTypedAPIKey else {
            draftStore.clear(for: kind)
            return
        }
        draftStore.save(
            AIProviderSettingsDraft(baseURL: baseURL, model: model, apiKey: apiKey),
            for: kind
        )
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
