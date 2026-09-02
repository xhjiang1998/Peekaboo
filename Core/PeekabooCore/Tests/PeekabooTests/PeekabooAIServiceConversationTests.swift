import Foundation
import Tachikoma
import Testing
@testable import PeekabooAutomation

@Suite
@MainActor
struct PeekabooAIServiceConversationTests {
    @Test
    func `Existing service resolves the current vision provider for every request`() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-conversation-provider-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let previousConfigDirectory = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
        let previousMigrationFlag = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
        setenv("PEEKABOO_CONFIG_DIR", tempDirectory.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        defer {
            if let previousConfigDirectory {
                setenv("PEEKABOO_CONFIG_DIR", previousConfigDirectory, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DIR")
            }
            if let previousMigrationFlag {
                setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", previousMigrationFlag, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            }
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try """
        {
          "aiProviders": { "providers": "openai/gpt-5.5" }
        }
        """.write(
            to: tempDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8)
        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        var capturedModels: [LanguageModel] = []
        let service = PeekabooAIService(textGenerator: { model, _, _ in
            capturedModels.append(model)
            return GenerateTextResult(text: "ok")
        })
        let turns = [PeekabooAIService.ConversationTurn(role: .user, text: "analyze")]

        _ = try await service.analyzeImageConversation(imageData: Data([1]), turns: turns)
        try ConfigurationManager.shared.updateConfiguration { configuration in
            configuration.aiProviders?.providers = "ollama/llava:latest"
        }
        _ = try await service.analyzeImageConversation(imageData: Data([1]), turns: turns)

        #expect(capturedModels.map(\.modelId) == ["gpt-5.5", "llava:latest"])
    }

    @Test
    func `Screenshot is attached once while follow-up turns keep their roles`() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let turns = [
            PeekabooAIService.ConversationTurn(role: .user, text: "Explain this screenshot"),
            PeekabooAIService.ConversationTurn(role: .assistant, text: "It shows a settings window"),
            PeekabooAIService.ConversationTurn(role: .user, text: "What should I click next?"),
        ]

        let messages = try PeekabooAIService.makeImageConversationMessages(
            imageData: imageData,
            turns: turns)

        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(self.text(in: messages[0]) == "Explain this screenshot")
        #expect(self.image(in: messages[0])?.data == imageData.base64EncodedString())
        #expect(self.image(in: messages[0])?.mimeType == "image/png")
        #expect(self.image(in: messages[1]) == nil)
        #expect(self.image(in: messages[2]) == nil)
    }

    @Test
    func `Conversation keeps the original screenshot turn and newest nineteen turns`() throws {
        let turns = (0..<25).map { index in
            PeekabooAIService.ConversationTurn(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "turn-\(index)")
        }

        let messages = try PeekabooAIService.makeImageConversationMessages(
            imageData: Data([1]),
            turns: turns)

        #expect(messages.count == 20)
        #expect(self.text(in: messages.first) == "turn-0")
        #expect(self.text(in: messages.last) == "turn-24")
        #expect(messages.compactMap { self.image(in: $0) }.count == 1)
    }

    @Test
    func `Conversation text is capped at thirty two thousand characters`() throws {
        let turns = [
            PeekabooAIService.ConversationTurn(role: .user, text: String(repeating: "a", count: 1_000)),
            PeekabooAIService.ConversationTurn(role: .assistant, text: String(repeating: "b", count: 40_000)),
            PeekabooAIService.ConversationTurn(role: .user, text: "latest question"),
        ]

        let messages = try PeekabooAIService.makeImageConversationMessages(
            imageData: Data([1]),
            turns: turns)
        let characterCount = messages.compactMap(self.text(in:)).reduce(0) { $0 + $1.count }

        #expect(characterCount <= 32_000)
        #expect(self.text(in: messages.first)?.hasPrefix("a") == true)
        #expect(self.text(in: messages.last) == "latest question")
    }

    @Test
    func `Image conversation uses explicit vision model and returns metadata`() async throws {
        var capturedModel: LanguageModel?
        var capturedMessages: [ModelMessage] = []
        let service = PeekabooAIService(textGenerator: { model, messages, _ in
            capturedModel = model
            capturedMessages = messages
            return GenerateTextResult(text: "Use the Save button")
        })
        let selectedModel = LanguageModel.openai(.gpt55)

        let result = try await service.analyzeImageConversation(
            imageData: Data([1, 2, 3]),
            turns: [.init(role: .user, text: "What should I do?")],
            model: selectedModel)

        #expect(capturedModel == selectedModel)
        #expect(capturedMessages.count == 1)
        #expect(self.image(in: capturedMessages[0]) != nil)
        #expect(result.provider == "openai")
        #expect(result.model == "gpt-5.5")
        #expect(result.text == "Use the Save button")
    }

    @Test
    func `Image conversation rejects history without a user turn`() {
        let turns = [
            PeekabooAIService.ConversationTurn(role: .assistant, text: "orphan answer"),
        ]

        #expect(throws: PeekabooAIService.ImageConversationError.missingUserTurn) {
            _ = try PeekabooAIService.makeImageConversationMessages(
                imageData: Data([1]),
                turns: turns)
        }
    }

    private func text(in message: ModelMessage?) -> String? {
        message?.content.compactMap { part in
            if case let .text(text) = part { text } else { nil }
        }.first
    }

    private func image(in message: ModelMessage?) -> ModelMessage.ContentPart.ImageContent? {
        message?.content.compactMap { part in
            if case let .image(image) = part { image } else { nil }
        }.first
    }
}
