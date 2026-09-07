# 项目交接

## 当前状态
寻简0.1.8 build9已正式发布，当前分支main。源码与截图提交9a4f0da，版本标签v0.1.8；发布元数据7a71e81均已推送public。README含搜索阅读、资料集和设置三张隔离原生截图。未替换本机安装版；本地.impeccable设计过程文件未公开、未删除。

## 本轮实现
StorageInsightsView统计去掉重复单位，保留完整数字宽度，横向不足时纵排；复用统计组件做窄窗截图。FileIndexCoordinator增加默认FileOperationService注入以验证隔离清理。真实协调器、SQLite、临时文件移动及撤销测试覆盖第二文件失败、同时刷新索引后恢复一致。
本次续办仅完善ThemeLayoutSnapshotTests原生验收：SwiftUI无障碍节点不声明协议，改为调用其实际公开ObjC方法；展开/收起断言0→1→0，五次滚动后再次验证。截图确认三条文件和操作按钮。保留9L统计刷新不丢结果、清理状态保护、空态时序及设置整理，以及9K原生侧栏和9J文案。

## 验证
发布回归发现取消轮询重启竞态：登录准备期间禁止重启，登录就绪后恢复；补受控挂起回归。最终`/tmp/XunJian-0.1.8-tests-final.log`568项0失败（4项条件跳过）；独立5万/10万门禁2项通过，Analyze、Runtime、XML/Plist及diff-check通过。9M千组原生交互66项历史证据不重复宣称FPS。

## 发布进度
三架构Archive、签名、公证、staple、DMG/Gatekeeper、挂载版本/架构和官方Runtime验证通过。Accepted任务：Universal dcf88480-82c5-4bec-b035-f96a20e60b63；arm64 8452b32b-ace8-4842-929f-0832471a6b09；Intel e6dbc7e4-900d-47f7-bf12-87fc363e0a10。首轮Universal因Sparkle辅助程序签名被拒，已用逐层签名修复包替代；旧包不得分发。正式包在Release/，哈希见docs/RELEASE-0.1.8.md。GitHub三资产digest/size一致，公开链接HTTP200；Pages built且线上appcast与本地逐字节相同，EdDSA验证通过。公证profile为XunJian-Notary，不读取凭据正文。

## 交付及边界
Debug：`/tmp/XunJian-Theme-Verification/Build/Products/Debug/寻简.app`。未清理用户文件或运行真实OAuth/AI。清理测试只在临时目录模拟废纸篓；交互使用原生无障碍操作，不宣称外部鼠标事件验证。普通宿主曾自动索引，已退出；临时改标识宿主移入废纸篓，临时xctestrun删除。英文全页、完整VoiceOver、跨系统、长时性能未测。既有PDF/OCR/SplitView夹具警告保留，Figma额度耗尽。
