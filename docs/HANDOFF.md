# 项目交接

## 当前项目状态

审查报告 F01–F24、21 项增强功能及复审发现的 P1/P2/P3 已完成源码闭环。当前仅为开发工作区，未生成、签名、提交或公证新 DMG。

## 已完成内容

- 动效遵循 Reduce Motion；语义色、Material、响应式断点、Dynamic Type、日期格式和可访问语义统一。
- AppModel 已拆为文件索引、AI 会话与 OAuth 协调器；AI 弹窗、文件工具栏和 Provider 设置卡片独立。
- 文件列表支持 640pt 可横向滚动的完整表格、多选、批量分类/废纸篓、拖入拖出、键盘操作、保存搜索、历史、过滤、导出与滚动/列偏好恢复。
- 全量/增量扫描读取失败 fail closed；数据库可重建，重叠来源拒绝，跨来源移动保留分类，文件撤销以设备/ inode/类型复验防止误操作替换文件。
- API Key AI 支持瞬时错误重试与 SSE 流式解释/问答；OAuth 安全回退为完整响应；取消会终止消费与底层流。
- Services 使用 `public.file-url`；菜单栏搜索改用 NSStatusItem；重复检测覆盖大文件、完整流式哈希且读取失败不返回部分结果；CSV 导出阻断公式注入。
- 缩略图缓存限额与排队取消、分类标签预构建索引、AI 同数量结果 revision、原生文本 Undo/Select All 快捷键均已修复。
- 文档包按单文件索引；破坏性操作复验文件身份；正文索引改为元数据先落库、正文后台补齐且可一键清除。
- 搜索/保存搜索/菜单栏跳转会清理冲突筛选；页面导出不再误用全库；表格键盘动作、分类批量拖放、Inspector 长文本预览和设置权限状态已补齐。

## 修改文件

App/AppModel、FileIndexCoordinator、AppDelegate；Infrastructure 的索引、文件操作、AI、重复检测；文件/分类/首页/设置/菜单栏/命令与共享组件；导航、OAuth 与审查回归测试；XcodeGen 配置。

## 验证

- arm64 Debug Build：通过。
- 全量离线测试：App 237 项执行；初次发现 2 个用例共 3 条断言失败，修复后对应 2/2 定向复跑通过；2 项发布级大数据门禁按设计跳过。OAuth Process 34/34，通过。
- `git diff --check`、Info.plist、String Catalog：通过。
- 未运行真实 OAuth、真实 AI、外部网络、签名、公证或 DMG。

## 已知问题与下一步

代码层无已知 P0/P1/P2/P3 阻断。发布前仍需人工验收拖拽、Services、菜单栏窗、VoiceOver、放大字号/Reduce Motion 和 360/640/1200pt 布局；确认源码冻结后再单独执行 Universal Release、签名、公证与 DMG。
