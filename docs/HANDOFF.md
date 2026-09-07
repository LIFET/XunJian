# 项目交接

## 当前状态
寻简0.1.8 build9已正式发布，当前分支main。源码与截图提交9a4f0da，版本标签v0.1.8；发布元数据7a71e81均已推送public。README含搜索阅读、资料集和设置三张隔离原生截图。未替换本机安装版；本地.impeccable设计过程文件未公开、未删除。

## 本轮实现
保留8V–9M全部实现：原生界面、索引状态、窄窗统计、侧栏与文案。查重以隔离文件验证部分失败、撤销及索引恢复；千组列表通过原生无障碍展开/收起和滚动验证。详情见PLANS历史记录。

## 验证
发布回归发现取消轮询重启竞态：登录准备期间禁止重启，登录就绪后恢复；补受控挂起回归。最终`/tmp/XunJian-0.1.8-tests-final.log`568项0失败（4项条件跳过）；独立5万/10万门禁2项通过，Analyze、Runtime、XML/Plist及diff-check通过。9M千组原生交互66项历史证据不重复宣称FPS。

## 发布进度
三架构Archive、签名、公证、staple、DMG/Gatekeeper、挂载版本/架构和官方Runtime验证通过；Accepted任务见PLANS。首轮Universal因Sparkle辅助程序签名被拒，已逐层签名修复；旧包不得分发。正式包在Release/，哈希见docs/RELEASE-0.1.8.md。GitHub三资产digest/size一致，公开链接HTTP200；Pages built且线上appcast与本地逐字节相同，EdDSA通过。公证profile为XunJian-Notary。

## 交付及边界
Debug：`/tmp/XunJian-Theme-Verification/Build/Products/Debug/寻简.app`。未清理用户文件或运行真实OAuth/AI。清理测试只在临时目录模拟废纸篓；交互使用原生无障碍操作，不宣称外部鼠标事件验证。普通宿主曾自动索引，已退出；临时改标识宿主移入废纸篓，临时xctestrun删除。英文全页、完整VoiceOver、跨系统、长时性能未测。既有PDF/OCR/SplitView夹具警告保留，Figma额度耗尽。
