import CoreGraphics
import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
struct ScreenshotPresentationContextTests {
    @Test
    func `Presentation identifies the exact capture and whether the session is new`() {
        let captureID = UUID()
        let context = ScreenshotPresentationContext(
            sessionID: "session-1",
            captureID: captureID,
            selectionRect: CGRect(x: 10, y: 20, width: 100, height: 80),
            displayID: nil,
            isNewSession: false)

        #expect(context.captureID == captureID)
        #expect(!context.isNewSession)
        #expect(context.displayID == nil)
    }
}
