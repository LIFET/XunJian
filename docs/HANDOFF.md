# 项目交接

## 当前状态
寻简0.1.8 build9，分支`codex/reliability-audit-fixes`。用户授权将8V–9M累积实现提交、推送和发布。README加入三张隔离原生截图。源码验收通过，三架构公证发布进行中，未替换安装版。

## 本轮实现
StorageInsightsView统计去掉重复单位，保留完整数字宽度，横向不足时纵排；复用统计组件做窄窗截图。FileIndexCoordinator增加默认FileOperationService注入以验证隔离清理。真实协调器、SQLite、临时文件移动及撤销测试覆盖第二文件失败、同时刷新索引后恢复一致。
本次续办仅完善ThemeLayoutSnapshotTests原生验收：SwiftUI无障碍节点不声明协议，改为调用其实际公开ObjC方法；展开/收起断言0→1→0，五次滚动后再次验证。截图确认三条文件和操作按钮。保留9L统计刷新不丢结果、清理状态保护、空态时序及设置整理，以及9K原生侧栏和9J文案。

## 验证
发布回归发现取消轮询重启竞态：登录准备期间禁止重启，登录就绪后恢复；补受控挂起回归。最终`/tmp/XunJian-0.1.8-tests-final.log`568项0失败（4项条件跳过）；独立5万/10万门禁2项通过，Analyze、Runtime、XML/Plist及diff-check通过。9M千组原生交互66项历史证据不重复宣称FPS。

## 发布进度
Universal首轮公证9a92edab-5847-4528-aeda-dd0367db5d63为Invalid：Sparkle四个辅助程序缺少Developer ID和时间戳。新增scripts/sign-release-app.sh逐层签名校验；修复包用macOS-r2.dmg，不能发布旧包。Universal和arm64 Archive通过，Intel进行中。公证使用历史Keychain profile XunJian-Notary，不读取凭据正文。正式包位于Release/.staging-0.1.8，最终公证ID和校验值待补。

## 交付及边界
Debug：`/tmp/XunJian-Theme-Verification/Build/Products/Debug/寻简.app`。未清理用户文件或运行真实OAuth/AI。清理测试只在临时目录模拟废纸篓；交互使用原生无障碍操作，不宣称外部鼠标事件验证。普通宿主曾自动索引，已退出；临时改标识宿主移入废纸篓，临时xctestrun删除。英文全页、完整VoiceOver、跨系统、长时性能未测。既有PDF/OCR/SplitView夹具警告保留，Figma额度耗尽。
