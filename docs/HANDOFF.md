# 项目交接

## 当前项目状态

寻简 0.1.2（build 3）已正式发布。源码提交为 `ff7de66`，annotated tag 为 `v0.1.2`；GitHub Release“寻简 0.1.2”已公开，Universal、Apple Silicon、Intel 三份 DMG 均可下载。Sparkle `appcast.xml` 保留 0.1.0，并新增以 Universal DMG 生成及验证的 0.1.2 EdDSA 更新项。

## 已完成内容

- 三种 DMG 均通过 Apple 公证、staple/validate、Gatekeeper 与 `hdiutil verify`。
- 挂载验收确认版本 0.1.2/build 3；Universal App/XPC 为 `x86_64 arm64`，Apple Silicon 为 `arm64`，Intel 为 `x86_64`。
- App 深层签名有效；Sparkle 内嵌代码均为 Team `76V7CQ4T45` 且带时间戳；OpenAI/xAI Runtime 分别为官方 Team `2DC432GLL2`、`5Y6N3AJ54S`。
- Apple Silicon 原任务被 Apple 后端丢失；以同一份哈希稳定的 r2 DMG 受控重提为 `ade197ae-0097-47a0-9440-9cdaf259c2e8`，Accepted 后完成全部门禁。

## 发布文件

- Universal SHA-256：`e7556fefdc46a285fe516a9f2786583dfd276c0d03961ea0fb398938a734c1c7`
- Apple Silicon SHA-256：`f7d5615b679d453b000a82aaae19846436e8e16c6d13ed40f26bfed5db1ab5a6`
- Intel SHA-256：`b081bacb5722ec73ce2db178d6b3313e95bb64c99227f723c4d50dbd4e71f40e`

## 技术决策与边界

- 仅分发公证 DMG；Codex/Grok Runtime 随 App/XPC 内置，不读取用户本机 CLI。
- 未运行真实 OAuth、AI 或付费模型请求。
- 后续仍建议人工验证一次从 0.1.0 经 Sparkle 升级至 0.1.2，以及 VoiceOver、常用窗口宽度和真实文件拖拽。
