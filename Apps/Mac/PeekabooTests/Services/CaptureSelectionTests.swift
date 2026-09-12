import AppKit
import CoreGraphics
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct CaptureSelectionTests {
    @Test
    func `Reverse drag is normalized without changing display identity`() throws {
        let selection = try #require(CaptureSelection(
            start: CGPoint(x: 220, y: 180),
            end: CGPoint(x: 20, y: 40),
            displayID: 42))

        #expect(selection.rect == CGRect(x: 20, y: 40, width: 200, height: 140))
        #expect(selection.displayID == 42)
    }

    @Test
    func `Negative global coordinates are preserved`() throws {
        let selection = try #require(CaptureSelection(
            start: CGPoint(x: -500, y: 300),
            end: CGPoint(x: -300, y: 450),
            displayID: nil))

        #expect(selection.rect == CGRect(x: -500, y: 300, width: 200, height: 150))
    }

    @Test(arguments: [
        (CGSize(width: 7.9, height: 100), false),
        (CGSize(width: 100, height: 7.9), false),
        (CGSize(width: 8, height: 8), true),
    ])
    func `Selection requires at least eight points in both dimensions`(
        size: CGSize,
        isValid: Bool)
    {
        let selection = CaptureSelection(
            start: .zero,
            end: CGPoint(x: size.width, y: size.height),
            displayID: 1)

        #expect((selection != nil) == isValid)
    }

    @Test
    func `Selection is clamped to the display where dragging started`() throws {
        let selection = try #require(CaptureSelection.clamped(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 900, y: -200),
            within: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayID: 42))

        #expect(selection.rect == CGRect(x: 100, y: 0, width: 700, height: 100))
        #expect(selection.displayID == 42)
    }

    @Test
    func `Selection panel policy supports full screen without becoming main`() {
        #expect(CaptureSelectionPanelPolicy.styleMask == [.borderless, .nonactivatingPanel])
        #expect(CaptureSelectionPanelPolicy.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(CaptureSelectionPanelPolicy.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(CaptureSelectionPanelPolicy.canBecomeKey)
        #expect(!CaptureSelectionPanelPolicy.canBecomeMain)
    }

    @Test
    func `Initial key panel follows the screen containing the mouse`() {
        let frames = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600),
        ]

        #expect(CaptureSelectionPanelPolicy.initialKeyPanelIndex(
            mouseLocation: CGPoint(x: 1200, y: 300),
            screenFrames: frames) == 1)
        #expect(CaptureSelectionPanelPolicy.initialKeyPanelIndex(
            mouseLocation: CGPoint(x: -100, y: 300),
            screenFrames: frames) == 0)
    }

    @Test
    func `Escape fallback monitor is active only for a selection key panel`() {
        #expect(CaptureSelectionPanelPolicy.needsEscapeFallback(
            hasSelectionKeyPanel: true,
            isResponderHandlingEscape: false))
        #expect(!CaptureSelectionPanelPolicy.needsEscapeFallback(
            hasSelectionKeyPanel: false,
            isResponderHandlingEscape: false))
        #expect(!CaptureSelectionPanelPolicy.needsEscapeFallback(
            hasSelectionKeyPanel: true,
            isResponderHandlingEscape: true))
    }

    @Test
    func `Escape fallback monitor is removed exactly once`() {
        let token = NSObject()
        var removeCount = 0
        let monitor = CaptureSelectionEscapeMonitor(
            addMonitor: { _ in token },
            removeMonitor: { removedToken in
                let isExpectedToken = (removedToken as AnyObject) === token
                #expect(isExpectedToken)
                removeCount += 1
            })

        monitor.start { $0 }
        monitor.stop()
        monitor.stop()

        #expect(removeCount == 1)
    }
}
