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
            #expect(model == .openai(.gpt55))
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "这是答案")
        }
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        try await fixture.service.analyze(sessionID: session.id)

        #expect(UUID(uuidString: session.id) != nil)
        #expect(session.kind == .screenshot)
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
        var analyzedModels: [LanguageModel] = []
        let fixture = self.makeFixture(
            modelResolver: { pinnedModel in
                resolvedPins.append(pinnedModel)
                if let pinnedModel {
                    guard let model = LanguageModel.parse(from: pinnedModel) else {
                        throw ScreenshotConversationServiceError.pinnedModelUnavailable
                    }
                    return model
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
    func `Automatic model is pinned before a failed first request and retry keeps that model`() async throws {
        var automaticModel = LanguageModel.minimaxCN(.m3)
        var resolvedPins: [String?] = []
        var analyzedModels: [LanguageModel] = []
        var analysisCount = 0
        let fixture = self.makeFixture(
            modelResolver: { pinnedModel in
                resolvedPins.append(pinnedModel)
                return pinnedModel.flatMap { LanguageModel.parse(from: $0) } ?? automaticModel
            },
            analyzer: { _, _, model in
                analyzedModels.append(model)
                analysisCount += 1
                if analysisCount == 1 {
                    automaticModel = .openai(.gpt55)
                    throw TestModelResolutionError.providerPayload
                }
                return ScreenshotConversationAnalysis(
                    provider: "minimax-cn",
                    model: "MiniMax-M3",
                    text: "重试成功")
            })
        defer { fixture.cleanup() }

        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        await #expect(throws: TestModelResolutionError.providerPayload) {
            try await fixture.service.analyze(sessionID: session.id)
        }
        #expect(fixture.sessionStore.session(id: session.id)?.modelName == "minimax-cn/MiniMax-M3")

        try await fixture.service.analyze(sessionID: session.id)

        #expect(resolvedPins == [nil, "minimax-cn/MiniMax-M3"])
        #expect(analyzedModels == [.minimaxCN(.m3), .minimaxCN(.m3)])
    }

    @Test
    func `Initial model resolution failure becomes a sanitized retryable status`() async throws {
        var analyzerWasCalled = false
        let fixture = self.makeFixture(
            modelResolver: { _ in throw TestModelResolutionError.providerPayload },
            analyzer: { _, _, _ in
                analyzerWasCalled = true
                return ScreenshotConversationAnalysis(provider: "unused", model: "unused", text: "unused")
            })
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))

        await #expect(throws: TestModelResolutionError.providerPayload) {
            try await fixture.service.analyze(sessionID: session.id)
        }

        #expect(!analyzerWasCalled)
        #expect(fixture.service.status(for: session.id) == .failed("AI 模型不可用，请检查 Provider 配置后重试"))
        if case let .failed(message) = fixture.service.status(for: session.id) {
            #expect(!message.contains("provider-secret-payload"))
        }
    }

    @Test
    func `Follow-up model resolution failure keeps the appended user turn and sanitized status`() async throws {
        var resolutionCount = 0
        var analyzerCount = 0
        let fixture = self.makeFixture(
            modelResolver: { pinnedModel in
                resolutionCount += 1
                guard resolutionCount == 1 else {
                    throw TestModelResolutionError.providerPayload
                }
                #expect(pinnedModel == nil)
                return .minimaxCN(.m3)
            },
            analyzer: { _, _, _ in
                analyzerCount += 1
                return ScreenshotConversationAnalysis(
                    provider: "minimax-cn",
                    model: "MiniMax-M3",
                    text: "初次答案")
            })
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        try await fixture.service.analyze(sessionID: session.id)

        await #expect(throws: TestModelResolutionError.providerPayload) {
            try await fixture.service.sendFollowUp("继续追问", sessionID: session.id)
        }

        let stored = try #require(fixture.sessionStore.session(id: session.id))
        #expect(Array(stored.messages.map(\.content).suffix(2)) == ["初次答案", "继续追问"])
        #expect(analyzerCount == 1)
        #expect(fixture.service.status(for: session.id) == .failed("AI 模型不可用，请检查 Provider 配置后重试"))
    }

    @Test
    func `Cancelling without an active request preserves failed status`() async throws {
        let fixture = self.makeFixture { _, _, _ in
            throw TestModelResolutionError.providerPayload
        }
        defer { fixture.cleanup() }
        let session = try fixture.service.createConversation(imageData: Data([1, 2, 3]))
        _ = try? await fixture.service.analyze(sessionID: session.id)
        let failedStatus = fixture.service.status(for: session.id)

        fixture.service.cancel(sessionID: session.id)

        #expect(fixture.service.status(for: session.id) == failedStatus)
        #expect(failedStatus == .failed("AI 分析失败，请重试"))
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
                guard let pinnedModel,
                      let model = LanguageModel.parse(from: pinnedModel)
                else {
                    throw ScreenshotConversationServiceError.pinnedModelUnavailable
                }
                return model
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
        #expect(fixture.service.status(for: session.id) == .failed("AI 分析已取消，可重试或跳过"))
        #expect(fixture.service.captures(sessionID: session.id).map(\.analysisState) == [.failed])
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
            modelResolver: { _ in .openai(.gpt55) },
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
            modelResolver: { _ in .openai(.gpt55) },
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
    func `Ordinary session named screenshot analysis stays on ordinary route`() throws {
        let fixture = self.makeFixture { _, _, _ in
            ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
        }
        defer { fixture.cleanup() }
        let session = fixture.sessionStore.createSession(
            id: UUID().uuidString.lowercased(),
            title: "截图分析")

        #expect(session.kind == .ordinary)
        #expect(fixture.service.route(for: session.id) == .ordinary)
        #expect(!fixture.service.isScreenshotSession(session.id))
    }

    @Test
    func `Starting service migrates a legacy session with context to screenshot kind`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-kind-context-migration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let sessionID = UUID()
        sessionStore.sessions = [ConversationSession(
            id: sessionID.uuidString.lowercased(),
            title: "Any legacy title",
            kind: nil)]
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        try contextStore.save(imageData: Data([4, 2]), for: sessionID)

        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(sessionStore.session(id: sessionID.uuidString.lowercased())?.kind == .screenshot)
        #expect(service.route(for: sessionID.uuidString.lowercased()) == .screenshotAvailable)
        let restoredStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        #expect(restoredStore.session(id: sessionID.uuidString.lowercased())?.kind == .screenshot)
    }

    @Test
    func `Starting service migrates only strict legacy screenshot fingerprint without context`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-kind-fingerprint-migration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let legacyID = UUID().uuidString.lowercased()
        let sameTitleID = UUID().uuidString.lowercased()
        let explicitOrdinaryID = UUID().uuidString.lowercased()
        sessionStore.sessions = [
            ConversationSession(
                id: legacyID,
                title: "截图分析",
                messages: [
                    ConversationMessage(role: .user, content: ScreenshotConversationService.defaultPrompt),
                ],
                kind: nil),
            ConversationSession(
                id: sameTitleID,
                title: "截图分析",
                messages: [ConversationMessage(role: .user, content: "普通问题")],
                kind: nil),
            ConversationSession(
                id: explicitOrdinaryID,
                title: "截图分析",
                messages: [
                    ConversationMessage(role: .user, content: ScreenshotConversationService.defaultPrompt),
                ],
                kind: .ordinary),
        ]
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))

        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(sessionStore.session(id: legacyID)?.kind == .screenshot)
        #expect(service.route(for: legacyID) == .screenshotContextMissing)
        #expect(sessionStore.session(id: sameTitleID)?.kind == .ordinary)
        #expect(service.route(for: sameTitleID) == .ordinary)
        #expect(sessionStore.session(id: explicitOrdinaryID)?.kind == .ordinary)
        #expect(service.route(for: explicitOrdinaryID) == .ordinary)
    }

    @Test
    func `Cancelling analysis invalidates its result after cancelling the task`() async throws {
        var analyzerObservedCancellation = false
        let fixture = self.makeFixture { _, _, _ in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                analyzerObservedCancellation = true
                throw CancellationError()
            }
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
        try await analysis.value
        #expect(analyzerObservedCancellation)
        #expect(fixture.sessionStore.session(id: session.id)?.messages.map(\.role) == [.user])
        #expect(fixture.service.status(for: session.id) == .failed("AI 分析已取消，可重试或跳过"))
        #expect(fixture.service.captures(sessionID: session.id).map(\.analysisState) == [.failed])
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
        #expect(fixture.service.status(for: session.id) == .failed("AI 分析已取消，可重试或跳过"))
        #expect(fixture.service.captures(sessionID: session.id).map(\.analysisState) == [.failed])
    }

    private func makeFixture(
        modelResolver: @escaping ScreenshotConversationService.ModelResolver = { _ in .openai(.gpt55) },
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

    private enum TestModelResolutionError: Error, Equatable, LocalizedError {
        case providerPayload

        var errorDescription: String? {
            "provider-secret-payload"
        }
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
