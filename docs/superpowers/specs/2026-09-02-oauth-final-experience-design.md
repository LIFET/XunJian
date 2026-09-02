# 寻简 OAuth 最终体验设计

## 状态

- 日期：2026-09-02
- 设计状态：已确认
- 实施状态：已完成并通过真实 OAuth/UI 验收
- 发布边界：仅面向寻简随公证 DMG 内置的 Codex / Grok 官方 Runtime

## 目标

为 Codex 与 Grok 提供一致、低摩擦且安全的 OAuth 登录体验：优先直接进入可完成授权的系统浏览器页面，成功后自动恢复连接并加载模型；只有自动回跳不可用时才暴露 Device Code 备用流程。

## 非目标

- 不使用 `WKWebView`。
- 不注入网页脚本、不读取 Cookie、不抓取网页内容、不操作 DOM。
- 不复制或解析 OAuth Token，不将 Token 返回主 App。
- 不关闭整个浏览器窗口或其他标签页。
- 不改变 API Key 登录与本地 0600 凭据文件路径。
- 不改动 OAuth 之外的 AI 请求、索引或文件管理功能。

## 用户体验

### Grok

1. 用户点击“使用 Grok 账号登录”。
2. Bridge 以 Grok Runtime 官方 `login --device-auth` 流程启动登录；Runtime 使用服务端返回的 `verification_uri_complete` 打开已携带短码的授权页。
3. 寻简显示“已在浏览器打开授权页”，不解析 Runtime 的自由文本输出，也不重复打开第二个页面。
4. 授权完成后，寻简自动刷新认证状态、加载模型并保存当前 OAuth 连接。
5. 若官方 Runtime 无法自动打开浏览器，寻简显示明确失败和重试入口；不得从日志猜测或拼接授权 URL。

### Codex

1. 用户点击“使用 ChatGPT 登录”。
2. Bridge 使用 Codex App Server 官方 Browser OAuth + PKCE 流程。
3. 寻简只打开 App Server 返回并通过白名单校验的 HTTPS 授权 URL；PKCE verifier、challenge、回调校验及 Token 均由官方 Runtime 管理。
4. 浏览器授权回跳完成后，寻简自动刷新认证状态、加载模型并保存连接。
5. 自动回跳失败、远程环境或官方 Runtime 明确不兼容时，才显示 Device Code 备用入口。

### 浏览器完成行为

- 授权页可自行关闭本次标签页或认证会话时，允许其自动关闭。
- 浏览器策略阻止自动关闭时，显示“授权完成，可返回寻简”。
- 寻简不通过自动化能力关闭浏览器进程、窗口或其他标签页。

### Device Code 备用体验

- 默认设置页不显示“复制验证码”“粘贴验证码”或设备码内容。
- 主流程失败且错误可回退时，显示单一“改用设备码登录”入口。
- 备用界面可显示一次性短码、复制按钮和验证页入口；取消、成功或 attempt 失效后立即清理。
- 寻简不提供“粘贴验证码”，因为验证码应输入 Provider 官方页面，而不是回填 App。

## 架构设计

### OAuth Bridge 协议

`OAuthBridgeLoginAttempt` 增加明确的展示语义：

- `method`：`.browser` 或 `.deviceCode`
- `browserLaunchMode`：`.application` 或 `.providerRuntime`
- `authorizationURL`：仅 `.application` 模式存在，由寻简校验并打开
- `userCode`：仅 Device Code 备用流程使用
- `callbackMode`：`.automatic` 或 `.manualFallback`

解码必须保持 fail closed：字段组合与登录方式不匹配、Provider 不一致、未知枚举或不安全 URL 均拒绝进入认证状态。

### Bridge 层

- Codex 继续复用官方 App Server 的 Browser OAuth / Device Code API，不自行实现 PKCE。
- Grok 主流程改用官方 `login --device-auth`，由固定版本 Runtime 消费 `verification_uri_complete` 并打开系统浏览器。
- Bridge 不读取自由文本中的任意 URL，不从日志猜测短码，不拼接验证链接，不执行 shell。
- Bridge 只返回展示信息、attempt ID 和认证状态，不返回 Token、Cookie 或 Runtime 凭据正文。

### App 层状态机

`OAuthCoordinator` 使用统一状态流：

`disconnected → starting → awaitingBrowser → finalizing → loadingModels → connected`

Device Code 备用流程使用同一 attempt ID，不创建第二套连接状态。每次状态变更均校验 Provider、generation 与 attempt ID；取消、切换 Provider、重试及迟到回调不得覆盖新状态。

### 授权成功后的固定顺序

1. 确认 Provider、generation 与 attempt ID 仍属于当前尝试。
2. 从 Bridge 刷新官方认证状态。
3. 请求该 OAuth 账号的全部可用模型。
4. 历史模型仍存在时恢复历史选择；否则选择第一个可用模型。
5. 保存 OAuth Provider、认证模式与模型选择。
6. 标记连接完成，并清理一次性展示、轮询任务和登录临时状态。

账号认证成功但模型请求失败时，保留“已登录、模型待加载”状态，提供“重新加载模型”，不得错误显示为完整连接。

## URL 安全规则

- 只允许 HTTPS。
- Provider 域名使用精确白名单；不接受相似后缀、IP 地址或非官方跳转域。
- 默认只允许 443 端口。
- 拒绝 userinfo、password、fragment、空 host、超长 URL 与无效编码。
- App 在打开 URL 前再次校验，Bridge 校验不能替代主 App 边界校验。

## 错误与恢复

- URL 不安全或响应结构无效：终止当前尝试，显示安全错误，不自动降级到猜测链接。
- 自动回跳超时：保留可取消状态，并显示 Device Code 备用入口。
- 用户关闭浏览器：继续等待，可选择重新打开或取消。
- 模型为空：显示明确空状态，不保存空模型。
- 模型加载失败：保留认证状态，允许重试。
- App 重启：只从官方凭据状态恢复并重新加载模型，不恢复短码或旧授权 URL。
- 取消登录：终止 Runtime 登录、清理临时状态并拒绝迟到结果。

## 验收矩阵

### 自动化测试

- Grok：Provider Runtime 管理浏览器、浏览器启动失败、取消、完成与迟到结束。
- Codex：Browser OAuth、Device Code 备用、回调失败、attempt ID 不匹配。
- 状态机：成功、取消、重复点击、Provider 切换、迟到结果、重启恢复。
- 模型：完整加载、恢复历史模型、历史模型失效、空列表、加载失败和重试。
- UI：默认隐藏设备码操作；只有可回退失败时显示备用入口。
- 安全：非 HTTPS、超长 URL、userinfo、异常端口、未知域名全部拒绝。
- 源码门禁：无 `WKWebView`、脚本注入、Cookie 读取或 DOM 自动填写路径。

### 人工验收

- Grok 点击后直接进入已带短码的官方授权页。
- Codex 默认完成 Browser OAuth + PKCE 自动回跳。
- 授权成功后自动显示账号连接状态与完整模型列表。
- 历史模型恢复正确；无历史模型时选择首个可用模型。
- 浏览器允许时关闭本次授权标签页；不允许时显示完成页。
- 自动回跳失败后 Device Code 入口可用，普通流程不出现复制/粘贴验证码。
- 未执行真实模型请求即可完成登录与模型列表验收；计费请求单独授权。

## 实施边界

优先修改现有 OAuth 协议、Bridge 登录解析、`OAuthCoordinator` 与设置页登录展示；复用现有 generation、attempt ID、模型加载和 Runtime 签名校验。不得借此重构无关 AI、索引、文件或发布模块。
