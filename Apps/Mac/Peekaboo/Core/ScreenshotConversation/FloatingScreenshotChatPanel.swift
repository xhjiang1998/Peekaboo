import AppKit
import SwiftUI

@MainActor
protocol FloatingPanelControlling: AnyObject {
    var frame: CGRect { get set }
    var isVisible: Bool { get }
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
}

@MainActor
final class FloatingScreenshotChatPanel: NSPanel, FloatingPanelControlling {
    private let onEscape: @MainActor () -> Void

    override var frame: CGRect {
        get { super.frame }
        set { self.setFrame(newValue, display: false) }
    }

    override var canBecomeKey: Bool { true }

    init<Content: View>(
        contentRect: CGRect,
        onEscape: @escaping @MainActor () -> Void,
        @ViewBuilder rootView: () -> Content)
    {
        self.onEscape = onEscape
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = NSHostingView(rootView: rootView())
    }

    override func cancelOperation(_ sender: Any?) {
        self.onEscape()
    }
}

extension FloatingScreenshotChatPanelController {
    convenience init<Content: View>(
        @ViewBuilder rootView: @escaping (FloatingScreenshotChatState) -> Content)
    {
        let state = FloatingScreenshotChatState()
        self.init(state: state, rootView: rootView)
    }

    convenience init<Content: View>(
        state: FloatingScreenshotChatState,
        @ViewBuilder rootView: @escaping (FloatingScreenshotChatState) -> Content)
    {
        self.init(
            state: state,
            visibleFrameForDisplay: Self.visibleFrame,
            panelFactory: { frame, onEscape in
                FloatingScreenshotChatPanel(
                    contentRect: frame,
                    onEscape: onEscape) {
                        rootView(state)
                    }
            })
    }

    private static func visibleFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == displayID
        })?.visibleFrame
    }
}
