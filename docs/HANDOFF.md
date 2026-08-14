# 项目交接

## 当前项目状态

全面优化审查后的第二轮修复（H1–H3、M1–M13、L1–L28）已落地并通过离线回归与发布门禁。当前仅为开发工作区，未生成、签名、提交或公证新 DMG。

## 本轮已完成内容

- **SQL 与索引热路径**：`rebuildSearchEntry` 改为整批 3 条语句 prepare 一次、逐行 reset 重绑定（H1）；搜索去掉二级 ORDER BY 以恢复 FTS5 rank 流式、仅页满时才跑 COUNT 并在 Swift 内做相关性并列排序（M2）；DB 打开补 `busy_timeout`，`replaceFiles` 大事务后 `wal_checkpoint(TRUNCATE)` + `PRAGMA optimize`（L22）；`removeMissingFiles` 的逐行 stat 移出 DB actor 到 detached 任务（M1）。
- **内存模型增量更新（H2）**：DB 新增 `fetchFiles(fileIDs:)`、`fetchFileCategoryLinks(fileIDs:)`；`reconcileFiles`/`removeMissingFiles` 返回被移除的 ID 集合；协调器新增 `refreshFiles/refreshLinks/refreshCategories/refreshSources`，FSEvents 调和、单文件移动、分类增删改、AI 分类、来源添加/重授权/启停均不再整表重读；`reloadIndex` 以批处理标志合并派生索引重建；recentFiles 改为 O(n) 前 8 部分选择，分类/文件双 by-ID 缓存供 O(1) 查询。
- **扫描与提取**：`enumerate`/`scanChanges` 去掉第二份排序副本（M3）；正文提取以 4 路有界 TaskGroup 并发且保持 64 条批量写库与取消（M4）；进度回调加 200ms 时间下限，减少主线程跳转（L2）；重复文件检测按组 4 路并发哈希、阻塞读移入 detached（M5）；FSEvents 去掉 NoDefer 恢复内核 250ms 批处理（L19）。
- **App 层**：菜单栏/命令面板的 detached 全索引扫描可通过取消标志提前中止（M9）；拖入文件按 canonical 路径字典 O(1) 命中（M10）；DB 故障挂起同时取消分类 drain 并清空 pending（L1）；批量废纸篓单遍 canonical 化（L3）；手动过滤持久化改为 400ms 防抖 + 退场立即落盘（L4）；OAuth 等待者以 WaiterBox 支持取消回收（L5）；设置索引统计在扫描期间跳过、扫描结束补算（L7）；`selectedFile`/`selectedFiles` 走 by-ID 缓存（M8）。
- **Views 层**：AI 分类弹窗按 filesRevision 缓存名字序、每 body 只做选中置顶稳定分区（H3）；分类页搜索 120ms 防抖并复用已算 ID 集（M6）；所有文件工具栏行与更多菜单按字号缩放（M7）；Inspector Finder 标签读取移出主线程（M13）；补上重复组图标按钮无障碍标签、搜索历史删除按钮非 hover 时禁用并移出无障碍树、AI 弹窗自动聚焦、⌘1/⌘2 在无列表页自动落到所有文件、扫描位置开关无障碍标签、废纸篓撤销横幅延长至 12 秒、AI 结果空态明确化、圆角/语义色统一到 Token、字节格式化缓存（L8–L16、L18）。
- **OAuthBridge**：每次 AI 生成不再双重哈希运行时二进制，先 restore 有效 proof 短路（M11）；JSON 行解码前线性嵌套深度预检（M12）；Grok usage 求和改溢出安全减法（L24）；Codex 验证模型缺失时回退到官方目录首个模型（L25）；崩溃遗留的 proof 临时文件自动清扫（L26）；进程排空循环的全系统 pid 扫描降至最多每 100ms 一次（L27）。
- **已明确不做**：L17（AI 搜索过滤每 body 重建 ≤500 元素集合，由分页天然有界）；L23（跳过 realpath 会破坏 FSEvents 物理路径与逻辑路径的身份对齐）；L28/JSONLineFramer 移除（测试直接覆盖该结构，保留）。

## 修改文件

App（AppModel、FileIndexCoordinator、OAuthCoordinator、QuickSearchMatching）、Infrastructure（索引、监控、重复检测、Finder 标签、文件操作、文本提取）、Views（AI 弹窗、外壳、分类、命令面板、文件浏览/工具栏/检查器/搜索框、导出、所有文件、首页、设置、存储洞察、菜单栏搜索、命令）、OAuthBridge（main、JSONLineRPC、SupervisedLineProcess、GrokACPClient）与回归测试。

## 验证

- arm64 Debug Build：通过。
- 全量离线测试：App 248/248（2 项发布级大数据门禁按设计跳过）、OAuth Process 34/34，0 失败。
- 发布门禁显式启用：5 万文件 1.019 秒、10 万文件 3.311 秒，全部通过。
- `git diff --check` 通过。
- 未运行真实 OAuth、真实 AI、外部网络、签名、公证或 DMG。

## 已知问题与下一步

代码层无已知 P0/P1/P2/P3 阻断。发布前仍需人工验收拖拽、Services、菜单栏窗、VoiceOver、放大字号/Reduce Motion、360/640/1200pt 布局与日期筛选；确认源码冻结后再单独执行 Universal Release、签名、公证与 DMG。
