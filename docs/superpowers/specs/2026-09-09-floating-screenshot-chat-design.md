# Peekaboo 悬浮截图会话设计

## 背景与目标

当前 `CaptureAndAskCoordinator` 在截图会话创建后通过 `MainWindowPresenter` 激活应用、显示 Dock，
并把完整会话窗口置前。这会打断用户正在操作的应用。与此同时，助手消息使用
`AttributedString.MarkdownParsingOptions.interpretedSyntax = .inlineOnlyPreservingWhitespace`，只能解析粗体等
行内语法，标题、列表、分割线和代码块会显示为原始 Markdown。

本次改造目标：

1. 用户按 `⌥Q` 完成区域截图后，不跳转主窗口，在选区附近强制显示一个半透明悬浮会话卡片。
2. 卡片复用同一个窗口，展示截图、分析状态、AI 回答和文本追问。
3. 自动展示不抢夺用户当前应用的键盘焦点；用户主动点击输入框后才能输入。
4. 主窗口和悬浮卡统一正确渲染常用块级 Markdown。
5. 截图会话仍持久化到主窗口的历史记录，原有普通会话流程不受影响。

## 范围

### 包含

- 截图快捷键默认值调整为 `⌥Q`，并继续允许用户在设置中修改。
- 新增全局唯一、可复用的截图会话悬浮卡。
- 依据截图选区和当前显示器自动定位，并支持水平拖动。
- 折叠式截图预览、分析进度、回答、错误重试和文本追问。
- 新截图替换悬浮卡当前内容；旧会话仍保留在会话历史中。
- 统一的块级 Markdown 渲染组件。
- 对定位、复用、状态切换、并发切换和 Markdown 解析增加自动化测试。

### 不包含

- 多张悬浮卡同时存在。
- 卡片自由缩放或垂直拖动。
- 在悬浮卡中浏览全部历史会话。
- 语音输入、文件上传、截图标注或 OCR 单独展示。
- 修改 AI Provider、模型选择或会话上下文协议。
- 对普通主窗口进行整体视觉重构。

## 交互设计

### 截图与出现时机

1. 用户按下全局快捷键 `⌥Q`。
2. 完成区域选择和截图后，创建新的“截图分析”会话。
3. 悬浮卡立即出现并展示截图缩略图及“正在分析截图…”；不等待 AI 返回。
4. AI 消息到达时，卡片原位更新并自动滚动到最新回答。
5. 用户可以直接阅读，也可以点击底部输入框继续文本追问。

悬浮卡展示使用 `orderFrontRegardless()`，但不调用 `NSApp.activate`，也不临时显示 Dock。
窗口初次出现时不是键盘焦点窗口。只有用户点击输入控件时，面板才成为 key window。

### 卡片布局

卡片固定宽度为 `460pt`。高度由内容决定，最大值为 `600pt`；在较小屏幕上最大高度为
`visibleFrame.height - 32pt`。主要结构从上到下为：

1. **标题栏**：拖动区域、“截图分析”、当前模型名称、折叠按钮和关闭按钮。
2. **截图预览**：默认折叠为约 `100pt` 高的缩略图，点击后在卡片内展开，再次点击折叠。
3. **会话内容**：展示用户首条分析请求、AI 回答、分析进度或失败提示；超出可用高度时内部滚动。
4. **追问输入**：固定在底部，分析进行中时禁用提交，完成后发送纯文本追问。

半透明效果由原生视觉材质承载，外层使用连续圆角和轻阴影。卡片不依赖 WebView。

### 定位和拖动

展示请求携带 `sessionID`、`CaptureSelection.rect` 和 `displayID`。定位器在对应显示器的
`visibleFrame` 中计算位置：

1. 优先放在选区右侧，间距 `12pt`。
2. 右侧放不下时放到选区左侧。
3. 两侧都放不下时，选择可见面积更大的一侧并把窗口限制在屏幕边距 `16pt` 内。
4. 垂直方向优先让卡片顶部与选区顶部对齐，再限制到可见区域内。

标题栏接收拖动手势，只更新窗口 X 坐标；Y 坐标保持不变。拖动过程中 X 坐标始终限制在当前
显示器 `visibleFrame` 的左右边界内。再次截图时重新依据新选区定位，不沿用旧卡片位置。

### 关闭与复用

- 全局只创建一个悬浮面板实例。
- 点击关闭按钮，或面板获得键盘焦点后按 `Esc`，会隐藏面板但不会删除会话。
- 用户主动隐藏后，本次分析完成不会再次弹出面板。
- 再次按 `⌥Q` 截图时，面板重置为折叠预览、绑定新会话并重新显示。
- 若旧截图仍在分析，则调用现有截图会话取消能力停止旧任务，再启动新会话；旧会话保留取消状态。

## 架构设计

### 展示边界

用截图专用展示协议替代截图链路对 `MainWindowPresenting` 的依赖：

```swift
struct ScreenshotPresentationContext: Equatable, Sendable {
    let sessionID: String
    let selectionRect: CGRect
    let displayID: CGDirectDisplayID
}

@MainActor
protocol ScreenshotConversationPresenting: AnyObject {
    func present(_ context: ScreenshotPresentationContext)
    func dismiss()
}
```

`CaptureAndAskCoordinator` 仍负责权限、选区、截图、会话创建和分析编排，但把完整展示上下文传给
新的 presenter。普通主窗口继续由现有窗口入口独立管理。

### 悬浮面板

新增 `FloatingScreenshotChatPanelController`：

- 持有唯一的 `NSPanel` 和 `NSHostingView`。
- `NSPanel` 使用非激活面板风格，允许在需要输入时成为 key window。
- 面板层级为 `.floating`，`collectionBehavior` 支持当前 Space 和全屏辅助展示。
- 负责 show/hide、会话切换、屏幕定位、水平拖动和 `Esc` 处理。
- 不负责读取截图、发送消息或解释业务状态。

窗口位置计算提取为无 UI 依赖的 `FloatingPanelPlacement`，输入选区、屏幕可见区域、窗口尺寸和
边距，输出窗口原点，便于单元测试覆盖多显示器与边界场景。

### SwiftUI 内容

新增 `FloatingScreenshotChatView`，复用现有环境对象：

- `SessionStore`：通过当前悬浮 `sessionID` 获取会话及消息。
- `ScreenshotConversationService`：读取截图、查询状态、重试、取消和发送追问。
- `PeekabooSettings`：展示当前配置和保持现有 Agent 行为。

视图内部拆分为小组件：

- `CollapsibleScreenshotPreview`
- `ScreenshotConversationMessages`
- `ScreenshotConversationProgress`
- `ScreenshotConversationErrorBanner`
- `ScreenshotFollowUpComposer`

主窗口现有 `ScreenshotPreviewCard` 和错误提示可迁移为共享组件，避免主窗口与悬浮卡产生两套
状态判断和重试逻辑。

### 状态与并发

`CaptureAndAskCoordinator` 增加当前分析会话和分析任务的显式跟踪：

- 区域选择阶段继续防止快捷键重入。
- 分析阶段允许发起新截图。
- 新截图会话创建后，取消上一个仍在运行的截图分析，并把 presenter 切换到新会话。
- 旧任务晚到的完成或失败不能改变新会话的悬浮卡状态。
- 悬浮卡直接观察 `ScreenshotConversationService` 和 `SessionStore` 中按 session 隔离的状态，
  不复制消息数据。

## Markdown 渲染

### 根因

当前 `AssistantMessageContent` 把完整回答交给 `AttributedString` 的 inline-only 模式，因而块级
标记不会生成布局结构。简单地换成完整模式仍无法让单个 `Text` 完整呈现列表缩进、分割线和
代码块背景。

### 方案

在 Mac App target 中直接引入 Apple `swift-markdown`，新增 `MarkdownMessageView`：

1. 用 `Markdown.Document` 解析内容为语法树。
2. 按块生成原生 SwiftUI 视图，而不是 WebView 或 HTML。
3. 第一阶段明确支持：段落、1–6 级标题、有序/无序列表、分割线、引用、围栏代码块、行内代码、
   粗体、斜体和链接。
4. 普通文本和无法识别的节点必须保留原始内容，不能静默丢字。
5. 代码块使用等宽字体、轻背景和横向滚动；普通段落允许换行和文本选择。
6. `AssistantMessageContent` 与悬浮卡消息列表共同调用该组件，保证两处显示一致。

渲染器把 Markdown 语法树转换为可测试的轻量显示模型，再由 SwiftUI 映射为视图。解析和样式
分离后，可以用单元测试验证块顺序、列表编号和纯文本回退，而不依赖 UI 截图测试。

## 数据流

```text
⌥Q
  → CaptureSelectionController 返回 rect/displayID
  → ScreenCaptureService 截图
  → ScreenshotConversationService 创建并持久化会话
  → FloatingScreenshotChatPanelController 绑定会话并立即显示
  → ScreenshotConversationService 异步分析
  → SessionStore 追加/更新消息
  → FloatingScreenshotChatView 自动刷新和滚动
  → 用户文本追问
  → ScreenshotConversationService.sendFollowUp
  → 同一会话追加回答，不重新携带截图
```

## 错误处理

- **无屏幕录制权限**：保留现有系统提示和打开设置入口；未创建会话时不显示空卡片。
- **选区取消**：回到空闲状态，不显示卡片。
- **截图或会话创建失败**：使用现有明确错误提示，不改变当前已显示卡片。
- **AI 分析失败**：卡片内展示错误原因和“重试”，保留截图及会话，不弹模态窗口。
- **截图文件丢失**：显示“原截图已丢失，请重新截图”，禁用追问。
- **Provider/鉴权错误**：展示服务返回的可读错误，重试复用当前截图会话。
- **新截图取消旧分析**：旧会话记录取消状态，不把取消错误显示到新卡片。
- **Markdown 解析失败**：回退到原始纯文本，保证内容可读。

## 预计代码影响

- `Apps/Mac/Package.swift`：增加 `swift-markdown` 依赖。
- `Apps/Mac/Peekaboo/Core/KeyboardShortcutNames.swift`：默认快捷键改为 `⌥Q`。
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureAndAskCoordinator.swift`：传递展示上下文并管理最新分析。
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/MainWindowPresenter.swift`：截图链路不再依赖该 presenter；普通主窗口行为保留。
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanelController.swift`：新增唯一面板及窗口行为。
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingPanelPlacement.swift`：新增纯定位算法。
- `Apps/Mac/Peekaboo/Features/ScreenshotConversation/*`：新增悬浮卡和可共享截图会话组件。
- `Apps/Mac/Peekaboo/Features/Main/MessageComponents/MarkdownMessageView.swift`：新增块级 Markdown 渲染器。
- `Apps/Mac/Peekaboo/Features/Main/MessageComponents/MessageContentView.swift`：统一使用新渲染器。
- `Apps/Mac/Peekaboo/PeekabooApp.swift`：组装并持有悬浮 presenter。
- 对应 `Apps/Mac/PeekabooTests`：新增和调整单元测试。

具体文件拆分可在实施中根据现有 SwiftFormat 和单文件职责微调，但不得改变上述边界。

## 测试策略

### 自动化测试

1. `CaptureAndAskCoordinatorTests`
   - 展示事件发生在分析开始之前。
   - 展示上下文完整携带 session、rect 和 displayID。
   - 新截图取消旧分析，旧任务结果不会覆盖新状态。
   - 选区取消、权限失败和截图失败不错误显示卡片。
2. `FloatingPanelPlacementTests`
   - 右侧优先、右侧不足回退左侧。
   - 两侧均不足时保持在 visible frame 内。
   - 顶部、底部、菜单栏、Dock 和多显示器坐标边界。
   - 水平拖动保持 Y 不变并限制 X。
3. `FloatingScreenshotChatPanelControllerTests`
   - 多次展示只创建一个面板。
   - 切换会话会重置截图折叠状态并重新定位。
   - 手动关闭后当前分析完成不会重新显示。
   - 自动展示不会调用应用激活或 Dock 显示。
4. `MarkdownMessageViewTests`
   - 标题、列表、分割线、代码块和行内样式被解析为正确显示模型。
   - 混合中英文、空行和长代码不丢失内容。
   - 非法 Markdown 回退后仍保留原始文字。

### 本机验收

1. 在浏览器、微信和终端中分别按 `⌥Q`，确认截图后原应用仍保持焦点。
2. 分别截取屏幕左、中、右区域，确认卡片定位正确且未越界。
3. 左右拖动卡片，确认 Y 坐标不变；重新截图后按新选区重新定位。
4. 连续快速截取两张图，确认只存在一个卡片且最终展示第二张图。
5. 展开、折叠截图，发送两轮纯文本追问，确认不会再次上传截图。
6. 使用包含标题、列表、分割线、代码块、粗体和链接的回答验证两处 Markdown 显示一致。
7. 模拟无效 API Key、断网和服务限流，确认卡片内可读报错与重试行为。

### 交付门禁

- 运行 Mac App 相关 Swift 测试。
- 运行 `pnpm run lint` 和 `pnpm run format`。
- 运行 `pnpm run test:safe`；若环境限制导致无法运行，记录具体限制并至少完成相关定向测试。
- 远程构建产出可运行的未签名或开发签名 App/DMG，并在目标 Mac 上完成上述本机验收。

## 验收标准

- `⌥Q` 截图后，悬浮卡在截图附近可见，原应用不被强制切走。
- 卡片固定宽度、最大高度受限，能水平拖动且不会离开当前屏幕。
- 任意时刻只有一个截图悬浮卡；新截图正确替换内容并隔离旧任务结果。
- 截图默认折叠，能够展开；分析状态、错误、重试和追问均可在卡片内完成。
- 后续追问属于同一会话且不重复携带截图。
- 主窗口与悬浮卡正确渲染约定的 Markdown，不再展示原始标题和列表标记。
- 原有会话历史、模型配置、Provider 配置及普通主窗口行为保持可用。
