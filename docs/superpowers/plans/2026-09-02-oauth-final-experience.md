# 寻简 OAuth 最终体验 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Grok 默认直达带短码的官方授权页、Codex 默认使用 Browser OAuth + PKCE，并只在主流程失败时显示 Device Code 备用入口；授权完成后自动恢复连接和模型选择。

**Architecture:** 保留现有 App → XPC Bridge → 内置官方 Runtime 边界。协议只增加登录展示元数据；Grok 改用官方 `--device-auth` 并由固定 Runtime 管理系统浏览器，Codex 保持 App Server Browser OAuth。主 App 继续用 generation/attempt ID 隔离竞态，复用现有认证轮询与模型加载逻辑。

**Tech Stack:** Swift 6、SwiftUI、AppKit `OpenURLAction`、NSXPC、Codex App Server 0.147.0、Grok Runtime 1.0.0、XCTest、XcodeGen。

---

## 文件边界

- Modify: `XunJian/Infrastructure/OAuthBridgeProtocol.swift` — 登录展示协议与协议版本。
- Modify: `XunJianOAuthBridge/Core/SupervisedLineProcess.swift` — Grok 官方登录参数。
- Modify: `XunJianOAuthBridge/main.swift` — Provider 对应的登录展示元数据。
- Modify: `XunJian/App/AppModel.swift` — 主 App 登录展示值与现有转发方法。
- Modify: `XunJian/App/OAuthCoordinator.swift` — 展示校验、备用入口条件、成功后的模型收口。
- Modify: `XunJian/Views/Settings/AIProviderSettingsRow.swift` — 默认入口、等待状态和备用入口。
- Modify: `XunJianTests/OAuthBridgeTests.swift` — 协议、Coordinator、AppModel 与 UI 决策回归。
- Modify: `XunJianTests/OAuthProcessTests.swift` — Grok Runtime 参数门禁。
- Modify: `docs/HANDOFF.md`、`docs/PLANS.md` — 记录完成状态和真实验收边界。

不新增 Runtime、不更换依赖、不修改 API Key、AI 请求、索引、文件操作、发布或公证代码。

### Task 1: 给 OAuth 登录尝试增加明确展示语义

**Files:**
- Modify: `XunJian/Infrastructure/OAuthBridgeProtocol.swift`
- Test: `XunJianTests/OAuthBridgeTests.swift`

- [x] **Step 1: 写失败的协议往返测试**

在 `OAuthBridgeTests` 增加：

```swift
func testLoginAttemptRoundTripPreservesBrowserPresentationOwnership() throws {
    let attempt = OAuthBridgeLoginAttempt(
        provider: .grok,
        attemptID: UUID(uuidString: "8E38C402-8D53-49C1-A269-9F2350A9D823")!,
        method: .browser,
        browserLaunchMode: .providerRuntime,
        callbackMode: .automatic,
        authorizationURL: nil,
        userCode: nil
    )
    let response = OAuthBridgeResponse.success(
        requestID: UUID(uuidString: "633971B5-5F78-4584-950E-C69664433633")!,
        result: .loginAttempt(attempt)
    )

    let decoded = try OAuthBridgeCodec.decode(
        OAuthBridgeResponse.self,
        from: OAuthBridgeCodec.encode(response)
    )

    XCTAssertEqual(decoded.result?.loginAttempt, attempt)
    XCTAssertEqual(decoded.result?.loginAttempt?.browserLaunchMode, .providerRuntime)
    XCTAssertEqual(decoded.result?.loginAttempt?.callbackMode, .automatic)
}
```

- [x] **Step 2: 运行聚焦测试并确认先失败**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests/testLoginAttemptRoundTripPreservesBrowserPresentationOwnership \
  test >/tmp/xunjian-oauth-task1-red.log 2>&1
rg -n "error:|failed|TEST FAILED" /tmp/xunjian-oauth-task1-red.log | head -40
```

Expected: FAIL，提示 `browserLaunchMode`、`callbackMode` 或新初始化参数不存在。

- [x] **Step 3: 实现最小协议类型**

在 `OAuthBridgeProtocol.swift` 增加并用于 `OAuthBridgeLoginAttempt`：

```swift
enum OAuthBrowserLaunchMode: String, Codable, Equatable, Sendable {
    case application
    case providerRuntime
}

enum OAuthCallbackMode: String, Codable, Equatable, Sendable {
    case automatic
    case manualFallback
}

struct OAuthBridgeLoginAttempt: Codable, Equatable, Sendable {
    let provider: OAuthBridgeProvider
    let attemptID: UUID
    let method: OAuthBridgeLoginMethod
    let browserLaunchMode: OAuthBrowserLaunchMode
    let callbackMode: OAuthCallbackMode
    let authorizationURL: URL?
    let userCode: String?
}
```

仓库当前协议版本已是 `7`，把 `OAuthBridgeConstants.protocolVersion` 升为 `8`，并把
`XunJianOAuthBridge/main.swift` 的编码失败回退 JSON 同步为 `8`。更新本仓库内所有
`OAuthBridgeLoginAttempt` 初始化点，不保留隐式默认值，避免旧组合悄悄通过。

- [x] **Step 4: 运行协议与客户端回归**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests \
  -only-testing:XunJianTests/OAuthProtocolClientTests \
  test >/tmp/xunjian-oauth-task1-green.log 2>&1
rg -n "Executed|TEST SUCCEEDED|error:|failed" /tmp/xunjian-oauth-task1-green.log | tail -30
```

Expected: 两组测试 0 failure，输出 `TEST SUCCEEDED`。

### Task 2: Grok 使用官方完整短码授权页，Codex 保持 Browser OAuth

**Files:**
- Modify: `XunJianOAuthBridge/Core/SupervisedLineProcess.swift`
- Modify: `XunJianOAuthBridge/main.swift`
- Test: `XunJianTests/OAuthProcessTests.swift`
- Test: `XunJianTests/OAuthBridgeTests.swift`

- [x] **Step 1: 写 Grok 参数和 Provider 展示失败测试**

在 `OAuthProcessTests` 对 `makeGrokLoginConfiguration` 断言：

```swift
XCTAssertEqual(
    configuration.arguments,
    ["--no-auto-update", "login", "--device-auth"]
)
```

在 `OAuthBridgeTests` 的源码边界测试中只读取
`XunJianOAuthBridge/main.swift`，并断言 Grok 返回：

```swift
XCTAssertTrue(source.contains("method: .browser"))
XCTAssertTrue(source.contains("browserLaunchMode: .providerRuntime"))
XCTAssertTrue(source.contains("callbackMode: .automatic"))
XCTAssertFalse(source.contains("verification_uri_complete"))
```

最后一项保证寻简不从 Runtime 日志解析或猜测授权链接；`verification_uri_complete` 由官方 Runtime 内部消费。

- [x] **Step 2: 运行聚焦测试并确认先失败**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianOAuthProcessTests/OAuthProcessTests \
  -only-testing:XunJianTests/OAuthBridgeTests \
  test >/tmp/xunjian-oauth-task2-red.log 2>&1
rg -n "error:|failed|TEST FAILED" /tmp/xunjian-oauth-task2-red.log | head -40
```

Expected: FAIL，当前 Grok 参数仍为 `login --oauth`，登录尝试也没有展示元数据。

- [x] **Step 3: 修改 Grok 官方登录参数**

把 `makeGrokLoginConfiguration` 的参数精确改为：

```swift
arguments: ["--no-auto-update", "login", "--device-auth"]
```

不设置自定义 `BROWSER`，不提供浏览器脚本，不解析 stdout 中的 URL；固定 Grok Runtime 自己使用服务端 `verification_uri_complete` 打开系统浏览器。

- [x] **Step 4: 返回正确的 Provider 展示元数据**

Codex Browser OAuth：

```swift
return OAuthBridgeLoginAttempt(
    provider: .codex,
    attemptID: attemptID,
    method: method,
    browserLaunchMode: .application,
    callbackMode: method == .browser ? .automatic : .manualFallback,
    authorizationURL: attempt.authorizationURL,
    userCode: attempt.userCode
)
```

Grok 主流程：

```swift
return OAuthBridgeLoginAttempt(
    provider: .grok,
    attemptID: attemptID,
    method: .browser,
    browserLaunchMode: .providerRuntime,
    callbackMode: .automatic,
    authorizationURL: nil,
    userCode: nil
)
```

- [x] **Step 5: 运行 Bridge / Process 回归**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianOAuthProcessTests/OAuthProcessTests \
  -only-testing:XunJianTests/OAuthBridgeTests \
  test >/tmp/xunjian-oauth-task2-green.log 2>&1
rg -n "Executed|TEST SUCCEEDED|error:|failed" /tmp/xunjian-oauth-task2-green.log | tail -30
```

Expected: 0 failure，`TEST SUCCEEDED`。

### Task 3: 主 App 校验登录展示并仅在可回退失败时开放 Device Code

**Files:**
- Modify: `XunJian/App/AppModel.swift`
- Modify: `XunJian/App/OAuthCoordinator.swift`
- Test: `XunJianTests/OAuthBridgeTests.swift`

- [x] **Step 1: 写登录展示和备用入口失败测试**

增加以下核心用例：

```swift
@MainActor
func testGrokProviderManagedLoginDoesNotReturnAnApplicationURL() async {
    let fake = FakeOAuthBridgeService()
    let model = AppModel(oauthBridgeService: fake)
    let attemptID = UUID(uuidString: "81B3FCE0-D2A6-41E7-AC97-F5E85DDC781F")!
    await fake.configureLoginAttempt(OAuthBridgeLoginAttempt(
        provider: .grok,
        attemptID: attemptID,
        method: .browser,
        browserLaunchMode: .providerRuntime,
        callbackMode: .automatic,
        authorizationURL: nil,
        userCode: nil
    ))

    let presentation = await model.beginOAuthLogin(for: .grok)

    XCTAssertEqual(presentation?.attemptID, attemptID)
    XCTAssertEqual(presentation?.browserLaunchMode, .providerRuntime)
    XCTAssertNil(presentation?.authorizationURL)
    XCTAssertFalse(model.aiOAuthDeviceCodeFallbacks.contains(.grok))
}
```

```swift
@MainActor
func testCodexDeviceCodeFallbackIsLimitedToRecoverableBrowserFailures() {
    XCTAssertTrue(OAuthCoordinator.canOfferDeviceCodeFallback(
        for: .codex,
        error: OAuthBridgeClientError.requestTimedOut
    ))
    XCTAssertFalse(OAuthCoordinator.canOfferDeviceCodeFallback(
        for: .grok,
        error: OAuthBridgeClientError.requestTimedOut
    ))
    XCTAssertFalse(OAuthCoordinator.canOfferDeviceCodeFallback(
        for: .codex,
        error: OAuthBridgeClientError.protocolMismatch
    ))
}
```

再增加一个切换回归：先把 Codex 置于可回退状态，调用
`switchToOAuthDeviceCodeLogin(for:)`，断言旧 Browser attempt 被取消一次、Device Code
只启动一次、fallback 被移除；Grok 和未开放 fallback 的 Codex 都必须直接返回 nil。

- [x] **Step 2: 运行聚焦测试并确认先失败**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests/testGrokProviderManagedLoginDoesNotReturnAnApplicationURL \
  -only-testing:XunJianTests/OAuthBridgeTests/testCodexDeviceCodeFallbackIsLimitedToRecoverableBrowserFailures \
  test >/tmp/xunjian-oauth-task3-red.log 2>&1
rg -n "error:|failed|TEST FAILED" /tmp/xunjian-oauth-task3-red.log | head -40
```

Expected: FAIL，缺少 `AIOAuthLoginPresentation` 和备用入口状态。

- [x] **Step 3: 增加主 App 展示值和只读状态**

在 `AppModel.swift` 增加：

```swift
struct AIOAuthLoginPresentation: Equatable, Sendable {
    let attemptID: UUID
    let authorizationURL: URL?
    let browserLaunchMode: OAuthBrowserLaunchMode
    let callbackMode: OAuthCallbackMode
}
```

在 `OAuthCoordinator` 增加：

```swift
@Published private(set) var deviceCodeFallbacks = Set<AIProviderKind>()
@Published private(set) var loginPresentations: [
    AIProviderKind: AIOAuthLoginPresentation
] = [:]
```

由 `AppModel` 暴露只读状态。为避免在第 3 阶段提前改动已有未提交的设置页，
`beginOAuthLogin(for:)` 暂时保留 `URL?` 兼容返回值；第 4 阶段由 UI 读取
`aiOAuthLoginPresentations` 获取完整展示语义：

```swift
var aiOAuthLoginPresentations: [AIProviderKind: AIOAuthLoginPresentation] {
    oauth.loginPresentations
}

var aiOAuthDeviceCodeFallbacks: Set<AIProviderKind> {
    oauth.deviceCodeFallbacks
}

func switchToOAuthDeviceCodeLogin(
    for kind: AIProviderKind
) async -> AIOAuthDeviceCodePresentation? {
    await oauth.switchToDeviceCodeLogin(for: kind)
}
```

不得把一次性授权 URL、短码、attempt ID 或 fallback 状态写入 UserDefaults。

- [x] **Step 4: 校验 Provider 与展示字段组合**

把 Browser 登录成功校验收敛为纯函数：

```swift
static func validLoginAttempt(
    _ attempt: OAuthBridgeLoginAttempt,
    provider: OAuthBridgeProvider,
    method: OAuthBridgeLoginMethod
) -> Bool {
    guard attempt.provider == provider, attempt.method == method else { return false }
    switch (provider, method, attempt.browserLaunchMode, attempt.callbackMode) {
    case (.codex, .browser, .application, .automatic):
        return attempt.userCode == nil
            && attempt.authorizationURL.map(validOAuthAuthorizationURL) == true
    case (.codex, .deviceCode, .application, .manualFallback):
        return attempt.authorizationURL.map(validOAuthAuthorizationURL) == true
            && attempt.userCode.map(validDeviceUserCode) == true
    case (.grok, .browser, .providerRuntime, .automatic):
        return attempt.authorizationURL == nil && attempt.userCode == nil
    default:
        return false
    }
}
```

`beginLogin` 成功时返回 `AIOAuthLoginPresentation`；Grok 返回 nil URL 但保留 provider-managed 展示，Codex 返回需由 App 打开的白名单 URL。

- [x] **Step 5: 只为 Codex 可恢复失败开放备用入口**

增加纯函数并在 Browser 登录失败分支调用：

```swift
static func canOfferDeviceCodeFallback(
    for kind: AIProviderKind,
    error: Error
) -> Bool {
    guard kind == .codex else { return false }
    if let clientError = error as? OAuthBridgeClientError {
        switch clientError {
        case .requestTimedOut:
            return true
        case let .service(payload):
            return payload.code == .unsupportedOperation
                || payload.code == .authenticationFailed
        case .connectionFailed, .signingRequirementUnavailable, .invalidRequest,
             .invalidResponse, .protocolMismatch, .requestMismatch:
            return false
        }
    }
    return false
}
```

开始新登录、取消、断开、注销或成功认证时清除对应 fallback；普通 disconnected 状态不显示备用入口。

把“验证 fallback → 移除 fallback → 取消仍存活的 Browser attempt → 启动 Device Code”
收敛到 `OAuthCoordinator.switchToDeviceCodeLogin(for:)`，同一个 async 方法内顺序执行，
避免 SwiftUI 连续启动两个 `Task` 造成旧 attempt 与新 attempt 交错。这里使用不重复修改
fallback 的内部取消路径；只有 Codex 且 `deviceCodeFallbacks` 已包含该 Provider 时才允许切换。

`loginPresentations` 必须在新登录覆盖、取消、断开、注销、失败和成功认证时同步清理，
不得让旧 URL 或旧 attempt ID 残留到下一次登录。

- [x] **Step 6: 复用现有模型完成链路并补断言**

不得重写 `refreshModels`。增加测试证明连接完成时继续执行现有规则：历史模型存在则恢复；否则选 `isDefault`，再回退首项；空列表进入失败状态且不保存空模型。

- [x] **Step 7: 运行 Coordinator / AppModel 回归**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests \
  test >/tmp/xunjian-oauth-task3-green.log 2>&1
rg -n "Executed|TEST SUCCEEDED|error:|failed" /tmp/xunjian-oauth-task3-green.log | tail -30
```

Expected: 0 failure，`TEST SUCCEEDED`。

### Task 4: 收口设置页登录操作与浏览器行为

**Files:**
- Modify: `XunJian/Views/Settings/AIProviderSettingsRow.swift`
- Test: `XunJianTests/OAuthBridgeTests.swift`

- [x] **Step 1: 写 UI 决策失败测试**

把按钮可见性抽为可测试的纯展示值：

```swift
struct OAuthLoginActionPresentation: Equatable {
    let showsPrimaryLogin: Bool
    let showsDeviceCodeFallback: Bool
    let showsCopyCode: Bool
    let showsBrowserWaitingMessage: Bool
}
```

实现精确决策函数：

```swift
extension OAuthLoginActionPresentation {
    static func make(
        state: AIOAuthState,
        hasDeviceCodePresentation: Bool,
        fallbackAvailable: Bool,
        browserLaunchMode: OAuthBrowserLaunchMode?
    ) -> Self {
        let isDisconnected = state == .disconnected
        let isAuthenticating: Bool
        if case .authenticating = state {
            isAuthenticating = true
        } else {
            isAuthenticating = false
        }
        return Self(
            showsPrimaryLogin: isDisconnected,
            showsDeviceCodeFallback: fallbackAvailable && !hasDeviceCodePresentation,
            showsCopyCode: hasDeviceCodePresentation,
            showsBrowserWaitingMessage: isAuthenticating
                && browserLaunchMode == .providerRuntime
                && !hasDeviceCodePresentation
        )
    }
}
```

测试：

```swift
func testDeviceCodeControlsStayHiddenUntilFallbackIsExplicitlyAvailable() {
    let disconnected = OAuthLoginActionPresentation.make(
        state: .disconnected,
        hasDeviceCodePresentation: false,
        fallbackAvailable: false,
        browserLaunchMode: nil
    )
    let providerManaged = OAuthLoginActionPresentation.make(
        state: .authenticating(
            attemptID: UUID(uuidString: "D545D78A-A911-4AA1-8C43-C8E1476137A6")!,
            authorizationURL: nil
        ),
        hasDeviceCodePresentation: false,
        fallbackAvailable: false,
        browserLaunchMode: .providerRuntime
    )

    XCTAssertTrue(disconnected.showsPrimaryLogin)
    XCTAssertFalse(disconnected.showsDeviceCodeFallback)
    XCTAssertFalse(disconnected.showsCopyCode)
    XCTAssertTrue(providerManaged.showsBrowserWaitingMessage)
}
```

- [x] **Step 2: 运行测试并确认先失败**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests/testDeviceCodeControlsStayHiddenUntilFallbackIsExplicitlyAvailable \
  test >/tmp/xunjian-oauth-task4-red.log 2>&1
rg -n "error:|failed|TEST FAILED" /tmp/xunjian-oauth-task4-red.log | head -40
```

Expected: FAIL，缺少 `OAuthLoginActionPresentation`。

- [x] **Step 3: 实现最小 UI 行为**

- `.disconnected`：只显示 Provider 主登录按钮与“刷新状态”。
- Grok `.authenticating` + `.providerRuntime`：显示“已在浏览器打开授权页，请完成授权”，不显示短码。
- Codex `.authenticating` + `.application`：保留“在浏览器中继续”。
- `deviceCodeFallbacks` 包含 Codex 时：显示“改用设备码登录”。点击时只调用
  `switchToOAuthDeviceCodeLogin(for:)`，由 Coordinator 原子化地取消旧 attempt 并启动现有 Device Code 流程。
- 只有 `currentDeviceCodePresentation` 存在时才显示短码、复制按钮和验证页入口。
- 不新增“粘贴验证码”。

`openAuthorizationURL` 继续只打开 Codex 官方白名单 URL；Grok provider-managed 流程不经过该函数。

- [x] **Step 4: 增加源码安全门禁**

在测试中读取受控源码并断言：

```swift
XCTAssertFalse(source.contains("WKWebView"))
XCTAssertFalse(source.contains("document.cookie"))
XCTAssertFalse(source.contains("evaluateJavaScript"))
XCTAssertFalse(source.contains("querySelector"))
```

- [x] **Step 5: 运行 UI 决策与 OAuth 回归**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  -only-testing:XunJianTests/OAuthBridgeTests \
  test >/tmp/xunjian-oauth-task4-green.log 2>&1
rg -n "Executed|TEST SUCCEEDED|error:|failed" /tmp/xunjian-oauth-task4-green.log | tail -30
```

Expected: 0 failure，`TEST SUCCEEDED`。

### Task 5: 完整验证、文档与验收后提交

**Files:**
- Modify: `docs/HANDOFF.md`
- Modify: `docs/PLANS.md`
- Verify: all files above

- [x] **Step 1: 生成工程并运行完整测试**

Run:

```bash
xcodegen generate
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' \
  test >/tmp/xunjian-oauth-final-test.log 2>&1
rg -n "Executed|TEST SUCCEEDED|TEST FAILED|error:|failed" \
  /tmp/xunjian-oauth-final-test.log | tail -50
```

Expected: 主工程与 OAuth Process 全部 0 failure，`TEST SUCCEEDED`；允许既有大型性能门禁按默认配置跳过。

- [x] **Step 2: 运行静态分析与格式门禁**

Run:

```bash
xcodebuild -project XunJian.xcodeproj -scheme XunJian \
  -destination 'platform=macOS' analyze \
  >/tmp/xunjian-oauth-final-analyze.log 2>&1
rg -n "ANALYZE SUCCEEDED|ANALYZE FAILED|error:" \
  /tmp/xunjian-oauth-final-analyze.log | tail -30
xmllint --noout appcast.xml
plutil -lint XunJian/Info.plist XunJianOAuthBridge/Info.plist
git diff --check
```

Expected: `ANALYZE SUCCEEDED`，XML/Plist/diff 全部通过。

- [x] **Step 3: 人工 OAuth 验收**

状态：`PASSED`。Codex Browser OAuth + PKCE 自动回跳、Grok 完整短码授权页、登出重登、状态自动刷新与模型列表加载均已通过；未发送真实模型请求。

仅在用户明确允许真实 OAuth 后执行，不发送真实模型请求：

1. Grok 点击登录后直接打开带短码的官方页面。
2. Codex 使用 Browser OAuth + PKCE 自动回跳。
3. 普通界面不显示复制或粘贴验证码。
4. 主流程失败时只显示 Codex Device Code 备用入口。
5. 成功后自动加载完整模型列表并恢复有效历史模型。
6. 浏览器允许时关闭本次授权标签；不允许时显示完成页且不关闭其他窗口。
7. 重启寻简后认证和模型选择恢复。

- [x] **Step 4: 更新交接文档**

在 `docs/HANDOFF.md` 与 `docs/PLANS.md` 记录：实现范围、自动化测试数量、真实 OAuth 是否执行、浏览器关闭边界、未发送真实模型请求。

- [ ] **Step 5: 验收通过后再提交与发布**

先检查仅包含本计划和进入本轮前已有的用户改动：

```bash
git status --short
git diff --check
git diff --stat
```

用户确认验收后，使用中文结构化提交；不得在确认前执行：

```bash
git add \
  XunJian/Infrastructure/OAuthBridgeProtocol.swift \
  XunJianOAuthBridge/Core/SupervisedLineProcess.swift \
  XunJianOAuthBridge/main.swift \
  XunJian/App/AppModel.swift \
  XunJian/App/OAuthCoordinator.swift \
  XunJian/Views/Settings/AIProviderSettingsRow.swift \
  XunJianTests/OAuthBridgeTests.swift \
  XunJianTests/OAuthProcessTests.swift \
  docs/HANDOFF.md docs/PLANS.md \
  docs/superpowers/specs/2026-09-02-oauth-final-experience-design.md \
  docs/superpowers/plans/2026-09-02-oauth-final-experience.md
git commit \
  -m "修复：收口 OAuth 浏览器登录与模型恢复" \
  -m "问题或需求描述：Grok 未优先直达完整短码授权页，Codex 备用设备码默认暴露，登录后的模型恢复状态不够明确。" \
  -m "修复或实现思路：统一登录展示协议，Grok 改用官方 device-auth 浏览器流程，Codex 保持 Browser OAuth + PKCE，并通过 attempt/generation 收口备用入口和模型加载。"
```

不在本计划中推送、打 Tag、公证或替换 Release；这些属于独立发布任务。
