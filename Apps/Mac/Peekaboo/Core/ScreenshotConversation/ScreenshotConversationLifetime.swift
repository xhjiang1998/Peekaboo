import Foundation
import Observation

@Observable
@MainActor
final class ScreenshotConversationLifetime {
    private(set) var reusableSessionID: String?

    func bind(sessionID: String) {
        self.reusableSessionID = sessionID
    }

    func endReuseCycle() {
        self.reusableSessionID = nil
    }
}
