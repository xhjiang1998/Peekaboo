# Peekaboo Floating Screenshot Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Replace the screenshot flow's forced main-window jump with one reusable translucent floating chat card and render assistant block Markdown correctly in both chat surfaces.

**Architecture:** CaptureAndAskCoordinator passes a session plus capture geometry to a screenshot-specific presenter. A single NSPanel hosts a SwiftUI card that observes the existing SessionStore and ScreenshotConversationService; pure placement and Markdown display models keep geometry and parsing testable outside AppKit rendering.

**Tech Stack:** Swift 6.2, macOS 14+, AppKit NSPanel, SwiftUI, Observation, Swift Testing, KeyboardShortcuts, Apple swift-markdown 0.7.x.

**Spec:** docs/superpowers/specs/2026-09-09-floating-screenshot-chat-design.md

## Global Constraints

- The default shortcut is ⌥Q and remains user-configurable.
- Exactly one floating screenshot panel exists and is reused for later captures.
- Automatic presentation must not call NSApp.activate or expose the Dock.
- The panel width is exactly 460pt; maximum height is min(600pt, visibleFrame.height - 32pt).
- Initial placement prefers 12pt to the selection's right, falls back left, and remains inside a 16pt visible-frame margin.
- Dragging changes only X and remains inside the selected display's visible frame.
- The screenshot preview starts collapsed at approximately 100pt and may be expanded in place.
- A newer capture cancels the previous screenshot analysis and owns subsequent floating-card updates.
- Closing suppresses reopening for that request; a new capture may show the panel again.
- Follow-ups stay in the same screenshot session and reuse its stored image context.
- The UI remains native AppKit and SwiftUI; no WebView or HTML renderer is introduced.
- Unsupported or malformed Markdown falls back to readable source text without dropping content.
- Existing ordinary chat, provider selection, model selection and session persistence remain unchanged.

---

## File Structure

New production files:

- Apps/Mac/Peekaboo/Core/ScreenshotConversation/ScreenshotPresentationContext.swift: presentation boundary.
- Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingPanelPlacement.swift: pure placement calculations.
- Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanel.swift: NSPanel behavior.
- Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanelController.swift: singleton panel lifecycle.
- Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatState.swift: observable UI state.
- Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatView.swift: floating card composition.
- Apps/Mac/Peekaboo/Features/ScreenshotConversation/ScreenshotConversationComponents.swift: shared screenshot controls.
- Apps/Mac/Peekaboo/Features/Main/MessageComponents/MarkdownDisplayModel.swift: parsed display tree.
- Apps/Mac/Peekaboo/Features/Main/MessageComponents/MarkdownMessageView.swift: native renderer.

New tests:

- Apps/Mac/PeekabooTests/Services/FloatingPanelPlacementTests.swift
- Apps/Mac/PeekabooTests/Services/FloatingScreenshotChatPanelControllerTests.swift
- Apps/Mac/PeekabooTests/Views/MarkdownDisplayModelTests.swift
- Apps/Mac/PeekabooTests/Views/FloatingScreenshotChatStateTests.swift

Existing files modified:

- Apps/Mac/Package.swift
- Apps/Mac/Peekaboo/Core/KeyboardShortcutNames.swift
- Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureAndAskCoordinator.swift
- Apps/Mac/Peekaboo/Features/Main/MessageComponents/MessageContentView.swift
- Apps/Mac/Peekaboo/Features/Main/SessionChatView.swift
- Apps/Mac/Peekaboo/PeekabooApp.swift
- Apps/Mac/PeekabooTests/Services/CaptureAndAskCoordinatorTests.swift

---

### Task 1: Block Markdown display model and shared renderer

**Files:**
- Modify: Apps/Mac/Package.swift
- Create: Apps/Mac/Peekaboo/Features/Main/MessageComponents/MarkdownDisplayModel.swift
- Create: Apps/Mac/Peekaboo/Features/Main/MessageComponents/MarkdownMessageView.swift
- Modify: Apps/Mac/Peekaboo/Features/Main/MessageComponents/MessageContentView.swift
- Test: Apps/Mac/PeekabooTests/Views/MarkdownDisplayModelTests.swift

**Interfaces:**
- Consumes: String assistant content and Markdown.Document.
- Produces: MarkdownDisplayDocument.init(source:), MarkdownDisplayBlock and MarkdownMessageView.init(markdown:).

- [ ] **Step 1: Write failing parser tests**

Create tests that require source-order parsing for a heading, unordered list, thematic break, quote and fenced code. Add a second test for strong, emphasis, inline code and links. Add a fallback assertion that plain text is never lost.

The core expectations are:

    let document = MarkdownDisplayDocument(source: source)
    #expect(document.blocks == [
        .heading(level: 1, inline: [.text("标题")]),
        .unorderedList([
            [.text("第一项")],
            [.text("第二项")],
        ]),
        .thematicBreak,
        .quote([.paragraph([.text("引用")])]),
        .codeBlock(language: "swift", code: "let value = 1\n"),
    ])

- [ ] **Step 2: Run the parser test and verify red state**

Run:

    swift test --package-path Apps/Mac --filter MarkdownDisplayModelTests

Expected: compilation fails because MarkdownDisplayDocument does not exist.

- [ ] **Step 3: Add swift-markdown and implement the display model**

Add this package dependency:

    .package(url: "https://github.com/apple/swift-markdown", from: "0.7.3"),

Add this target product:

    .product(name: "Markdown", package: "swift-markdown"),

Define:

    enum MarkdownDisplayInline: Equatable, Sendable {
        case text(String)
        case strong([Self])
        case emphasis([Self])
        case code(String)
        case link(label: [Self], destination: String)
    }

    indirect enum MarkdownDisplayBlock: Equatable, Sendable {
        case paragraph([MarkdownDisplayInline])
        case heading(level: Int, inline: [MarkdownDisplayInline])
        case unorderedList([[MarkdownDisplayInline]])
        case orderedList(start: Int, items: [[MarkdownDisplayInline]])
        case quote([MarkdownDisplayBlock])
        case thematicBreak
        case codeBlock(language: String?, code: String)
    }

    struct MarkdownDisplayDocument: Equatable, Sendable {
        let source: String
        let blocks: [MarkdownDisplayBlock]
        var plainText: String
        init(source: String)
    }

Recursively visit Heading, Paragraph, UnorderedList, OrderedList, BlockQuote, ThematicBreak, CodeBlock, Text, Strong, Emphasis, InlineCode and Link. Unsupported blocks append their plain text. A non-empty source must always produce at least one readable block.

- [ ] **Step 4: Implement the SwiftUI renderer and switch assistant messages**

MarkdownMessageView uses a leading VStack. Render headings with title-to-headline fonts, lists with bullets or calculated numbers, rules with Divider, quotes with a leading accent bar, and code blocks with monospaced text plus horizontal scrolling. Inline nodes build one AttributedString with bold, italic, monospaced and link attributes.

Its public surface is:

    struct MarkdownMessageView: View {
        let document: MarkdownDisplayDocument

        init(markdown: String) {
            self.document = MarkdownDisplayDocument(source: markdown)
        }
    }

Replace AssistantMessageContent's inlineOnlyPreservingWhitespace branch with MarkdownMessageView(markdown: message.content).

- [ ] **Step 5: Run focused tests and formatting**

    swift test --package-path Apps/Mac --filter MarkdownDisplayModelTests
    pnpm run format

Expected: Markdown tests pass and formatting exits zero.

- [ ] **Step 6: Commit**

    git add Apps/Mac/Package.swift Apps/Mac/Peekaboo/Features/Main/MessageComponents Apps/Mac/PeekabooTests/Views/MarkdownDisplayModelTests.swift
    git commit -m "fix(mac): render assistant block markdown"

---

### Task 2: Presentation context and placement calculations

**Files:**
- Create: Apps/Mac/Peekaboo/Core/ScreenshotConversation/ScreenshotPresentationContext.swift
- Create: Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingPanelPlacement.swift
- Test: Apps/Mac/PeekabooTests/Services/FloatingPanelPlacementTests.swift

**Interfaces:**
- Consumes: selection rect, display ID, visible frame and panel size.
- Produces: ScreenshotPresentationContext, ScreenshotConversationPresenting and FloatingPanelPlacement.

- [ ] **Step 1: Write failing geometry tests**

Cover:

    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let panel = CGSize(width: 460, height: 600)

    #expect(FloatingPanelPlacement.origin(
        selectionRect: CGRect(x: 100, y: 300, width: 300, height: 200),
        visibleFrame: visible,
        panelSize: panel).x == 412)

    #expect(FloatingPanelPlacement.origin(
        selectionRect: CGRect(x: 900, y: 300, width: 300, height: 200),
        visibleFrame: visible,
        panelSize: panel).x == 428)

    #expect(FloatingPanelPlacement.clampedX(
        -200,
        visibleFrame: visible,
        panelWidth: 460) == 16)

Also cover negative multi-display coordinates and vertical clamping around menu bar and Dock.

- [ ] **Step 2: Run and verify red state**

    swift test --package-path Apps/Mac --filter FloatingPanelPlacementTests

Expected: compilation fails because the placement type is missing.

- [ ] **Step 3: Implement presentation types**

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

- [ ] **Step 4: Implement placement**

Use gap 12 and margin 16. Prefer a fully fitting right position, then left. When neither fits, choose the side with more space and clamp. Align panel top with selection top, then clamp Y. Expose:

    enum FloatingPanelPlacement {
        static func origin(
            selectionRect: CGRect,
            visibleFrame: CGRect,
            panelSize: CGSize) -> CGPoint

        static func clampedX(
            _ proposedX: CGFloat,
            visibleFrame: CGRect,
            panelWidth: CGFloat) -> CGFloat
    }

- [ ] **Step 5: Test and commit**

    swift test --package-path Apps/Mac --filter FloatingPanelPlacementTests
    git add Apps/Mac/Peekaboo/Core/ScreenshotConversation/ScreenshotPresentationContext.swift Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingPanelPlacement.swift Apps/Mac/PeekabooTests/Services/FloatingPanelPlacementTests.swift
    git commit -m "feat(mac): calculate screenshot panel placement"

---

### Task 3: Reusable non-activating panel lifecycle

**Files:**
- Create: Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanel.swift
- Create: Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanelController.swift
- Create: Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatState.swift
- Test: Apps/Mac/PeekabooTests/Services/FloatingScreenshotChatPanelControllerTests.swift
- Test: Apps/Mac/PeekabooTests/Views/FloatingScreenshotChatStateTests.swift

**Interfaces:**
- Consumes: ScreenshotPresentationContext, display visible-frame lookup and a SwiftUI root view.
- Produces: one panel controller, observable state and horizontal movement.

- [ ] **Step 1: Write failing lifecycle tests**

Define a testable panel boundary:

    @MainActor
    protocol FloatingPanelControlling: AnyObject {
        var frame: CGRect { get set }
        var isVisible: Bool { get }
        func orderFrontRegardless()
        func orderOut(_ sender: Any?)
    }

Assert that two presentations create one panel, the second context replaces the first, preview expansion resets, dismiss calls orderOut, and horizontal movement preserves Y while clamping X. Assert presentation has no application-activation dependency.

- [ ] **Step 2: Run and verify red state**

    swift test --package-path Apps/Mac --filter FloatingScreenshotChatPanelControllerTests
    swift test --package-path Apps/Mac --filter FloatingScreenshotChatStateTests

Expected: compilation fails because the state and controller are missing.

- [ ] **Step 3: Implement observable state**

    @Observable
    @MainActor
    final class FloatingScreenshotChatState {
        private(set) var currentContext: ScreenshotPresentationContext?
        var isPreviewExpanded = false
        private(set) var presentationGeneration = 0
        private(set) var dismissedGeneration: Int?

        var isDismissedForCurrentPresentation: Bool
        func present(_ context: ScreenshotPresentationContext)
        func togglePreview()
        func markDismissed()
    }

present resets preview and increments the generation. A new generation clears the effective dismissed state.

- [ ] **Step 4: Implement panel and controller**

FloatingScreenshotChatPanel uses borderless, nonactivatingPanel and fullSizeContentView masks. Set transparent background, shadow, floating level, floating-panel behavior, no hide on deactivate, key-only-if-needed, and canJoinAllSpaces plus fullScreenAuxiliary. Override canBecomeKey as true and route cancelOperation to onEscape.

The controller API is:

    @MainActor
    final class FloatingScreenshotChatPanelController: ScreenshotConversationPresenting {
        static let panelWidth: CGFloat = 460
        static let maximumPanelHeight: CGFloat = 600

        let state: FloatingScreenshotChatState

        func present(_ context: ScreenshotPresentationContext)
        func dismiss()
        func moveHorizontally(translation: CGFloat, startX: CGFloat)
    }

Match displayID with NSScreenNumber. Create the panel once, size it with min(600, visibleFrame.height - 32), apply FloatingPanelPlacement, then call orderFrontRegardless. Never call NSApp.activate.

- [ ] **Step 5: Test and commit**

    swift test --package-path Apps/Mac --filter FloatingScreenshotChatPanelControllerTests
    swift test --package-path Apps/Mac --filter FloatingScreenshotChatStateTests
    git add Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanel.swift Apps/Mac/Peekaboo/Core/ScreenshotConversation/FloatingScreenshotChatPanelController.swift Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatState.swift Apps/Mac/PeekabooTests/Services/FloatingScreenshotChatPanelControllerTests.swift Apps/Mac/PeekabooTests/Views/FloatingScreenshotChatStateTests.swift
    git commit -m "feat(mac): add reusable screenshot chat panel"

---

### Task 4: Floating content and shared screenshot controls

**Files:**
- Create: Apps/Mac/Peekaboo/Features/ScreenshotConversation/ScreenshotConversationComponents.swift
- Create: Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatView.swift
- Modify: Apps/Mac/Peekaboo/Features/ScreenshotConversation/FloatingScreenshotChatState.swift
- Modify: Apps/Mac/Peekaboo/Features/Main/SessionChatView.swift
- Test: Apps/Mac/PeekabooTests/Views/FloatingScreenshotChatStateTests.swift

**Interfaces:**
- Consumes: floating state, SessionStore, ScreenshotConversationService and MarkdownMessageView.
- Produces: card UI, collapsible preview, shared progress/error UI and follow-up composer.

- [ ] **Step 1: Add failing state behavior tests**

Assert:

    state.present(firstContext)
    #expect(!state.isPreviewExpanded)
    state.togglePreview()
    #expect(state.isPreviewExpanded)
    state.markDismissed()
    #expect(state.isDismissedForCurrentPresentation)
    state.present(secondContext)
    #expect(!state.isPreviewExpanded)
    #expect(!state.isDismissedForCurrentPresentation)

- [ ] **Step 2: Run and verify red state**

    swift test --package-path Apps/Mac --filter FloatingScreenshotChatStateTests

Expected: new assertions fail until the state methods are complete.

- [ ] **Step 3: Extract shared controls**

Move ScreenshotPreviewCard and ScreenshotAnalysisErrorBanner out of SessionChatView.swift. The shared preview takes sessionID and isExpanded, uses a 100pt collapsed height and 280pt expanded maximum, loads image data with task(id: sessionID), and preserves the existing missing-image copy.

Create ScreenshotFollowUpComposer with:

    let sessionID: String
    let placeholder: String
    let canSubmit: Bool
    let isBusy: Bool

It trims input, calls sendFollowUp, disables submission while busy, and exposes the existing stop action.

- [ ] **Step 4: Build FloatingScreenshotChatView**

Compose a header, divider, scrollable preview and messages, progress or inline error, divider and fixed bottom composer. Width is 460. Use hud-window material, an 18pt continuous corner radius and light shadow. DetailedMessageRow renders messages so the main window and card share Markdown behavior.

The header receives close, preview-toggle and drag callbacks. Do not auto-focus the text field. When the session is unavailable, show a compact readable error rather than an empty card.

- [ ] **Step 5: Test, build and commit**

    swift test --package-path Apps/Mac --filter FloatingScreenshotChatStateTests
    swift build --package-path Apps/Mac
    git add Apps/Mac/Peekaboo/Features/ScreenshotConversation Apps/Mac/Peekaboo/Features/Main/SessionChatView.swift Apps/Mac/PeekabooTests/Views/FloatingScreenshotChatStateTests.swift
    git commit -m "feat(mac): show screenshot conversation in floating card"

---

### Task 5: Latest-capture ownership and cancellation

**Files:**
- Modify: Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureAndAskCoordinator.swift
- Modify: Apps/Mac/PeekabooTests/Services/CaptureAndAskCoordinatorTests.swift

**Interfaces:**
- Consumes: ScreenshotConversationPresenting, CaptureSelection, conversation creation, analysis and cancellation.
- Produces: geometry-aware presentation before analysis and latest-capture-wins behavior.

- [ ] **Step 1: Require geometry in existing tests**

Change the presenter closure to accept ScreenshotPresentationContext. Assert the successful flow presents sessionID, selection.rect and selection.displayID before analysis begins.

- [ ] **Step 2: Add failing concurrency tests**

Use two controllable analyses and a cancellation spy. Verify: A starts, B is captured while A waits, A is cancelled exactly once, presenter switches to B, and a late completion from A cannot change B's analyzing or ready state. Preserve the existing selection re-entry test.

- [ ] **Step 3: Run and verify red state**

    swift test --package-path Apps/Mac --filter CaptureAndAskCoordinatorTests

Expected: compilation or assertions fail because the existing coordinator only presents a session ID and leaves old analysis running.

- [ ] **Step 4: Implement request ownership**

Change dependencies to:

    typealias ConversationPresenter = (ScreenshotPresentationContext) -> Void
    typealias ConversationCanceller = (String) -> Void

Track captureTask and analysisTask separately plus latestSessionID. Selection remains non-reentrant; analysis does not block a later selection. When B is created, cancel A through ScreenshotConversationService.cancel(sessionID:), bind and present B, then analyze B. After every await, mutate state only when latestSessionID matches.

- [ ] **Step 5: Test and commit**

    swift test --package-path Apps/Mac --filter CaptureAndAskCoordinatorTests
    swift test --package-path Apps/Mac --filter ScreenshotConversationServiceTests
    swift test --package-path Apps/Mac --filter ScreenshotConversationEndToEndTests
    git add Apps/Mac/Peekaboo/Core/ScreenshotConversation/CaptureAndAskCoordinator.swift Apps/Mac/PeekabooTests/Services/CaptureAndAskCoordinatorTests.swift
    git commit -m "feat(mac): route captures to latest floating session"

---

### Task 6: App assembly and Option-Q default

**Files:**
- Modify: Apps/Mac/Peekaboo/PeekabooApp.swift
- Modify: Apps/Mac/Peekaboo/Core/KeyboardShortcutNames.swift
- Create: Apps/Mac/PeekabooTests/Core/KeyboardShortcutNamesTests.swift

**Interfaces:**
- Consumes: connected SessionStore, ScreenshotConversationService and app environment.
- Produces: one retained panel controller wired to the global shortcut.

- [ ] **Step 1: Add the failing shortcut expectation**

Extract a stable shortcut default for testing if KeyboardShortcuts does not expose the registered default:

    enum PeekabooShortcutDefaults {
        static let captureAndAsk = KeyboardShortcuts.Shortcut(.q, modifiers: [.option])
    }

Assert the registered captureAndAsk name uses that value. PeekabooApp.swift is excluded from the Swift Package test
target, so application assembly is verified by the Mac app build in Step 4; the panel and coordinator lifecycle
remain covered through their included-module unit tests.

- [ ] **Step 2: Run and verify red state**

    swift test --package-path Apps/Mac --filter CaptureAndAsk
    swift test --package-path Apps/Mac --filter KeyboardShortcutNamesTests

Expected: the shortcut assertion fails because the current default is Option-Command-A.

- [ ] **Step 3: Wire the controller**

AppDelegate retains:

    private var floatingScreenshotChatPanelController: FloatingScreenshotChatPanelController?

During connectToState, create it once with SessionStore, ScreenshotConversationService and the hosted root view environment. Pass it to CaptureAndAskCoordinator. Remove MainWindowPresenter only from screenshot capture assembly; normal main-window commands remain unchanged.

Register:

    static let captureAndAsk = Self(
        "captureAndAsk",
        initial: .init(.q, modifiers: [.option]))

Stored custom shortcuts continue to override the new default.

- [ ] **Step 4: Test, build and commit**

    swift test --package-path Apps/Mac --filter CaptureAndAsk
    swift test --package-path Apps/Mac --filter KeyboardShortcutNamesTests
    swift build --package-path Apps/Mac
    git add Apps/Mac/Peekaboo/PeekabooApp.swift Apps/Mac/Peekaboo/Core/KeyboardShortcutNames.swift Apps/Mac/PeekabooTests/Core/KeyboardShortcutNamesTests.swift
    git commit -m "feat(mac): open screenshot chat with option q"

---

### Task 7: Regression verification and development DMG

**Files:**
- Modify only files needed to fix failures caused by Tasks 1 through 6.
- Keep build artifacts outside Git in the existing build output directory.

**Interfaces:**
- Consumes: completed panel, Markdown renderer and existing remote macOS build workflow.
- Produces: reviewed source plus an installable development App or DMG.

- [ ] **Step 1: Run the Mac package suite**

    swift test --package-path Apps/Mac

Expected: all Mac tests pass. Fix only causally related failures and rerun their focused suites first.

- [ ] **Step 2: Run format, lint and safe regression gates**

    pnpm run format
    pnpm run lint
    pnpm run test:safe

Expected: all commands exit zero. If this Mac lacks the required Xcode SDK, run the same commands on the existing remote macOS builder and retain output.

- [ ] **Step 3: Review the complete feature diff**

Review from bb0749f through HEAD for focus activation, window leaks, stale cross-session results, multi-display coordinates, lost Markdown text, unsafe links and accidental provider or persistence changes. Every correction begins with a failing regression test and ends with the focused plus full checks.

- [ ] **Step 4: Commit review fixes only when needed**

Stage only reviewed feature files and use:

    git commit -m "fix(mac): harden floating screenshot chat"

Do not create an empty commit.

- [ ] **Step 5: Build remotely without publishing**

Use the existing remote macOS build and packaging workflow from the final commit. Do not notarize or publish. Download the App or DMG to the user's Mac and verify its checksum.

- [ ] **Step 6: Execute the acceptance matrix**

1. Trigger ⌥Q over a browser and confirm the browser remains active.
2. Capture left, center and right regions; confirm fallback placement and no off-screen frame.
3. Drag horizontally and confirm Y does not change.
4. Expand and collapse; confirm every new capture starts collapsed.
5. Start two captures quickly; confirm one card and the second session wins.
6. Send two text follow-ups; confirm the same session and no duplicated screenshot.
7. Render headings, lists, a rule, quote, code, bold and a link in floating and main windows.
8. Force an AI error; confirm readable inline error and Retry.
9. Close during analysis; confirm completion does not reopen, then confirm a new capture does.

- [ ] **Step 7: Report final evidence**

    git status --short
    git log --oneline bb0749f..HEAD

Report the App or DMG absolute path, checksum, exact tests, manual acceptance results and any environment-limited checks.
