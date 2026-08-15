# 项目交接

## 当前项目状态

Phase 8 的代码实现与离线验收已完成；未生成 DMG、未运行真实 OAuth/AI。Sparkle 私钥已存登录钥匙串，公钥已接入，appcast 由 GitHub Pages 托管。

## 已完成内容

- 所有文件：Table 单一选择链路、网格局部选中更新、Inspector 动画期间稳定视图树；正文与 Finder 标签使用 16 项有界缓存，取消和文件身份变更不会回写旧内容。
- AI：OAuth 字节预算、结构化“看文件”、本地片段检索与引用、多轮“问文件”；分类支持全部文件类型、最多 50 个文件分批、置信度/理由、逐项编辑/跳过、本地兜底、应用后撤销。分类默认只发送文件名与类型，正文需用户显式开启。
- 扫描：设置可切换指定文件夹/整台 Mac，授权数据彼此保留；全盘按顶层 scope 分批提交、检查点续扫、暂停/继续、失败范围保留，排除系统基础设施与高风险隐私目录，禁用根目录 FSEvents 风暴。两种模式索引共存但只展示当前模式。
- 更新：固定 Sparkle 2.9.5；feed 为 `https://lifet.github.io/XunJian/appcast.xml`，密钥账户为 `com.xingmingbo.XunJian`，私钥未导出。

## 验证

- App 测试 305 项（2 项默认跳过）、OAuth Process 37 项，0 失败；OAuthBridge 62/62、OAuthProtocol 64/64。
- 显式 5 万/10 万门禁 2/2；10 万：写入 1.383s、恢复 0.109s、搜索 0.0013s、筛选和五种排序 0.399s。
- arm64 Debug 构建、`git diff --check`、Info.plist、entitlements、String Catalog 均通过。

## 已知边界与下一步

- 首个签名发布前仍需验证升级、伪造包拒绝和失败恢复。
- 此前用户看到的 Debug App 早于本轮构建；目前 App 未运行。下次须启动新产物再人工验证选中/Inspector、整机扫描与真实 OAuth；真实 AI 会产生请求费用，不自动执行。
