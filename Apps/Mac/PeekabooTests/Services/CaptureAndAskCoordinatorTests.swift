import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct CaptureAndAskCoordinatorTests {
    @Test
    func `Successful capture presents conversation before analysis`() async {
        var events: [String] = []
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let captureRect = CGRect(x: 10, y: 780, width: 200, height: 100)
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: {
                events.append("permission")
                return true
            },
            selectArea: {
                events.append("select")
                return selection
            },
            resolveCaptureRect: { rect in
                #expect(rect == selection.rect)
                return captureRect
            },
            captureArea: { rect in
                events.append("capture")
                #expect(rect == captureRect)
                return Data([1, 2, 3])
            },
            createConversation: { imageData in
                events.append("create")
                #expect(imageData == Data([1, 2, 3]))
                return "screenshot-session"
            },
            presentWindow: { sessionID in
                events.append("present:\(sessionID)")
            },
            analyze: { sessionID in
                events.append("analyze:\(sessionID)")
            })

        await coordinator.performCapture()

        #expect(events == [
            "permission",
            "select",
            "capture",
            "create",
            "present:screenshot-session",
            "analyze:screenshot-session",
        ])
        #expect(coordinator.state == .ready(sessionID: "screenshot-session"))
    }

    @Test
    func `Cancelling selection returns to idle without capturing`() async {
        var didCapture = false
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { nil },
            resolveCaptureRect: { $0 },
            captureArea: { _ in
                didCapture = true
                return Data()
            },
            createConversation: { _ in "unused" },
            presentWindow: { _ in },
            analyze: { _ in })

        await coordinator.performCapture()

        #expect(!didCapture)
        #expect(coordinator.state == .idle)
    }

    @Test
    func `Missing screen recording permission stops before selection`() async {
        var didSelect = false
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { false },
            selectArea: {
                didSelect = true
                return nil
            },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data() },
            createConversation: { _ in "unused" },
            presentWindow: { _ in },
            analyze: { _ in })

        await coordinator.performCapture()

        #expect(!didSelect)
        #expect(coordinator.state == .failed(.screenRecordingDenied))
    }

    @Test
    func `Repeated shortcut does not start a second selection`() async {
        var selectionCount = 0
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: {
                selectionCount += 1
                try? await Task.sleep(for: .milliseconds(30))
                return nil
            },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data() },
            createConversation: { _ in "unused" },
            presentWindow: { _ in },
            analyze: { _ in })

        coordinator.startCapture()
        coordinator.startCapture()
        try? await Task.sleep(for: .milliseconds(60))

        #expect(selectionCount == 1)
        #expect(coordinator.state == .idle)
    }
}
