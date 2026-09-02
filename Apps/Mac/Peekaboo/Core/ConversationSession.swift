import Foundation
import Observation
import PeekabooCore

// MARK: - Session Management

enum SessionStoreLoadState: Equatable {
    case missing
    case loaded
    case failed
}

/// Manages conversation sessions with automatic persistence.
///
/// Sessions are automatically saved to `~/Library/Application Support/Peekaboo/sessions.json`
/// and loaded on initialization. This class uses the modern @Observable pattern
/// for SwiftUI integration.
@Observable
@MainActor
final class SessionStore {
    var sessions: [ConversationSession] = []
    var currentSession: ConversationSession?
    private(set) var loadState: SessionStoreLoadState = .missing

    private let titleGenerator = SessionTitleGenerator()

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            self.storageURL = Self.defaultStorageURL()
        }
        self.loadSessions()
    }

    private static func defaultStorageURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let peekabooDirectory = baseDirectory.appendingPathComponent("Peekaboo", isDirectory: true)

        do {
            try fileManager.createDirectory(at: peekabooDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create application support directory: \(error)")
        }

        return peekabooDirectory.appendingPathComponent("sessions.json", isDirectory: false)
    }

    func createSession(
        id: String? = nil,
        title: String = "",
        modelName: String = "") -> ConversationSession
    {
        let session = ConversationSession(
            id: id,
            title: title.isEmpty ? "New Session" : title,
            modelName: modelName)
        self.sessions.insert(session, at: 0)
        self.currentSession = session
        Task { @MainActor in
            self.saveSessions()
        }
        return session
    }

    func session(id: String) -> ConversationSession? {
        self.sessions.first(where: { $0.id == id })
    }

    func addMessage(_ message: ConversationMessage, to session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].messages.append(message)
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func updateSummary(_ summary: String, for session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].summary = summary
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func updateTitle(_ title: String, for session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].title = title
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func updateModelName(_ modelName: String, for session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].modelName = modelName
        Task { @MainActor in
            self.saveSessions()
        }
    }

    /// Generate AI title for session based on first user message
    func generateTitleForSession(_ session: ConversationSession) {
        // Only generate title if it's still "New Session" and has user messages
        guard session.title == "New Session",
              let firstUserMessage = session.messages.first(where: { $0.role == .user })
        else {
            return
        }

        Task { @MainActor in
            let generatedTitle = await titleGenerator.generateTitleFromFirstMessage(firstUserMessage.content)
            if generatedTitle != "New Session" {
                self.updateTitle(generatedTitle, for: session)
            }
        }
    }

    func updateLastMessage(_ message: ConversationMessage, in session: ConversationSession) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == session.id }),
              !sessions[sessionIndex].messages.isEmpty else { return }

        let lastIndex = self.sessions[sessionIndex].messages.count - 1
        self.sessions[sessionIndex].messages[lastIndex] = message
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func selectSession(_ session: ConversationSession) {
        self.currentSession = session
    }

    private func loadSessions() {
        guard FileManager.default.fileExists(atPath: self.storageURL.path) else {
            self.loadState = .missing
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.sessions = try decoder.decode([ConversationSession].self, from: data)
            self.loadState = .loaded
        } catch {
            self.loadState = .failed
            print("Failed to load sessions: \(error)")
        }
    }

    func saveSessions() {
        guard self.loadState != .failed else {
            print("Skipped saving sessions because existing persistence could not be loaded")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: self.storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self.sessions)
            try data.write(to: self.storageURL, options: .atomic)
        } catch {
            print("Failed to save sessions: \(error)")
        }
    }
}
