import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct ScreenshotConversationServiceTests {
    @Test
    func `Creating and analyzing a screenshot conversation persists image and answer`() async throws {
        let fixture = self.makeFixture { imageData, turns, model in
            #expect(imageData == Data([1, 2, 3]))
            #expect(turns == [
                .init(role: .user, text: ScreenshotConversationService.defaultPrompt),
            ])
            #expect(model == nil)
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "这是答案")
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        try await fixture.service.analyze(sessionID: session.id)

        #expect(UUID(uuidString: session.id) != nil)
        #expect(try fixture.contextStore.imageData(for: UUID(uuidString: session.id)!) == Data([1, 2, 3]))
        let stored = try #require(fixture.sessionStore.session(id: session.id))
        #expect(stored.messages.map(\.role) == [.user, .assistant])
        #expect(stored.messages.map(\.content) == [ScreenshotConversationService.defaultPrompt, "这是答案"])
        #expect(stored.modelName == "openai/gpt-5.5")
        #expect(fixture.service.status(for: session.id) == .ready)
    }

    @Test
    func `Follow-up reuses screenshot context and sends ordinary text history`() async throws {
        var capturedTurns: [[PeekabooAIService.ConversationTurn]] = []
        let fixture = self.makeFixture { _, turns, _ in
            capturedTurns.append(turns)
            let answer = capturedTurns.count == 1 ? "初次答案" : "追问答案"
            return ScreenshotConversationAnalysis(provider: "anthropic", model: "claude-sonnet", text: answer)
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([9, 8, 7]))
        try await fixture.service.analyze(sessionID: session.id)
        try await fixture.service.sendFollowUp("左下角数字是什么？", sessionID: session.id)

        #expect(capturedTurns.count == 2)
        #expect(capturedTurns[1] == [
            .init(role: .user, text: ScreenshotConversationService.defaultPrompt),
            .init(role: .assistant, text: "初次答案"),
            .init(role: .user, text: "左下角数字是什么？"),
        ])
        let stored = try #require(fixture.sessionStore.session(id: session.id))
        #expect(stored.messages.map(\.content) == [
            ScreenshotConversationService.defaultPrompt,
            "初次答案",
            "左下角数字是什么？",
            "追问答案",
        ])
    }

    @Test
    func `Cancelled request cannot append a late answer`() async throws {
        let fixture = self.makeFixture { _, _, _ in
            try? await Task.sleep(for: .milliseconds(30))
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "迟到答案")
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([4, 5, 6]))
        let task = Task { try await fixture.service.analyze(sessionID: session.id) }
        await Task.yield()
        fixture.service.cancel(sessionID: session.id)
        _ = try? await task.value

        let stored = try #require(fixture.sessionStore.session(id: session.id))
        #expect(stored.messages.map(\.role) == [.user])
        #expect(fixture.service.status(for: session.id) == .idle)
    }

    private func makeFixture(
        analyzer: @escaping ScreenshotConversationService.Analyzer) -> Fixture
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-service-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { nil },
            analyzer: analyzer)
        return Fixture(
            root: root,
            sessionStore: sessionStore,
            contextStore: contextStore,
            service: service)
    }

    private struct Fixture {
        let root: URL
        let sessionStore: SessionStore
        let contextStore: ScreenshotConversationContextStore
        let service: ScreenshotConversationService

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
