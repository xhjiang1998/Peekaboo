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

        let rootPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let contextsPermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("contexts").path)[.posixPermissions] as? NSNumber
        let imagesPermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("images").path)[.posixPermissions] as? NSNumber
        let imagePermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("images/\(context.imageFileName)").path)[.posixPermissions] as? NSNumber
        let contextPermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("contexts/\(sessionID.uuidString.lowercased()).json").path)[.posixPermissions]
            as? NSNumber
        #expect(rootPermissions?.intValue == 0o700)
        #expect(contextsPermissions?.intValue == 0o700)
        #expect(imagesPermissions?.intValue == 0o700)
        #expect(imagePermissions?.intValue == 0o600)
        #expect(contextPermissions?.intValue == 0o600)
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
    func `Image reader rejects symbolic links`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data([1, 2, 3]).write(to: outside)
        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        let context = try store.save(imageData: Data([4]), for: sessionID)
        let imageURL = root.appendingPathComponent("images/\(context.imageFileName)")
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: outside)

        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            _ = try store.imageData(for: sessionID)
        }
        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            _ = try store.hasImage(for: sessionID)
        }
    }

    @Test
    func `Context reader rejects symbolic links`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(imageData: Data([4]), for: sessionID)
        let contextURL = root.appendingPathComponent("contexts/\(sessionID.uuidString.lowercased()).json")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: contextURL, to: outside)
        try FileManager.default.createSymbolicLink(at: contextURL, withDestinationURL: outside)

        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            _ = try store.context(for: sessionID)
        }
    }

    @Test
    func `Image reader rejects files above the size limit`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        let context = try store.save(imageData: Data([4]), for: sessionID)
        let imageURL = root.appendingPathComponent("images/\(context.imageFileName)")
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(ScreenshotConversationContextStore.maximumImageBytes + 1))
        try handle.close()

        #expect(throws: ScreenshotConversationContextStoreError.fileTooLarge) {
            _ = try store.imageData(for: sessionID)
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
