import CoreGraphics

@MainActor
final class FloatingScreenshotChatPanelController: ScreenshotConversationPresenting {
    static let panelWidth: CGFloat = 460
    static let maximumPanelHeight: CGFloat = 600

    typealias VisibleFrameLookup = (CGDirectDisplayID) -> CGRect?
    typealias PanelFactory = (
        _ frame: CGRect,
        _ onEscape: @escaping @MainActor () -> Void) -> any FloatingPanelControlling

    let state: FloatingScreenshotChatState

    private let visibleFrameForDisplay: VisibleFrameLookup
    private let panelFactory: PanelFactory
    private var panel: (any FloatingPanelControlling)?

    init(
        state: FloatingScreenshotChatState,
        visibleFrameForDisplay: @escaping VisibleFrameLookup,
        panelFactory: @escaping PanelFactory)
    {
        self.state = state
        self.visibleFrameForDisplay = visibleFrameForDisplay
        self.panelFactory = panelFactory
    }

    convenience init(
        visibleFrameForDisplay: @escaping VisibleFrameLookup,
        panelFactory: @escaping PanelFactory)
    {
        self.init(
            state: FloatingScreenshotChatState(),
            visibleFrameForDisplay: visibleFrameForDisplay,
            panelFactory: panelFactory)
    }

    func present(_ context: ScreenshotPresentationContext) {
        self.state.present(context)
        guard let visibleFrame = self.visibleFrameForDisplay(context.displayID) else {
            self.panel?.orderOut(nil)
            return
        }

        let panelSize = CGSize(
            width: Self.panelWidth,
            height: min(Self.maximumPanelHeight, visibleFrame.height - 32))
        let panelFrame = CGRect(
            origin: FloatingPanelPlacement.origin(
                selectionRect: context.selectionRect,
                visibleFrame: visibleFrame,
                panelSize: panelSize),
            size: panelSize)

        if let panel = self.panel {
            panel.frame = panelFrame
        } else {
            self.panel = self.panelFactory(panelFrame) { [weak self] in
                self?.dismiss()
            }
        }
        self.panel?.orderFrontRegardless()
    }

    func dismiss() {
        self.state.markDismissed()
        self.panel?.orderOut(nil)
    }

    func moveHorizontally(translation: CGFloat, startX: CGFloat) {
        guard let panel = self.panel,
              let context = self.state.currentContext,
              let visibleFrame = self.visibleFrameForDisplay(context.displayID)
        else {
            return
        }

        var frame = panel.frame
        frame.origin.x = FloatingPanelPlacement.clampedX(
            startX + translation,
            visibleFrame: visibleFrame,
            panelWidth: frame.width)
        panel.frame = frame
    }
}
