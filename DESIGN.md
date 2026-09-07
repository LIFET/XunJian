---
name: "寻简 · Editorial Desk"
description: "原生 macOS 的黑白编辑台：平面结果索引与原位阅读。"
colors:
  accent: "#202124"
  canvas: "#FFFFFF"
  surface: "#F7F8FA"
  selection: "#ECEDEE"
  accent-dark: "#ECEDEF"
  canvas-dark: "#202123"
  surface-dark: "#27282B"
  selection-dark: "#3B3D40"
typography:
  headline:
    fontFamily: "system-ui"
    fontSize: "24pt"
    fontWeight: 600
  title:
    fontFamily: "system-ui"
    fontSize: "14pt"
    fontWeight: 600
  body:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 400
  label:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 500
  caption:
    fontFamily: "system-ui"
    fontSize: "11pt"
    fontWeight: 400
rounded:
  flat: "0pt"
  chip: "6pt"
  icon-control: "7pt"
  control: "8pt"
  card: "10pt"
spacing:
  tight: "4pt"
  row: "10pt"
  section-inner: "12pt"
  page-compact: "16pt"
  page: "24pt"
components:
  icon-button:
    rounded: "{rounded.icon-control}"
    size: "34pt"
  navigation-tab:
    height: "38pt"
  search-field:
    height: "40pt"
  search-field-compact:
    height: "34pt"
  filter-chip:
    backgroundColor: "{colors.selection}"
    rounded: "{rounded.chip}"
    height: "34pt"
    padding: "0pt 10pt"
  result-row:
    rounded: "{rounded.flat}"
    height: "112pt"
  result-row-selected:
    backgroundColor: "{colors.selection}"
    rounded: "{rounded.flat}"
    height: "112pt"
  result-row-selected-dark:
    backgroundColor: "{colors.selection-dark}"
    rounded: "{rounded.flat}"
    height: "112pt"
  collection-row:
    rounded: "{rounded.flat}"
    padding: "0pt 12pt"
  reader-toolbar:
    height: "48pt"
    padding: "0pt 16pt"
---

# Design System: 寻简 · Editorial Desk

## Overview

**Creative North Star: "Editorial Desk · 黑白编辑台"**

同一工作面承载查找、判断与阅读。白、冰灰和石墨构成安静的应用外壳，真实文件内容占据主要视觉面积；结果靠文字、细线与选择状态组织，不靠悬浮卡片组织。

这是已实现的原生 macOS 系统，不是网页或 iPhone 布局。所有尺寸中的 pt 表示 SwiftUI/AppKit 逻辑点，不按 CSS 点数换算；`system-ui` 是原生系统字体的可移植标记，实际由 `Font.system`、`NSFont.systemFont` 与系统中文回退解析。原生窗口、搜索、菜单、表单及文件图标保持平台行为。

**Key Characteristics:**

- 中性色应用外壳，语义状态与真实文件图标保留必要颜色。
- 搜索、选择、原位阅读连续，辅助栏可收起与恢复。
- 下划线导航、平面结果行、原生表单共用清晰的状态层次。

记录依据：`AppVisualTheme.swift`、`XunJianUI.swift`、`AppShellView.swift` 及本文各组件所列源码；批准方向见 `docs/DESIGN-9F.md`。当前浅色、深色、窄窗、设置、资料集截图见 `.impeccable/review/9f-*.png`。它们是有限场景的证据，不代表全产品、所有 macOS 版本或完整辅助功能验收。FORM 未执行 concept-roll 的流程缺项保持原记录，不补造 seed，也不据本文宣称完整流程通过。

## Colors

浅色是白色阅读面与冰灰结果面，深色使用接近的石墨层次；强调色随外观反转，不另设装饰性色。

### Primary

- **石墨强调色**：`accent`／`accent-dark`，用于应用 tint、查询命中下划线与结果选择标记。
- 文字导航默认使用系统 primary／secondary 前景；不能把所有文字替换成固定强调色。

### Neutral

- **阅读面**：`canvas`／`canvas-dark`，承载工作区、阅读外壳与页面背景。
- **索引面**：`surface`／`surface-dark`，区分搜索结果区域与阅读区域。
- **选择底色**：`selection`／`selection-dark`，用于结果选择、筛选条件和资料集悬停。

系统文字、分隔线、控件底色与成功／警告／危险色保留 `NSColor` 或 SwiftUI 语义引用，不提取成固定色值。高对比度结果选择回退到原生绘制，非活动窗口仍保留可辨认的选择。

### Named Rules

**The Quiet Chrome Rule.** 中性色负责应用结构；状态颜色、系统文件图标及原文件内容不受黑白外壳限制。

## Typography

**Body Font:** macOS 系统无衬线字体，中文由系统回退；未引入品牌展示字体。
**Label/Mono Font:** 计数和 PDF 页码使用等宽数字；代码预览使用原生等宽系统字体。

**Character:** 标题层级紧凑，靠字号、字重和主次文字色区分信息，不靠大段空白或装饰性字标。

### Hierarchy

- **Headline**：概览和设置页面标题；搜索工作区不另放大标题。
- **Title**：结果文件名，顶部目的地选中态也使用相同字号与半粗字重。
- **Body**：结果摘要及页面辅助说明。
- **Label**：工具栏文字、阅读区文件名、阅读／信息和设置页签。
- **Caption**：路径、日期、匹配类型、PDF 页码等辅助信息。

未显式指定的 `body`、`headline`、`caption` 等系统文字样式继续由 macOS 决定，不以固定点数强行替换。文本预览采用原生 15pt 字体；PDF 内页排版属于文档，不属于应用字体阶梯。没有从截图猜测行高或字符间距。

### Named Rules

**The Content Boundary Rule.** 应用字体规则止于阅读外壳；PDF 的字体、图片、页色与排版由真实文件决定。

## Layout

`AppShellView` 使用原生 `NavigationSplitView` 与 `inspector`。标题栏承载搜索／资料集／最近，目录是默认隐藏的辅助栏；搜索带在结果与阅读分栏上方，不随阅读区开关消失。侧栏可用宽度为 180–260pt，理想值 212pt；阅读区最小 280pt，宽度上限根据窗口与辅助栏计算，最多 1040pt。批准图的约三分之一／三分之二是方向，不是实现中的固定比例。

搜索带水平内边距 20pt、垂直内边距 12pt，搜索控件采用 frontmatter 的正常／紧凑高度。类型、排序、视图、大小/日期筛选、保存搜索与AI集中在搜索带；小于800pt时类型/排序/视图合并为带分组的原生菜单。结果数量只在底栏显示，活动条件仍可单独清除。保存搜索使用独立命名Sheet，取消不保存。结果行的文件图标为32pt，摘要最多两行，路径与日期位于底部。

共享页面留白使用 `page`／`page-compact`，`pagePadding(for:)` 在内容宽度小于520pt时切换；并非所有页面都调用该函数。资料集概览保留24pt留白、最大内容宽度920pt和24pt标题；设置正文左对齐，最大宽度760pt。设置暂时隐藏资源目录，不改写文件页的展开偏好，顶部目的地可直接返回；macOS15及以上同时隐藏系统目录开关。原生设置分组不按结果列表结构重排。

窗口宽度是原生内容区域测量值。辅助栏在小于 960pt 时自动收起、大于 1020pt 时恢复；阅读区按 1080／1140pt 使用不同收起与恢复阈值，避免边界抖动。手动展开意图在允许宽度内保留；小于 720pt 时阅读入口禁用，并提示需要更宽窗口。窗口小于 1100pt 时阅读区与辅助栏不同时展示。不得把这些值解释为手机／平板断点。

## Elevation & Depth

工作区、结果行和资料集概览默认平面，以背景明度和细分隔线建立层次。`WorkspaceRowSeparator` 是 0.5pt 横线；AppKit 结果行也使用细线分隔，但遵循各自的语义分隔色透明度。

原生菜单、设置分组和命令面板是有意保留的层次，不属于“结果无卡片”的禁用范围。命令面板复用 `xunjianFloatingSurface`：正常透明度下为原生 regular material 与柔和阴影；减少透明度时使用不透明系统底色并取消阴影，增加对比度时加粗边框。它是浮层的实现，不是普通页面背景模板。

### Named Rules

**The Flat Workspace Rule.** 结果索引和资料集概览不用圆角卡片或投影分隔条目；原生表单与临时浮层保持自己的层次。

## Shapes

结果与资料集行是直角连续列表，激活状态采用细线或底色；圆角只属于对应控件、标签、已有分组与浮层。共享图标按钮、筛选标签、控件和分组使用 frontmatter 中各自的半径，不把它们统一成一个大圆角。

窗口外形、交通灯、搜索框轮廓和系统菜单由 macOS 管理，不从批准图提取外窗圆角或重绘系统控件。

## Components

### Buttons

`XunJianIconButtonStyle`：图标为 16pt，布局目标见 `icon-button`。悬停／按下使用 primary 低透明度底色，按下改变透明度而不改变位置；禁用态使用次级前景与降低透明度。选中态使用 accent 透明底色，高对比度时补描边。原生 `Button` 保留键盘激活；不能据此声称所有自定义按钮都有同一种焦点环。

`XunJianToolbarButtonStyle` 为文字标签扩展宽度。原生按钮与 `Menu` 继续使用当前 macOS 样式；不为系统按钮编造固定填色、阴影或像素尺寸。

### Inputs / Fields

`SearchField.swift` 的 `NSSearchField` 提供搜索图标、清除、最近搜索菜单及默认焦点环；正常和紧凑高度取 frontmatter。取消操作先清空非空查询，再退出焦点。设置和筛选表单使用原生输入框、Picker、Toggle，不模拟网页输入控件。

### Navigation

`EditorialNavigationTabs`、阅读／信息页签和设置页签使用文字与 2pt 底部标记表示当前位置，不使用大面积彩色胶囊。顶部未选中目的地为常规字重，选中为半粗；阅读和设置页签采用 label 字重。各处保留选中辅助功能语义。

顶部三个目的地分别保留名称与独立辅助功能标识；父容器不覆盖子项。资源目录采用原生 `List(selection:)` 和 `NavigationLink` 处理选择与方向键，不拦截为其他页面跳转。设置只在窗口工具栏保留一个可见入口，系统菜单和快捷键仍可进入；目录底部仅保留存储概览。

### Chips

`AllFilesView.filterChip`：中性选择底色、紧凑圆角和清除图标。点击删除对应条件，查询保留；不能用胶囊数量或颜色代替明确的筛选文字。

### Results & Collections

`LargeFileTableView.swift` 与 `FileBrowseViewSupport.swift`：固定高度平面结果行；系统文件图标、文件名、摘要、路径、日期和实际匹配类型分层显示。选中行使用中性底色与 2pt 前缘标记；失去窗口焦点仍保留选择，高对比度回退原生选择。查询命中以原生属性文本下划线表示。

`CategoriesView.swift`：资料集概览行最小高度52pt，18pt图标、名称、真实数量和进入箭头横向对齐；悬停使用选择底色。文件网格模式仍是现有浏览能力，不能把默认平面列表推广成禁止所有网格。

### Reader

`FileInspectorEmptyView.swift`：文件名中间截断并提供完整提示；宽度足够时标题和操作同排，空间不足时标题独立一行，阅读／信息、打开菜单与关闭保持完整。未选文件或多选时不显示无效阅读页签。切换阅读内容时沿用现有预览挂载及选择状态。

`DocumentPreviewView.swift`：PDFKit 渲染真实文件；PDF 底栏从 `PDFReadingProgress` 读取当前页与总页数，未知页码不显示假值。正文、代码、图像及不支持格式分别沿用当前原生预览／外部打开路径。不得把演示 PDF 的文字、建筑图或白色纸张改造成应用装饰。

### Settings & Motion

`SettingsView.swift` 使用原生 `Form(.grouped)`；标题、分区与正文位于同一居中内容列（最大760pt），标题和说明采用28pt水平内距与原生表单边缘对齐。分组、菜单、开关和错误状态延续平台语义。

共享反馈为 0.12 秒 ease-out，共享状态过渡为 0.18 秒 ease-out；顶部导航标记另用 0.16 秒 ease-out。减少动态效果时取消这些显式动画。动效服务于悬停、按下和状态变化，不增加循环装饰或布局跳动。

命令面板采用 0.16 秒 ease-out 的透明度过渡，动画只附着在浮层容器，不传递给底下的主内容；沿用减少动态效果与 Escape 关闭行为。

## Do's and Don'ts

### Do:

- **Do** 优先复用原生搜索、菜单、表单、窗口及文件图标，沿用真实键盘与选中语义。
- **Do** 用中性底色、细线、字重与明确文字标记位置和选择，同时保留真实语义颜色。
- **Do** 根据窗口宽度让辅助栏退让，保留可恢复入口与用户明确的展开意图。
- **Do** 从选中文件和当前数据读取正文、数量、路径与 PDF 页码。

### Don't:

- **Don't** 恢复已否决的彩色常驻导航轨、搜索大标题或结果卡片套框。
- **Don't** 将 macOS 逻辑点换成 CSS 尺度，或套用 iPhone 的导航结构、触控目标与字体阶梯。
- **Don't** 把 PDF 示例文字、页数、图片、系统文件图标颜色或旧主题描述提升为品牌 token。
- **Don't** 把平面结果列表规则扩大成禁止原生表单圆角、临时浮层、语义颜色或文件网格。

未规范化：旧 precision／reading 的青色／暖灰说明与当前统一调色板不符，不能继续继承为视觉语言；批准图的 PDF 标题、项目代码与插图属于示例文档，不是应用展示字体、眉题或资产。当前记录不新增设计整改，也不把未覆盖的验证范围写成已保证的系统能力。
