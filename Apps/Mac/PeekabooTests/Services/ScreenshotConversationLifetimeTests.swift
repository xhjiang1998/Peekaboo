import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct ScreenshotConversationLifetimeTests {
    @Test
    func `Binding exposes one reusable session until the cycle ends`() {
        let lifetime = ScreenshotConversationLifetime()

        #expect(lifetime.reusableSessionID == nil)

        lifetime.bind(sessionID: "session-1")
        #expect(lifetime.reusableSessionID == "session-1")

        lifetime.endReuseCycle()
        #expect(lifetime.reusableSessionID == nil)
    }

    @Test
    func `Binding a new session replaces the previous reusable session`() {
        let lifetime = ScreenshotConversationLifetime()

        lifetime.bind(sessionID: "session-1")
        lifetime.bind(sessionID: "session-2")

        #expect(lifetime.reusableSessionID == "session-2")
    }

    @Test
    func `Ending an empty reuse cycle is idempotent`() {
        let lifetime = ScreenshotConversationLifetime()

        lifetime.endReuseCycle()
        lifetime.endReuseCycle()

        #expect(lifetime.reusableSessionID == nil)
    }

    @Test
    func `A fresh lifetime does not restore a previous process cycle`() {
        let original = ScreenshotConversationLifetime()
        original.bind(sessionID: "session-1")

        let relaunched = ScreenshotConversationLifetime()

        #expect(relaunched.reusableSessionID == nil)
    }
}
