# 项目交接

## 当前项目状态

Phase 8M 深度审查修复及 v0.1.0 发布构建已完成；数据安全、十万文件性能、UI/无障碍及 OAuth/XPC 并发与签名权限边界均已关闭。Universal DMG 已完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 与 Sparkle EdDSA 验证；未运行应用内真实 OAuth/AI 或文件扫描。

## 已完成内容

- 分类详情保留“全部分类”返回入口，并在右侧恢复原生样式的“编辑分类”。
- 列表交还 macOS `Table` 原生弹性列宽与水平滚动；窄窗不再用 640pt 画布直接裁掉尾部内容。
- 列表单击、⌘点选、⇧点选交还原生 Table，双击继续执行既有打开行为；避免名称按钮拦截后选中高亮迟到。
- 文件索引按类型预分组，切换类型不再遍历完整文件库；排序与 ID 派生继续在后台完成。
- 分类详情筛选保留旧列表直到新结果提交，列表行补齐 VoiceOver 摘要与选中状态。
- 24pt 列表图标改用 Quick Look 缩略图，并保留并发门禁、有界缓存与失败占位。
- JSON-RPC 通知队列改为 65,536 条与 4 MiB 双重上限；合法 Grok 流不再因旧 256 条阈值误报 `prompt.notification-overflow`，超预算仍 fail closed。
- 批量操作栏在窄窗自动收纳为“更多操作”，保留分类、移除、废纸篓与取消选择的原有动作。
- Inspector 仅在文件页且窗口不少于 720pt 时可手动打开；更窄窗口会稳定收起，避免挤压主体。
- 废纸篓横幅关闭按钮使用 28×28pt 命中区；重建索引期间保留可读按钮标题与 VoiceOver 名称。
- 中文菜单统一为“在 Finder 中显示”。
- 文件名称列移除单元格级手势遮罩，单击、⌘/⇧多选交还原生 Table；双击、右键与拖拽分别落在 Table/TableRow 层，整段名称宽度均可选中。
- 外部全选/取消与 Table 高亮双向同步；原生集合选择会维护 Finder 风格 lead/anchor，键盘与菜单动作不再落到旧文件。
- Inspector 显隐后 Table 保持同一布局身份并使用原生列宽自适应，不再因 detail 宽度跨阈值重建大表；工具栏与菜单同步显隐/禁用状态。
- 列表和网格滚动位置统一改为 500ms 防抖持久化；辅助列不再重复朗读名称列已提供的整行 VoiceOver 摘要。
- 分类详情“编辑分类”使用原生菜单，完整提供“修改名称…”与 destructive“删除分类…”，复用既有 Sheet 和确认框。
- 搜索框改用系统 `NSSearchField`，放大镜、清除键、焦点环、键盘与 VoiceOver 语义交还 AppKit；搜索历史和现有查询逻辑不变。
- 文件类型、排序和显示方式分别改用原生 menu Picker 与 segmented Picker；过滤、AI、排序方向及更多操作使用系统 Button/Menu，不再绘制按钮表面和选中态。
- 多选操作区改用原生 `GroupBox + ControlGroup`，窄窗继续收纳到系统 Menu；扫描、导出、撤销和数据库错误栏统一使用系统 bar 材质与原生进度/按钮。
- 搜索历史改由 `NSSearchField` 原生最近搜索菜单承载；菜单栏搜索结果与命令面板结果改用原生 `List`，保留键盘选择、打开和页面跳转动作。
- 分类详情列表改用原生 `Table`，AI 分类文件选择改用带集合选择的原生 `List`；分类图标改用 palette `Picker`。
- AI Provider 展开收起交还 `DisclosureGroup`；OAuth、AI 结果、Inspector 信息与正文预览统一使用 `GroupBox`/`LabeledContent`。
- 正文查找改用原生搜索框与 `ControlGroup`；首页扫描位置使用 `GroupBox + LabeledContent + ControlGroup`，授权、启停和移除语义保持不变。
- 存储洞察的摘要、比例和文件排行分别使用 `GroupBox`、`ProgressView`、`List`，重复文件哈希与清理流程保持不变。
- Codex/Grok 使用独立 XPC connection lane；单一 Provider 的取消或协议失败不再使另一 Provider 的登录、状态或生成任务失效。
- OAuth 业务请求会先占用 Provider，再等待已启动的状态探针；占用期间前台轮询跳过该 Provider，取消会精确释放占用。
- Codex 状态探针读取账户后必须关闭私有 Runtime 并完成清理才能返回；App 补齐持久化 security-scoped bookmark entitlement。

## 验证

- Phase 8G 的 LagIsolation、RemainingReview、OAuthProtocolClient 共 112 项，0 失败。
- Phase 8I FileSelection、LagIsolation、NavigationModel、RemainingReview 共 96 项，0 失败；arm64 Debug 测试构建通过。
- Phase 8J FileSelection、LagIsolation、RemainingReview 共 59/59、0 失败；本地 Grok 对原生 Table/Inspector 与分类菜单补丁复审 `APPROVED`。
- Phase 8K arm64 Debug 测试构建通过；RemainingReview 32/32、FileSelection 13/13、LagIsolation 14/14，共 59/59、0 失败。
- 隔离索引实点名称文字、缩略图、名称列空白区均即时选中，右键原生菜单可用；本地 Grok 对名称列修复结论为 `APPROVED`，其余 8 项审查边界已收口。
- Phase 8L arm64 Debug 构建通过；FileSelection 13/13、LagIsolation 14/14、RemainingReview 32/32，共 59/59、0 失败；本地 Grok 提供原生控件边界复核，未改仓库。
- Phase 8M 首阶段：隐藏/排除文件增量对账真实 SQLite 回归 1/1 通过；Swift parse 通过。扫描取消路径在数据库提交后统一抛出取消并触发现有 `reloadIndex`，整盘 checkpoint 仅在任务仍持有 generation 时推进。
- Phase 8M 性能阶段：十万级 ID 下标移到后台生成；原生 Table 仅对外部选择刷新；Inspector 预览限制 2 万字并可取消，多选摘要不再排序完整选择集；分页全选与批量目标保持一致。LagIsolation 14/14、RemainingReview 33/33，共 47/47 通过；正文前缀与扫描安全聚焦测试通过。
- Phase 8M UI/无障碍阶段：命令面板结果改为真实按钮并隔离背景焦点；原生搜索框异步聚焦会复核最新绑定；首页 ⌘F 不再跳页；冷启动窄窗立即收起侧栏；整盘设置、分类工具栏与正文预览补连续窄宽回退；网格补 VoiceOver“打开”动作。Swift parse、arm64 Debug 构建通过，RemainingReview 33/33 通过。
- Phase 8M OAuth/XPC 阶段：OAuthBridge 66/66、OAuthProtocolClient 66/66，共 132/132、0 失败；entitlements 校验及 Swift parse 通过。本地 Grok 因计划模式要求创建临时审查目录而被终止，未修改仓库。
- v0.1.0 Universal Release archive 构建通过；Apple 公证任务 `86b10a9e-5658-437e-a333-fdba207a150f` Accepted，DMG staple/validate、Gatekeeper、挂载后深层签名、双架构与 `hdiutil verify` 均通过；最终 SHA-256 为 `6da244e368e2e23bb6ed78593019713d6d31fef0967f3540cbef97825edad90f`。

## 已知边界与下一步

- 需用当前新构建继续人工复核 360/640/960/1200pt 的 Table 水平滚动、⌘/⇧多选、Inspector 显隐及真实 Grok 看文件/问文件；真实 AI 会产生请求费用，未自动执行。
- 仍需用旧构建执行一次真实 Sparkle 升级与伪造包拒绝人工验收；本次未自动运行真实 OAuth/AI。
