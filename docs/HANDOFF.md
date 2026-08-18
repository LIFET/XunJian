# 项目交接

## 当前项目状态

寻简 0.1.3（build 4）正在正式发布。源码提交 `9b49c425ef81` 已推送 `main`。Universal 与 Intel 已完成 Apple 公证、装订和门禁；Apple Silicon 公证仍由 Apple 处理。Sparkle 使用已公证 Universal DMG，`appcast.xml` 保留 0.1.2 与 0.1.0。

## 已完成内容

- 修正设置页、详情栏、内容预览、滚动区域和窄窗口菜单布局。
- OAuth 登录后通过受限 XPC 加载账号可用模型，支持选择、独立持久化并用于后续 OAuth AI 请求。
- 三种 DMG 均为 0.1.3/build 4；Universal App/XPC 为 `x86_64 arm64`，Apple Silicon 为 `arm64`，Intel 为 `x86_64`。
- App 深层签名有效；Sparkle Team 为 `76V7CQ4T45` 且带时间戳；OpenAI/xAI Runtime 分别为官方 Team `2DC432GLL2`、`5Y6N3AJ54S`。
- Universal 公证 `7e0710b9-acb7-44fb-8623-b9a75b6f653a`、Intel 公证 `d106676e-e892-4011-b3a8-7e7dd6bafeb8` 均 Accepted，并通过 staple/validate、Gatekeeper 与 `hdiutil verify`。

## 发布文件

- Universal SHA-256：`60006e99a129757f6b31027f0f21ff6860b078efdf25569407cf541d0ac560b7`
- Intel SHA-256：`f9d1c4924c447a2d688b250af6506cb23a9a695c712d2956ed9caca620b5694c`
- Apple Silicon 公证 `8f71a39c-5d97-4619-8145-fbcd5f56a5cf` 仍为 In Progress；完成装订后补资产与最终 SHA-256。

## 边界与下一步

- 只公开已公证 DMG；Apple Silicon 完成后装订、复验并补上传。
- 未运行真实 OAuth、AI 或付费模型请求。
