import Foundation
import Observation
import os.log
import PeekabooCore
import Tachikoma

struct ScreenshotConversationAnalysis: Equatable, Sendable {
    let provider: String
    let model: String
    let text: String
}

enum ScreenshotConversationStatus: Equatable, Sendable {
    case idle
    case analyzing
    case cancelling
    case ready
    case failed(String)
}

enum ScreenshotConversationRoute: Equatable, Sendable {
    case ordinary
    case screenshotAvailable
    case screenshotContextMissing
}

enum ScreenshotConversationServiceError: Error, Equatable, LocalizedError {
    case emptyMessage
    case invalidSessionID
    case sessionNotFound
    case imageContextMissing
    case requestAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "请输入问题"
        case .invalidSessionID, .sessionNotFound:
            "截图会话不存在，请重新截图"
        case .imageContextMissing:
            "原截图已丢失，请重新截图"
        case .requestAlreadyInProgress:
            "正在分析，请稍候"
        }
    }
}

@Observable
@MainActor
final class ScreenshotConversationService {
    typealias Analyzer = (
        _ imageData: Data,
        _ turns: [PeekabooAIService.ConversationTurn],
        _ model: LanguageModel?) async throws -> ScreenshotConversationAnalysis
    typealias ModelResolver = () throws -> LanguageModel?

    static let defaultPrompt = """
    请分析这张截图，提取关键信息并给出可直接使用的结论。
    如果截图包含题目、报错、文档或界面问题，请直接回答或解释；
    如果信息不足，请明确指出缺失信息。不要执行任何桌面操作。
    """

    private let sessionStore: SessionStore
    private let contextStore: ScreenshotConversationContextStore
    private let modelResolver: ModelResolver
    private let analyzer: Analyzer
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "ScreenshotConversation")
    private var statuses: [String: ScreenshotConversationStatus] = [:]
    private var activeRequestIDs: [String: UUID] = [:]
    private var activeRequestTasks: [String: Task<ScreenshotConversationAnalysis, Error>] = [:]

    init(
        sessionStore: SessionStore,
        contextStore: ScreenshotConversationContextStore,
        modelResolver: @escaping ModelResolver,
        analyzer: @escaping Analyzer)
    {
        self.sessionStore = sessionStore
        self.contextStore = contextStore
        self.modelResolver = modelResolver
        self.analyzer = analyzer
        self.cleanupStaleContexts()
    }

    convenience init(
        sessionStore: SessionStore,
        contextStore: ScreenshotConversationContextStore,
        settings: PeekabooSettings,
        aiService: PeekabooAIService = PeekabooAIService())
    {
        self.init(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: {
                try settings.resolvedVisionModel(using: aiService)
            },
            analyzer: { imageData, turns, model in
                let result = try await aiService.analyzeImageConversation(
                    imageData: imageData,
                    turns: turns,
                    model: model)
                return ScreenshotConversationAnalysis(
                    provider: result.provider,
                    model: result.model,
                    text: result.text)
            })
    }

    func status(for sessionID: String) -> ScreenshotConversationStatus {
        self.statuses[sessionID] ?? .idle
    }

    func isScreenshotSession(_ sessionID: String) -> Bool {
        self.route(for: sessionID) != .ordinary
    }

    func route(for sessionID: String) -> ScreenshotConversationRoute {
        guard let session = self.sessionStore.session(id: sessionID),
              let id = UUID(uuidString: sessionID)
        else {
            return .ordinary
        }

        do {
            if try self.contextStore.context(for: id) != nil {
                return try self.contextStore.hasImage(for: id)
                    ? .screenshotAvailable
                    : .screenshotContextMissing
            }
        } catch {
            return session.title == "截图分析" ? .screenshotContextMissing : .ordinary
        }
        return session.title == "截图分析" ? .screenshotContextMissing : .ordinary
    }

    func imageData(for sessionID: String) throws -> Data? {
        guard let id = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }
        return try self.contextStore.imageData(for: id)
    }

    @discardableResult
    func createConversation(
        imageData: Data,
        prompt: String = ScreenshotConversationService.defaultPrompt) throws -> ConversationSession
    {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw ScreenshotConversationServiceError.emptyMessage
        }

        let id = UUID()
        try self.contextStore.save(imageData: imageData, for: id)
        let session = self.sessionStore.createSession(
            id: id.uuidString.lowercased(),
            title: "截图分析")
        self.sessionStore.addMessage(
            ConversationMessage(role: .user, content: normalizedPrompt),
            to: session)
        self.statuses[session.id] = .idle
        return self.sessionStore.session(id: session.id) ?? session
    }

    func analyze(sessionID: String) async throws {
        guard self.activeRequestTasks[sessionID] == nil else {
            throw ScreenshotConversationServiceError.requestAlreadyInProgress
        }
        guard let session = self.sessionStore.session(id: sessionID) else {
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        guard let imageData = try self.imageData(for: sessionID) else {
            throw ScreenshotConversationServiceError.imageContextMissing
        }

        let requestID = UUID()
        self.activeRequestIDs[sessionID] = requestID
        self.statuses[sessionID] = .analyzing
        let requestTask = Task {
            try await self.analyzer(
                imageData,
                Self.turns(from: session.messages),
                try self.modelResolver())
        }
        self.activeRequestTasks[sessionID] = requestTask

        let result: ScreenshotConversationAnalysis
        do {
            result = try await requestTask.value
        } catch {
            guard self.activeRequestIDs[sessionID] == requestID else {
                return
            }
            self.activeRequestIDs[sessionID] = nil
            self.activeRequestTasks[sessionID] = nil
            if requestTask.isCancelled || error is CancellationError {
                self.statuses[sessionID] = .idle
                throw CancellationError()
            }
            self.statuses[sessionID] = .failed("AI 分析失败，请重试")
            throw error
        }

        guard self.activeRequestIDs[sessionID] == requestID else {
            return
        }
        self.activeRequestIDs[sessionID] = nil
        self.activeRequestTasks[sessionID] = nil
        if requestTask.isCancelled {
            self.statuses[sessionID] = .idle
            throw CancellationError()
        }
        guard let currentSession = self.sessionStore.session(id: sessionID) else {
            self.statuses[sessionID] = .idle
            return
        }
        self.sessionStore.addMessage(
            ConversationMessage(role: .assistant, content: result.text),
            to: currentSession)
        self.sessionStore.updateModelName(
            "\(result.provider)/\(result.model)",
            for: currentSession)
        self.statuses[sessionID] = .ready
    }

    func sendFollowUp(_ text: String, sessionID: String) async throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw ScreenshotConversationServiceError.emptyMessage
        }
        guard self.activeRequestTasks[sessionID] == nil else {
            throw ScreenshotConversationServiceError.requestAlreadyInProgress
        }
        guard let session = self.sessionStore.session(id: sessionID) else {
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        guard self.route(for: sessionID) == .screenshotAvailable else {
            throw ScreenshotConversationServiceError.imageContextMissing
        }

        self.sessionStore.addMessage(
            ConversationMessage(role: .user, content: normalizedText),
            to: session)
        try await self.analyze(sessionID: sessionID)
    }

    func cancel(sessionID: String) {
        guard let task = self.activeRequestTasks[sessionID] else {
            self.statuses[sessionID] = .idle
            return
        }
        self.statuses[sessionID] = .cancelling
        task.cancel()
    }

    func deleteSession(sessionID: String) throws {
        guard let id = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }

        self.activeRequestTasks[sessionID]?.cancel()
        self.activeRequestTasks[sessionID] = nil
        self.activeRequestIDs[sessionID] = nil
        try self.contextStore.removeContext(for: id)
        self.statuses.removeValue(forKey: sessionID)
        self.sessionStore.sessions.removeAll { $0.id == sessionID }
        if self.sessionStore.currentSession?.id == sessionID {
            self.sessionStore.currentSession = nil
        }
        self.sessionStore.saveSessions()
    }

    private func cleanupStaleContexts() {
        guard self.sessionStore.loadState != .failed else {
            self.logger.error("Skipped screenshot context cleanup because session persistence could not be loaded")
            return
        }
        let validSessionIDs = Set(self.sessionStore.sessions.compactMap { UUID(uuidString: $0.id) })
        do {
            let removedSessionIDs = try self.contextStore.cleanupContexts(keeping: validSessionIDs)
            if !removedSessionIDs.isEmpty {
                self.logger.info("Removed \(removedSessionIDs.count, privacy: .public) orphaned screenshot contexts")
            }
        } catch {
            self.logger.error("Failed to clean orphaned screenshot contexts")
        }
    }

    private static func turns(
        from messages: [ConversationMessage]) -> [PeekabooAIService.ConversationTurn]
    {
        messages.compactMap { message in
            switch message.role {
            case .user:
                PeekabooAIService.ConversationTurn(role: .user, text: message.content)
            case .assistant:
                PeekabooAIService.ConversationTurn(role: .assistant, text: message.content)
            case .system:
                nil
            }
        }
    }
}
