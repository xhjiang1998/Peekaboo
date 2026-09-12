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

struct ScreenshotSubmission: Equatable, Sendable {
    let sessionID: String
    let captureID: UUID
    let index: Int
    let isNewSession: Bool
}

struct ScreenshotCaptureDescriptor: Equatable, Identifiable, Sendable {
    let captureID: UUID
    let index: Int
    let analysisState: ScreenshotCaptureAnalysisState

    var id: UUID { self.captureID }
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
    case pinnedModelUnavailable

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
        case .pinnedModelUnavailable:
            "该截图会话使用的模型当前不可用，请恢复对应 Provider 配置"
        }
    }
}

@Observable
@MainActor
final class ScreenshotConversationService {
    typealias Analyzer = (
        _ imageData: Data?,
        _ turns: [PeekabooAIService.ConversationTurn],
        _ model: LanguageModel) async throws -> ScreenshotConversationAnalysis
    typealias ModelResolver = (_ pinnedModelName: String?) throws -> LanguageModel
    typealias CaptureAnalyzer = (
        _ imageData: Data,
        _ history: [PeekabooAIService.ConversationTurn],
        _ currentPrompt: String,
        _ model: LanguageModel) async throws -> ScreenshotConversationAnalysis

    static let defaultPrompt = """
    请分析这张截图，提取关键信息并给出可直接使用的结论。
    如果截图包含题目、报错、文档或界面问题，请直接回答或解释；
    如果信息不足，请明确指出缺失信息。不要执行任何桌面操作。
    """

    private static let modelResolutionFailureMessage = "AI 模型不可用，请检查 Provider 配置后重试"

    private let sessionStore: SessionStore
    private let contextStore: ScreenshotConversationContextStore
    private let modelResolver: ModelResolver
    private let analyzer: Analyzer
    private let captureAnalyzer: CaptureAnalyzer
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "ScreenshotConversation")
    private var statuses: [String: ScreenshotConversationStatus] = [:]
    private var activeRequestIDs: [String: UUID] = [:]
    private var activeRequestTasks: [String: Task<ScreenshotConversationAnalysis, Error>] = [:]
    private var captureQueues: [String: [UUID]] = [:]
    private var queuedCaptureIDs: [String: Set<UUID>] = [:]
    private var drainTasks: [String: Task<Void, Never>] = [:]
    private var captureRevision = 0

    init(
        sessionStore: SessionStore,
        contextStore: ScreenshotConversationContextStore,
        modelResolver: @escaping ModelResolver,
        analyzer: @escaping Analyzer,
        captureAnalyzer: CaptureAnalyzer? = nil)
    {
        self.sessionStore = sessionStore
        self.contextStore = contextStore
        self.modelResolver = modelResolver
        self.analyzer = analyzer
        self.captureAnalyzer = captureAnalyzer ?? { imageData, history, currentPrompt, model in
            try await analyzer(
                imageData,
                history + [.init(role: .user, text: currentPrompt)],
                model)
        }
        self.migrateLegacySessionKinds()
        self.migrateLegacyContextsAndReconcile()
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
            modelResolver: { pinnedModelName in
                if let pinnedModelName {
                    guard let model = aiService.resolveConfiguredModel(pinnedModelName) else {
                        throw ScreenshotConversationServiceError.pinnedModelUnavailable
                    }
                    return model
                }
                return try settings.resolvedVisionModel(using: aiService)
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
            },
            captureAnalyzer: { imageData, history, currentPrompt, model in
                let result = try await aiService.analyzeImageTurn(
                    imageData: imageData,
                    history: history,
                    currentPrompt: currentPrompt,
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

    func isBusy(sessionID: String) -> Bool {
        self.activeRequestTasks[sessionID] != nil || self.isCaptureQueueBusy(sessionID: sessionID)
    }

    func retryAnalysis(sessionID: String) async throws {
        try await self.analyze(sessionID: sessionID)
    }

    func isScreenshotSession(_ sessionID: String) -> Bool {
        self.route(for: sessionID) != .ordinary
    }

    func route(for sessionID: String) -> ScreenshotConversationRoute {
        guard let session = self.sessionStore.session(id: sessionID),
              session.kind == .screenshot
        else {
            return .ordinary
        }
        guard let id = UUID(uuidString: sessionID) else {
            return .screenshotContextMissing
        }

        do {
            guard let context = try self.contextStore.context(for: id) else {
                return .screenshotContextMissing
            }
            if context.schemaVersion < 2 {
                return try self.contextStore.hasImage(for: id)
                    ? .screenshotAvailable
                    : .screenshotContextMissing
            }
            let hasAnyCaptureImage = try context.captures.contains { capture in
                try self.contextStore.imageData(for: id, captureID: capture.id) != nil
            }
            return hasAnyCaptureImage ? .screenshotAvailable : .screenshotContextMissing
        } catch {
            return .screenshotContextMissing
        }
    }

    func imageData(for sessionID: String) throws -> Data? {
        guard let id = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }
        return try self.contextStore.imageData(for: id)
    }

    func imageData(sessionID: String, captureID: UUID) throws -> Data? {
        guard let id = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }
        return try self.contextStore.imageData(for: id, captureID: captureID)
    }

    func captures(sessionID: String) -> [ScreenshotCaptureDescriptor] {
        _ = self.captureRevision
        guard let id = UUID(uuidString: sessionID),
              let context = try? self.contextStore.context(for: id)
        else {
            return []
        }
        return context.captures.enumerated().map { offset, capture in
            ScreenshotCaptureDescriptor(
                captureID: capture.id,
                index: offset + 1,
                analysisState: capture.analysisState)
        }
    }

    @discardableResult
    func submitScreenshot(
        imageData: Data,
        reusing reusableSessionID: String?,
        prompt: String = ScreenshotConversationService.defaultPrompt) throws -> ScreenshotSubmission
    {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw ScreenshotConversationServiceError.emptyMessage
        }

        let captureID = UUID()
        let assistantMessageID = UUID()
        let originalSessions = self.sessionStore.sessions
        let originalCurrentSession = self.sessionStore.currentSession
        let reusable = try self.reusableSession(reusableSessionID)
        let sessionID = reusable?.id ?? UUID().uuidString.lowercased()
        guard let sessionUUID = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }

        let context: ScreenshotConversationContext
        if reusable != nil {
            context = try self.contextStore.append(
                imageData: imageData,
                captureID: captureID,
                assistantMessageID: assistantMessageID,
                to: sessionUUID)
        } else {
            context = try self.contextStore.save(
                imageData: imageData,
                for: sessionUUID,
                captureID: captureID,
                assistantMessageID: assistantMessageID)
            _ = self.sessionStore.createSession(
                id: sessionID,
                title: "截图分析",
                kind: .screenshot)
        }

        guard let session = self.sessionStore.session(id: sessionID) else {
            try? self.rollbackSubmission(
                captureID: captureID,
                sessionID: sessionUUID,
                isNewSession: reusable == nil)
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        self.sessionStore.addMessage(
            ConversationMessage(id: captureID, role: .user, content: normalizedPrompt),
            to: session)

        do {
            try self.sessionStore.persistSessionsNow()
        } catch {
            self.sessionStore.sessions = originalSessions
            self.sessionStore.currentSession = originalCurrentSession
            try? self.rollbackSubmission(
                captureID: captureID,
                sessionID: sessionUUID,
                isNewSession: reusable == nil)
            throw error
        }

        if reusable == nil {
            self.statuses[sessionID] = .idle
        }
        self.captureRevision &+= 1
        return ScreenshotSubmission(
            sessionID: sessionID,
            captureID: captureID,
            index: context.captures.count,
            isNewSession: reusable == nil)
    }

    @discardableResult
    func createConversation(
        imageData: Data,
        prompt: String = ScreenshotConversationService.defaultPrompt) throws -> ConversationSession
    {
        let submission = try self.submitScreenshot(
            imageData: imageData,
            reusing: nil,
            prompt: prompt)
        guard let session = self.sessionStore.session(id: submission.sessionID) else {
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        return session
    }

    func analyze(sessionID: String) async throws {
        guard self.activeRequestTasks[sessionID] == nil,
              self.drainTasks[sessionID] == nil
        else {
            throw ScreenshotConversationServiceError.requestAlreadyInProgress
        }
        guard let session = self.sessionStore.session(id: sessionID) else {
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        if let capture = try self.nextRetryableCapture(sessionID: sessionID) {
            if capture.analysisState == .failed {
                guard let sessionUUID = UUID(uuidString: sessionID) else {
                    throw ScreenshotConversationServiceError.invalidSessionID
                }
                try self.contextStore.updateAnalysisState(.pending, for: capture.id, in: sessionUUID)
            }
            do {
                try await self.analyzeCapture(sessionID: sessionID, captureID: capture.id)
            } catch is CancellationError {
                return
            }
            return
        }

        guard session.messages.last?.role == .user else { return }
        try await self.analyzeTextTurn(sessionID: sessionID)
    }

    func sendFollowUp(_ text: String, sessionID: String) async throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw ScreenshotConversationServiceError.emptyMessage
        }
        guard self.activeRequestTasks[sessionID] == nil,
              !self.isCaptureQueueBusy(sessionID: sessionID)
        else {
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

    func enqueueAnalysis(_ submission: ScreenshotSubmission) {
        guard let sessionUUID = UUID(uuidString: submission.sessionID),
              let context = try? self.contextStore.context(for: sessionUUID),
              let capture = context.captures.first(where: { $0.id == submission.captureID }),
              capture.analysisState == .pending
        else {
            return
        }
        self.enqueueCaptureID(submission.captureID, sessionID: submission.sessionID, context: context)
        self.startDrainIfNeeded(sessionID: submission.sessionID)
    }

    func retryCapture(sessionID: String, captureID: UUID) {
        guard let sessionUUID = UUID(uuidString: sessionID),
              let context = try? self.contextStore.context(for: sessionUUID),
              let capture = context.captures.first(where: { $0.id == captureID }),
              capture.analysisState == .failed
        else {
            return
        }
        do {
            try self.setCaptureState(.pending, captureID: captureID, sessionID: sessionUUID)
            let refreshedContext = try self.contextStore.context(for: sessionUUID) ?? context
            self.enqueueCaptureID(captureID, sessionID: sessionID, context: refreshedContext)
            self.startDrainIfNeeded(sessionID: sessionID)
        } catch {
            self.statuses[sessionID] = .failed("无法保存重试状态，请检查磁盘空间")
        }
    }

    func skipFailedCapture(sessionID: String, captureID: UUID) {
        guard let sessionUUID = UUID(uuidString: sessionID),
              let context = try? self.contextStore.context(for: sessionUUID),
              context.captures.first(where: { $0.id == captureID })?.analysisState == .failed
        else {
            return
        }
        do {
            try self.setCaptureState(.skipped, captureID: captureID, sessionID: sessionUUID)
            self.removeQueuedCapture(captureID, sessionID: sessionID)
            self.startDrainIfNeeded(sessionID: sessionID)
            if !self.isCaptureQueueBusy(sessionID: sessionID) {
                self.statuses[sessionID] = .ready
            }
        } catch {
            self.statuses[sessionID] = .failed("无法保存跳过状态，请检查磁盘空间")
        }
    }

    func cancel(sessionID: String) {
        guard let task = self.activeRequestTasks[sessionID] else {
            return
        }
        self.activeRequestIDs[sessionID] = nil
        self.statuses[sessionID] = .cancelling
        task.cancel()
    }

    func deleteSession(sessionID: String) throws {
        guard let id = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }

        self.drainTasks[sessionID]?.cancel()
        self.drainTasks[sessionID] = nil
        self.captureQueues[sessionID] = nil
        self.queuedCaptureIDs[sessionID] = nil
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

    private func reusableSession(_ sessionID: String?) throws -> ConversationSession? {
        guard let sessionID,
              let session = self.sessionStore.session(id: sessionID),
              session.kind == .screenshot,
              let id = UUID(uuidString: sessionID),
              let context = try self.contextStore.context(for: id),
              context.schemaVersion >= 2
        else {
            return nil
        }
        return session
    }

    private func rollbackSubmission(
        captureID: UUID,
        sessionID: UUID,
        isNewSession: Bool) throws
    {
        if isNewSession {
            try self.contextStore.removeContext(for: sessionID)
        } else {
            _ = try self.contextStore.removeCapture(captureID, from: sessionID)
        }
    }

    private func nextRetryableCapture(sessionID: String) throws -> ScreenshotCapture? {
        guard let sessionUUID = UUID(uuidString: sessionID) else {
            throw ScreenshotConversationServiceError.invalidSessionID
        }
        guard let context = try self.contextStore.context(for: sessionUUID) else {
            throw ScreenshotConversationServiceError.imageContextMissing
        }
        return context.captures.first(where: {
            $0.analysisState == .pending || $0.analysisState == .failed
        })
    }

    private func enqueueCaptureID(
        _ captureID: UUID,
        sessionID: String,
        context: ScreenshotConversationContext)
    {
        var queuedIDs = self.queuedCaptureIDs[sessionID, default: []]
        guard queuedIDs.insert(captureID).inserted else { return }
        let captureOrder = Dictionary(uniqueKeysWithValues: context.captures.enumerated().map { ($1.id, $0) })
        var queue = self.captureQueues[sessionID, default: []]
        queue.append(captureID)
        queue.sort { captureOrder[$0, default: .max] < captureOrder[$1, default: .max] }
        self.captureQueues[sessionID] = queue
        self.queuedCaptureIDs[sessionID] = queuedIDs
    }

    private func removeQueuedCapture(_ captureID: UUID, sessionID: String) {
        self.captureQueues[sessionID]?.removeAll(where: { $0 == captureID })
        self.queuedCaptureIDs[sessionID]?.remove(captureID)
        if self.captureQueues[sessionID]?.isEmpty == true {
            self.captureQueues[sessionID] = nil
            self.queuedCaptureIDs[sessionID] = nil
        }
    }

    private func isCaptureQueueBusy(sessionID: String) -> Bool {
        !(self.captureQueues[sessionID]?.isEmpty ?? true) || self.drainTasks[sessionID] != nil
    }

    private func startDrainIfNeeded(sessionID: String) {
        guard self.drainTasks[sessionID] == nil,
              self.activeRequestTasks[sessionID] == nil,
              let captureID = self.captureQueues[sessionID]?.first,
              let sessionUUID = UUID(uuidString: sessionID),
              let context = try? self.contextStore.context(for: sessionUUID),
              context.captures.first(where: { $0.id == captureID })?.analysisState != .failed
        else {
            return
        }
        self.drainTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.drainCaptureQueue(sessionID: sessionID)
        }
    }

    private func drainCaptureQueue(sessionID: String) async {
        defer {
            self.drainTasks[sessionID] = nil
        }
        while !Task.isCancelled, let captureID = self.captureQueues[sessionID]?.first {
            guard let sessionUUID = UUID(uuidString: sessionID),
                  let context = try? self.contextStore.context(for: sessionUUID),
                  let capture = context.captures.first(where: { $0.id == captureID })
            else {
                self.removeQueuedCapture(captureID, sessionID: sessionID)
                continue
            }
            switch capture.analysisState {
            case .ready, .skipped:
                self.removeQueuedCapture(captureID, sessionID: sessionID)
                continue
            case .failed:
                return
            case .analyzing:
                try? self.setCaptureState(.failed, captureID: captureID, sessionID: sessionUUID)
                self.statuses[sessionID] = .failed("AI 分析中断，请重试")
                return
            case .pending:
                break
            }

            do {
                try await self.analyzeCapture(sessionID: sessionID, captureID: captureID)
                self.removeQueuedCapture(captureID, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        if !Task.isCancelled {
            self.statuses[sessionID] = .ready
        }
    }

    private func analyzeCapture(sessionID: String, captureID: UUID) async throws {
        guard let sessionUUID = UUID(uuidString: sessionID),
              let context = try self.contextStore.context(for: sessionUUID),
              let capture = context.captures.first(where: { $0.id == captureID }),
              let session = self.sessionStore.session(id: sessionID),
              let promptIndex = session.messages.firstIndex(where: { $0.id == captureID }),
              session.messages[promptIndex].role == .user
        else {
            throw ScreenshotConversationServiceError.imageContextMissing
        }
        guard let imageData = try self.contextStore.imageData(for: sessionUUID, captureID: captureID) else {
            try? self.setCaptureState(.failed, captureID: captureID, sessionID: sessionUUID)
            self.statuses[sessionID] = .failed("原截图已丢失，请重新截图")
            throw ScreenshotConversationServiceError.imageContextMissing
        }

        try self.setCaptureState(.analyzing, captureID: captureID, sessionID: sessionUUID)
        self.statuses[sessionID] = .analyzing
        let selectedModel: LanguageModel
        do {
            selectedModel = try self.resolveAndPinModel(for: session)
        } catch {
            try? self.setCaptureState(.failed, captureID: captureID, sessionID: sessionUUID)
            self.statuses[sessionID] = .failed(Self.modelResolutionFailureMessage)
            throw error
        }

        let skippedCaptureIDs = Set(context.captures
            .filter { $0.analysisState == .skipped }
            .map(\.id))
        let history = Self.turns(
            from: Array(session.messages[..<promptIndex]),
            excludingUserMessageIDs: skippedCaptureIDs)
        let currentPrompt = session.messages[promptIndex].content
        let requestID = UUID()
        self.activeRequestIDs[sessionID] = requestID
        let requestTask = Task {
            try await self.captureAnalyzer(imageData, history, currentPrompt, selectedModel)
        }
        self.activeRequestTasks[sessionID] = requestTask

        let result: ScreenshotConversationAnalysis
        do {
            result = try await requestTask.value
        } catch {
            self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
            if requestTask.isCancelled || error is CancellationError {
                try? self.setCaptureState(.pending, captureID: captureID, sessionID: sessionUUID)
                self.statuses[sessionID] = .idle
                throw CancellationError()
            }
            try? self.setCaptureState(.failed, captureID: captureID, sessionID: sessionUUID)
            self.statuses[sessionID] = .failed("AI 分析失败，请重试")
            throw error
        }

        guard self.activeRequestIDs[sessionID] == requestID, !requestTask.isCancelled else {
            self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
            try? self.setCaptureState(.pending, captureID: captureID, sessionID: sessionUUID)
            self.statuses[sessionID] = .idle
            throw CancellationError()
        }
        self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
        let assistantMessage = ConversationMessage(
            id: capture.assistantMessageID,
            role: .assistant,
            content: result.text)
        self.sessionStore.insertOrUpdateMessage(
            assistantMessage,
            after: captureID,
            in: sessionID)
        do {
            try self.sessionStore.persistSessionsNow()
            try self.setCaptureState(.ready, captureID: captureID, sessionID: sessionUUID)
        } catch {
            try? self.setCaptureState(.failed, captureID: captureID, sessionID: sessionUUID)
            self.statuses[sessionID] = .failed("无法保存 AI 回答，请检查磁盘空间后重试")
            throw error
        }
        self.statuses[sessionID] = .ready
    }

    private func analyzeTextTurn(sessionID: String) async throws {
        guard let session = self.sessionStore.session(id: sessionID),
              let prompt = session.messages.last,
              prompt.role == .user
        else {
            throw ScreenshotConversationServiceError.sessionNotFound
        }
        let assistantMessageID = UUID()
        let selectedModel: LanguageModel
        do {
            selectedModel = try self.resolveAndPinModel(for: session)
        } catch {
            self.statuses[sessionID] = .failed(Self.modelResolutionFailureMessage)
            throw error
        }
        let skippedIDs = self.skippedCaptureIDs(sessionID: sessionID)
        let turns = Self.turns(from: session.messages, excludingUserMessageIDs: skippedIDs)
        let requestID = UUID()
        self.activeRequestIDs[sessionID] = requestID
        self.statuses[sessionID] = .analyzing
        let requestTask = Task {
            try await self.analyzer(nil, turns, selectedModel)
        }
        self.activeRequestTasks[sessionID] = requestTask
        do {
            let result = try await requestTask.value
            guard self.activeRequestIDs[sessionID] == requestID, !requestTask.isCancelled else {
                self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
                self.statuses[sessionID] = .idle
                self.startDrainIfNeeded(sessionID: sessionID)
                throw CancellationError()
            }
            self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
            self.sessionStore.insertOrUpdateMessage(
                ConversationMessage(
                    id: assistantMessageID,
                    role: .assistant,
                    content: result.text),
                after: prompt.id,
                in: sessionID)
            try self.sessionStore.persistSessionsNow()
            self.statuses[sessionID] = .ready
            self.startDrainIfNeeded(sessionID: sessionID)
        } catch {
            self.clearActiveRequest(sessionID: sessionID, requestID: requestID)
            if requestTask.isCancelled || error is CancellationError {
                self.statuses[sessionID] = .idle
                self.startDrainIfNeeded(sessionID: sessionID)
                throw CancellationError()
            }
            self.statuses[sessionID] = .failed("AI 分析失败，请重试")
            self.startDrainIfNeeded(sessionID: sessionID)
            throw error
        }
    }

    private func resolveAndPinModel(for session: ConversationSession) throws -> LanguageModel {
        let pinnedModelName = session.modelName.isEmpty ? nil : session.modelName
        let selectedModel = try self.modelResolver(pinnedModelName)
        if pinnedModelName == nil {
            self.sessionStore.updateModelName(
                PeekabooAIService.modelIdentifier(for: selectedModel),
                for: session)
            try self.sessionStore.persistSessionsNow()
        }
        return selectedModel
    }

    private func clearActiveRequest(sessionID: String, requestID: UUID) {
        let activeRequestID = self.activeRequestIDs[sessionID]
        guard activeRequestID == requestID || activeRequestID == nil else { return }
        if activeRequestID == requestID {
            self.activeRequestIDs[sessionID] = nil
        }
        self.activeRequestTasks[sessionID] = nil
    }

    private func skippedCaptureIDs(sessionID: String) -> Set<UUID> {
        guard let sessionUUID = UUID(uuidString: sessionID),
              let context = try? self.contextStore.context(for: sessionUUID)
        else {
            return []
        }
        return Set(context.captures.filter { $0.analysisState == .skipped }.map(\.id))
    }

    private func setCaptureState(
        _ state: ScreenshotCaptureAnalysisState,
        captureID: UUID,
        sessionID: UUID) throws
    {
        try self.contextStore.updateAnalysisState(state, for: captureID, in: sessionID)
        self.captureRevision &+= 1
    }

    private func migrateLegacyContextsAndReconcile() {
        guard self.sessionStore.loadState != .failed else {
            self.logger.error("Skipped screenshot capture reconciliation because session persistence could not be loaded")
            return
        }

        for session in self.sessionStore.sessions where session.kind == .screenshot {
            guard let sessionUUID = UUID(uuidString: session.id),
                  let storedContext = try? self.contextStore.context(for: sessionUUID)
            else {
                continue
            }
            do {
                if storedContext.schemaVersion < 2 {
                    try self.migrateLegacyContext(storedContext, session: session)
                } else {
                    try self.reconcile(context: storedContext, session: session)
                }
            } catch {
                self.statuses[session.id] = .failed("截图会话恢复失败，请重新截图")
                self.logger.error("Failed to reconcile screenshot capture state")
            }
        }
    }

    private func migrateLegacyContext(
        _ context: ScreenshotConversationContext,
        session: ConversationSession) throws
    {
        guard let promptIndex = session.messages.firstIndex(where: { $0.role == .user }) else {
            self.statuses[session.id] = .failed("旧版截图缺少关联问题，无法重试")
            return
        }
        let prompt = session.messages[promptIndex]
        let adjacentAssistant = session.messages.indices.contains(promptIndex + 1) &&
            session.messages[promptIndex + 1].role == .assistant
            ? session.messages[promptIndex + 1]
            : nil
        let migrated = ScreenshotConversationContext(
            schemaVersion: 2,
            sessionID: context.sessionID,
            imageFileName: context.imageFileName,
            createdAt: context.createdAt,
            captures: [ScreenshotCapture(
                id: prompt.id,
                imageFileName: context.imageFileName,
                createdAt: context.createdAt,
                analysisState: adjacentAssistant == nil ? .failed : .ready,
                assistantMessageID: adjacentAssistant?.id ?? UUID())])
        try self.contextStore.replaceContext(migrated)
        self.captureRevision &+= 1
        self.statuses[session.id] = adjacentAssistant == nil
            ? .failed("AI 分析中断，请重试")
            : .ready
    }

    private func reconcile(
        context: ScreenshotConversationContext,
        session: ConversationSession) throws
    {
        let messageIDs = Set(session.messages.map(\.id))
        var reconciled = context
        reconciled.captures.removeAll(where: { !messageIDs.contains($0.id) })
        guard !reconciled.captures.isEmpty else {
            try self.contextStore.removeContext(for: context.sessionID)
            self.captureRevision &+= 1
            return
        }

        var hasFailedCapture = false
        for index in reconciled.captures.indices {
            guard reconciled.captures[index].analysisState != .skipped else { continue }
            let hasCommittedAnswer = messageIDs.contains(reconciled.captures[index].assistantMessageID)
            reconciled.captures[index].analysisState = hasCommittedAnswer ? .ready : .failed
            hasFailedCapture = hasFailedCapture || !hasCommittedAnswer
        }
        if reconciled != context {
            try self.contextStore.replaceContext(reconciled)
            self.captureRevision &+= 1
        }
        self.statuses[session.id] = hasFailedCapture
            ? .failed("AI 分析中断，请重试")
            : .ready
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

    private func migrateLegacySessionKinds() {
        guard self.sessionStore.loadState != .failed else {
            self.logger.error("Skipped screenshot session migration because session persistence could not be loaded")
            return
        }

        var changed = false
        for index in self.sessionStore.sessions.indices {
            let session = self.sessionStore.sessions[index]
            let sessionID = UUID(uuidString: session.id)
            let hasContext: Bool
            if let sessionID {
                hasContext = (try? self.contextStore.context(for: sessionID)) != nil
            } else {
                hasContext = false
            }

            let migratedKind: ConversationSessionKind?
            if hasContext {
                migratedKind = .screenshot
            } else if session.kind == nil {
                migratedKind = Self.matchesLegacyScreenshotFingerprint(session)
                    ? .screenshot
                    : .ordinary
            } else {
                migratedKind = nil
            }

            guard let migratedKind, session.kind != migratedKind else { continue }
            self.sessionStore.sessions[index].kind = migratedKind
            changed = true
        }

        if changed {
            self.sessionStore.saveSessions()
        }
    }

    private static func matchesLegacyScreenshotFingerprint(_ session: ConversationSession) -> Bool {
        UUID(uuidString: session.id) != nil &&
            session.title == "截图分析" &&
            session.messages.first(where: { $0.role == .user })?.content == Self.defaultPrompt
    }

    private static func turns(
        from messages: [ConversationMessage],
        excludingUserMessageIDs excludedIDs: Set<UUID> = []) -> [PeekabooAIService.ConversationTurn]
    {
        messages.compactMap { message in
            switch message.role {
            case .user:
                guard !excludedIDs.contains(message.id) else { return nil }
                return PeekabooAIService.ConversationTurn(role: .user, text: message.content)
            case .assistant:
                return PeekabooAIService.ConversationTurn(role: .assistant, text: message.content)
            case .system:
                return nil
            }
        }
    }
}
