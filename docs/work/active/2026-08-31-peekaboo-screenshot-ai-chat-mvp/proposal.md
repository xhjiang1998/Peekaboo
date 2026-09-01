---
summary: 'Define the approved screenshot-to-AI conversation MVP scope for the Peekaboo Mac app.'
read_when:
  - 'implementing or reviewing the screenshot AI conversation MVP'
---

# Peekaboo 截图 AI 会话 MVP · 需求提案

## 基本信息

| 项目 | 内容 |
|---|---|
| 状态 | 已批准，进入技术方案 |
| 日期 | 2026-08-31 |
| 产品与验收人 | 用户本人 |
| 开发范围 | 当前本地 Peekaboo Mac App |
| 首要交付物 | 本机可启动的 `.app` |

## 背景

用户需要一个无需命令行参与的 macOS 截图 AI 对话软件。当前 Peekaboo Mac App 能打开会话窗口，也具备区域截图和视觉模型分析的底层能力，但现有全局快捷键仅打开 Agent 弹窗、主窗口或 Inspector，没有“快捷键选区后自动分析”的固定入口。当前 Agent 的公开执行入口以文本任务为主，图片内容在 App 包装层会退化成 `[Image message]` 描述，不能直接满足可靠的截图会话。

本需求需要优先在用户本机形成可运行功能，而不是先完成正式 DMG、发布签名或大规模模块精简。

## 目标

1. Peekaboo Mac App 可在用户当前 macOS 机器上启动并常驻。
2. 用户通过一个可配置的全局快捷键进入拖拽选区，无需打开终端。
3. 选区完成后 1 秒内创建截图会话、强制激活主会话窗口并显示加载状态；AI 实际返回时间受所选 provider 和网络影响，不纳入 1 秒指标。
4. App 自动将选区截图和默认分析问题发送给已配置的视觉模型，并把答案显示在会话中。
5. 用户可在同一会话继续普通对话；App 在后台保留该会话的原始截图上下文，用户无需重复截图或重复选择图片。
6. 新建普通会话时不继承旧截图上下文。

## 范围

### 本次包含

- 新增截图 AI 全局快捷键及设置入口。
- 新增多显示器可用的拖拽选区与 `Esc` 取消；单次选区限制在一个显示器内。
- 复用 `ScreenCaptureServiceProtocol.captureArea` 截取用户选区。
- 截图后创建独立会话并强制显示 `SessionMainWindow`。
- 新增截图会话协调与视觉分析服务调用。
- 保存截图会话所需的图片引用和消息上下文。
- 在会话中展示截图、加载状态、AI 答案和错误提示。
- 同一截图会话内继续追问。
- 针对快捷键、选区状态、会话创建、窗口置前、视觉请求和失败分支补充测试。

### 涉及模块

- `Apps/Mac/Peekaboo/Core/KeyboardShortcutNames.swift`
- `Apps/Mac/Peekaboo/PeekabooApp.swift`
- `Apps/Mac/Peekaboo/Core/ConversationSession.swift` / `SessionStore`
- `Apps/Mac/Peekaboo/Features/Main/SessionMainWindow.swift`
- `Apps/Mac/Peekaboo/Features/Main/SessionChatView.swift`
- `Core/PeekabooAutomationKit` 截图协议与实现
- `Core/PeekabooCore` 中的 `PeekabooAIService`

## 不做范围

- 首个本机 MVP 不交付正式签名、Notarization、Sparkle 更新或对外 DMG。
- 不新增点击、输入、窗口控制、Shell 等桌面自动化能力。
- 不优先删除 CLI、MCP、Bridge、Inspector 或 Visualizer 源码；仅保证新链路不依赖这些能力。
- 第一版不做窗口智能选择、全屏截图和 OCR 专用模式，只做拖拽选区。
- 不建设独立云端业务后台；AI 后台沿用用户在 Peekaboo 中配置的 provider/API Key。
- 不保证外部 AI provider 在固定时间内返回答案，只保证本地窗口和加载状态及时出现。

## 验收标准

1. 在已安装完整 Xcode/Swift 6.2 工具链的用户机器上，可以构建并启动 Debug `.app`。
2. App 运行时按默认截图快捷键，500 毫秒内显示覆盖当前屏幕的选区层；快捷键可在设置中修改。
3. 用户拖拽有效区域并松开鼠标后，1 秒内出现并置前主会话窗口，窗口中显示截图消息及“正在分析”状态。
4. `Esc` 在选区阶段取消操作，不创建会话、不发送图片。
5. 视觉模型配置有效时，AI 返回内容追加到当前截图会话；失败时显示可理解的权限、配置、网络或模型错误，不静默改传整屏。
6. 在当前截图会话中连续提出至少 3 个问题，消息顺序正确，后续问题无需重新截图，并可引用原截图内容。
7. 新建普通会话后提出问题，不携带上一个截图会话的图片上下文。
8. 连续执行 10 次“快捷键 → 选区 → 会话置前”操作，不出现重复窗口、重复会话、崩溃或截图串会话。
9. 截图 AI 主链路不要求 Accessibility 权限，不执行 UI 自动化或 Shell。

## 风险

| 风险 | 影响 | 初步处理 |
|---|---|---|
| 当前机器未安装完整 Xcode，Swift 版本低于 manifest 要求 | 无法构建、运行和验证 `.app` | 先安装并选择包含 Swift 6.2 的完整 Xcode |
| 未配置稳定开发签名时 TCC 身份随重编译变化 | Screen Recording 可能反复授权 | MVP 可 unsigned 验证；随后配置个人 Apple Development team |
| 多显示器坐标系、缩放比例和负坐标 | 截取区域错位 | 选区控制器统一输出全局 AppKit 坐标，并增加多屏/Retina 测试 |
| `NSApp.activate` 在全屏 App 或不同 Space 下的置前表现 | “强制弹窗”可能不稳定 | 主窗口显式激活、置前并验证 Spaces/全屏场景；必要时调整 collection behavior |
| 现有会话模型只持久化文本/音频 | 截图上下文丢失或历史会话不可恢复 | 使用 App 层独立 context store 按 session ID 保存图片引用，不修改既有会话 schema |
| 每轮追问都携带原图会增加请求体和模型成本 | 响应变慢、费用上升 | MVP 优先可靠性；后续再做图片上下文压缩或 provider 会话复用 |
| Vision model 设置目前未真正接入分析服务 | UI 选择与实际模型不一致 | 协调器显式解析并传入视觉模型，补配置测试 |

## 相关方

| 角色 | 人员 | 职责 |
|---|---|---|
| 产品/验收 | 用户本人 | 确认交互、在本机验收功能 |
| 设计/开发 | Codex | 源码分析、技术方案、实现与验证 |
| 外部依赖 | 用户选择的 AI provider | 提供视觉模型和文本生成能力 |
| 开发环境依赖 | 用户本人 / Codex | 准备完整 Xcode、必要的 Screen Recording 权限和模型凭据 |

## 批准记录

- 2026-08-31，用户确认截图会话规则：“嗯可以”。
- 2026-08-31，用户明确批准进入下一阶段：“确认按推荐口径进入技术方案”。
