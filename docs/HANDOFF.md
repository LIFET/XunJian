# 项目交接

## 当前项目状态

寻简 0.1.7（build 8）候选版已完成设置草稿、正文预览菜单、全窗口滚动条及 OAuth 最终体验，并完成真实 OAuth/UI 验收；当前正在执行发布门禁，尚未提交或发布。

## 已完成内容

- 全局滚动条改为应用内原生 overlay 小尺寸样式，覆盖主窗口、设置、详情、菜单栏及大文件视图，不修改系统偏好；移除每次布局都递归遍历视图树的开销。
- 菜单栏偏好与语言通知统一切回主 RunLoop，关闭后台 UserDefaults 通知触发 Swift 6 actor 隔离断言的崩溃路径。
- SQLite 建库、打开和迁移移出 MainActor；启动状态区分“正在打开 / 可用 / 失败”，只在真实失败时显示重试，并以 generation 丢弃取消或重试后的迟到结果。
- AI Provider 未保存的 Base URL、模型和 API Key 仅在当前 App 会话内保留，离开设置页再返回不会丢失；保存后立即清除内存草稿，不写入磁盘。
- “预览正文”菜单与命令面板统一按可提取文本能力启用，图片、视频等不再显示可执行状态。
- 细滚动条桥接器会在 App 新窗口、Sheet 或 Popover 成为关键窗口时应用 overlay 小尺寸样式，并增加 AppKit 回归测试。
- OAuth 最终体验第 1 阶段完成：登录尝试协议增加登录方式、浏览器归属和回调语义；协议版本由 7 升至 8，并同步修正 Bridge 编码失败回退版本。
- OAuth 最终体验第 2 阶段完成：Grok 主登录改用固定官方 Runtime 的 `login --device-auth`，由 Runtime 消费完整短码授权 URL；寻简不解析日志、不注入浏览器环境或网页脚本。
- OAuth 最终体验第 3 阶段完成：主 App 严格校验 Provider/方式/浏览器归属/回调组合；只在 Codex 可恢复 Browser OAuth 失败后开放一次 Device Code 回退，并原子切换 attempt；成功状态复用原模型恢复链路，空模型明确失败且不覆盖历史选择。
- OAuth 最终体验第 4 阶段完成：设置页默认只显示 Provider 主登录；Grok 授权中展示由官方 Runtime 管理的浏览器等待状态；Codex 仅在可恢复失败后显示“改用设备码登录”，且只有真实 Device Code 展示存在时才显示短码、复制和验证页入口。
- Codex 已通过系统浏览器 Browser OAuth + PKCE 自动回跳；Grok 已通过官方完整短码授权 URL 登录，二者均自动保存连接并加载模型列表，无需手动刷新。
- Grok 登出在官方 Runtime 返回异常时仍以安全文件校验清除本地私有凭据；OAuth 轮询在正常结束和取消后都会清理任务，可立即重新登录。
## 验证与边界

- 主工程 409 项执行、2 项大型门禁跳过、0 失败；OAuth Process 38 项、0 失败。
- OAuth 协议阶段 RED 已确认缺少展示字段；GREEN 聚焦 2/2、OAuth Bridge/Protocol Client 回归 135/135，均 0 失败。
- Grok 授权参数 RED 精确复现 `--oauth` 与预期不符；GREEN OAuth Bridge 70/70、OAuth Process 39/39，均 0 失败。
- 主 App 展示与回退 RED 已确认缺少状态/API；GREEN 聚焦 5/5、OAuth Bridge 回归 75/75，均 0 失败。
- OAuth UI 决策 RED 已确认缺少纯展示模型；GREEN 决策/源码安全聚焦 2/2、OAuth Bridge 回归 77/77，均 0 失败；受控源码不含 WKWebView、Cookie/DOM/JavaScript 自动化。
- 最终全量回归首次发现并修正 1 条仍断言旧 Grok `login --oauth` 的测试；聚焦复跑 1/1 后，主工程 418 项（2 项大型门禁按设计跳过）与 OAuth Process 39 项均 0 失败，`TEST SUCCEEDED`。
- `xcodebuild analyze`、`xmllint`、两份 Info.plist、OAuth 禁用 API/浏览器注入源码扫描及 `git diff --check` 均通过。
- 5 万/10 万门禁 2/2 通过，分别 0.857s / 4.276s。
- `xcodebuild analyze`、`xmllint`、`plutil`、`git diff --check` 通过；仅有 macOS 测试宿主 `linkd` 环境噪声。
- 三架构 DMG 均通过 0.1.6/build 7、App/XPC 精确架构、深层签名、Sparkle Team/时间戳、OpenAI/xAI 官方 Runtime 签名、`hdiutil verify`、Apple 公证、staple 与 Gatekeeper。
- 真实 Codex/Grok OAuth 已完成登出、登录、自动状态更新和模型加载验收；OAuth Bridge/Protocol Client 最终 149/149、0 失败。未运行 AI、模型或付费请求；VoiceOver 等其余系统集成项仍以 `docs/MANUAL_ACCEPTANCE.md` 为准。
- 0.1.7 发布门禁：主工程 424 项（2 项大型门禁默认跳过）与 OAuth Process 39 项共 463 项、0 失败；5 万/10 万门禁 2/2、0 失败；Analyze、Runtime、XML、Plist、OAuth 源码安全扫描及 `git diff --check` 均通过。

## 下一步

OAuth 人工验收已完成，用户已确认提交、推送并发布 0.1.7（build 8）；不发送模型请求。官方授权页只能自行关闭本次标签或显示完成页，寻简不会自动化关闭浏览器进程、窗口或其他标签。
