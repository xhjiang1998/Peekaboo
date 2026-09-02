import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .integration))
@MainActor
struct ScreenshotConversationEndToEndTests {
    @Test
    func `Capture analysis and three follow-ups keep one screenshot conversation`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-e2e-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        var requests: [(Data, [PeekabooAIService.ConversationTurn])] = []
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { nil },
            analyzer: { imageData, turns, _ in
                requests.append((imageData, turns))
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: "answer-\(requests.count)")
            })
        let selection = CaptureSelection(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            displayID: 7)!
        var presentedSessionID: String?
        let coordinator = CaptureAndAskCoordinator(
            permissionCheck: { true },
            selectArea: { selection },
            resolveCaptureRect: { $0 },
            captureArea: { _ in Data([1, 2, 3]) },
            createConversation: { imageData in
                try service.createConversation(imageData: imageData).id
            },
            presentWindow: { presentedSessionID = $0 },
            analyze: { try await service.analyze(sessionID: $0) })

        await coordinator.performCapture()
        let sessionID = try #require(presentedSessionID)
        try await service.sendFollowUp("追问一", sessionID: sessionID)
        try await service.sendFollowUp("追问二", sessionID: sessionID)
        try await service.sendFollowUp("追问三", sessionID: sessionID)

        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.0 == Data([1, 2, 3]) })
        #expect(requests.map { $0.1.last?.text } == [
            ScreenshotConversationService.defaultPrompt,
            "追问一",
            "追问二",
            "追问三",
        ])
        #expect(service.route(for: sessionID) == .screenshotAvailable)
        #expect(sessionStore.session(id: sessionID)?.messages.count == 8)
    }
}
