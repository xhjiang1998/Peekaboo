import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct FloatingScreenshotChatPanelControllerTests {
    @Test
    func panelMovesToTheActiveSpaceAndSupportsFullScreenWithoutJoiningEverySpace() {
        let panel = FloatingScreenshotChatPanel(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 600),
            onEscape: {}) {
                EmptyView()
            }

        #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(panel.collectionBehavior.contains(.canJoinAllApplications))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.borderless))
        #expect(panel.titleVisibility == .hidden)
        #expect(panel.titlebarAppearsTransparent)
        #expect(panel.minSize == CGSize(width: 360, height: 260))
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)
    }

    @Test
    func repeatedPresentationReusesOnePanelAndReplacesStateWithoutActivatingApp() throws {
        let first = Self.context(
            sessionID: "first",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7)
        let second = Self.context(
            sessionID: "second",
            selectionRect: CGRect(x: 900, y: 500, width: 200, height: 100),
            displayID: 8)
        let fixture = PanelControllerFixture()

        fixture.controller.present(first)
        fixture.controller.state.togglePreview()
        fixture.controller.present(second)

        #expect(fixture.createdPanels.count == 1)
        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.orderFrontRegardlessCallCount == 2)
        #expect(fixture.controller.state.currentContext == second)
        #expect(!fixture.controller.state.isPreviewExpanded)
        #expect(fixture.requestedDisplayIDs == [7, 8])
        #expect(panel.frame.origin == CGPoint(x: 428, y: 16))
        #expect(panel.frame.size == CGSize(width: 460, height: 600))
        #expect(fixture.events == ["create", "front", "front"])
    }

    @Test
    func panelHeightIsLimitedByDisplayVisibleFrame() throws {
        let fixture = PanelControllerFixture(
            visibleFrames: [7: CGRect(x: 0, y: 20, width: 900, height: 500)])

        fixture.controller.present(Self.context(
            sessionID: "short-display",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))

        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.frame.size == CGSize(width: 460, height: 468))
        #expect(panel.maxSize == CGSize(width: 868, height: 468))
    }

    @Test
    func savedWindowFrameIsNormalizedAndRestoredForANewSession() throws {
        let store = TestFloatingPanelGeometryStore(
            frame: CGRect(x: -2_000, y: -1_000, width: 900, height: 900))
        let fixture = PanelControllerFixture(geometryStore: store)

        fixture.controller.present(Self.context(
            sessionID: "restored",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))

        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.frame == CGRect(x: 16, y: 16, width: 900, height: 868))
        #expect(store.savedFrames.isEmpty)
    }

    @Test
    func anotherCaptureInTheSameSessionPreservesUserGeometryOnTheSameDisplay() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "same",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: 300, y: 180, width: 720, height: 500)

        fixture.controller.present(Self.context(
            sessionID: "same",
            selectionRect: CGRect(x: 800, y: 500, width: 200, height: 100),
            displayID: 7,
            isNewSession: false))

        #expect(panel.frame == CGRect(x: 300, y: 180, width: 720, height: 500))
        #expect(panel.orderOutCallCount == 0)
    }

    @Test
    func captureOnAnotherDisplayHidesThenRoutesTheExistingPanelAndPreservesSize() throws {
        let fixture = PanelControllerFixture(visibleFrames: [
            7: CGRect(x: 0, y: 0, width: 1440, height: 900),
            8: CGRect(x: -1440, y: 0, width: 1440, height: 900),
        ])
        fixture.controller.present(Self.context(
            sessionID: "same",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: 300, y: 180, width: 720, height: 500)

        fixture.controller.present(Self.context(
            sessionID: "same",
            selectionRect: CGRect(x: -1_300, y: 500, width: 200, height: 100),
            displayID: 8,
            isNewSession: false))

        #expect(panel.orderOutCallCount == 1)
        #expect(panel.frame.size == CGSize(width: 720, height: 500))
        #expect(panel.frame.minX >= -1424)
        #expect(panel.frame.maxX <= -16)
        #expect(fixture.events == ["create", "front", "out", "front"])
    }

    @Test
    func moveCallbackNormalizesAndPersistsWithoutRecursiveWrites() throws {
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(geometryStore: store)
        fixture.controller.present(Self.context(
            sessionID: "move",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: -200, y: -300, width: 460, height: 600)

        panel.sendDidMove()

        #expect(panel.frame == CGRect(x: 16, y: 16, width: 460, height: 600))
        #expect(panel.setFrameCallCount == 1)
        #expect(store.savedFrames == [panel.frame])
    }

    @Test
    func rapidMoveCallbacksPersistOnlyTheLatestFrame() throws {
        var scheduledActions: [@MainActor () -> Void] = []
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(
            geometryStore: store,
            scheduleMovePersistence: { scheduledActions.append($0) })
        fixture.controller.present(Self.context(
            sessionID: "debounce",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)

        panel.frame = CGRect(x: -100, y: 50, width: 460, height: 600)
        panel.sendDidMove()
        panel.frame = CGRect(x: 1_200, y: 50, width: 460, height: 600)
        panel.sendDidMove()
        #expect(scheduledActions.count == 2)

        scheduledActions[0]()
        #expect(store.savedFrames.isEmpty)
        scheduledActions[1]()
        #expect(store.savedFrames == [CGRect(x: 964, y: 50, width: 460, height: 600)])
    }

    @Test
    func liveResizeIsConstrainedAndItsEndIsImmediatelyNormalizedAndSaved() throws {
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(geometryStore: store)
        fixture.controller.present(Self.context(
            sessionID: "resize",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)

        #expect(panel.proposeResize(CGSize(width: 100, height: 2_000)) == CGSize(width: 360, height: 868))
        panel.frame = CGRect(x: 1_300, y: 800, width: 600, height: 500)
        panel.sendDidEndLiveResize()

        #expect(panel.frame == CGRect(x: 824, y: 384, width: 600, height: 500))
        #expect(store.savedFrames == [panel.frame])
    }

    @Test
    func screenChangeRefreshesMaximumSizeAndNormalizes() throws {
        var screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(
            visibleFrames: [7: screens[0]],
            screenFrames: { screens },
            geometryStore: store)
        fixture.controller.present(Self.context(
            sessionID: "screen",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: 500, y: 400, width: 800, height: 700)
        screens = [CGRect(x: 0, y: 0, width: 900, height: 600)]

        panel.sendDidChangeScreen()

        #expect(panel.maxSize == CGSize(width: 868, height: 568))
        #expect(panel.frame == CGRect(x: 84, y: 16, width: 800, height: 568))
        #expect(store.savedFrames == [panel.frame])
    }

    @Test
    func emptyScreenSnapshotDoesNotModifyOrPersistGeometry() throws {
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(
            screenFrames: { [] },
            geometryStore: store)
        fixture.controller.present(Self.context(
            sessionID: "empty",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: -100, y: -100, width: 460, height: 600)

        panel.sendDidMove()

        #expect(panel.frame == CGRect(x: -100, y: -100, width: 460, height: 600))
        #expect(store.savedFrames.isEmpty)
    }

    @Test
    func defaultSizeResetKeepsOriginWhenItFitsAndPersists() throws {
        let store = TestFloatingPanelGeometryStore()
        let fixture = PanelControllerFixture(geometryStore: store)
        fixture.controller.present(Self.context(
            sessionID: "reset",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame = CGRect(x: 300, y: 200, width: 900, height: 400)

        panel.sendResetToDefaultSize()

        #expect(panel.frame == CGRect(x: 300, y: 200, width: 460, height: 600))
        #expect(store.savedFrames == [panel.frame])
    }

    @Test
    func dismissOrdersReusablePanelOutMarksGenerationAndEndsReuseCycle() throws {
        let fixture = PanelControllerFixture()
        var dismissCallCount = 0
        fixture.controller.onDismiss = { dismissCallCount += 1 }
        fixture.controller.present(Self.context(
            sessionID: "session",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))

        fixture.controller.dismiss()

        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.orderOutCallCount == 1)
        #expect(fixture.controller.state.isDismissedForCurrentPresentation)
        #expect(dismissCallCount == 1)
    }

    @Test
    func escapeRoutesThroughControllerDismissal() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "session",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))

        let panel = try #require(fixture.createdPanels.first)
        panel.sendEscape()

        #expect(panel.orderOutCallCount == 1)
        #expect(fixture.controller.state.isDismissedForCurrentPresentation)
    }

    @Test
    func horizontalMovementPreservesYAndClampsXToVisibleFrame() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "session",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let panel = try #require(fixture.createdPanels.first)
        panel.frame.origin.y = 123

        fixture.controller.moveHorizontally(translation: -1_000, startX: 200)
        #expect(panel.frame.origin == CGPoint(x: 16, y: 123))

        fixture.controller.moveHorizontally(translation: 2_000, startX: 200)
        #expect(panel.frame.origin == CGPoint(x: 964, y: 123))
    }

    @Test
    func horizontalMovementBeforePresentationDoesNothing() {
        let fixture = PanelControllerFixture()

        fixture.controller.moveHorizontally(translation: 100, startX: 200)

        #expect(fixture.createdPanels.isEmpty)
        #expect(fixture.requestedDisplayIDs.isEmpty)
    }

    @Test
    func unresolvedInitialDisplayUpdatesStateWithoutCreatingPanel() {
        let fixture = PanelControllerFixture(visibleFrames: [:])
        let context = Self.context(
            sessionID: "missing-display",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 999)

        fixture.controller.present(context)

        #expect(fixture.createdPanels.isEmpty)
        #expect(fixture.controller.state.currentContext == context)
    }

    @Test
    func missingDisplayIdentityUsesTheScreenWithGreatestSelectionIntersection() throws {
        let fixture = PanelControllerFixture(visibleFrames: [
            7: CGRect(x: 0, y: 0, width: 1440, height: 900),
            8: CGRect(x: -1440, y: 0, width: 1440, height: 900),
        ])

        fixture.controller.present(Self.context(
            sessionID: "fallback",
            selectionRect: CGRect(x: -1_300, y: 300, width: 200, height: 100),
            displayID: nil))

        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.frame.minX >= -1424)
        #expect(panel.frame.maxX <= -16)
    }

    @Test
    func missingDisplayIdentityFallsBackToSelectionScreenWithoutHidingThePanel() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "valid-a",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        let missingIdentity = Self.context(
            sessionID: "missing-display-identity",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: nil)

        fixture.controller.present(missingIdentity)

        let panel = try #require(fixture.createdPanels.first)
        #expect(fixture.controller.state.currentContext == missingIdentity)
        #expect(panel.isVisible)
        #expect(panel.orderOutCallCount == 0)
        #expect(fixture.requestedDisplayIDs == [7])
    }

    @Test
    func unresolvedDisplayIdentityFallsBackToSelectionScreen() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "valid-a",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))
        fixture.controller.state.togglePreview()
        let unresolved = Self.context(
            sessionID: "unresolved-b",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 999)

        fixture.controller.present(unresolved)

        let panel = try #require(fixture.createdPanels.first)
        #expect(fixture.controller.state.currentContext == unresolved)
        #expect(fixture.controller.state.presentationGeneration == 2)
        #expect(!fixture.controller.state.isPreviewExpanded)
        #expect(panel.isVisible)
        #expect(panel.orderOutCallCount == 0)
        #expect(fixture.requestedDisplayIDs == [7, 999])
    }

    private static func context(
        sessionID: String,
        selectionRect: CGRect,
        displayID: CGDirectDisplayID?,
        isNewSession: Bool = true) -> ScreenshotPresentationContext
    {
        ScreenshotPresentationContext(
            sessionID: sessionID,
            selectionRect: selectionRect,
            displayID: displayID,
            isNewSession: isNewSession)
    }
}

@MainActor
private final class PanelControllerFixture {
    private let visibleFrames: [CGDirectDisplayID: CGRect]
    private(set) var createdPanels: [TestFloatingPanel] = []
    private(set) var requestedDisplayIDs: [CGDirectDisplayID] = []
    private(set) var events: [String] = []
    private(set) lazy var controller = FloatingScreenshotChatPanelController(
        visibleFrameForDisplay: { [weak self] displayID in
            self?.requestedDisplayIDs.append(displayID)
            return self?.visibleFrames[displayID]
        },
        screenFrames: self.screenFrames,
        mainVisibleFrame: { [weak self] in self?.visibleFrames[7] },
        geometryStore: self.geometryStore,
        scheduleMovePersistence: self.scheduleMovePersistence,
        panelFactory: { [weak self] frame, onEscape in
            let panel = TestFloatingPanel(
                frame: frame,
                onEscape: onEscape,
                onOrderFront: { [weak self] in self?.events.append("front") },
                onOrderOut: { [weak self] in self?.events.append("out") })
            self?.createdPanels.append(panel)
            self?.events.append("create")
            return panel
        })

    private let screenFrames: @MainActor () -> [CGRect]
    private let geometryStore: TestFloatingPanelGeometryStore
    private let scheduleMovePersistence: FloatingScreenshotChatPanelController.MovePersistenceScheduler

    init(
        visibleFrames: [CGDirectDisplayID: CGRect] = [
            7: CGRect(x: 0, y: 0, width: 1440, height: 900),
            8: CGRect(x: 0, y: 0, width: 1440, height: 900),
        ],
        screenFrames: (@MainActor () -> [CGRect])? = nil,
        geometryStore: TestFloatingPanelGeometryStore = TestFloatingPanelGeometryStore(),
        scheduleMovePersistence: @escaping FloatingScreenshotChatPanelController.MovePersistenceScheduler = {
            action in action()
        })
    {
        self.visibleFrames = visibleFrames
        self.screenFrames = screenFrames ?? { Array(visibleFrames.values) }
        self.geometryStore = geometryStore
        self.scheduleMovePersistence = scheduleMovePersistence
    }
}

@MainActor
private final class TestFloatingPanel: FloatingPanelControlling {
    var frame: CGRect
    var minSize = CGSize.zero
    var maxSize = CGSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    var geometryEvents: FloatingPanelGeometryEvents?
    private(set) var isVisible = false
    private(set) var orderFrontRegardlessCallCount = 0
    private(set) var orderOutCallCount = 0
    private(set) var setFrameCallCount = 0

    private let onEscape: @MainActor () -> Void
    private let onOrderFront: @MainActor () -> Void
    private let onOrderOut: @MainActor () -> Void

    init(
        frame: CGRect,
        onEscape: @escaping @MainActor () -> Void,
        onOrderFront: @escaping @MainActor () -> Void,
        onOrderOut: @escaping @MainActor () -> Void)
    {
        self.frame = frame
        self.onEscape = onEscape
        self.onOrderFront = onOrderFront
        self.onOrderOut = onOrderOut
    }

    func orderFrontRegardless() {
        self.isVisible = true
        self.orderFrontRegardlessCallCount += 1
        self.onOrderFront()
    }

    func orderOut(_ sender: Any?) {
        self.isVisible = false
        self.orderOutCallCount += 1
        self.onOrderOut()
    }

    func setFrame(_ frame: CGRect, display _: Bool) {
        self.frame = frame
        self.setFrameCallCount += 1
        self.geometryEvents?.didMove()
    }

    func sendDidMove() { self.geometryEvents?.didMove() }
    func sendDidEndLiveResize() { self.geometryEvents?.didEndLiveResize() }
    func sendDidChangeScreen() { self.geometryEvents?.didChangeScreen() }
    func proposeResize(_ size: CGSize) -> CGSize { self.geometryEvents?.willResize(size) ?? size }
    func sendResetToDefaultSize() { self.geometryEvents?.resetToDefaultSize() }

    func sendEscape() {
        self.onEscape()
    }
}

@MainActor
private final class TestFloatingPanelGeometryStore: FloatingPanelGeometryStoring {
    private let frame: CGRect?
    private(set) var savedFrames: [CGRect] = []

    init(frame: CGRect? = nil) {
        self.frame = frame
    }

    func loadFrame() -> CGRect? { self.frame }
    func saveFrame(_ frame: CGRect) { self.savedFrames.append(frame) }
}
