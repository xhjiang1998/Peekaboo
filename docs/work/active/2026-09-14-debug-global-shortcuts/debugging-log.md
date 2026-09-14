# Global shortcuts diagnosis

## 症状

用户手动打开新版应用后，Option+Q 在全屏和普通桌面均无反应；Shift+Command+P 也无反应。

## 假设列表

1. 启动连接未完成：若成立，connectToState 创建的状态栏图标也可能缺失；全局快捷键注册依赖 HiddenWindowView.task。
2. 注册失败或快捷键事件未送达：若成立，状态栏交互正常，而快捷键没有回调。需要运行时日志或注册返回值验证。
3. 回调后的截图流程阻塞：若成立，其他全局快捷键通常应正常；主窗口快捷键也失效使该解释不足以单独解释症状。
4. 使用旧安装包或保存了不同快捷键：检查安装包哈希和 UserDefaults 可证伪；实际运行路径仍需现场验证。

## 验证记录

- debug bundle 的 captureAndAsk 为 carbonModifiers=2048、carbonKeyCode=12，即 Option+Q。
- showMainWindow 为 carbonModifiers=768、carbonKeyCode=35，即 Shift+Command+P。
- /Applications/Peekaboo.app bundle ID 为 boo.peekaboo.mac.debug；debug dylib SHA256 为 c99bac9347f719093909969271637a42e3ee4d22286fcebd99f1c9dfb37da62f，与已安装新构建一致。
- PeekabooApp.swift：HiddenWindowView.task 调用 connectToState；该方法创建 statusBarController，然后注册所有全局快捷键。
- 当前执行沙箱拒绝 ps 和 log show。无法以日志缺失判定应用未运行或回调未执行。
- 已请求用户验证顶部状态栏图标及点击响应；结果待确认。
- 用户后续截图确认状态栏点击可弹出 Ready 面板。完全未执行 connectToState 的假设不再符合现场；仍不能据此证明热键注册成功。
- 已查阅 Package.resolved 锁定的 KeyboardShortcuts 3.0.1（49c3fc04ea827f816df67843bfcc57286b47ff06）源码：HotKey 注册失败返回 nil；KeyboardShortcuts.isPaused 会抑制回调。应用只添加回调，未展示注册结果。注册失败和暂停状态均待运行时证据，不能认定根因。
- 下一最小实验：关闭设置/弹出面板，直接打开主窗口并在其前台测试 Option+Q，区分前台也失效与仅后台失效。
- 本仓库未发现 .claude 调试模板和指标脚本，按技能必填章节手动记录；未执行不存在的流程命令。

## 根因

尚未确认。快捷键保存值错误已排除；新安装包已核实，但实际运行进程路径未获验证。

### 用户补充与进一步代码证据

- 用户纠正：Open Peekaboo 实际有响应，提示权限；全屏时窗口被挡住。不能继续将此前“无反应”当成事件未送达的证据。
- CaptureAndAskCoordinator.showFailureAlert 使用 NSAlert.runModal，未配置全屏 collectionBehavior。startCapture 在 captureTask 非空时直接返回，而 captureTask 在 prepareCapture 返回后才清空。因此若权限警告未关闭，重复截图会被忽略。这是代码确认的阻塞链，但现场是否为此模态框仍待用户截图。
- PermissionsOnboardingController 使用普通 NSWindow，也未配置全屏 collectionBehavior；不能将其与截图失败的模态框混为一谈。
- showMainWindow 仅激活应用并 makeKeyAndOrderFront 或创建 SwiftUI 窗口，没有显式跨全屏空间展示策略。
- 当前安装签名 designated requirement 为 cdhash 2aa679a3689a451ebb0275fac00e984af430b223。此证据不等同于系统现存 TCC 授权身份匹配情况，尚不能认定授权失效原因。
- 设置页面的被动权限检查在预检失败、probe 尚未 unlock 时返回 false；截图路径会进一步尝试 ScreenCaptureKit。两者不能用同一个“已拒绝”结论替代真实运行时结果。
- 已请求用户提供应用自己的权限提示截图，以区分录屏警告和多项权限引导；未重置 TCC、修改签名或跳过权限检查。

## 修复方案

暂不修改配置、权限或业务代码；先区分启动连接缺失和事件注册/投递问题。

### 已执行的最小修复

- 用户要求继续自主探索并处理，未再请求用户截图。复核以前的权限诊断文档，发现上次已授权构建 designated requirement 为 f078d84c2a39711738b6fb3d1652f6b0a54890d8，而现安装包为 2aa679a3689a451ebb0275fac00e984af430b223；签名身份改变已确认，当前 TCC 是否匹配仍无法读取验证。
- 只读查询 TCC 被系统拒绝；未绕过、未修改数据库。当前可用签名证书数量为 0，未擅自生成或信任新证书。
- 找到运行中应用的 bridge.sock（Sep 14 13:58），但本机无 Peekaboo CLI；桥接接口需要签名身份认证，未伪造客户端或降低认证要求。
- 提交 88866c4：复用已有 FloatingScreenshotChatPanel，替换截图失败时的 NSAlert.runModal；显示后立即返回、允许下次截图。关闭和 Escape 释放面板，重试前关闭旧提示，按鼠标所在显示器定位。
- 此修改针对确认的模态阻塞缺陷，不宣称解决签名权限不匹配，也不宣称主窗口/引导页的全屏问题已经全部修复。
- 远程测试及构建运行：https://github.com/xhjiang1998/Peekaboo/actions/runs/34815825210 。尚未替换用户正在运行的安装包。

### 回归与审查进度

- 修改前静态阻塞检查 FAIL：命中 runModal；修改后 PASS：失败展示路径不再调用 runModal。此为静态结构回归，不冒充运行时单测红绿。
- 新增 Swift 测试：提示展示非模态、连续提示；浮窗全屏属性；补充权限失败后再次 startCapture 可重新检查。
- 本机生产文件 swiftc -frontend -parse 通过；本机 Swift 6.1.2 不支持现有 Swift 6.2 测试命名语法，完整测试交由远程 Xcode 26，不将本机测试标为通过。
- 独立 code-reviewer 静态审查：未发现阻断问题，建议补充重试回归，已补；本机桌面与远程测试结果仍待验。
- 使用 systematic-debugging 的测试先行要求；完整 code-review 技能合入门禁尚未通过（运行时回归/覆盖率未完成），本次为个人功能分支开发构建，不合入主干。
- 进一步实际验证：对当前 /Applications/Peekaboo.app 使用 codesign --verify -R 校验旧 cdhash 要求，返回 code failed to satisfy specified code requirement(s)；用当前 cdhash 要求则成功。证实新旧身份不兼容，不以此冒充当前 TCC 行的读取结果。
- 远程运行 34815825210：Core 会话测试步骤和完整 Mac app 测试步骤均已成功，进入应用打包阶段。对应生产代码提交 88866c4。另有仅测试等待条件改进的本地提交 0a39b9a，暂未推送以免现有并发策略取消正在打包的构建。

### 本轮已验证产物

- 运行 34815825210 最终 success：10 个 Core 测试、297 个 Mac 测试通过，App 构建打包成功。日志中的 XCTest “0 tests”不是测试缺失，实际测试为 Swift Testing，以上计数来自其最终通过摘要。
- 下载至 work/artifacts/nonblocking-capture-88866c4/Peekaboo.app.zip；SHA256 为 5c7471df2c6ce342f744efb2cf5da997805f6e965eb3644a20c1730695fe5db8，与远程校验文件一致。
- 解包至同目录 unpacked/Peekaboo.app；仅对这份工作区副本做 ad-hoc 签名，codesign --verify --deep --strict 成功；没有替换 /Applications 中正在使用的版本。
- 0a39b9a 在首轮构建完成后已推送，触发测试等待条件改进的后续 CI；它不改变生产代码。本轮已验证产物仍明确对应 88866c4。
- 尚未完成：当前系统 TCC 授权匹配验证、稳定签名身份配置、主窗口/引导页全屏展示修复、本机新包安装与实际桌面验收。不能宣称全部问题解决。

### 2026-09-14 本机安装与权限恢复

- 用户明确要求继续修复。已停止旧进程，并将已验证产物原位同步到 /Applications/Peekaboo.app；未触碰 ~/.peekaboo、API key 或会话数据。
- 安装后 debug dylib SHA256 为 e6eba6c1c877f24414d25c34c9246e034b1cd705d1b2f171f854c5347e6ab5a0，与修复包完全一致；codesign --verify --deep --strict 通过。
- 安装后的 designated requirement 为 d972cbed386df982a75836f5867cfba660593575，与旧安装身份 2aa679a3... 不同；旧 TCC 同名条目不能作为当前包已获授权的证据。
- 尝试仅重置 boo.peekaboo.mac.debug 的 ScreenCapture 授权，tccutil 被当前 Codex 沙箱明确拒绝：Operation not permitted from sandbox。尝试交由 Terminal 执行也被桌面 XPC 隔离拒绝。未重置其他应用权限，未直接修改 TCC 数据库。
- Codex 沙箱中的 LaunchServices 仍错误返回 kLSNoExecutableErr，但 Info.plist 的 CFBundleExecutable=Peekaboo 且可执行文件实际存在、签名校验成功；不能将该沙箱启动错误误判为安装包缺失。
- 剩余系统级一步：由登录用户环境执行 `/usr/bin/tccutil reset ScreenCapture boo.peekaboo.mac.debug`，再从 Applications 手动打开固定的修复包并通过 Peekaboo Permissions 页面触发一次 Grant。之后不得再替换或重新签名该包，直到引入稳定签名身份。

### 2026-09-14 跨应用全屏选区不可见

#### 症状

- 用户确认普通场景已能继续使用，但 Codex 处于 macOS 原生全屏空间时，Option+Q 不出现截图选区层。

#### 假设列表

1. 选区窗口只能加入所有 Spaces，不能加入其他应用的全屏空间。若成立，策略中应缺少 canJoinAllApplications，而同类系统覆盖层需要该标志。
2. 全局快捷键在全屏被系统或前台应用吞掉。若成立，即使选区窗口策略正确，也不会执行 startCapture；需要运行日志或注入诊断验证。
3. 快捷键已触发，但录屏权限失败提示藏在全屏后。若成立，新版非模态 failurePanel 应出现权限提示，而不是选区；需要安装后实测区分。
4. 选区面板层级过低。若成立，其 level 不应为 screenSaver；代码检查实际为 screenSaver，暂不支持该假设。

#### 验证记录与根因

- 代码确认选区面板已有 canJoinAllSpaces、stationary、fullScreenAuxiliary 和 screenSaver level，但缺少 canJoinAllApplications。
- 同一功能内的 FloatingScreenshotChatPanel 已使用 canJoinAllApplications，说明当前 SDK/部署目标已有项目内先例。
- Apple NSWindow.CollectionBehavior 文档明确：canJoinAllApplications 用于可加入其他应用全屏空间的浮动窗口和系统覆盖层；canJoinAllSpaces 仅描述 Spaces。该缺失能够精确解释普通桌面可见、其他应用全屏不可见的差异。
- 将主要根因确定为选区遮罩缺少 canJoinAllApplications；快捷键吞键与权限提示假设仍须新包桌面验收排除。

#### 修复方案与回归测试

- 测试先增加选区策略必须包含 canJoinAllApplications 的断言；修改前静态策略检查按预期失败。
- 生产代码只在 CaptureSelectionPanelPolicy.collectionBehavior 增加 canJoinAllApplications；解析和 diff 检查通过。
- 等待独立审查、远程 Xcode 26 全量 Mac 测试、重新打包安装和真实 Codex 全屏验收。

#### lessons

- canJoinAllSpaces 与 canJoinAllApplications 不是同义配置：前者跨 Space，后者才覆盖其他应用的全屏空间。跨应用截图遮罩必须把两层窗口管理语义分别验证。

## 回归测试

尚未实施修复。需要覆盖普通桌面与全屏下的截图快捷键、主窗口快捷键，以及退出重新打开后的初始化。

## lessons

进程启动、状态连接、热键注册及热键回调是不同阶段，不能仅凭用户已打开应用就推断注册成功；沙箱无法查看进程也不能证明进程不存在。
