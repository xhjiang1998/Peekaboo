import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct MainWindowPresenterTests {
    @Test
    func `Existing window is activated after screenshot session is selected`() throws {
        let fixture = self.makeSessionStore()
        defer { fixture.cleanup() }
        let screenshotSession = fixture.store.createSession(id: UUID().uuidString, title: "截图分析")
        _ = fixture.store.createSession(title: "普通会话")
        var events: [String] = []
        let presenter = MainWindowPresenter(
            sessionStore: fixture.store,
            showDock: { events.append("dock") },
            activateApp: { events.append("activate") },
            openWindow: { events.append("open") },
            bringWindowToFront: {
                events.append("bring:\(fixture.store.currentSession?.id ?? "nil")")
                return true
            },
            scheduleRetry: { _, operation in operation() })

        presenter.forceShow(sessionID: screenshotSession.id)

        #expect(events == ["dock", "activate", "bring:\(screenshotSession.id)"])
        #expect(fixture.store.currentSession?.id == screenshotSession.id)
    }

    @Test
    func `New window is opened once and retried until it can be brought forward`() {
        let fixture = self.makeSessionStore()
        defer { fixture.cleanup() }
        let session = fixture.store.createSession(id: UUID().uuidString, title: "截图分析")
        var openCount = 0
        var bringCount = 0
        var retryDelays: [TimeInterval] = []
        let presenter = MainWindowPresenter(
            sessionStore: fixture.store,
            showDock: {},
            activateApp: {},
            openWindow: { openCount += 1 },
            bringWindowToFront: {
                bringCount += 1
                return bringCount == 3
            },
            scheduleRetry: { delay, operation in
                retryDelays.append(delay)
                operation()
            })

        presenter.forceShow(sessionID: session.id)

        #expect(openCount == 1)
        #expect(bringCount == 3)
        #expect(retryDelays == [0.05, 0.05])
    }

    @Test
    func `Window lookup retries are bounded`() {
        let fixture = self.makeSessionStore()
        defer { fixture.cleanup() }
        let session = fixture.store.createSession(id: UUID().uuidString, title: "截图分析")
        var bringCount = 0
        var scheduleCount = 0
        let presenter = MainWindowPresenter(
            sessionStore: fixture.store,
            showDock: {},
            activateApp: {},
            openWindow: {},
            bringWindowToFront: {
                bringCount += 1
                return false
            },
            scheduleRetry: { _, operation in
                scheduleCount += 1
                operation()
            })

        presenter.forceShow(sessionID: session.id)

        #expect(bringCount == 10)
        #expect(scheduleCount == 9)
    }

    private func makeSessionStore() -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-main-window-presenter-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return StoreFixture(
            root: root,
            store: SessionStore(storageURL: root.appendingPathComponent("sessions.json")))
    }

    private struct StoreFixture {
        let root: URL
        let store: SessionStore

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
