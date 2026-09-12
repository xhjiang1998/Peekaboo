import CoreGraphics
import Foundation

struct ScreenshotPresentationContext: Equatable, Sendable {
    let sessionID: String
    let captureID: UUID
    let selectionRect: CGRect
    let displayID: CGDirectDisplayID?
    let isNewSession: Bool

    init(
        sessionID: String,
        captureID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        selectionRect: CGRect,
        displayID: CGDirectDisplayID?,
        isNewSession: Bool = true)
    {
        self.sessionID = sessionID
        self.captureID = captureID
        self.selectionRect = selectionRect
        self.displayID = displayID
        self.isNewSession = isNewSession
    }
}

@MainActor
protocol ScreenshotConversationPresenting: AnyObject {
    func present(_ context: ScreenshotPresentationContext)
    func dismiss()
}
