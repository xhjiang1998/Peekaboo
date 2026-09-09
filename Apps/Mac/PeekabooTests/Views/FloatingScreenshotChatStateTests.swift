import CoreGraphics
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
    func sharedScreenshotControlsUseTheFloatingCardLayoutContract() {
        #expect(ScreenshotPreviewCard.collapsedHeight == 100)
        #expect(ScreenshotPreviewCard.expandedMaximumHeight == 280)
        #expect(FloatingScreenshotChatView.cardWidth == 460)
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

    private static func context(sessionID: String) -> ScreenshotPresentationContext {
        ScreenshotPresentationContext(
            sessionID: sessionID,
            selectionRect: CGRect(x: 100, y: 300, width: 200, height: 100),
            displayID: 7)
    }
}
