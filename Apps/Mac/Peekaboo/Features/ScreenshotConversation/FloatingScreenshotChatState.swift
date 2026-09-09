import Observation

@Observable
@MainActor
final class FloatingScreenshotChatState {
    private(set) var currentContext: ScreenshotPresentationContext?
    var isPreviewExpanded = false
    private(set) var presentationGeneration = 0
    private(set) var dismissedGeneration: Int?

    var isDismissedForCurrentPresentation: Bool {
        self.currentContext != nil && self.dismissedGeneration == self.presentationGeneration
    }

    func present(_ context: ScreenshotPresentationContext) {
        self.currentContext = context
        self.isPreviewExpanded = false
        self.presentationGeneration += 1
        self.dismissedGeneration = nil
    }

    func togglePreview() {
        self.isPreviewExpanded.toggle()
    }

    func markDismissed() {
        guard self.currentContext != nil else { return }
        self.dismissedGeneration = self.presentationGeneration
    }
}
