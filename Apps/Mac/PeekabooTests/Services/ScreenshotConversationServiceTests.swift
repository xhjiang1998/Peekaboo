import Foundation
import PeekabooCore
import Tachikoma
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
        var capturedImages: [Data?] = []
        var capturedTurns: [[PeekabooAIService.ConversationTurn]] = []
        let fixture = self.makeFixture { imageData, turns, _ in
            capturedImages.append(imageData)
            capturedTurns.append(turns)
            let answer = capturedTurns.count == 1 ? "初次答案" : "追问答案"
            return ScreenshotConversationAnalysis(provider: "anthropic", model: "claude-sonnet", text: answer)
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([9, 8, 7]))
        try await fixture.service.analyze(sessionID: session.id)
        try await fixture.service.sendFollowUp("左下角数字是什么？", sessionID: session.id)

        #expect(capturedTurns.count == 2)
        #expect(capturedImages == [Data([9, 8, 7]), nil])
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
    func `Follow-up keeps the model pinned by the first screenshot request`() async throws {
        var resolvedPins: [String?] = []
        var analyzedModels: [LanguageModel?] = []
        let fixture = self.makeFixture(
            modelResolver: { pinnedModel in
                resolvedPins.append(pinnedModel)
                if let pinnedModel {
                    return LanguageModel.parse(from: pinnedModel)
                }
                return .minimaxCN(.m3)
            },
            analyzer: { _, _, model in
                analyzedModels.append(model)
                return ScreenshotConversationAnalysis(
                    provider: "minimax-cn",
                    model: "MiniMax-M3",
                    text: "答案-\(analyzedModels.count)")
            })
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        try await fixture.service.analyze(sessionID: session.id)
        try await fixture.service.sendFollowUp("继续", sessionID: session.id)

        #expect(resolvedPins == [nil, "minimax-cn/MiniMax-M3"])
        #expect(analyzedModels == [.minimaxCN(.m3), .minimaxCN(.m3)])
        #expect(fixture.sessionStore.session(id: session.id)?.modelName == "minimax-cn/MiniMax-M3")
    }

    @Test
    func `Restored screenshot session resolves its persisted pinned model`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-model-restore-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("sessions.json")
        let contextRoot = root.appendingPathComponent("contexts", isDirectory: true)
        let firstStore = SessionStore(storageURL: storageURL)
        let contextStore = ScreenshotConversationContextStore(rootDirectory: contextRoot)
        let firstService = ScreenshotConversationService(
            sessionStore: firstStore,
            contextStore: contextStore,
            modelResolver: { _ in .minimaxCN(.m3) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "minimax-cn", model: "MiniMax-M3", text: "初次")
            })
        let session = try firstService.createConversation(imageData: Data([7, 8, 9]))
        try await firstService.analyze(sessionID: session.id)
        firstStore.saveSessions()

        let restoredStore = SessionStore(storageURL: storageURL)
        var restoredPins: [String?] = []
        let restoredService = ScreenshotConversationService(
            sessionStore: restoredStore,
            contextStore: ScreenshotConversationContextStore(rootDirectory: contextRoot),
            modelResolver: { pinnedModel in
                restoredPins.append(pinnedModel)
                return pinnedModel.flatMap { LanguageModel.parse(from: $0) }
            },
            analyzer: { imageData, _, model in
                #expect(imageData == nil)
                #expect(model == .minimaxCN(.m3))
                return ScreenshotConversationAnalysis(provider: "minimax-cn", model: "MiniMax-M3", text: "追问")
            })

        try await restoredService.sendFollowUp("重启后的追问", sessionID: session.id)

        #expect(restoredPins == ["minimax-cn/MiniMax-M3"])
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

    @Test
    func `Deleting a screenshot session removes its session context and image`() throws {
        let fixture = self.makeFixture { _, _, _ in
            ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([7, 8, 9]))

        try fixture.service.deleteSession(sessionID: session.id)

        #expect(fixture.sessionStore.session(id: session.id) == nil)
        #expect(fixture.sessionStore.currentSession == nil)
        #expect(try fixture.contextStore.context(for: UUID(uuidString: session.id)!) == nil)
        #expect(try fixture.contextStore.imageData(for: UUID(uuidString: session.id)!) == nil)
    }

    @Test
    func `Starting service removes screenshot contexts without matching sessions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-service-reconcile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        let staleSessionID = UUID()
        _ = try contextStore.save(imageData: Data([4, 2]), for: staleSessionID)

        _ = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in nil },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(try contextStore.context(for: staleSessionID) == nil)
        #expect(try contextStore.imageData(for: staleSessionID) == nil)
    }

    @Test
    func `Starting service preserves screenshot contexts when session persistence is corrupt`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-service-corrupt-session-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("sessions.json")
        try Data("not valid json".utf8).write(to: storageURL)
        let sessionStore = SessionStore(storageURL: storageURL)
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        let recoverableSessionID = UUID()
        _ = try contextStore.save(imageData: Data([4, 2]), for: recoverableSessionID)

        _ = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in nil },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(sessionStore.loadState == .failed)
        #expect(try contextStore.context(for: recoverableSessionID) != nil)
        #expect(try contextStore.imageData(for: recoverableSessionID) == Data([4, 2]))
    }

    @Test
    func `Screenshot session with missing context never becomes an ordinary agent session`() throws {
        let fixture = self.makeFixture { _, _, _ in
            ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
        }
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))

        try fixture.contextStore.removeContext(for: UUID(uuidString: session.id)!)

        #expect(fixture.service.route(for: session.id) == .screenshotContextMissing)
        #expect(fixture.service.isScreenshotSession(session.id))
    }

    @Test
    func `Cancelling analysis cancels its task before allowing another request`() async throws {
        let fixture = self.makeFixture { _, _, _ in
            try await Task.sleep(for: .seconds(5))
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "late")
        }
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        let analysis = Task {
            try await fixture.service.analyze(sessionID: session.id)
        }
        await Task.yield()

        fixture.service.cancel(sessionID: session.id)

        #expect(fixture.service.status(for: session.id) == .cancelling)
        await #expect(throws: CancellationError.self) {
            try await analysis.value
        }
        #expect(fixture.service.status(for: session.id) == .idle)
    }

    @Test
    func `Cancelling immediately invalidates a noncooperative request without allowing request buildup`() async throws {
        let analyses = ControllableScreenshotAnalyses()
        let fixture = self.makeFixture { _, _, _ in
            await analyses.wait()
        }
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        let firstRequest = Task { try await fixture.service.analyze(sessionID: session.id) }
        await Task.yield()

        fixture.service.cancel(sessionID: session.id)

        await #expect(throws: ScreenshotConversationServiceError.requestAlreadyInProgress) {
            try await fixture.service.sendFollowUp("不要堆积请求", sessionID: session.id)
        }
        analyses.finish(with: ScreenshotConversationAnalysis(
            provider: "openai",
            model: "gpt-5.5",
            text: "迟到答案"))
        _ = try? await firstRequest.value
        let stored = try #require(fixture.sessionStore.session(id: session.id))
        #expect(stored.messages.map(\.role) == [.user])
        #expect(fixture.service.status(for: session.id) == .idle)
    }

    private func makeFixture(
        modelResolver: @escaping ScreenshotConversationService.ModelResolver = { _ in nil },
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
            modelResolver: modelResolver,
            analyzer: analyzer)
        return Fixture(
            root: root,
            sessionStore: sessionStore,
            contextStore: contextStore,
            service: service)
    }

    @MainActor
    private final class ControllableScreenshotAnalyses {
        private var continuation: CheckedContinuation<ScreenshotConversationAnalysis, Never>?

        func wait() async -> ScreenshotConversationAnalysis {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(with result: ScreenshotConversationAnalysis) {
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }
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
