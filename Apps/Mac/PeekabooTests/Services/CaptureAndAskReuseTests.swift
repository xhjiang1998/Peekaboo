import CoreGraphics
import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct CaptureAndAskReuseTests {
    @Test
    func cancellationDuringCaptureDoesNotSubmitOrReplaceTheOpenSession() async throws {
        let lifetime = ScreenshotConversationLifetime()
        lifetime.bind(sessionID: "existing")
        let selection = try #require(CaptureSelection(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), displayID: nil))
        var didSubmit = false
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data([1])
            },
            lifetime: lifetime,
            submitScreenshot: { _, _ in
                didSubmit = true
                return ScreenshotSubmission(sessionID: "new", captureID: UUID(), index: 1, isNewSession: true)
            },
            presentConversation: { _ in Issue.record("Cancelled capture was presented") },
            enqueueAnalysis: { _ in Issue.record("Cancelled capture was queued") })
        await Task { await coordinator.performCapture() }.value
        #expect(!didSubmit)
        #expect(lifetime.reusableSessionID == "existing")
    }

    @Test
    func repeatedCapturesReuseTheOpenFloatingConversationWithoutCancellingPriorWork() async throws {
        let lifetime = ScreenshotConversationLifetime()
        let selection = try #require(CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7))
        let firstCaptureID = UUID()
        let secondCaptureID = UUID()
        var reusableSessionIDs: [String?] = []
        var captureIDs = [firstCaptureID, secondCaptureID]
        var enqueued: [ScreenshotSubmission] = []
        var presented: [ScreenshotPresentationContext] = []

        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            lifetime: lifetime,
            submitScreenshot: { _, reusableSessionID in
                reusableSessionIDs.append(reusableSessionID)
                let isNewSession = reusableSessionID == nil
                return ScreenshotSubmission(
                    sessionID: reusableSessionID ?? "session-1",
                    captureID: captureIDs.removeFirst(),
                    index: reusableSessionIDs.count,
                    isNewSession: isNewSession)
            },
            presentConversation: { presented.append($0) },
            enqueueAnalysis: { enqueued.append($0) })

        await coordinator.performCapture()
        await coordinator.performCapture()

        #expect(reusableSessionIDs.count == 2)
        #expect(reusableSessionIDs[0] == nil)
        #expect(reusableSessionIDs[1] == "session-1")
        #expect(enqueued.map(\.captureID) == [firstCaptureID, secondCaptureID])
        #expect(presented.map(\.captureID) == [firstCaptureID, secondCaptureID])
        #expect(presented.map(\.isNewSession) == [true, false])
        #expect(lifetime.reusableSessionID == "session-1")
    }

    @Test
    func endingTheReuseCycleMakesTheNextCaptureRequestANewSession() async throws {
        let lifetime = ScreenshotConversationLifetime()
        lifetime.bind(sessionID: "old-session")
        lifetime.endReuseCycle()
        let selection = try #require(CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: nil))
        var reusableSessionID: String?

        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([4, 5, 6]) },
            lifetime: lifetime,
            submitScreenshot: { _, reusableID in
                reusableSessionID = reusableID
                return ScreenshotSubmission(
                    sessionID: "new-session",
                    captureID: UUID(),
                    index: 1,
                    isNewSession: true)
            },
            presentConversation: { _ in },
            enqueueAnalysis: { _ in })

        await coordinator.performCapture()

        #expect(reusableSessionID == nil)
        #expect(lifetime.reusableSessionID == "new-session")
    }
}
