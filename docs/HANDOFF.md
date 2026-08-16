# 项目交接

## 当前项目状态

Phase 8Q 原生控件生命周期与 OAuth 启动安全已完成源码收口；本轮尚未提交、打包或发布，未运行真实 OAuth/AI 或文件扫描。

## 已完成内容

- 四个内置 Runtime 已从本地 LFS 对象恢复为真实 Mach-O，并新增构建前大小、架构、SHA-256、官方签名门禁；状态探针只读安全元数据/proof，启动不再自动发模型验证。
- 原生列表/网格的选择 echo 与 renderer 所有权闭环；名称单元格及网格卡片子视图统一进入原生选择路径；列偏好迁移 v4 并修正 AppKit 列 ID 前缀；侧边栏偏好/窄窗强制收起分离，菜单按当前窗口真实路由。
- Unix `0/1` 秒系统占位时间归一为未知；持久化 security-scoped bookmark entitlement 恢复。

- 20,000 项以上的列表与网格改用 AppKit 数据源虚拟化，仅创建可见行/卡片；96,148 文件下单击、Inspector 显隐不再重建六位数 SwiftUI 视图树。
- 网格使用不可变几何快照，连续宽度与滚动位置不重叠；大列表 Finder 标签仅按可见单元异步读取并精确刷新。
- 文件筛选/排序改为页面局部原子快照与可取消稳定排序；工具栏按离散宽度只构建一套控件，不再同时布局多套 `ViewThatFits`。
- 搜索输入、进度、结果与预览高亮迁入窄状态，均不触发 `AppModel` 全局广播；旧 FTS 通过 SQLite progress handler 可取消，最新查询不再等待。
- 索引恢复的范围过滤和 ID 派生移出主线程；无变化复扫提前结束；独立 WAL 只读连接保证数据库写入期间搜索可继续。
- 增量派生期间若其他 publication 先提交，变化会原子回队重试，不再丢失内存索引更新。
- AI Provider 使用整行可点击的 Disclosure 样式，修正展开内容与状态区间距；列表/图标改为纯图标并与排序方向分隔。
- 9.6 万文件列表不再因原生点击二次滚动，超过阈值停用逐行滚动持久化与整表切换动画。
- 首页扫描位置改为稳定 HStack/VStack 回退；主搜索框提升为 40pt large 控件。
- 菜单栏搜索扩至 50 条可滚动结果、480pt 弹窗，移除延迟单击的双击识别并恢复独立操作按钮。
- AI 官方账号卡片增加 16pt 水平、14pt 垂直内容留白；超过 2 万项时从列表视图树中彻底移除 `scrollPosition`，不再仅丢弃回写。

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
- 整台 Mac 扫描仅覆盖当前用户可见目录、iCloud Drive 与 `/Users/Shared`；系统、其他用户、挂载卷及私密 Library 数据不再进入索引，每个范围超过 10 万文件会保留旧索引并提示缩小范围。
- `.ssh`、`.env*`、凭据、浏览器、邮件与消息路径在全量/增量扫描、旧索引清理、Inspector 和 AI 正文读取中统一拒绝；UTF-16（含无 BOM 中文）与 GB18030 文本可正确读取，二进制继续拒绝。
- 多选 lead 改为可见顺序邻近且确定；OAuth 动态 prompt 内容转义分隔符，防止正文伪造指令边界。

## 验证

- Phase 8Q：FileSelection 24/24、LagIsolation 26/26、NavigationModel 46/46、OAuthBridge 67/67、OAuth Process 38/38，共 201/201；arm64 Debug、XPC Runtime 构建门禁、整包深层签名均通过。
- 最终 QA 单实例确认：默认列显隐、跨列表/网格选择、菜单动作、搜索焦点、侧边栏偏好往返与 AI 状态均正确；启动仅 App/XPC 存活，未出现 `xunjian-connection-verifier` 或 Codex/Grok Provider Runtime。最终第四版在 96,148 条真实索引中实点名称文字、缩略图与网格卡片，选中即时迁移且等待 3 秒不回退。

- Phase 8P 合并回归：LagIsolation、FileSelection、RemainingReview、NavigationModel 共 113/113，0 失败；网格布局最终回归 26/26，0 失败；arm64 Release 与签名 Debug 构建成功。
- 10 万门禁：写入 1.485s、恢复 0.122s、普通搜索 1.35ms、写事务中搜索 1.23ms、交互组合 0.401s；1/1 通过。
- 真实 96,148 文件：新构建单实例下列表单击、网格单击、Inspector 打开三次 3 秒采样的主线程均处于事件等待，无旧实现约 1.1s 的 SwiftUI/AttributeGraph 布局栈；网格首屏与滚动后布局无重叠。
- Phase 8O：Swift parse 通过；LagIsolation、RemainingReview、FileSelection 共 62/62、0 失败；测试构建成功。
- Phase 8O 实机纠偏：强制启动 DerivedData 精确新构建（避免 LaunchServices 路由到 `/Applications` 旧包），真实 96,148 条索引载入；AI 卡片留白截图验收通过；LagIsolation 15/15、Debug build 通过。

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
- Phase 8N：扫描/数据库/编码/选择等聚焦测试 91 项通过（2 项既有发布级大数据门禁跳过），OAuthBridge + OAuthProtocolClient 132/132 通过，arm64 Debug 构建成功；本地 Grok 只读复审提出的 2 个 P1 与 2 个 P2 已全部修复。
- v0.1.0 Universal Release archive 构建通过；Apple 公证任务 `86b10a9e-5658-437e-a333-fdba207a150f` Accepted，DMG staple/validate、Gatekeeper、挂载后深层签名、双架构与 `hdiutil verify` 均通过；最终 SHA-256 为 `6da244e368e2e23bb6ed78593019713d6d31fef0967f3540cbef97825edad90f`。

## 已知边界与下一步

- 仍需人工复核 360/640/960/1200pt、VoiceOver、⌘/⇧多选及真实 Grok 看文件/问文件；真实 AI 会产生请求费用，未自动执行。
- 仍需用旧构建执行一次真实 Sparkle 升级与伪造包拒绝人工验收；本次未自动运行真实 OAuth/AI。
- 需在真实整盘数据上确认首次升级会移除旧系统/敏感索引，单个目录超 10 万时其他目录继续扫描；该验证会触碰用户文件，未自动执行。
