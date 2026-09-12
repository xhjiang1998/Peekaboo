import CoreGraphics

@MainActor
final class FloatingScreenshotChatPanelController: ScreenshotConversationPresenting {
    static let panelWidth: CGFloat = 460
    static let maximumPanelHeight: CGFloat = 600

    typealias VisibleFrameLookup = (CGDirectDisplayID) -> CGRect?
    typealias ScreenFramesLookup = @MainActor () -> [CGRect]
    typealias MainVisibleFrameLookup = @MainActor () -> CGRect?
    typealias MovePersistenceScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void
    typealias PanelFactory = (
        _ frame: CGRect,
        _ onEscape: @escaping @MainActor () -> Void) -> any FloatingPanelControlling

    let state: FloatingScreenshotChatState
    var onDismiss: (@MainActor () -> Void)?

    private let visibleFrameForDisplay: VisibleFrameLookup
    private let screenFrames: ScreenFramesLookup
    private let mainVisibleFrame: MainVisibleFrameLookup
    private let geometryStore: any FloatingPanelGeometryStoring
    private let scheduleMovePersistence: MovePersistenceScheduler
    private let panelFactory: PanelFactory
    private var panel: (any FloatingPanelControlling)?
    private var presentedDisplayID: CGDirectDisplayID?
    private var presentedVisibleFrame: CGRect?
    private var movePersistenceGeneration = 0
    private var hasPendingMovePersistence = false
    private var isApplyingFrame = false

    init(
        state: FloatingScreenshotChatState,
        visibleFrameForDisplay: @escaping VisibleFrameLookup,
        screenFrames: @escaping ScreenFramesLookup,
        mainVisibleFrame: @escaping MainVisibleFrameLookup,
        geometryStore: any FloatingPanelGeometryStoring,
        scheduleMovePersistence: @escaping MovePersistenceScheduler =
            FloatingScreenshotChatPanelController.scheduleAfterMoveDebounce,
        panelFactory: @escaping PanelFactory)
    {
        self.state = state
        self.visibleFrameForDisplay = visibleFrameForDisplay
        self.screenFrames = screenFrames
        self.mainVisibleFrame = mainVisibleFrame
        self.geometryStore = geometryStore
        self.scheduleMovePersistence = scheduleMovePersistence
        self.panelFactory = panelFactory
    }

    convenience init(
        visibleFrameForDisplay: @escaping VisibleFrameLookup,
        screenFrames: @escaping ScreenFramesLookup,
        mainVisibleFrame: @escaping MainVisibleFrameLookup,
        geometryStore: any FloatingPanelGeometryStoring,
        scheduleMovePersistence: @escaping MovePersistenceScheduler =
            FloatingScreenshotChatPanelController.scheduleAfterMoveDebounce,
        panelFactory: @escaping PanelFactory)
    {
        self.init(
            state: FloatingScreenshotChatState(),
            visibleFrameForDisplay: visibleFrameForDisplay,
            screenFrames: screenFrames,
            mainVisibleFrame: mainVisibleFrame,
            geometryStore: geometryStore,
            scheduleMovePersistence: scheduleMovePersistence,
            panelFactory: panelFactory)
    }

    func present(_ context: ScreenshotPresentationContext) {
        self.flushPendingMovePersistence()
        self.movePersistenceGeneration += 1
        let previousContext = self.state.currentContext
        self.state.present(context)
        guard let target = self.presentationTarget(for: context) else {
            self.panel?.orderFrontRegardless()
            return
        }
        let visibleFrame = target.visibleFrame

        let existingPanel = self.panel
        let isSameDisplay = self.isSamePresentedDisplay(
            as: target.displayID,
            visibleFrame: visibleFrame)
        let preservesGeometry = !context.isNewSession &&
            previousContext?.sessionID == context.sessionID &&
            isSameDisplay
        let routesToAnotherDisplay = existingPanel != nil &&
            self.presentedVisibleFrame != nil &&
            !isSameDisplay
        let panelFrame = self.frameForPresentation(
            context,
            visibleFrame: visibleFrame,
            existingFrame: existingPanel?.frame,
            preservesGeometry: preservesGeometry)

        if routesToAnotherDisplay {
            existingPanel?.orderOut(nil)
        }
        if let existingPanel {
            self.applyFrame(panelFrame, to: existingPanel)
        } else {
            self.panel = self.panelFactory(panelFrame) { [weak self] in
                self?.dismiss()
            }
            self.installGeometryEvents()
        }
        self.presentedDisplayID = target.displayID
        self.presentedVisibleFrame = visibleFrame
        self.updateSizeConstraints(fallbackScreen: visibleFrame)
        self.panel?.orderFrontRegardless()
    }

    func dismiss() {
        self.flushPendingMovePersistence()
        self.movePersistenceGeneration += 1
        self.state.markDismissed()
        self.panel?.orderOut(nil)
        self.onDismiss?()
    }

    func moveHorizontally(translation: CGFloat, startX: CGFloat) {
        guard let panel = self.panel,
              let context = self.state.currentContext,
              let displayID = context.displayID,
              let visibleFrame = self.visibleFrameForDisplay(displayID)
        else {
            return
        }

        var frame = panel.frame
        frame.origin.x = FloatingPanelPlacement.clampedX(
            startX + translation,
            visibleFrame: visibleFrame,
            panelWidth: frame.width)
        self.applyFrame(frame, to: panel)
    }

    private func frameForPresentation(
        _ context: ScreenshotPresentationContext,
        visibleFrame: CGRect,
        existingFrame: CGRect?,
        preservesGeometry: Bool) -> CGRect
    {
        let screens = self.screenFrames()
        if preservesGeometry,
           let existingFrame,
           let normalized = FloatingPanelGeometry.normalizedFrame(
               existingFrame,
               screens: [visibleFrame],
               fallbackScreen: visibleFrame)
        {
            return normalized
        }

        let savedFrame = context.isNewSession ? self.geometryStore.loadFrame() : nil
        let candidateScreens = screens.isEmpty ? [visibleFrame] : screens
        if let savedFrame,
           FloatingPanelGeometry.targetScreen(
               for: savedFrame,
               screens: candidateScreens,
               fallbackScreen: visibleFrame) == visibleFrame,
           let normalized = FloatingPanelGeometry.normalizedFrame(
               savedFrame,
               screens: [visibleFrame],
               fallbackScreen: visibleFrame)
        {
            return normalized
        }

        let proposedSize = savedFrame?.size ?? existingFrame?.size ?? FloatingPanelGeometry.defaultSize
        let maximumSize = FloatingPanelGeometry.maximumSize(for: visibleFrame)
        let panelSize = CGSize(
            width: min(proposedSize.width, maximumSize.width),
            height: min(proposedSize.height, maximumSize.height))
        let proposed = CGRect(
            origin: FloatingPanelPlacement.origin(
                selectionRect: context.selectionRect,
                visibleFrame: visibleFrame,
                panelSize: panelSize),
            size: panelSize)
        return FloatingPanelGeometry.normalizedFrame(
            proposed,
            screens: [visibleFrame],
            fallbackScreen: visibleFrame) ?? proposed
    }

    private func installGeometryEvents() {
        self.panel?.geometryEvents = FloatingPanelGeometryEvents(
            didMove: { [weak self] in self?.panelDidMove() },
            didEndLiveResize: { [weak self] in self?.panelDidEndLiveResize() },
            didChangeScreen: { [weak self] in self?.panelDidChangeScreen() },
            willResize: { [weak self] size in self?.constrainedResize(size) ?? size },
            resetToDefaultSize: { [weak self] in self?.resetToDefaultSize() })
    }

    private func panelDidMove() {
        guard !self.isApplyingFrame else { return }
        self.hasPendingMovePersistence = true
        self.movePersistenceGeneration += 1
        let generation = self.movePersistenceGeneration
        self.scheduleMovePersistence { [weak self] in
            guard let self, generation == self.movePersistenceGeneration else { return }
            self.hasPendingMovePersistence = false
            self.normalizeAndPersistFrame()
        }
    }

    private func panelDidChangeScreen() {
        self.hasPendingMovePersistence = false
        self.movePersistenceGeneration += 1
        guard !self.screenFrames().isEmpty else { return }
        self.updateSizeConstraints(fallbackScreen: self.currentFallbackScreen())
        self.normalizeAndPersistFrame()
    }

    private func panelDidEndLiveResize() {
        self.hasPendingMovePersistence = false
        self.movePersistenceGeneration += 1
        self.normalizeAndPersistFrame()
    }

    private func constrainedResize(_ proposedSize: CGSize) -> CGSize {
        guard let panel = self.panel else { return proposedSize }
        let maximum = panel.maxSize
        let minimum = CGSize(
            width: min(FloatingPanelGeometry.minimumSize.width, maximum.width),
            height: min(FloatingPanelGeometry.minimumSize.height, maximum.height))
        return CGSize(
            width: min(max(proposedSize.width, minimum.width), maximum.width),
            height: min(max(proposedSize.height, minimum.height), maximum.height))
    }

    private func resetToDefaultSize() {
        guard let panel = self.panel else { return }
        self.hasPendingMovePersistence = false
        self.movePersistenceGeneration += 1
        let proposed = CGRect(origin: panel.frame.origin, size: FloatingPanelGeometry.defaultSize)
        self.normalizeAndPersistFrame(proposedFrame: proposed)
    }

    private func normalizeAndPersistFrame(proposedFrame: CGRect? = nil) {
        guard !self.isApplyingFrame,
              let panel = self.panel
        else { return }
        let screens = self.screenFrames()
        guard !screens.isEmpty,
              let normalized = FloatingPanelGeometry.normalizedFrame(
                  proposedFrame ?? panel.frame,
                  screens: screens,
                  fallbackScreen: self.currentFallbackScreen())
        else { return }

        self.updateSizeConstraints(for: normalized, screens: screens, fallbackScreen: self.currentFallbackScreen())
        self.applyFrame(normalized, to: panel)
        self.geometryStore.saveFrame(normalized)
    }

    private func updateSizeConstraints(fallbackScreen: CGRect?) {
        guard let panel = self.panel else { return }
        let screens = self.screenFrames()
        self.updateSizeConstraints(for: panel.frame, screens: screens, fallbackScreen: fallbackScreen)
    }

    private func updateSizeConstraints(
        for frame: CGRect,
        screens: [CGRect],
        fallbackScreen: CGRect?)
    {
        guard let panel = self.panel,
              let targetScreen = FloatingPanelGeometry.targetScreen(
                  for: frame,
                  screens: screens.isEmpty ? fallbackScreen.map { [$0] } ?? [] : screens,
                  fallbackScreen: fallbackScreen)
        else { return }
        let maximum = FloatingPanelGeometry.maximumSize(for: targetScreen)
        panel.maxSize = maximum
        panel.minSize = CGSize(
            width: min(FloatingPanelGeometry.minimumSize.width, maximum.width),
            height: min(FloatingPanelGeometry.minimumSize.height, maximum.height))
    }

    private func currentFallbackScreen() -> CGRect? {
        if let presentedDisplayID,
           let frame = self.visibleFrameForDisplay(presentedDisplayID)
        {
            return frame
        }
        return self.presentedVisibleFrame ?? self.mainVisibleFrame()
    }

    private func presentationTarget(
        for context: ScreenshotPresentationContext) -> (visibleFrame: CGRect, displayID: CGDirectDisplayID?)?
    {
        if let displayID = context.displayID,
           let visibleFrame = self.visibleFrameForDisplay(displayID)
        {
            return (visibleFrame, displayID)
        }
        let screens = self.screenFrames()
        if screens.isEmpty {
            return self.mainVisibleFrame().map { ($0, nil) }
        }
        return FloatingPanelGeometry.targetScreen(
            for: context.selectionRect,
            screens: screens,
            fallbackScreen: self.mainVisibleFrame()).map { ($0, nil) }
    }

    private func isSamePresentedDisplay(
        as displayID: CGDirectDisplayID?,
        visibleFrame: CGRect) -> Bool
    {
        if let presentedDisplayID, let displayID {
            return presentedDisplayID == displayID
        }
        return self.presentedVisibleFrame == visibleFrame
    }

    private func flushPendingMovePersistence() {
        guard self.hasPendingMovePersistence else { return }
        self.hasPendingMovePersistence = false
        self.normalizeAndPersistFrame()
    }

    private func applyFrame(_ frame: CGRect, to panel: any FloatingPanelControlling) {
        guard panel.frame != frame else { return }
        self.isApplyingFrame = true
        panel.setFrame(frame, display: false)
        self.isApplyingFrame = false
    }

    private static func scheduleAfterMoveDebounce(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
