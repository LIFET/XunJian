# 项目交接

## 当前项目状态

寻简 0.1.6（build 7）修复版三架构 DMG 已完成 Apple 公证、staple、Gatekeeper、挂载复验并替换到 GitHub Release；Universal Sparkle 更新包已重新签名并上线。

## 已完成内容

- 全局滚动条改为应用内原生 overlay 小尺寸样式，覆盖主窗口、设置、详情、菜单栏及大文件视图，不修改系统偏好；移除每次布局都递归遍历视图树的开销。
- 菜单栏偏好与语言通知统一切回主 RunLoop，关闭后台 UserDefaults 通知触发 Swift 6 actor 隔离断言的崩溃路径。
- SQLite 建库、打开和迁移移出 MainActor；启动状态区分“正在打开 / 可用 / 失败”，只在真实失败时显示重试，并以 generation 丢弃取消或重试后的迟到结果。
## 验证与边界

- 主工程 406 项执行、2 项大型门禁跳过、0 失败；OAuth Process 38 项、0 失败。
- 5 万/10 万门禁 2/2 通过，分别 0.831s / 4.129s。
- `xcodebuild analyze`、`xmllint`、`plutil`、`git diff --check` 通过；仅有 macOS 测试宿主 `linkd` 环境噪声。
- 三架构 DMG 均通过 0.1.6/build 7、App/XPC 精确架构、深层签名、Sparkle Team/时间戳、OpenAI/xAI 官方 Runtime 签名、`hdiutil verify`、Apple 公证、staple 与 Gatekeeper。
- 未运行真实 OAuth、AI 或付费请求；真实 UI、VoiceOver 与系统集成项仍以 `docs/MANUAL_ACCEPTANCE.md` 为准。

## 下一步

0.1.6 正式发布已完成；后续开发从下一版本号与 build 号继续。
