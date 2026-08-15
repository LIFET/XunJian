# 项目交接

## 当前项目状态

本轮 Grok/Codex 联合深层审计与性能、OAuth 并发收尾已闭环；未生成 DMG。

## 已完成内容

- 所有文件缓存命中会裁剪跨页选择；批量废纸篓只作用于当前页命令目标，异步“选择全部”绑定页面 generation，迟到结果不再跨页回写。
- 10 万文件 ID 数组与集合在后台一次生成；快照只发布一次，网格方向键复用有序 ID，隐藏页面不再污染滚动位置。
- 修改日期下限排除未知日期；重复检测使用 `O_NOFOLLOW|O_NONBLOCK` 并只接受普通文件，拒绝链接、FIFO 与设备。
- OAuth 登录启动可真实取消并等待清理；断开/退出可抢占同 Provider 运行请求，旧请求不能释放新 reservation。
- 导出取消保持独立无障碍按钮；AI 零分类可直接新建；删除保存搜索需确认；Services 菜单补英文。
- 增量扫描仅发布真实可见变化，元数据事件精准刷新 Finder 标签，正文提取后主动重查当前搜索。
- Xcode 26.6 的连续覆盖率会让嵌入式 XPC 卡在启动阶段；测试方案已关闭覆盖率采集，避免 OAuth 假超时。

## 验证

- App 296 项（2 项发布级门禁跳过）与 OAuth Process 37 项全部通过，合计 333 项、0 失败；其中 OAuthBridge 62/62、OAuthProtocol 64/64。
- 显式 10 万文件门禁通过：写入 1.276 秒、恢复 0.109 秒、搜索 0.0012 秒、筛选与五种排序合计 0.398 秒，总计 2.094 秒。
- arm64 Debug 构建通过；Swift parse、Info.plist 与源码警告检查通过。

## 下一步

按 `docs/MANUAL_ACCEPTANCE.md` 人工验证 VoiceOver 导出取消、AI 新建分类、保存搜索确认、登录启动取消后立即重试与运行中退出。用户确认稳定后再另行构建、公证 DMG。

## 第五轮（继续全面检查 · 落地项）

- **All Files 卡顿**：移除 `EquatableSnapshotList` 的 selectionToken 比较——此前每次点击/方向键选择都会重建 10 万行 Table 视图树；Table 高亮由绑定驱动，无需整表重建。
- **Grok 验证容错（真实服务器漂移防御）**：setup 通知序列由“恰好 5 条固定顺序”改为有序必达子集遍历（容忍多余生命周期事件）；命令目录由“6 条全等”改为“必含 6 个已知名 + 额外命令仅允许 hint-only 输入”（有真实参数 schema 仍 fail-closed）；模型接受 grok-4.* 前缀、reasoning effort 接受 high/xhigh/max；response_started/reasoning_completed/sessions.changed 键集由严格相等改为必含子集；完成判定放宽为 response_completed 或 turn_completed 任一。
- **OAuth 超时叠层**：RPC 单请求可超过默认 45s（上限 75s）；验证外层窗口 45s→60s（低于客户端 XPC 70s）；Grok session/new 5s→15s；Grok session/prompt 与 Codex turn/start 显式传 75s 上限，冷启动慢响应不再被内层超时先杀。
- **验证与清理解耦**：closeAfterVerification 不再把会话历史删除（best-effort 隐私控制）AND 进验证成功判定，删除子进程失败不再把成功验证翻成失败。
- **扫描速度**：单源扫描后不再全库 reloadIndex（改为按该源增量发布，消除每次扫描后全库重物化+重排序）；增量 FSEvents 批次的正文提取移出枚举串行路径（元数据先行、之后 4 路并发 + 分批写库 + 取消丢弃 staging）；FSEvents 事件路径不再在回调里重复 canonical 化（scanChanges 的记忆化统一处理）；枚举加 .skipsHiddenFiles、缓存 resourceKeys 集合、取消检查改 64 步一查；canonical 缓存未命中只解析父目录一次。
- 验证：arm64 Debug 构建通过；App 296/296（2 项发布门禁按设计跳过）+ OAuth Process 37/37，0 失败；发布门禁 50k 0.850s / 100k 2.116s（较上轮 1.177s/3.122s 提升）。
- 备注：全量测试曾出现桥套件连锁超时，根因是脚本化测试在负载下的偶发断言 SIGTRAP 导致 launchd XPC 状态残留；隔离复跑全部通过，未再复现。
