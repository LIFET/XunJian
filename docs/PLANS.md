# 寻简开发计划

## 产品目标

以原生 macOS SwiftUI 应用统一展示用户主动授权目录中的文件，通过本地索引、快速搜索与最小必要的 AI 能力帮助用户找到、理解和简单管理文件。默认不复制、不移动、不改变原目录结构。

## 固定边界

- Local First；真实删除、移动、重命名只能由用户主动触发。
- AI 只接收完成当前请求所需的最少内容，不自动执行文件操作。
- 不做云盘、Finder 替代品、知识库、RAG 平台、Agent、协作或自动整理工作流。
- 原生 SwiftUI、Foundation、AppKit 与系统框架优先；只引入必要的轻量依赖。

## 实施阶段

- [x] Phase 1：基础工程、Sidebar、首页、所有文件、分类、设置、统一搜索入口与基础视觉。
- [x] Phase 2：目录授权、Security-Scoped Bookmark、文件扫描、Metadata、SQLite 与文件列表。
- [x] Phase 3：Quick Look、缩略图、打开、Finder 定位、安全文件操作与多分类。
- [x] Phase 4：文本提取、SQLite FTS5、本地搜索、过滤与排序。
- [x] Phase 5：FSEvents 增量监听、文件身份识别与索引一致性。
- [x] Phase 6：本地 API Key 凭据文件、统一 AI Provider、DeepSeek、Qwen，以及按官方能力评估 Codex/Grok；完成四项 AI 能力。
- [x] Phase 7：错误与空状态、性能、权限恢复、网络异常、UI 交互与完整验收。

## Phase 2 验收

- 系统目录选择器真实授权，Bookmark 可在重启后恢复。
- 扫描不阻塞主界面，支持取消、进度反馈与默认目录排除。
- SQLite 持久化扫描源和文件 Metadata，数据库目录 0700、文件 0600。
- 首页、文件表格/网格、基础名称/路径筛选和 Inspector 使用真实索引数据。
- 空目录、嵌套目录、中文、Emoji、隐藏文件、长文件名、1000 个文件与数据库替换均有测试。

## Phase 3 验收

- 列表、网格与 Inspector 展示系统缩略图；支持打开、Quick Look 与 Finder 定位。
- 重命名和移动执行真实文件操作，拒绝非法名称、目标冲突和不可写位置。
- 移到废纸篓必须二次确认，并明确可从系统废纸篓恢复。
- 分类支持新建、重命名、删除和多分类关联；删除分类不删除真实文件。
- 分类及关联写入 SQLite；重新扫描和退出重启后仍可恢复。

## Phase 4 验收

- 支持常见纯文本、Markdown、JSON/YAML/XML/CSV/HTML、源码与可直接提取文本的 PDF。
- SQLite FTS5 索引文件名、路径、分类与正文；中文查询、特殊字符和索引刷新均安全可用。
- 搜索异步执行并带 120ms 防抖，不调用 AI；支持文件类型过滤。
- 支持相关度、名称、修改/创建时间、大小、类型排序及升降序切换。

## Phase 5 验收

- FSEvents 仅监听可用的已授权来源，按文件事件识别新增、删除、修改、重命名与移动。
- 350ms 合并同源事件，只扫描受影响文件或目录，并在单个 SQLite 事务内同步 Metadata、分类与 FTS。
- 文件 ID 结合卷与资源标识；同一来源内重命名/移动保持身份和分类关联。
- 删除/移出目录执行轻量路径存在性校验；事件丢失、根变化时才回退一次完整扫描。
- 应用启动直接恢复持久化索引，不自动重新完整扫描。

## Phase 6 验收

- DeepSeek、Qwen、Codex、Grok 复用统一 Chat Completions 边界；Base URL/Model 可配置，一次只有一个当前 AI。
- API Key 仅存当前用户的 `Application Support/XunJian/Credentials/ai-credentials.plist`；目录 0700、文件 0600，缺失时自动重建为空文件。UserDefaults 只保存 Base URL、Model 与当前 Provider。
- API Key 不写入 App 包、索引或日志，分享或复制 App 不会携带密钥；本地文件不触发钥匙串密码提示，但不具备 Keychain 的系统级加密保护。
- 顶部搜索始终执行 120ms 防抖的纯本地索引搜索；AI 搜索只由用户点击独立入口后触发。
- AI 看文件、问文件不上传路径或无关文件；正文单次最多 4 万字符。AI 分类最多 8 个文件，只建议已有分类，确认后才应用。
- Phase 6 聚焦测试 13/13 通过，覆盖本地凭据持久化、缺失重建、权限、App 包隔离、Provider 独立删除、符号链接拒绝、请求/响应与 AI 能力。

## Phase 7A 验收

- 设置页支持新增目录、失效目录重新授权，以及二次确认后移除已授权目录。
- 移除来源只删除 Bookmark 与本地索引；原文件不变，FTS、文件和分类关联无孤儿记录。
- 外观支持跟随系统、浅色与深色，选择持久保存并即时作用于整个窗口。
- “所有文件”顶部仅保留 AI、类型、排序、升降序和显示方式控件；所有控件保持单行，文字标签隐藏但无障碍名称保留。
- 窗口变窄时，靠右控件按显示方式、排序方向、排序、文件类型的顺序进入“更多”；菜单内仍可完成全部操作。
- 低于 1080pt 自动收起 Inspector，低于 960pt 自动收起 Sidebar，并用滞回阈值恢复自动收起的栏；手动收起状态不被强制恢复。
- 窗口最小宽度为 360pt、默认 1200pt；控件显隐同时参考实际内容宽度，双侧栏最大宽度时也不挤压。
- 六列在实际内容宽度 1020→640pt 间连续压缩；低于 640pt 后所有列保持存在，由右边界逐像素裁切，放宽时对称恢复。
- 未授权目录且没有文件时，首页提示和授权入口在可用内容区域内居中，窄窗下仍完整显示。
- 现有 32 项测试、独立签名构建、真实 UI 与数据库完整性验收通过。

## Phase 7B 计划

### 7B-1 表格密度与访达日期（已完成）

- 为六列补齐合理的 `min / ideal / max` 宽度；实际内容区在 1020→640pt 间连续收缩，达到可读下限后从位置列一侧逐像素遮挡。
- 所有列始终保持可见状态；表格使用最小 640pt 内部画布与真实内容宽度外层裁切，不重建或改写 Table customization。
- 修改时间采用系统短日期、短时间与相对日期格式；中文显示“今天 01:49 / 前天 15:34 / 2026/8/2 02:09”，英文按所选语言区域显示。
- 验收宽屏、每个断点上下 1pt、双侧栏收放、今天/昨天/前天/普通日期及空日期。

### 7B-2 中英文界面

- [x] 第一部分：增加跟随系统、简体中文、English 三种持久化语言状态和根 Locale；接入 String Catalog，完成首页、Sidebar、“所有文件”及其 AI 弹窗、数量、类型、排序与 Finder 日期。语言开关暂不展示。
- [x] 第二部分：补齐设置、分类、Inspector、AppShell 弹窗、运行时错误和系统面板；默认分类只做显示层翻译，不改数据库中的用户数据或用户重命名结果；设置页 Picker 已启用并支持即时切换。
- [x] AI 协议字段、模型指令、文件名、路径及用户分类不随界面语言误改。
- 完整范围约 15–17 个文件，超过单阶段 10 文件边界；拆为“基础设施与主要页面”“弹窗/错误/默认分类”两步，全部覆盖前不暴露半成品语言开关。

### 7B-3 Codex / Grok 登录

- 最终产品必须提供 App 内置、可随 App 直接分发的 Codex/Grok OAuth 登录，不要求用户预装或登录本机 Codex/Grok CLI。
- 现有基于本机 CLI/XPC 的 OAuth 实现仅作为技术原型，已停止真实 smoke；下一阶段需先核实两家官方第三方 OAuth 能力，再以官方支持的嵌入式流程替换，不能复制本机 CLI Token 或模拟网页登录。
- OpenAI / xAI API Key 保留为独立回退；OAuth Token 由官方客户端管理，不写入 UserDefaults、日志或崩溃信息。
- 当前 App Sandbox 无法可靠读取外部 `~/.codex`、`~/.grok` 会话；已确认采用独立签名伴随服务，保留主 App 沙盒。
- 登录验收覆盖开始、取消、失败、成功、重启恢复、过期、断开、明确确认后的全局注销，以及未安装/版本不兼容；只有协议握手和一次真实请求成功后才显示已连接。
- [x] 7B-3A：建立按需嵌入、无 App Sandbox entitlement 的私有 XPC 服务、版本化 IPC、双向签名验证与官方签名 CLI 探测。
- [x] 7B-3B：接入 Codex App Server、Grok ACP、进程监督与协议测试。
- [x] 7B-3C-1：升级 v2 认证 IPC，接入 Codex ChatGPT 登录、Grok 官方 CLI OAuth、状态/取消/仅断开及 AppModel 独立 OAuth 状态；不触发真实登录或模型请求。
- [x] 7B-3C-2A：接入设置页、中英文状态、前台轮询和只断开；认证版本精确白名单为 Codex `0.146.0`、Grok `1.0.0 (3cd0d0cbcebe)`，兼容 Grok 当前四类只读被动通知，不执行登录或模型请求。
- [ ] 7B-3C-2B：v3 `verifyConnection`、0600 无工具 Agent Profile、专属 `GROK_HOME`、合成 `HOME`、跨 XPC 租约、`inspect --json` 与 owned UUID 清理已实现；Codex `0.146.0` 继续安全阻断。Grok 专属 OAuth 登录及两次无提示预检已通过。离线已补固定静态阶段码、精确中英文白名单及有序完整 post-prompt 生命周期，缺失/乱序/重复/ID 漂移全部 fail closed；Protocol 50/50、OAuthBridge 38 项（真实 smoke 1 项跳过），合计 88 项、0 失败。本阶段未发真实模型请求；下一步经用户再次确认后执行一次真实 smoke，再验收刷新、重启、过期与仅断开。
- 伴随服务只接受固定操作与固定官方 CLI，按 OpenAI Team `2DC432GLL2`、xAI Team `5Y6N3AJ54S` 校验签名；不经 shell、不继承 API Key/DYLD 环境、不读取或返回凭据文件。仅断开寻简不注销共享 CLI，会影响全局会话的 logout 必须再次确认。

#### 7B-3D 私有 Runtime 下载原型（已停止继续扩展）

- 推荐采用“寻简管理的私有官方运行时”：用户点击登录时由寻简自动下载固定版本的 Codex App Server / Grok Build 到自身 Application Support；不扫描 PATH、不复用 `~/.codex`/`~/.grok`，用户无需安装 CLI。
- 仅从 OpenAI/xAI 官方发布地址下载；下载后依次校验固定版本、SHA-256、Developer ID Team/identifier、非链接与权限，再原子安装。启动始终使用绝对私有路径，不经 shell。
- [x] 7B-3D-1（5 文件）：私有 Runtime Store、官方清单、流式硬限额、独立取消、release 指纹、SHA-256/Developer ID、raw/tar 受控解包、进程组清理、单飞/跨 Store 原子安装；固定 Codex App Server `0.147.0`、Grok `1.0.0` arm64，Process 38/38 通过，未登录或发模型请求。
- [x] 7B-3D-2A（10 文件）：Codex 浏览器 OAuth 使用私有 App Server `account/login/start(type: chatgpt)`；首次登录自动安装，状态刷新离线识别，专属 `CODEX_HOME`、合成 `HOME`、跨 XPC 租约、取消/仅断开与浏览器跳转均不依赖本机 Codex；Process 40/40、Protocol 50/50、Bridge 37 通过 + 1 个真实 smoke 跳过，0 失败；未执行真实登录或模型请求。
- [x] 7B-3D-2B（10 文件）：`chatgptDeviceCode` 的 v4 协议/UI、attemptID 绑定与 fail-closed 校验完成；真实设备码及浏览器 OAuth、重启恢复、刷新、“仅断开”与再次恢复均通过。固定 App Server `0.147.0` 正确 stdio 参数，并禁用 bundled skills/plugins、兼容其受限官方骨架。离线 Bridge 43 项（真实 smoke 1 项跳过）、Protocol 53/53 与本轮兼容窄测 3/3 均 0 失败；未发送模型请求。
- [x] 7B-3D-3（8 文件）：Grok OAuth/ACP 生产路径已切换至寻简私有 Managed Runtime；`probe/status` 离线校验，首次登录才按需下载，登录/验证/Session 删除均复验同一私有路径；复用专属 `GROK_HOME`、状态/取消/租约与清理，不依赖或回退本机 Grok。定向测试 3/3、Swift 6 strict typecheck 与 Debug App/XPC build 均通过；未执行真实下载、OAuth 或模型请求。
- [ ] 7B-3D-4：离线完成双架构 App/XPC、许可 NOTICE、升级与损坏恢复回归，但“首次登录下载 Runtime”不符合最终产品要求，停止继续扩展；不得把该原型标为可用 OAuth。
- 该方案面向 Developer ID 签名与公证后的站外 DMG/ZIP 分发；若目标是 Mac App Store，不能在运行时下载可执行代码，需改为把运行时直接打进 App，体积和审核风险单独评估。

#### 7B-3E 可用 OAuth 重建（内置分发方案已确认）

- 最终边界：只发布公证 DMG；Codex App Server 与 Grok Runtime 随 DMG 内的应用分发，不扫描或调用用户本机 CLI，不在登录时下载可执行代码；每位用户的 OAuth 凭据只写入自己的 Application Support。API Key 继续使用现有本地 0600 文件作为独立回退。
- [x] 7B-3E-1A（9 文件）：OAuth Bridge 协议升至 v5，新增 provider 绑定的 `generateText`；输入按 model/system/user 分段与总量门禁，输出上限 128 KiB，服务 75 秒、客户端 100 秒超时。Codex 使用固定 0.147 restricted-read、ephemeral thread、唯一 final + completed 聚合；Grok 复用严格 owned session 生命周期并返回有界通用文本。成功/失败/取消均关闭进程并清理临时目录，Grok 另删除精确 Session。App/XPC build 成功，OAuthBridge 46/46、OAuthProtocol 58/58，共 104/104 通过；未启动真实 CLI、OAuth、网络或模型。
- [x] 7B-3E-1B（6 文件）：新增 OAuth `AIProvider` 与持久化认证模式，让 `.signedInUnverified/.connected` 可独立设为当前 AI；搜索、解释、问答与分类通过现有 `AIService` 走 OAuth Chat IPC，API Key 本地凭据与 Provider 路径保持独立。OAuth 失效只清除 OAuth 当前项；设置页显示/切换当前模式。新增聚焦 5/5、OAuthBridge 51/51、Swift 语法检查与 Debug App/XPC build 均通过；未启动真实 CLI、OAuth、网络或模型。
- [x] 7B-3E-2A（10 文件）：Codex App Server 0.147.0 的 arm64/x86_64 官方签名产物已随 XPC Bundle 打包；状态、登录和 AI 请求只解析当前架构资源，并复验固定 SHA256、OpenAI Team/Identifier、权限与链接，Codex 登录下载路径已移除。Resolver/Bundle 4/4、Swift 6 strict typecheck、Debug App/XPC build 与产物签名/SHA 均通过。Release 已使用 Team `76V7CQ4T45` 的 Developer ID 签名并经 Apple 公证接受、stapling 与 Gatekeeper 验证；可分享 ZIP 位于 `Release/寻简-0.1.0-macOS.zip`。未启动 Runtime、OAuth、网络或模型。
- [x] 7B-3E-2B（10 文件）：Grok Build 1.0.0 的 arm64/x86_64 官方签名产物已随 XPC Bundle 打包；状态、登录、验证、AI 请求与 Session 删除只解析当前架构资源，并复验固定 SHA256、xAI Team/Identifier、权限与链接，Grok 登录下载路径已移除。App/XPC Release 均为 `arm64+x86_64`；Resolver/Bundle 3/3、Release Universal build、资源 SHA 与供应商签名检查均通过。未启动 Runtime、OAuth、网络或模型；2A 的旧 ZIP 尚未包含本阶段产物，不作为最终分发包。
- [ ] 7B-3E-3：删除不可达下载器/旧 smoke/误导文案；Codex、Grok 的真实 OAuth 与真实 AI 请求已通过，离线 OAuthProtocol 59/59、OAuthBridge 51/51、OAuthProcess 34/34 通过；Universal Developer ID DMG 已去除调试权限、补齐安全时间戳并提交 Apple 公证。原任务 `73c2c479-c04f-4ef5-89e8-7896289000e2` 长时间停留 `In Progress`，已做一次受控重试 `a3d982f4-b286-4b31-a43f-880277570f13`；任一 Accepted 后执行 staple 与 Gatekeeper 完成。

### 7B-4 API Key 本地持久化（已完成）

- Keychain 已替换为当前用户 Application Support 下的寻简本地凭据文件；App 分享不携带密钥，文件缺失自动重建。
- 保存、读取、删除、Provider 创建和设置文案已完成切换；旧 Keychain 条目保持原样且不再读取。

### 7C 大规模索引性能门禁（已完成）

- 新增只在发布验收时显式启用的 5 万文件性能门禁，覆盖批量写入、全量恢复、FTS 唯一命中、数据库体积和结果正确性。
- arm64 实测 50,000 条完整门禁 1/1 通过，XCTest 总用时 0.790 秒；日常测试默认跳过，避免拖慢普通回归。

### 7D 10 万文件与列表交互门禁（已完成）

- 新增 100,000 条发布验收，覆盖索引写入/恢复/FTS、类型筛选和名称、修改时间、创建时间、大小、类型五种排序；每项交互限时 1 秒。
- 门禁发现类型排序 1.099 秒的回归；将七种固定类型的本地化比较结果缓存为序位后降至 0.701 秒，排序语义不变。
- arm64 最终实测：写入 1.192 秒、恢复 0.107 秒、FTS 0.0013 秒、筛选+五种排序 0.998 秒；门禁与原排序正确性测试 2/2 通过。

### 7E 权限失效与重新授权验收（已完成）

- Bookmark 可在授权目录移动后解析到新位置；损坏 Bookmark 明确进入需重新授权状态。
- 重新授权不再强制目录仍处于旧路径，用户可选择移动后的当前位置；来源 ID、文件身份、分类与 FTS 索引保持一致。
- 移除来源会事务性清除来源、文件、FTS 与文件分类关联，不删除用户磁盘文件，也不删除可复用的分类实体。
- 聚焦验收 4/4 通过；未改 OAuth、公证包或性能实现。

### 7F UI 与命中区域完善（已完成）

- 首页、分类和文件网格增加轻量 hover/选中反馈；最近文件使用真实缩略图与统一访达式日期。
- 文件表格六列、分类文件行、网格卡片和 AI 分类行均支持整行单击、双击打开与右键菜单；图标按钮统一扩大命中区。
- OAuth 官方账号卡片按状态、说明、操作分层；Codex/Grok 均提供显式“验证连接”，只有固定最小真实请求与完整清理成功后才转绿。
- 寻简专属 OAuth 新增明确确认的“退出账号”；已移除共享 CLI 原型遗留的“仅断开寻简”入口与文案。
- 授权目录、AI 字段、分类标题、首页日期、扫描状态与弹窗在 360pt/英文环境下自动换行；Inspector 与网格状态层级保持一致。
- 顶部搜索恢复为纯本地索引搜索，不再因输入自然语言自动调用 AI；AI 能力保留独立显式入口。
- 离线 OAuthBridge 54/54、OAuthProtocolClient 60/60 与 Debug 构建均通过；未触发真实 OAuth、网络或计费模型请求。

### 7G 操作逻辑与恢复路径（已完成）

- AI 正文只在明确请求时按文件 ID 读取；英文界面使用英文指令，关闭任务弹窗会取消请求并阻止迟到结果回写。
- AI 搜索条件保留，普通搜索作为本地二次筛选；AI 分类支持本地筛选、已选置顶、逐条移除建议、事务性应用与一次撤销。
- 扫描用 generation、当前来源和待扫描集合隔离旧任务；移除来源不会让旧任务覆盖新状态。
- 删除分类自动回到分类总览；筛选隐藏文件清理选择，移动/重命名成功后按新路径恢复选中。
- API Key 保存以成功结果驱动清空与提示；Base URL/模型变化后必须先保存再重新验证，旧绿态不再误导。
- 数据库不可用持续显示恢复提示并禁用索引操作；无分类、授权失效及类型空结果均提供明确恢复路径。
- Debug 构建通过；FileIndex/Navigation/AI 聚焦 30 项执行、28 通过、2 项发布级大数据门禁按设计跳过，0 失败；未触发真实 OAuth、网络或计费请求。
- 当前待公证 DMG 早于本阶段源码；正式交付 7G 前必须重新构建、签名并公证新 DMG，不得把旧产物标为包含本轮修复。

### 7H 文件浏览偏好与应用图标（已完成）

- 扫描默认忽略名称以 `.` 开头的文件与目录；设置可显式开启，切换后立即更新可见结果并重扫已授权来源。
- 所有文件表格取消双击优先造成的单击等待，单击立即选择、双击仍打开。
- 文件类型、排序、升降序与列表/图标显示方式通过用户偏好持久化，切换页面和重启后保留。
- 新增完整 macOS AppIcon asset catalog；隐藏文件扫描回归 4/4 与 arm64 Debug 构建通过。

### 7I 最终数据一致性与恢复体验（已完成）

- 搜索返回总数并支持 500 项分批加载；普通搜索保留旧结果直到新结果提交，浏览/搜索排序与方向、表格列布局及列表/网格滚动位置独立记忆。

### 7J 全面审查报告闭环（已完成）

- [x] F01–F24 全部完成：动效/Reduce Motion、Dynamic Type、640pt 完整表格、多选拖拽快捷键、职责拆分、缓存/索引性能、设计 Token、无障碍/本地化、失败反馈、Provider 合并、SSE 流式与默认分类单一来源。
- [x] 报告 21 项增强全部实现：复制路径、Quick Look、批量分类、手动过滤、搜索历史、Inspector AI、分类排序、来源启停、保存搜索、命令面板、内嵌预览、拖入拖出、结果导出、菜单栏搜索、Services、存储洞察、通用撤销、Finder 标签、自定义列、扫描通知、重复检测。
- [x] 复审 P1/P2/P3：扫描完整性、撤销身份、原生文本命令、Services 类型、AI revision、FSEvents 测试、版本、完整哈希、CSV 公式注入、缩略图等待取消与 Swift 警告均闭环。
- [x] arm64 Debug 与离线全量测试通过：App 232 项（2 项发布级大数据门禁跳过）、OAuth Process 34/34，0 失败。
- [ ] 发布前人工验收：拖拽、Services、菜单栏、VoiceOver、放大字号/Reduce Motion、常见窗口宽度；确认后再构建和公证新 DMG。
- 全量扫描的枚举或元数据读取失败会整批拒绝替换；增量扫描只对成功 scope 做差集更新，失败 scope 不再触发全源清理，人工分类不会因临时权限或 iCloud 错误丢失。
- 数据库运行时失败会停止监控、释放旧实例并由“重试”重新打开；恢复性全量扫描排队且不取消用户扫描，过期文件会清理失效索引。
- 授权来源拒绝相等、父子或符号链接重叠；跨授权来源移动通过单事务迁移分类、索引和 FTS，失败不主动破坏旧分类关系。
- 单主窗口消除跨窗口搜索/选择/危险弹窗串扰；OAuth 轮询提升到 App 生命周期，API Key 测试单飞可停止，凭据损坏与快速分类连点均有安全恢复。
- App 测试 232 项执行（230 通过、2 项发布门禁跳过）、Process 34/34、arm64 Debug 构建通过；本阶段未生成、签名、提交或公证新 DMG。

## 风险

- 外部应用进行的跨来源移动仍可能获得新身份；寻简内置“移动到”已迁移分类与搜索索引，文件身份仍由卷与资源标识决定，不引入版本系统。
- 内容哈希只用于用户显式触发的“查找重复文件”：先按大小分组，只对可能重复的组做 SHA-256 流式分块计算；大文件不静默跳过，读取失败整次明确失败且不返回部分哈希。结果不落库，也不参与文件身份或同步。
- Office 文档解析与 OCR 不在当前范围；单文件提取上限 8MB，索引正文上限 20 万字符。
- 5 万/10 万文件的索引与列表筛选/排序门禁已通过；真实界面滚动的帧率与内存峰值尚未自动量化。
- 在线 Provider 未使用真实 API Key 做计费请求；设置页提供显式“测试连接”，不把“密钥已保存”冒充“已连接”。
- Qwen 当前推荐地域 Workspace Base URL；默认兼容地址可编辑，用户需与 API Key 所属地域保持一致。
