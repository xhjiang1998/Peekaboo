import AppKit
import SwiftUI

@MainActor
protocol FloatingPanelControlling: AnyObject {
    var frame: CGRect { get set }
    var isVisible: Bool { get }
    var minSize: CGSize { get set }
    var maxSize: CGSize { get set }
    var geometryEvents: FloatingPanelGeometryEvents? { get set }
    func setFrame(_ frameRect: CGRect, display flag: Bool)
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
}

@MainActor
struct FloatingPanelGeometryEvents {
    let didMove: () -> Void
    let didEndLiveResize: () -> Void
    let didChangeScreen: () -> Void
    let willResize: (CGSize) -> CGSize
    let resetToDefaultSize: () -> Void
}

@MainActor
final class FloatingScreenshotChatPanel: NSPanel, FloatingPanelControlling, NSWindowDelegate {
    private let onEscape: @MainActor () -> Void
    var geometryEvents: FloatingPanelGeometryEvents?

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
            contentRect: .zero,
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications, .fullScreenAuxiliary]
        self.minSize = FloatingPanelGeometry.minimumSize
        self.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        self.contentView = NSHostingView(rootView: rootView())
        self.setFrame(contentRect, display: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func cancelOperation(_ sender: Any?) {
        self.onEscape()
    }

    func requestDefaultSizeReset() {
        self.geometryEvents?.resetToDefaultSize()
    }

    func windowDidMove(_ notification: Notification) {
        self.geometryEvents?.didMove()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        self.geometryEvents?.didEndLiveResize()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        self.geometryEvents?.didChangeScreen()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        self.geometryEvents?.willResize(frameSize) ?? frameSize
    }

    @objc private func screenParametersDidChange() {
        self.geometryEvents?.didChangeScreen()
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
            screenFrames: { NSScreen.screens.map(\.visibleFrame) },
            mainVisibleFrame: { NSScreen.main?.visibleFrame },
            geometryStore: FloatingPanelGeometryStore(),
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
