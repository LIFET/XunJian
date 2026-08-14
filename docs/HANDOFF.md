# 项目交接

## 当前项目状态

第三轮（卡顿治理 + 设置页并入主体）已落地并通过离线回归与发布门禁。当前仅为开发工作区，未生成、签名、提交或公证新 DMG。

## 第三轮已完成内容

- **设置页并入主体窗口**：移除独立 `Settings` 场景；设置成为 Sidebar/命令面板/⌘, 菜单的主窗口页面（`NavigationDestination.settings`），`presentsErrors` 在关键窗口呈现；AI 菜单的“打开设置”改走页面导航；外壳通知链超限问题经 `GlobalPresentations` 收容。
- **卡顿治理（主线程）**：`rebuildFileDerivedIndexes` 不再对每个文件做 realpath（`file.path` 已是规范形态，原实现每次索引变更在主线程做 ~20 万次 syscall）；`refreshFiles` 由 O(k·n) 数组手术改为 O(n+k) 双有序归并；`updateCommandTargetFiles` 改为无分配的 zip 短路比较；`onFilesChanged`/分类页选择清理复用维护中的 `allFileIDs`；`IndexStatistics` 的整表 map 移出主线程。
- **卡顿治理（后台与视图）**：所有文件/分类页的 detached 大排序通过取消标志保持至多一个在飞；AI 分类弹窗的名字排序与查询过滤全部移出 body（O(1) body，60ms 防抖）；网格卡片与分类行 hover 状态下沉到行视图，鼠标移动不再整页失效；滚动位置持久化 500ms 合并，不再每次选择写 UserDefaults；正文预览高亮范围按查询预计算，翻动匹配不再重扫全文。
- **基础设施与桥**：正文提取的阻塞 I/O 移入 detached 任务，不再占用协作线程池；`reconcileFiles` 范围查询改为两条常驻、可走索引的语句；`fetchFiles(fileIDs:)`/`fetchFileCategoryLinks(fileIDs:)` 按 900 ID 分块防参数上限；运行时二进制哈希按文件身份（dev/inode/size/mtime）缓存，OAuth 状态轮询不再反复哈希 200MB 二进制；RPC 解码共享单例；stdout/stderr 排空 10ms→空闲 100ms 自适应退避；FSEvents 上下文补 retain/release 回调消除 use-after-free；`waitForExit` 由阻塞 `waitpid` 改为有 5 秒上限的 WNOHANG 轮询，D 状态子进程不再永久卡死桥服务。
- **已明确不做**：SSE 流的有界化（响应量受 Provider 输出约束、弹窗关闭即取消，无实际积压路径）；`FileSelection` 每次按键的 O(n) 索引查找（量级毫秒级，改造收益低于风险）。

## 修改文件

App（AppModel、FileIndexCoordinator、XunJianApp）、Infrastructure（索引、监控）、Views（外壳、侧栏、命令面板、所有文件、分类、AI 弹窗、检查器、设置统计、正文预览、网格组件）、OAuthBridge（JSONLineRPC、SupervisedLineProcess、ManagedRuntimeStore）与回归测试。

## 验证

- arm64 Debug Build：通过。
- 全量离线测试：App 248/248（2 项发布级大数据门禁按设计跳过）、OAuth Process 34/34，0 失败。
- 发布门禁显式启用：5 万文件 1.298 秒、10 万文件 2.794 秒，全部通过。
- `git diff --check` 通过。
- 未运行真实 OAuth、真实 AI、外部网络、签名、公证或 DMG。

## 已知问题与下一步

代码层无已知 P0/P1/P2/P3 阻断。发布前仍需人工验收拖拽、Services、菜单栏窗、VoiceOver、放大字号/Reduce Motion、360/640/1200pt 布局与日期筛选，以及设置页在主体窗口内的完整操作路径；确认源码冻结后再单独执行 Universal Release、签名、公证与 DMG。
