import CoreGraphics

struct ScreenshotPresentationContext: Equatable, Sendable {
    let sessionID: String
    let selectionRect: CGRect
    let displayID: CGDirectDisplayID?
}

@MainActor
protocol ScreenshotConversationPresenting: AnyObject {
    func present(_ context: ScreenshotPresentationContext)
    func dismiss()
}
