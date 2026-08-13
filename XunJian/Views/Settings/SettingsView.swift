import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.simplifiedChinese.rawValue
    @AppStorage(MenuBarSearchPreference.storageKey) private var showsMenuBarSearch = true
    // Bound to the same keys the file list writes, so changing a default here
    // takes effect immediately rather than only for new windows.
    @AppStorage("allFiles.sortOrder") private var defaultSortOrder = FileSortOrder.modifiedAt
    @AppStorage("allFiles.sortAscending") private var defaultSortAscending = false
    @AppStorage("allFiles.viewMode") private var defaultViewMode = FileBrowseViewMode.list
    @AppStorage(FileActivationBehavior.storageKey)
    private var doubleClickBehavior = FileActivationBehavior.open
    @State private var sourcePendingRemoval: FileSource?
    /// Highlighted while a folder is dragged over the authorisation area (F06).
    @State private var droppedFolderTargeted = false

    var body: some View {
        Form {
            Section("通用") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(verbatim: option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id(language)
                Picker("界面语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(verbatim: option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    AppLanguage.localized(
                        "扫描完成后发送通知",
                        english: "Notify when a scan finishes"
                    ),
                    isOn: Binding(
                        get: {
                            UserDefaults.standard.bool(
                                forKey: "notifications.scanComplete"
                            )
                        },
                        set: { enabled in
                            UserDefaults.standard.set(
                                enabled,
                                forKey: "notifications.scanComplete"
                            )
                            if enabled {
                                UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                            }
                        }
                    )
                )
                .toggleStyle(.switch)

                Toggle(
                    AppLanguage.localized(
                        "在菜单栏显示快速搜索",
                        english: "Show quick search in the menu bar"
                    ),
                    isOn: $showsMenuBarSearch
                )
                .toggleStyle(.switch)
            }

            Section("浏览") {
                Picker(
                    AppLanguage.localized("默认排序", english: "Default Sort"),
                    selection: $defaultSortOrder
                ) {
                    ForEach(FileSortOrder.allCases.filter { $0 != .relevance }) { order in
                        Text(verbatim: order.localizedTitle).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .id(language)

                Picker(
                    AppLanguage.localized("默认顺序", english: "Default Order"),
                    selection: $defaultSortAscending
                ) {
                    Text(verbatim: AppLanguage.localized("升序", english: "Ascending")).tag(true)
                    Text(verbatim: AppLanguage.localized("降序", english: "Descending")).tag(false)
                }
                .pickerStyle(.menu)
                .id(language)

                Picker(
                    AppLanguage.localized("默认显示方式", english: "Default View"),
                    selection: $defaultViewMode
                ) {
                    ForEach(FileBrowseViewMode.allCases) { mode in
                        Text(verbatim: mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .id(language)

                Picker(
                    AppLanguage.localized("双击文件时", english: "Double-clicking a file"),
                    selection: $doubleClickBehavior
                ) {
                    ForEach(FileActivationBehavior.allCases) { behavior in
                        Text(verbatim: behavior.localizedTitle).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
                .id(language)
            }

            Section("文件位置") {
                Toggle(
                    AppLanguage.localized(
                        "显示以点号开头的隐藏文件",
                        english: "Show dot-prefixed hidden files"
                    ),
                    isOn: Binding(
                        get: { appModel.includesHiddenFiles },
                        set: { appModel.setIncludesHiddenFiles($0) }
                    )
                )
                .disabled(appModel.isScanning || !appModel.isDatabaseAvailable)

                Text(
                    verbatim: AppLanguage.localized(
                        "默认不索引 .DS_Store 等以“.”开头的文件和文件夹；修改后会重新扫描。",
                        english: "By default, files and folders beginning with “.”, such as .DS_Store, are not indexed. Changing this setting rescans your folders."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        LabeledContent("已授权目录", value: "\(appModel.sources.count)")
                        Button("添加文件夹") {
                            appModel.chooseFolder()
                        }
                        .disabled(!appModel.isDatabaseAvailable)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("已授权目录", value: "\(appModel.sources.count)")
                        Button("添加文件夹") {
                            appModel.chooseFolder()
                        }
                        .disabled(!appModel.isDatabaseAvailable)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    // Drop a folder here to authorise it (F06).
                    for url in urls {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(
                            atPath: url.path,
                            isDirectory: &isDirectory
                        ), isDirectory.boolValue else { continue }
                        appModel.addFolderDropped(url: url)
                    }
                    return true
                } isTargeted: { isTargeted in
                    droppedFolderTargeted = isTargeted
                }
                .padding(4)
                .background(
                    droppedFolderTargeted
                        ? XunJianUI.Fill.selectedSoft
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: XunJianUI.Radius.control, style: .continuous)
                )

                ForEach(appModel.sources) { source in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            sourceIdentity(source)
                                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                            sourcePrimaryAction(source)
                            // N06: pause a slow folder without removing its
                            // index; enable again to rescan it.
                            Toggle(
                                AppLanguage.localized(
                                    source.enabled ? "索引中" : "已暂停",
                                    english: source.enabled ? "Indexing" : "Paused"
                                ),
                                isOn: Binding(
                                    get: { source.enabled },
                                    set: { appModel.setSourceEnabled(source, enabled: $0) }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appModel.isDatabaseAvailable)
                            Button("移除…", role: .destructive) {
                                sourcePendingRemoval = source
                            }
                            .disabled(!appModel.isDatabaseAvailable)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            sourceIdentity(source)
                            HStack(spacing: 8) {
                                sourcePrimaryAction(source)
                                Menu {
                                    Button("移除…", role: .destructive) {
                                        sourcePendingRemoval = source
                                    }
                                } label: {
                                    Label("更多", systemImage: "ellipsis.circle")
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(!appModel.isDatabaseAvailable)
                            }
                        }
                    }
                }

                if !appModel.sources.isEmpty {
                    Button("重新扫描全部位置") {
                        appModel.refreshAllSources()
                    }
                    .disabled(appModel.isScanning)
                    .disabled(!appModel.isDatabaseAvailable)
                }
            }

            Section {
                LabeledContent(
                    "当前 AI",
                    value: activeProviderSummary
                )

                ForEach(AIProviderKind.allCases) { kind in
                    AIProviderSettingsRow(kind: kind)
                }
            } header: {
                Text("AI 服务")
            } footer: {
                Text(
                    verbatim: AppLanguage.localized(
                        "凭据只保存在当前用户的寻简本地数据目录，不会写入 App 包或随 App 分享。普通搜索始终在本地完成。",
                        english: "Credentials stay in XunJian's local data folder for the current user and are never included in the app bundle or shared with it. Regular search always stays on your Mac."
                    )
                )
            }

            Section("关于") {
                LabeledContent(
                    "应用",
                    value: AppLanguage.localized("寻简", english: "XunJian")
                )
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppLanguage.localized("设置", english: "Settings"))
        .confirmationDialog(
            "移除文件夹授权？",
            isPresented: Binding(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourcePendingRemoval
        ) { source in
            Button(
                AppLanguage.localized(
                    "移除“\(source.displayName)”",
                    english: "Remove “\(source.displayName)”"
                ),
                role: .destructive
            ) {
                appModel.removeSource(source)
                sourcePendingRemoval = nil
            }
            Button("取消", role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { _ in
            Text("只会移除寻简保存的授权与本地索引，不会删除原文件夹或其中的文件。")
        }
    }

    @ViewBuilder
    private func sourceIdentity(_ source: FileSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.accessState == .available ? "folder" : "folder.badge.exclamationmark")
                .foregroundStyle(
                    Color(
                        nsColor: source.accessState == .available
                            ? .secondaryLabelColor
                            : .systemOrange
                    )
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: source.displayName)
                    .lineLimit(1)
                Text(verbatim: source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sourcePrimaryAction(_ source: FileSource) -> some View {
        if source.accessState == .available {
            Button("重新扫描") {
                appModel.scanSource(source)
            }
            .disabled(appModel.isScanning)
            .disabled(!appModel.isDatabaseAvailable)
        } else {
            Button("重新授权") {
                appModel.reauthorizeSource(source)
            }
            .disabled(!appModel.isDatabaseAvailable)
        }
    }

    private func providerTitle(_ kind: AIProviderKind) -> String {
        guard kind == .qwen else { return kind.title }
        return AppLanguage.localized("Qwen / 千问", english: "Qwen")
    }

    private var activeProviderSummary: String {
        guard let kind = appModel.activeAIProviderKind,
              let mode = appModel.activeAIAuthenticationMode else {
            return AppLanguage.localized("未配置", english: "Not Configured")
        }
        let modeTitle = switch mode {
        case .apiKey: "API Key"
        case .oauth: "OAuth"
        }
        return "\(providerTitle(kind)) · \(modeTitle)"
    }
}

private struct AIProviderSettingsRow: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL

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

                responsiveField("Base URL") {
                    TextField("https://…", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                responsiveField("Model") {
                    TextField("模型名称", text: $model)
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

                responsiveField("API Key") {
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
                    Text(verbatim: AppLanguage.localizedRuntimeMessage(message))
                        .font(.caption)
                        .foregroundStyle(XunJianUI.Semantic.danger)
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
            .padding(.top, 8)
        } label: {
            HStack {
                Text(verbatim: providerTitle)
                Spacer()
                if appModel.activeAIProviderKind == kind {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                if !isExpanded {
                    Text(verbatim: providerStatusTitle)
                        .foregroundStyle(providerStatusColor)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(providerAccessibilityLabel)
        }
        .onAppear(perform: synchronizeFields)
        .onAppear {
            guard !didApplyInitialExpansion else { return }
            didApplyInitialExpansion = true
            isExpanded = appModel.activeAIProviderKind == kind
        }
        .onChange(of: appModel.aiProviderSettings) { _, _ in
            synchronizeFields()
        }
        .onChange(of: activeExpansionID) { _, newValue in
            guard let newValue else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded = newValue == kind
            }
        }
        .onChange(of: currentOAuthState) { oldValue, newValue in
            guard oldValue != newValue else { return }
            announceAccessibility("\(providerTitle)：\(newValue.localizedTitle)")
        }
        .confirmationDialog(
            AppLanguage.localized(
                "移除 \(providerTitle) 的 API Key？",
                english: "Remove \(providerTitle) API Key?"
            ),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除 API Key", role: .destructive) {
                appModel.deleteAIKey(for: kind)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                verbatim: AppLanguage.localized(
                    "密钥会从寻简的本地凭据文件中删除；Base URL 和模型名称会保留。",
                    english: "The key will be removed from XunJian's local credential file; the Base URL and model name will be kept."
                )
            )
        }
        .confirmationDialog(
            AppLanguage.localized(
                "验证 \(providerTitle) 连接？",
                english: "Verify \(providerTitle) Connection?"
            ),
            isPresented: $showsOAuthVerificationConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                AppLanguage.localized(
                    "验证连接",
                    english: "Verify Connection"
                )
            ) {
                Task { await appModel.verifyOAuthConnection(for: kind) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                verbatim: AppLanguage.localized(
                    "将向 \(providerTitle) 发送固定且禁用工具的最小提示，可能计入模型用量。不会发送文件名、路径或文件内容；完成后会立即关闭并清理本次验证会话。",
                    english: "XunJian will send \(providerTitle) a fixed minimal prompt with tools disabled, which may count toward model usage. No file names, paths, or file contents are sent. The verification session is closed and cleaned up immediately afterward."
                )
            )
        }
        .confirmationDialog(
            AppLanguage.localized(
                "退出 \(providerTitle) 账号？",
                english: "Sign Out of \(providerTitle)?"
            ),
            isPresented: $showsOAuthLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                AppLanguage.localized("退出账号", english: "Sign Out"),
                role: .destructive
            ) {
                Task { await appModel.logoutOAuthProvider(for: kind) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                verbatim: AppLanguage.localized(
                    "只会清除寻简专属的 \(providerTitle) 登录，不会影响其他应用中的账号。之后如需使用 OAuth，必须重新登录。",
                    english: "This clears only XunJian's private \(providerTitle) sign-in and does not affect accounts in other apps. You must sign in again to use OAuth."
                )
            )
        }
    }

    private var settings: AIProviderSettings {
        appModel.aiSettings(for: kind)
    }

    @ViewBuilder
    private var oauthAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Label {
                        Text(
                            verbatim: AppLanguage.localized(
                                "官方账号",
                                english: "Official Account"
                            )
                        )
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    oauthStatusBadge
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(
                            verbatim: AppLanguage.localized(
                                "官方账号",
                                english: "Official Account"
                            )
                        )
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    oauthStatusBadge
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            XunJianUI.Fill.quiet,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
                .strokeBorder(XunJianUI.Fill.stroke, lineWidth: 1)
        }
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
            Button("保存") {
                guard appModel.saveAIProvider(
                    kind,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                ) else { return }
                apiKey = ""
                withAnimation { showsSavedConfirmation = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation { showsSavedConfirmation = false }
                }
            }
            if connectionState == .testing {
                Button(
                    AppLanguage.localized("停止测试", english: "Stop Test"),
                    role: .cancel
                ) { appModel.cancelAIProviderTest(kind) }
            } else {
                Button("测试连接") { appModel.testAIProvider(kind) }
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
                Button("移除 API Key…", role: .destructive) {
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
        appModel.aiOAuthStates[kind] ?? .statusUnknown
    }

    private var currentDeviceCodePresentation: AIOAuthDeviceCodePresentation? {
        guard kind == .codex,
              case let .authenticating(attemptID, authorizationURL) = currentOAuthState,
              let presentation = appModel.aiOAuthDeviceCodePresentations[kind],
              presentation.attemptID == attemptID,
              presentation.verificationURL == authorizationURL else {
            return nil
        }
        return presentation
    }

    private var isOAuthVerificationInFlight: Bool {
        appModel.aiOAuthVerificationsInFlight.contains(kind)
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
                  case let .authenticating(_, currentURL) = appModel.aiOAuthStates[kind],
                  currentURL == authorizationURL,
                  appModel.aiOAuthDeviceCodePresentations[kind] == nil else { return }
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
        appModel.aiConnectionState(for: kind)
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
        appModel.activeAIProviderKind == kind
            && appModel.activeAIAuthenticationMode == .apiKey
    }

    private var isActiveOAuth: Bool {
        appModel.activeAIProviderKind == kind
            && appModel.activeAIAuthenticationMode == .oauth
    }

    private var activeExpansionID: AIProviderKind? {
        appModel.activeAIAuthenticationMode == nil ? nil : appModel.activeAIProviderKind
    }

    private var activeModeTitle: String {
        guard appModel.activeAIProviderKind == kind else { return "" }
        return appModel.activeAIAuthenticationMode == .oauth ? "OAuth" : "API Key"
    }

    private var providerStatusPresentation: AIProviderCollapsedStatusPresentation {
        AIProviderCollapsedStatusPresentation.make(
            supportsOAuth: supportsOAuth,
            isCurrentProvider: appModel.activeAIProviderKind == kind,
            activeMode: appModel.activeAIAuthenticationMode,
            hasAPIKey: settings.hasAPIKey,
            apiKeyState: connectionState,
            hasCredentialError: appModel.aiCredentialError(for: kind) != nil,
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

    private var providerAccessibilityLabel: String {
        let current = appModel.activeAIProviderKind == kind
            ? AppLanguage.localized("当前 AI，", english: "Current AI, ") + activeModeTitle + "，"
            : ""
        return "\(providerTitle)，\(current)\(providerStatusTitle)"
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
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .frame(minWidth: 72, alignment: .leading)
                content()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                content()
            }
        }
    }
}

struct AIProviderCollapsedStatusPresentation: Equatable {
    enum Tone: Equatable {
        case secondary
        case green
        case orange
        case red

        var color: Color {
            switch self {
            case .secondary: XunJianUI.Semantic.neutral
            case .green: XunJianUI.Semantic.success
            case .orange: XunJianUI.Semantic.warning
            case .red: XunJianUI.Semantic.danger
            }
        }
    }

    let title: String
    let tone: Tone

    static func make(
        supportsOAuth: Bool,
        isCurrentProvider: Bool,
        activeMode: AIAuthenticationMode?,
        hasAPIKey: Bool,
        apiKeyState: AIConnectionState,
        hasCredentialError: Bool,
        hasUnsavedConfigurationChanges: Bool,
        oauthState: AIOAuthState
    ) -> Self {
        let apiKey = apiKeyPresentation(
            hasAPIKey: hasAPIKey,
            state: apiKeyState,
            hasCredentialError: hasCredentialError,
            hasUnsavedConfigurationChanges: hasUnsavedConfigurationChanges
        )
        guard supportsOAuth else { return apiKey }

        let oauth = Self(
            title: AppLanguage.localized(
                "OAuth：\(oauthState.localizedTitle)",
                english: "OAuth: \(oauthState.localizedTitle)"
            ),
            tone: oauthTone(for: oauthState)
        )
        if isCurrentProvider {
            switch activeMode {
            case .apiKey:
                return apiKey
            case .oauth:
                return oauth
            case nil:
                break
            }
        }

        return Self(
            title: "\(oauth.title) · \(apiKey.title)",
            tone: hasCredentialError
                ? .red
                : hasUnsavedConfigurationChanges ? .orange : .secondary
        )
    }

    private static func apiKeyPresentation(
        hasAPIKey: Bool,
        state: AIConnectionState,
        hasCredentialError: Bool,
        hasUnsavedConfigurationChanges: Bool
    ) -> Self {
        if hasCredentialError {
            return Self(
                title: AppLanguage.localized(
                    "API Key：文件不可用",
                    english: "API Key: File Unavailable"
                ),
                tone: .red
            )
        }
        if hasUnsavedConfigurationChanges {
            return Self(
                title: AppLanguage.localized(
                    "API Key：配置已修改，需保存后重测",
                    english: "API Key: Changed; Save and Retest"
                ),
                tone: .orange
            )
        }
        guard hasAPIKey else {
            return Self(
                title: AppLanguage.localized(
                    "API Key：未保存",
                    english: "API Key: Not Saved"
                ),
                tone: .secondary
            )
        }

        switch state {
        case .notConfigured:
            return Self(
                title: AppLanguage.localized(
                    "API Key：未保存",
                    english: "API Key: Not Saved"
                ),
                tone: .secondary
            )
        case .saved:
            return Self(
                title: AppLanguage.localized(
                    "API Key：已保存，需验证",
                    english: "API Key: Saved; Verification Required"
                ),
                tone: .orange
            )
        case .testing:
            return Self(
                title: AppLanguage.localized(
                    "API Key：正在验证",
                    english: "API Key: Verifying"
                ),
                tone: .orange
            )
        case .verified:
            return Self(
                title: AppLanguage.localized(
                    "API Key：已验证",
                    english: "API Key: Verified"
                ),
                tone: .green
            )
        case .failed:
            return Self(
                title: AppLanguage.localized(
                    "API Key：验证失败",
                    english: "API Key: Verification Failed"
                ),
                tone: .red
            )
        }
    }

    private static func oauthTone(for state: AIOAuthState) -> Tone {
        switch state {
        case .connected:
            .green
        case .starting, .authenticating, .signedInDisconnected, .signedInUnverified:
            .orange
        case .unavailable, .failed:
            .red
        case .statusUnknown, .disconnected:
            .secondary
        }
    }
}
