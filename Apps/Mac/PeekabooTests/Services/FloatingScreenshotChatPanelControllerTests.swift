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
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
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
    }

    @Test
    func dismissOrdersReusablePanelOutAndMarksGenerationDismissed() throws {
        let fixture = PanelControllerFixture()
        fixture.controller.present(Self.context(
            sessionID: "session",
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7))

        fixture.controller.dismiss()

        let panel = try #require(fixture.createdPanels.first)
        #expect(panel.orderOutCallCount == 1)
        #expect(fixture.controller.state.isDismissedForCurrentPresentation)
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
    func missingDisplayIdentityUpdatesStateAndHidesVisibleOldPanel() throws {
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
        #expect(!panel.isVisible)
        #expect(panel.orderOutCallCount == 1)
        #expect(fixture.requestedDisplayIDs == [7])
    }

    @Test
    func unresolvedNewDisplayReplacesStateAndHidesVisibleOldPanel() throws {
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
        #expect(!panel.isVisible)
        #expect(panel.orderOutCallCount == 1)
    }

    private static func context(
        sessionID: String,
        selectionRect: CGRect,
        displayID: CGDirectDisplayID?) -> ScreenshotPresentationContext
    {
        ScreenshotPresentationContext(
            sessionID: sessionID,
            selectionRect: selectionRect,
            displayID: displayID)
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
        panelFactory: { [weak self] frame, onEscape in
            let panel = TestFloatingPanel(
                frame: frame,
                onEscape: onEscape,
                onOrderFront: { [weak self] in self?.events.append("front") })
            self?.createdPanels.append(panel)
            self?.events.append("create")
            return panel
        })

    init(visibleFrames: [CGDirectDisplayID: CGRect] = [
        7: CGRect(x: 0, y: 0, width: 1440, height: 900),
        8: CGRect(x: 0, y: 0, width: 1440, height: 900),
    ]) {
        self.visibleFrames = visibleFrames
    }
}

@MainActor
private final class TestFloatingPanel: FloatingPanelControlling {
    var frame: CGRect
    private(set) var isVisible = false
    private(set) var orderFrontRegardlessCallCount = 0
    private(set) var orderOutCallCount = 0

    private let onEscape: @MainActor () -> Void
    private let onOrderFront: @MainActor () -> Void

    init(
        frame: CGRect,
        onEscape: @escaping @MainActor () -> Void,
        onOrderFront: @escaping @MainActor () -> Void)
    {
        self.frame = frame
        self.onEscape = onEscape
        self.onOrderFront = onOrderFront
    }

    func orderFrontRegardless() {
        self.isVisible = true
        self.orderFrontRegardlessCallCount += 1
        self.onOrderFront()
    }

    func orderOut(_ sender: Any?) {
        self.isVisible = false
        self.orderOutCallCount += 1
    }

    func sendEscape() {
        self.onEscape()
    }
}
