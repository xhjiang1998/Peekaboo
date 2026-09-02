import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct ScreenshotConversationContextStoreTests {
    @Test
    func `Saved screenshot context can be restored by session ID`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let store = ScreenshotConversationContextStore(rootDirectory: root)

        let context = try store.save(imageData: imageData, for: sessionID)

        #expect(context.sessionID == sessionID)
        #expect(context.imageFileName == "\(sessionID.uuidString.lowercased()).png")
        #expect(try store.imageData(for: sessionID) == imageData)

        let restoredStore = ScreenshotConversationContextStore(rootDirectory: root)
        #expect(try restoredStore.context(for: sessionID) == context)
        #expect(try restoredStore.imageData(for: sessionID) == imageData)
    }

    @Test
    func `Removing a screenshot context deletes metadata and image`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(imageData: Data([1, 2, 3]), for: sessionID)

        try store.removeContext(for: sessionID)

        #expect(try store.context(for: sessionID) == nil)
        #expect(try store.imageData(for: sessionID) == nil)
    }

    @Test
    func `Context metadata cannot escape the screenshot directory`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let contextsDirectory = root.appendingPathComponent("contexts", isDirectory: true)
        try FileManager.default.createDirectory(at: contextsDirectory, withIntermediateDirectories: true)
        let unsafeContext = ScreenshotConversationContext(
            sessionID: sessionID,
            imageFileName: "../outside.png",
            createdAt: Date())
        let data = try JSONEncoder().encode(unsafeContext)
        try data.write(
            to: contextsDirectory.appendingPathComponent("\(sessionID.uuidString.lowercased()).json"),
            options: .atomic)

        let store = ScreenshotConversationContextStore(rootDirectory: root)

        #expect(throws: ScreenshotConversationContextStoreError.unsafeImageFileName) {
            _ = try store.context(for: sessionID)
        }
    }

    @Test
    func `Cleanup removes image files without matching context`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let orphan = imagesDirectory.appendingPathComponent("orphan.png")
        try Data([1]).write(to: orphan)
        let store = ScreenshotConversationContextStore(rootDirectory: root)

        let removed = try store.cleanupOrphanedImages()

        #expect(removed == ["orphan.png"])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test
    func `Cleanup removes contexts whose sessions no longer exist`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let retainedSessionID = UUID()
        let removedSessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(imageData: Data([1]), for: retainedSessionID)
        _ = try store.save(imageData: Data([2]), for: removedSessionID)

        let removed = try store.cleanupContexts(keeping: [retainedSessionID])

        #expect(removed == [removedSessionID])
        #expect(try store.imageData(for: retainedSessionID) == Data([1]))
        #expect(try store.context(for: removedSessionID) == nil)
        #expect(try store.imageData(for: removedSessionID) == nil)
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-context-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
