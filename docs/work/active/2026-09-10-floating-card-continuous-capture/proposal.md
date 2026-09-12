---
summary: 'Optimize the floating screenshot card for free resizing, continuous screenshots, and capture from macOS full-screen Spaces.'
read_when:
  - 'implementing or reviewing continuous screenshot conversations and floating-card window behavior'
---

# Peekaboo 悬浮截图卡连续会话与全屏框选 · 需求提案

## 基本信息

| 项目 | 内容 |
|---|---|
| 状态 | 已批准，进入技术方案 |
| 日期 | 2026-09-10 |
| 产品与验收人 | 用户本人 |
| 开发范围 | 当前本地 Peekaboo Mac App |
| 首要交付物 | 可在用户 Mac 上直接运行和验收的 `.app` |

## 背景

现有 Peekaboo 已能通过 `⌥Q` 框选截图、调用 AI 分析，并用单个半透明悬浮卡展示回答与追问。但实际使用中仍有三个明显断点：悬浮卡只能横向拖动且不能缩放；连续截图会自动创建多个会话，割裂同一任务的上下文；在 macOS 全屏应用所在的独立 Space 内触发快捷键时，框选层不能稳定出现在当前画面上。

用户希望把它变成一个不中断当前工作、可连续补充截图的桌面助手：只要悬浮卡没有关闭，下一次截图就继续添加到当前会话；关闭后才切断上下文。

## 目标

1. 悬浮卡可在当前显示器可见区域内进行横向和纵向拖动，并支持边缘或四角缩放。
2. 悬浮卡保持打开期间，连续 3 次及以上 `⌥Q` 截图都追加到同一个截图会话，不新增历史会话。
3. 每张新截图完成后 1 秒内追加到当前卡片并进入有序分析队列；AI 返回耗时不计入该指标。
4. 在 Safari、微信等标准 macOS 全屏应用的独立 Space 中按 `⌥Q` 后，500 毫秒内在当前全屏画面显示框选层，不切换回桌面或其他 Space。
5. 用户关闭悬浮卡或主动点击“新会话”后，下一张截图创建新会话，旧会话内容不再作为新请求上下文。

## 范围

### 本次包含

- 标题栏支持二维自由拖动，拖动后窗口不离开当前显示器可见区域。
- 悬浮卡支持原生边缘和四角缩放，并设置最小尺寸与屏幕可见范围上限。
- 保存并恢复用户最后一次调整的卡片位置和尺寸；双击标题栏恢复推荐尺寸。
- 悬浮卡未关闭时，新截图追加到当前截图会话，并在卡片中按顺序展示多张截图。
- 顶部提供截图缩略项，可查看当前会话中的第 1、2、3…张截图；默认选中最新截图。
- 每张图片只在其首次分析请求中上传一次；后续纯文本追问沿用会话文本上下文，不重复上传历史截图。
- 前一张截图仍在分析时，新截图进入队列顺序执行，不取消前一张，也不串改消息顺序。
- 增加“新会话”入口；关闭卡片、按卡片关闭语义的 `Esc`，或主动新建会话都会结束当前复用周期。
- 修复标准 macOS 全屏应用 Space 中 `⌥Q` 框选：框选层和结果卡都留在触发快捷键时的 Space，不主动激活 Peekaboo 并切换桌面。
- 补充窗口拖拽、缩放、连续截图上下文、队列并发和全屏 Space 窗口策略测试。

### 涉及模块

- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureSelectionController.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureAndAskCoordinator.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanel.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanelController.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingPanelPlacement.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/ScreenshotConversationContextStore.swift`
- `Apps/Mac/Peekaboo/Core/ScreenshotConversation/ScreenshotConversationService.swift`
- `Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatView.swift`
- 对应的 `Apps/Mac/PeekabooTests` 测试文件

## 不做范围

- 不同时打开多张悬浮卡；全局仍只复用一个卡片窗口。
- 不在本轮加入任意形状、套索或手绘路径裁剪；“画圈截图”仍指矩形拖拽框选。
- 不保证受 DRM/HDCP 保护的视频画面可被截取；系统返回黑屏或禁止捕获时不绕过系统保护。
- 不承诺支持独占式全屏游戏或阻止系统全局快捷键的应用；本轮以标准 macOS 全屏 Space 为验收范围。
- 不把每轮请求都重新上传会话中的全部历史截图，避免请求体、延迟和模型费用随截图数线性增长。
- 不修改 Provider、模型选择、API Key 管理或普通主窗口会话逻辑。
- 不在本轮处理正式 Developer ID 签名、公证或 DMG 发布流程。

## 验收标准

1. 在用户本机交付构建中，悬浮卡可向上下左右任意方向拖动；连续拖动 20 次后窗口仍至少完整保留在当前显示器可见区域内。
2. 可从任意边缘或四角调整卡片尺寸；最小尺寸不低于 `360×260pt`，最大尺寸不超过当前显示器可见区域；双击标题栏恢复约 `460×600pt` 推荐尺寸。
3. 退出并重新启动 App 后，首次出现的悬浮卡恢复上次有效位置与尺寸；若显示器布局改变，则自动收敛到当前可见区域。
4. 悬浮卡保持打开时连续完成 3 张截图，历史列表只新增 1 个会话，卡片内可看到 3 个按时间排序的截图项，最新项默认选中。
5. 前一张仍在分析时再截 2 张，3 个请求按截图顺序完成；不得取消前一张、重复上传同一图片、创建额外会话或让回答关联到错误截图。
6. 截图完成后发送 3 次纯文本追问，追问均进入同一会话且请求不再携带历史图片。
7. 点击关闭、在卡片聚焦时按 `Esc`，或点击“新会话”后再次截图，必须创建新的会话；新会话不继承旧会话的截图或消息。
8. Safari 全屏、微信全屏和至少一个其他标准 macOS 全屏应用中分别执行 3 次 `⌥Q`：每次 500 毫秒内在当前 Space 出现框选层，整个流程不切回桌面；选区完成后悬浮卡仍显示在当前全屏 Space。
9. 在全屏框选阶段按 `Esc`，框选层立即关闭，不创建消息、不调用 AI，原全屏应用仍保持在原 Space。
10. 普通桌面、多显示器、屏幕录制权限错误、AI 请求失败/重试及现有 Markdown 展示不发生回归。

## 风险

| 风险 | 影响 | 初步处理 |
|---|---|---|
| `NSApp.activate` 与 macOS 全屏 Space 切换冲突 | 快捷键触发后跳回桌面，用户误以为全屏不能截图 | 技术方案中验证去除应用激活后的键盘/鼠标事件获取方式，并让选区面板加入当前全屏 Space |
| `canJoinAllSpaces`、`moveToActiveSpace` 与 `fullScreenAuxiliary` 组合有系统行为差异 | 框选层或结果卡出现在错误 Space | 分离框选面板与结果面板策略，使用实际全屏应用做本机回归测试 |
| 当前截图上下文结构每个会话只保存一张图片 | 连续截图会覆盖旧图或无法准确关联回答 | 升级为会话内有序截图记录，并设计向后兼容迁移 |
| 同一会话多张截图与纯文本消息缺少显式关联 | AI 回答可能针对错误图片 | 为截图消息建立稳定 ID/序号，请求队列按截图事件绑定图片 |
| 快速连续截图产生并发和顺序竞争 | 回答乱序、状态覆盖或重复上传 | 每个会话使用串行队列和独立请求标识；用可控异步测试验证顺序 |
| 自由缩放破坏内容布局或输入区可用性 | 卡片过小、Markdown/截图显示异常 | 设置最小尺寸，内容区滚动，输入区固定，覆盖小尺寸和大字体测试 |
| 用户调整位置后显示器断开或分辨率变化 | 卡片落在屏幕外 | 每次展示及屏幕参数变化时把保存 frame 收敛到当前 visible frame |
| 项目没有可用的 `kb-search` Skill 和 proposal 模板 | 无法复用仓库外部经验或标准模板 | 复用项目现有 proposal 结构，并在技术方案阶段以现有实现和 Apple 官方行为作为证据 |

## 相关方

| 角色 | 人员 | 职责 |
|---|---|---|
| 产品/验收 | 用户本人 | 确认交互规则，在目标 Mac 上验收拖拽、连续截图与全屏 Space |
| 设计/开发 | Codex | 技术方案、实现、自动化测试、远程构建与本机安装验证 |
| 平台依赖 | macOS AppKit / Spaces / ScreenCaptureKit | 提供全局快捷键、窗口层级、全屏 Space 和屏幕捕获能力 |
| 外部依赖 | 当前已配置的 MiniMax Provider | 提供图片分析与后续文本对话 |

## 已确认的产品决策

- 2026-09-10，用户确认采用“复用一个折叠式悬浮卡”。
- 2026-09-10，用户确认卡片未关闭时，下一次截图继续添加到当前会话。
- 关闭卡片代表结束本轮截图上下文；下一次截图创建新会话。
- 旧截图不在每次后续追问时重复上传；历史分析文本继续作为对话上下文。

## 批准记录

- 2026-09-10，用户确认悬浮卡未关闭时，后续截图继续添加到当前会话：“这个可以，而且很好”。
- 2026-09-10，用户在收到 proposal 和进入技术方案提示后明确要求：“执行”。
