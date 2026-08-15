# 寻简 XunJian

<p align="center">
  <img src="XunJian/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="128" alt="寻简图标">
</p>

<p align="center">
  面向 macOS 的本地文件检索、分类与 AI 辅助整理工具。
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-2ea44f">
</p>

> **项目状态：积极开发中。** 当前代码适合本地构建和测试，尚未发布正式签名安装包。请勿把 Debug 构建当作稳定版本分发。

## 为什么做寻简

文件越多，Finder 的层级目录越难回答“那份合同在哪里”“最近修改的表格有哪些”“这些资料应该归到哪一类”。寻简把文件索引、全文搜索、人工分类与可选 AI 能力放在一个原生 macOS 应用中，同时坚持本地优先：搜索、筛选、分类和索引数据库都保存在用户自己的 Mac 上。

## 主要功能

- **本地文件索引**：扫描用户明确授权的文件夹，支持隐藏文件策略、增量刷新和失败恢复。
- **整台 Mac 扫描**：高级模式按受控范围分批扫描，可暂停、继续和断点恢复；不可访问的系统与隐私位置会跳过并明确提示。
- **快速检索**：文件名、路径、分类与可提取正文全文搜索，支持类型、日期和排序筛选。
- **列表与网格浏览**：多选、键盘操作、快速查看、Finder 定位、重命名、移动和移到废纸篓。
- **自定义分类**：文件可关联多个分类，支持拖放、批量操作与 AI 建议后的人工确认。
- **AI 文件理解**：结构化“看文件”、带片段依据的连续“问文件”、自然语言搜索和批量分类。
- **多种认证方式**：Codex/ChatGPT 与 Grok 使用应用专属 OAuth；DeepSeek、Qwen 等兼容 Provider 使用用户自己的 API Key。
- **在线更新基础设施**：已接入 Sparkle 2，并使用公开 HTTPS [appcast](https://lifet.github.io/XunJian/appcast.xml)；正式发布仍需签名更新包并完成公证验证。

## 隐私与安全

- 文件索引数据库保存在本机，寻简不会上传整个文件库。
- AI 功能只在用户主动触发时调用当前 Provider。
- AI 分类默认只发送文件名和类型；发送可提取正文必须由用户显式开启。
- “看文件”和“问文件”不会发送文件路径，并对正文实施 UTF-8 字节上限。
- OAuth Runtime、会话目录和凭据与用户全局 CLI 环境隔离。
- 本地 API Key 文件使用受控目录、严格权限、原子写入并拒绝符号链接。

详细安全边界与人工验收步骤见 [docs/MANUAL_ACCEPTANCE.md](docs/MANUAL_ACCEPTANCE.md)。

## 环境要求

- Apple silicon 或 Intel Mac
- macOS 14 或更高版本
- Xcode 26 或兼容的 Swift 6 工具链
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+
- [Git LFS](https://git-lfs.com/)

## 本地构建

```bash
git clone https://github.com/LIFET/XunJian.git
cd XunJian
git lfs pull
xcodegen generate
open XunJian.xcodeproj
```

首次打开项目时，Xcode 会解析固定版本的 Sparkle 依赖。请选择 `XunJian` Scheme，在 macOS 目标上运行。

也可以从命令行构建：

```bash
xcodebuild build \
  -project XunJian.xcodeproj \
  -scheme XunJian \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64'
```

## 测试

```bash
xcodebuild test \
  -project XunJian.xcodeproj \
  -scheme XunJian \
  -destination 'platform=macOS,arch=arm64'
```

真实 OAuth、AI 请求、Developer ID 签名、公证和更新安装不会由普通离线测试自动执行。

## 项目结构

```text
XunJian/                    SwiftUI 主应用
XunJianOAuthBridge/         隔离的 OAuth / AI Runtime XPC
XunJianTests/               应用、索引、协议与安全回归测试
docs/                       计划、交接和人工验收文档
project.yml                 XcodeGen 工程定义
```

## 第三方 Runtime

仓库通过 Git LFS 保存固定版本的官方 Codex App Server 与 Grok Build Runtime，以便应用内 OAuth 与模型请求不依赖用户预装 CLI。应用运行前会校验固定 SHA-256、Developer ID、Team ID、文件类型和权限。

这些 Runtime 不属于寻简项目本身，其许可证和完整第三方声明见 [OAuthRuntimeNOTICE.txt](XunJian/Resources/OAuthRuntimeNOTICE.txt)。使用相关服务时还应遵守对应服务提供方的条款。

## 贡献

欢迎提交 Issue 和 Pull Request。提交前请：

1. 保持修改范围集中，不提交凭据、个人路径、构建产物或用户数据。
2. 为行为变化补充回归测试。
3. 确认 Debug 构建和相关测试通过。
4. 不替换固定 Runtime 或放宽 OAuth/文件安全校验，除非同时提供供应链证据和完整验收。

## 许可证

寻简自身源码采用 [MIT License](LICENSE)。第三方组件、官方 Runtime 和品牌分别遵循其原始许可证与条款。
