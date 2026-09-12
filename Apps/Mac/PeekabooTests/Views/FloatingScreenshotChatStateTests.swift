import CoreGraphics
import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
@MainActor
struct FloatingScreenshotChatStateTests {
    @Test
    func presentReplacesContextResetsPreviewAndStartsNewGeneration() {
        let state = FloatingScreenshotChatState()
        let first = Self.context(sessionID: "first")
        let second = Self.context(sessionID: "second")

        state.present(first)
        #expect(!state.isPreviewExpanded)
        state.togglePreview()
        #expect(state.isPreviewExpanded)
        state.markDismissed()
        #expect(state.isDismissedForCurrentPresentation)
        state.present(second)

        #expect(state.currentContext == second)
        #expect(!state.isPreviewExpanded)
        #expect(state.presentationGeneration == 2)
        #expect(state.dismissedGeneration == nil)
        #expect(!state.isDismissedForCurrentPresentation)
    }

    @Test
    func sameSessionPresentationSelectsLatestCaptureWithoutCollapsingPreview() {
        let state = FloatingScreenshotChatState()
        let firstCaptureID = UUID()
        let secondCaptureID = UUID()

        state.present(Self.context(
            sessionID: "session",
            captureID: firstCaptureID,
            isNewSession: true))
        state.togglePreview()
        state.present(Self.context(
            sessionID: "session",
            captureID: secondCaptureID,
            isNewSession: false))

        #expect(state.currentContext?.captureID == secondCaptureID)
        #expect(state.selectedCaptureID == secondCaptureID)
        #expect(state.isPreviewExpanded)
        #expect(state.presentationGeneration == 2)
    }

    @Test
    func userCanSelectAnEarlierCaptureUntilANewCaptureArrives() {
        let state = FloatingScreenshotChatState()
        let firstCaptureID = UUID()
        let secondCaptureID = UUID()
        let thirdCaptureID = UUID()
        state.present(Self.context(
            sessionID: "session",
            captureID: firstCaptureID,
            isNewSession: true))
        state.present(Self.context(
            sessionID: "session",
            captureID: secondCaptureID,
            isNewSession: false))

        state.selectCapture(firstCaptureID)
        #expect(state.selectedCaptureID == firstCaptureID)

        state.present(Self.context(
            sessionID: "session",
            captureID: thirdCaptureID,
            isNewSession: false))
        #expect(state.selectedCaptureID == thirdCaptureID)
    }

    @Test
    func sharedScreenshotControlsUseTheFloatingCardLayoutContract() {
        #expect(ScreenshotPreviewCard.collapsedHeight == 100)
        #expect(ScreenshotPreviewCard.expandedMaximumHeight == 280)
        #expect(FloatingScreenshotChatView.cardWidth == 460)
        #expect(FloatingScreenshotChatView.conversationRegions == [
            .header,
            .scrollableConversation,
            .status,
            .composer,
        ])
    }

    @Test
    func followUpComposerTrimsInputBeforeSubmission() {
        #expect(ScreenshotFollowUpComposer.normalizedInput("  继续解释\n") == "继续解释")
        #expect(ScreenshotFollowUpComposer.normalizedInput(" \n\t ").isEmpty)
    }

    @Test
    func togglePreviewChangesExpansionForCurrentPresentation() {
        let state = FloatingScreenshotChatState()
        state.present(Self.context(sessionID: "session"))

        state.togglePreview()
        #expect(state.isPreviewExpanded)

        state.togglePreview()
        #expect(!state.isPreviewExpanded)
    }

    @Test
    func markDismissedAppliesOnlyToExistingCurrentPresentation() {
        let state = FloatingScreenshotChatState()

        state.markDismissed()
        #expect(state.dismissedGeneration == nil)
        #expect(!state.isDismissedForCurrentPresentation)

        state.present(Self.context(sessionID: "session"))
        state.markDismissed()

        #expect(state.dismissedGeneration == state.presentationGeneration)
        #expect(state.isDismissedForCurrentPresentation)
    }

    private static func context(
        sessionID: String,
        captureID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        isNewSession: Bool = true) -> ScreenshotPresentationContext
    {
        ScreenshotPresentationContext(
            sessionID: sessionID,
            captureID: captureID,
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7,
            isNewSession: isNewSession)
    }
}
