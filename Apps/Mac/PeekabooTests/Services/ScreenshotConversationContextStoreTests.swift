import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct ScreenshotConversationContextStoreTests {
    @Test
    func `Legacy v1 context decodes without synthesizing captures`() throws {
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([
            "sessionID": sessionID.uuidString,
            "imageFileName": "\(sessionID.uuidString.lowercased()).png",
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
        ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let context = try decoder.decode(ScreenshotConversationContext.self, from: legacyData)

        #expect(context.schemaVersion == 1)
        #expect(context.sessionID == sessionID)
        #expect(context.captures.isEmpty)
    }

    @Test
    func `Legacy manifest ignores injected capture paths before any file operation`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data([9]).write(to: outside)
        let sessionID = UUID()
        let rootFileName = "\(sessionID.uuidString.lowercased()).png"
        let contextsDirectory = root.appendingPathComponent("contexts", isDirectory: true)
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: contextsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: imagesDirectory.appendingPathComponent(rootFileName))
        let maliciousJSON: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "imageFileName": rootFileName,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "captures": [[
                "id": UUID().uuidString,
                "imageFileName": "../../\(outside.lastPathComponent)",
                "createdAt": Date().timeIntervalSinceReferenceDate,
                "analysisState": "pending",
                "assistantMessageID": UUID().uuidString,
            ]],
        ]
        let contextURL = contextsDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).json")
        try JSONSerialization.data(withJSONObject: maliciousJSON).write(to: contextURL)
        let store = ScreenshotConversationContextStore(rootDirectory: root)

        #expect(try store.context(for: sessionID)?.captures.isEmpty == true)
        try store.removeContext(for: sessionID)

        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func `Second capture is appended in controlled session subdirectory`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let firstCaptureID = UUID()
        let secondCaptureID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)

        _ = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: firstCaptureID,
            assistantMessageID: UUID())
        let context = try store.append(
            imageData: Data([2]),
            captureID: secondCaptureID,
            assistantMessageID: UUID(),
            to: sessionID)

        #expect(context.schemaVersion == 2)
        #expect(context.captures.map(\.id) == [firstCaptureID, secondCaptureID])
        #expect(context.captures[1].imageFileName ==
            "\(sessionID.uuidString.lowercased())/\(secondCaptureID.uuidString.lowercased()).png")
        #expect(try store.imageData(for: sessionID, captureID: secondCaptureID) == Data([2]))
    }

    @Test
    func `Capture state can be updated without changing stable IDs`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let captureID = UUID()
        let assistantMessageID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: captureID,
            assistantMessageID: assistantMessageID)

        let context = try store.updateAnalysisState(.ready, for: captureID, in: sessionID)

        #expect(context.captures.first?.id == captureID)
        #expect(context.captures.first?.assistantMessageID == assistantMessageID)
        #expect(context.captures.first?.analysisState == .ready)
    }

    @Test
    func `Context rejects capture paths that do not match stable IDs`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let contextsDirectory = root.appendingPathComponent("contexts", isDirectory: true)
        try FileManager.default.createDirectory(at: contextsDirectory, withIntermediateDirectories: true)
        let context = ScreenshotConversationContext(
            schemaVersion: 2,
            sessionID: sessionID,
            imageFileName: "\(sessionID.uuidString.lowercased()).png",
            createdAt: Date(),
            captures: [
                ScreenshotCapture(
                    id: UUID(),
                    imageFileName: "\(sessionID.uuidString.lowercased())/../outside.png",
                    createdAt: Date(),
                    analysisState: .pending,
                    assistantMessageID: UUID()),
            ])
        try JSONEncoder().encode(context).write(
            to: contextsDirectory.appendingPathComponent("\(sessionID.uuidString.lowercased()).json"))

        let store = ScreenshotConversationContextStore(rootDirectory: root)
        #expect(throws: ScreenshotConversationContextStoreError.unsafeImageFileName) {
            _ = try store.context(for: sessionID)
        }
    }

    @Test
    func `Removing context deletes every capture image and its empty directory`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: UUID(),
            assistantMessageID: UUID())
        _ = try store.append(
            imageData: Data([2]),
            captureID: UUID(),
            assistantMessageID: UUID(),
            to: sessionID)

        try store.removeContext(for: sessionID)

        #expect(try store.context(for: sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath:
            root.appendingPathComponent("images/\(sessionID.uuidString.lowercased())").path))
    }

    @Test
    func `Orphan cleanup traverses controlled capture directories`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let orphanCaptureID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: UUID(),
            assistantMessageID: UUID())
        let sessionDirectory = root.appendingPathComponent(
            "images/\(sessionID.uuidString.lowercased())",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let orphanRelativePath =
            "\(sessionID.uuidString.lowercased())/\(orphanCaptureID.uuidString.lowercased()).png"
        try Data([9]).write(to: root.appendingPathComponent("images/\(orphanRelativePath)"))

        let removed = try store.cleanupOrphanedImages()

        #expect(removed == [orphanRelativePath])
        #expect(!FileManager.default.fileExists(atPath:
            root.appendingPathComponent("images/\(orphanRelativePath)").path))
    }

    @Test
    func `Appended image and directory receive private permissions`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        _ = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: UUID(),
            assistantMessageID: UUID())
        let captureID = UUID()
        _ = try store.append(
            imageData: Data([2]),
            captureID: captureID,
            assistantMessageID: UUID(),
            to: sessionID)
        let directoryURL = root.appendingPathComponent("images/\(sessionID.uuidString.lowercased())")
        let imageURL = directoryURL.appendingPathComponent("\(captureID.uuidString.lowercased()).png")
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: directoryURL.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(
            atPath: imageURL.path)[.posixPermissions] as? NSNumber

        #expect(directoryPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
    }

    @Test
    func `Symlinked session directory cannot redirect capture reads writes or deletes`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sessionID = UUID()
        let firstCaptureID = UUID()
        let linkedCaptureID = UUID()
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        let firstContext = try store.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: firstCaptureID,
            assistantMessageID: UUID())
        let linkedFileName =
            "\(sessionID.uuidString.lowercased())/\(linkedCaptureID.uuidString.lowercased()).png"
        var captures = firstContext.captures
        captures.append(ScreenshotCapture(
            id: linkedCaptureID,
            imageFileName: linkedFileName,
            createdAt: Date(),
            analysisState: .pending,
            assistantMessageID: UUID()))
        _ = try store.replaceContext(ScreenshotConversationContext(
            schemaVersion: 2,
            sessionID: sessionID,
            imageFileName: firstContext.imageFileName,
            createdAt: firstContext.createdAt,
            captures: captures))
        let sessionDirectory = root.appendingPathComponent(
            "images/\(sessionID.uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(
            at: sessionDirectory,
            withDestinationURL: outsideDirectory)
        let outsideLinkedImage = outsideDirectory.appendingPathComponent(
            "\(linkedCaptureID.uuidString.lowercased()).png")
        try Data([8]).write(to: outsideLinkedImage)
        let newCaptureID = UUID()

        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            _ = try store.imageData(for: sessionID, captureID: linkedCaptureID)
        }
        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            _ = try store.append(
                imageData: Data([2]),
                captureID: newCaptureID,
                assistantMessageID: UUID(),
                to: sessionID)
        }
        #expect(throws: ScreenshotConversationContextStoreError.unsafeFileType) {
            try store.removeContext(for: sessionID)
        }

        #expect(try Data(contentsOf: outsideLinkedImage) == Data([8]))
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent(
            "\(newCaptureID.uuidString.lowercased()).png").path))
    }

    @Test
    func `Manifest overflow rolls back only the newly appended image`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let rootFileName = "\(sessionID.uuidString.lowercased()).png"
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        var captures = [ScreenshotCapture(
            id: UUID(),
            imageFileName: rootFileName,
            createdAt: createdAt,
            analysisState: .pending,
            assistantMessageID: UUID())]
        var overflowingCaptureID = UUID()
        var overflowingAssistantID = UUID()
        while true {
            let captureID = UUID()
            let assistantID = UUID()
            let candidate = captures + [ScreenshotCapture(
                id: captureID,
                imageFileName: "\(sessionID.uuidString.lowercased())/\(captureID.uuidString.lowercased()).png",
                createdAt: createdAt,
                analysisState: .pending,
                assistantMessageID: assistantID)]
            let candidateContext = ScreenshotConversationContext(
                schemaVersion: 2,
                sessionID: sessionID,
                imageFileName: rootFileName,
                createdAt: createdAt,
                captures: candidate)
            if try JSONEncoder().encode(candidateContext).count >
                ScreenshotConversationContextStore.maximumContextBytes
            {
                overflowingCaptureID = captureID
                overflowingAssistantID = assistantID
                break
            }
            captures = candidate
        }
        let store = ScreenshotConversationContextStore(rootDirectory: root)
        let originalContext = ScreenshotConversationContext(
            schemaVersion: 2,
            sessionID: sessionID,
            imageFileName: rootFileName,
            createdAt: createdAt,
            captures: captures)
        try store.replaceContext(originalContext)

        #expect(throws: ScreenshotConversationContextStoreError.contextTooLarge) {
            _ = try store.append(
                imageData: Data([7]),
                captureID: overflowingCaptureID,
                assistantMessageID: overflowingAssistantID,
                to: sessionID,
                createdAt: createdAt)
        }

        #expect(try store.context(for: sessionID) == originalContext)
        let rejectedImage = root.appendingPathComponent(
            "images/\(sessionID.uuidString.lowercased())/\(overflowingCaptureID.uuidString.lowercased()).png")
        #expect(!FileManager.default.fileExists(atPath: rejectedImage.path))
    }

    @Test
    func `Saved screenshot context can be restored by session ID`() throws {
        let root = self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let store = ScreenshotConversationContextStore(rootDirectory: root)

        let context = try store.save(imageData: imageData, for: sessionID)

        #expect(context.schemaVersion == 1)
        #expect(context.captures.isEmpty)
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
