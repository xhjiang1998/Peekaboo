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
            presentConversation: { context in
                #expect(context.sessionID == "screenshot-session")
                #expect(context.selectionRect == selection.rect)
                #expect(context.displayID == selection.displayID)
                events.append("present:\(context.sessionID)")
            },
            analyze: { sessionID in
                events.append("analyze:\(sessionID)")
            },
            cancelConversation: { _ in })

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
            presentConversation: { _ in },
            analyze: { _ in },
            cancelConversation: { _ in })

        await coordinator.performCapture()

        #expect(!didCapture)
        #expect(coordinator.state == .idle)
    }

    @Test
    func `Selection focus restores the original application without activating Peekaboo`() {
        var events: [String] = []
        let focus = CaptureSelectionFocusController(
            captureRestoreAction: {
                events.append("capture-frontmost")
                return { events.append("restore-frontmost") }
            })

        focus.prepareForSelection()
        focus.restoreAfterSelection()
        focus.restoreAfterSelection()

        #expect(events == ["capture-frontmost", "restore-frontmost"])
    }

    @Test
    func `Missing screen recording permission stops before selection`() async {
        var didSelect = false
        var reportedFailures: [CaptureAndAskFailure] = []
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { false },
            selectArea: {
                didSelect = true
                return nil
            },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data() },
            createConversation: { _ in "unused" },
            presentConversation: { _ in },
            analyze: { _ in },
            cancelConversation: { _ in },
            reportFailure: { reportedFailures.append($0) })

        await coordinator.performCapture()

        #expect(!didSelect)
        #expect(coordinator.state == .failed(.screenRecordingDenied))
        #expect(reportedFailures == [.screenRecordingDenied])
    }

    @Test
    func `Analysis failure stays in conversation without showing a modal alert`() async {
        var reportedFailures: [CaptureAndAskFailure] = []
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in "screenshot-session" },
            presentConversation: { _ in },
            analyze: { _ in throw TestFailure.analysis },
            cancelConversation: { _ in },
            reportFailure: { reportedFailures.append($0) })

        await coordinator.performCapture()

        #expect(coordinator.state == .failed(.analysisFailed))
        #expect(reportedFailures.isEmpty)
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
            presentConversation: { _ in },
            analyze: { _ in },
            cancelConversation: { _ in })

        coordinator.startCapture()
        coordinator.startCapture()
        try? await Task.sleep(for: .milliseconds(60))

        #expect(selectionCount == 1)
    }

    @Test
    func `A slow analysis does not block starting another screenshot`() async {
        var selectionCount = 0
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: {
                selectionCount += 1
                return selection
            },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in UUID().uuidString },
            presentConversation: { _ in },
            analyze: { _ in
                try? await Task.sleep(for: .milliseconds(120))
            },
            cancelConversation: { _ in })

        coordinator.startCapture()
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.startCapture()
        try? await Task.sleep(for: .milliseconds(40))

        #expect(selectionCount == 2)
    }

    @Test
    func `Latest capture cancels prior analysis and ignores its late success`() async {
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let analyses = ControllableAnalyses()
        var sessionIDs = ["session-a", "session-b"]
        var presentedContexts: [ScreenshotPresentationContext] = []
        var cancelledSessionIDs: [String] = []
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in sessionIDs.removeFirst() },
            presentConversation: { presentedContexts.append($0) },
            analyze: { try await analyses.wait(for: $0) },
            cancelConversation: { cancelledSessionIDs.append($0) })

        coordinator.startCapture()
        let firstAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a"]
        }
        #expect(firstAnalysisStarted)

        coordinator.startCapture()
        let secondAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a", "session-b"]
        }
        #expect(secondAnalysisStarted)
        #expect(cancelledSessionIDs == ["session-a"])
        #expect(presentedContexts == [
            ScreenshotPresentationContext(
                sessionID: "session-a",
                selectionRect: selection.rect,
                displayID: selection.displayID),
            ScreenshotPresentationContext(
                sessionID: "session-b",
                selectionRect: selection.rect,
                displayID: selection.displayID),
        ])
        #expect(coordinator.state == .analyzing(sessionID: "session-b"))

        analyses.succeed("session-a")
        let staleAnalysisFinished = await self.waitUntil {
            analyses.finishedSessionIDs.contains("session-a")
        }
        #expect(staleAnalysisFinished)
        #expect(coordinator.state == .analyzing(sessionID: "session-b"))

        analyses.succeed("session-b")
        let latestAnalysisFinished = await self.waitUntil {
            coordinator.state == .ready(sessionID: "session-b")
        }
        #expect(latestAnalysisFinished)
        #expect(cancelledSessionIDs == ["session-a"])
    }

    @Test
    func `Late failure from cancelled analysis cannot replace latest ready state`() async {
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let analyses = ControllableAnalyses()
        var sessionIDs = ["session-a", "session-b"]
        var reportedFailures: [CaptureAndAskFailure] = []
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in sessionIDs.removeFirst() },
            presentConversation: { _ in },
            analyze: { try await analyses.wait(for: $0) },
            cancelConversation: { _ in },
            reportFailure: { reportedFailures.append($0) })

        coordinator.startCapture()
        let firstAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a"]
        }
        #expect(firstAnalysisStarted)
        coordinator.startCapture()
        let secondAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a", "session-b"]
        }
        #expect(secondAnalysisStarted)

        analyses.succeed("session-b")
        let latestAnalysisFinished = await self.waitUntil {
            coordinator.state == .ready(sessionID: "session-b")
        }
        #expect(latestAnalysisFinished)

        analyses.fail("session-a")
        let staleAnalysisFinished = await self.waitUntil {
            analyses.finishedSessionIDs.contains("session-a")
        }
        #expect(staleAnalysisFinished)
        #expect(coordinator.state == .ready(sessionID: "session-b"))
        #expect(reportedFailures.isEmpty)
    }

    @Test
    func `Late cancellation from superseded analysis cannot replace latest ready state`() async {
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        let analyses = ControllableAnalyses()
        var sessionIDs = ["session-a", "session-b"]
        var reportedFailures: [CaptureAndAskFailure] = []
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in sessionIDs.removeFirst() },
            presentConversation: { _ in },
            analyze: { try await analyses.wait(for: $0) },
            cancelConversation: { _ in },
            reportFailure: { reportedFailures.append($0) })

        coordinator.startCapture()
        let firstAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a"]
        }
        #expect(firstAnalysisStarted)
        coordinator.startCapture()
        let secondAnalysisStarted = await self.waitUntil {
            analyses.startedSessionIDs == ["session-a", "session-b"]
        }
        #expect(secondAnalysisStarted)

        analyses.succeed("session-b")
        let latestAnalysisFinished = await self.waitUntil {
            coordinator.state == .ready(sessionID: "session-b")
        }
        #expect(latestAnalysisFinished)

        analyses.cancel("session-a")
        let staleAnalysisFinished = await self.waitUntil {
            analyses.finishedSessionIDs.contains("session-a")
        }
        #expect(staleAnalysisFinished)
        #expect(coordinator.state == .ready(sessionID: "session-b"))
        #expect(reportedFailures.isEmpty)
    }

    @Test
    func `New capture cancels prior session request even after coordinator analysis finished`() async {
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        var sessionIDs = ["session-a", "session-b"]
        var cancelledSessionIDs: [String] = []
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { _ in sessionIDs.removeFirst() },
            presentConversation: { _ in },
            analyze: { _ in },
            cancelConversation: { cancelledSessionIDs.append($0) })

        await coordinator.performCapture()
        await coordinator.performCapture()

        #expect(cancelledSessionIDs == ["session-a"])
        #expect(coordinator.state == .ready(sessionID: "session-b"))
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private enum TestFailure: Error {
        case analysis
    }

    @MainActor
    private final class ControllableAnalyses {
        private(set) var startedSessionIDs: [String] = []
        private(set) var finishedSessionIDs: [String] = []
        private var continuations: [String: CheckedContinuation<Void, any Error>] = [:]

        func wait(for sessionID: String) async throws {
            self.startedSessionIDs.append(sessionID)
            defer { self.finishedSessionIDs.append(sessionID) }
            try await withCheckedThrowingContinuation { continuation in
                self.continuations[sessionID] = continuation
            }
        }

        func succeed(_ sessionID: String) {
            self.continuations.removeValue(forKey: sessionID)?.resume()
        }

        func fail(_ sessionID: String) {
            self.continuations.removeValue(forKey: sessionID)?.resume(throwing: TestFailure.analysis)
        }

        func cancel(_ sessionID: String) {
            self.continuations.removeValue(forKey: sessionID)?.resume(throwing: CancellationError())
        }
    }
}
