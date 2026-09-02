import Foundation

struct ScreenshotConversationContext: Codable, Equatable, Sendable {
    let sessionID: UUID
    let imageFileName: String
    let createdAt: Date
}

enum ScreenshotConversationContextStoreError: Error, Equatable {
    case mismatchedSessionID
    case unsafeImageFileName
}

@MainActor
final class ScreenshotConversationContextStore {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let contextsDirectory: URL
    private let imagesDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootDirectory = resolvedRoot
        self.contextsDirectory = resolvedRoot.appendingPathComponent("contexts", isDirectory: true)
        self.imagesDirectory = resolvedRoot.appendingPathComponent("images", isDirectory: true)
    }

    @discardableResult
    func save(imageData: Data, for sessionID: UUID) throws -> ScreenshotConversationContext {
        try self.createDirectoriesIfNeeded()

        let imageFileName = Self.imageFileName(for: sessionID)
        let context = ScreenshotConversationContext(
            sessionID: sessionID,
            imageFileName: imageFileName,
            createdAt: Date())
        let imageURL = self.imagesDirectory.appendingPathComponent(imageFileName, isDirectory: false)
        let contextURL = self.contextURL(for: sessionID)

        try imageData.write(to: imageURL, options: .atomic)

        do {
            let contextData = try self.encoder.encode(context)
            try contextData.write(to: contextURL, options: .atomic)
        } catch {
            try? self.fileManager.removeItem(at: imageURL)
            throw error
        }

        return context
    }

    func context(for sessionID: UUID) throws -> ScreenshotConversationContext? {
        let url = self.contextURL(for: sessionID)
        guard self.fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let context = try self.decoder.decode(
            ScreenshotConversationContext.self,
            from: Data(contentsOf: url))
        guard context.sessionID == sessionID else {
            throw ScreenshotConversationContextStoreError.mismatchedSessionID
        }
        try Self.validate(imageFileName: context.imageFileName)
        return context
    }

    func imageData(for sessionID: UUID) throws -> Data? {
        guard let context = try self.context(for: sessionID) else {
            return nil
        }

        let imageURL = self.imagesDirectory.appendingPathComponent(
            context.imageFileName,
            isDirectory: false)
        guard self.fileManager.fileExists(atPath: imageURL.path) else {
            return nil
        }
        return try Data(contentsOf: imageURL)
    }

    func removeContext(for sessionID: UUID) throws {
        let context = try self.context(for: sessionID)
        if let context {
            let imageURL = self.imagesDirectory.appendingPathComponent(
                context.imageFileName,
                isDirectory: false)
            try self.removeIfPresent(imageURL)
        }
        try self.removeIfPresent(self.contextURL(for: sessionID))
    }

    @discardableResult
    func cleanupOrphanedImages() throws -> [String] {
        try self.createDirectoriesIfNeeded()

        let referencedImages = try self.referencedImageFileNames()
        let imageURLs = try self.fileManager.contentsOfDirectory(
            at: self.imagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var removedFileNames: [String] = []

        for imageURL in imageURLs where imageURL.pathExtension.lowercased() == "png" {
            let fileName = imageURL.lastPathComponent
            guard !referencedImages.contains(fileName) else {
                continue
            }

            try self.fileManager.removeItem(at: imageURL)
            removedFileNames.append(fileName)
        }

        return removedFileNames.sorted()
    }

    @discardableResult
    func cleanupContexts(keeping sessionIDs: Set<UUID>) throws -> [UUID] {
        try self.createDirectoriesIfNeeded()

        let contextURLs = try self.fileManager.contentsOfDirectory(
            at: self.contextsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var removedSessionIDs: [UUID] = []

        for contextURL in contextURLs where contextURL.pathExtension.lowercased() == "json" {
            guard let sessionID = UUID(uuidString: contextURL.deletingPathExtension().lastPathComponent),
                  let context = try? self.decoder.decode(
                      ScreenshotConversationContext.self,
                      from: Data(contentsOf: contextURL)),
                  context.sessionID == sessionID,
                  (try? Self.validate(imageFileName: context.imageFileName)) != nil
            else {
                try self.fileManager.removeItem(at: contextURL)
                continue
            }

            guard !sessionIDs.contains(sessionID) else {
                continue
            }
            try self.removeContext(for: sessionID)
            removedSessionIDs.append(sessionID)
        }

        _ = try self.cleanupOrphanedImages()
        return removedSessionIDs.sorted { $0.uuidString < $1.uuidString }
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peekaboo", isDirectory: true)
            .appendingPathComponent("ScreenshotConversations", isDirectory: true)
    }

    private static func imageFileName(for sessionID: UUID) -> String {
        "\(sessionID.uuidString.lowercased()).png"
    }

    private static func validate(imageFileName: String) throws {
        let isSinglePathComponent = URL(fileURLWithPath: imageFileName).lastPathComponent == imageFileName
        let hasUnsupportedSeparator = imageFileName.contains("/") || imageFileName.contains("\\")
        guard isSinglePathComponent,
              !hasUnsupportedSeparator,
              imageFileName != ".",
              imageFileName != "..",
              imageFileName.lowercased().hasSuffix(".png")
        else {
            throw ScreenshotConversationContextStoreError.unsafeImageFileName
        }
    }

    private func contextURL(for sessionID: UUID) -> URL {
        self.contextsDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).json",
            isDirectory: false)
    }

    private func createDirectoriesIfNeeded() throws {
        try self.fileManager.createDirectory(
            at: self.rootDirectory,
            withIntermediateDirectories: true)
        try self.fileManager.createDirectory(
            at: self.contextsDirectory,
            withIntermediateDirectories: true)
        try self.fileManager.createDirectory(
            at: self.imagesDirectory,
            withIntermediateDirectories: true)
    }

    private func referencedImageFileNames() throws -> Set<String> {
        let contextURLs = try self.fileManager.contentsOfDirectory(
            at: self.contextsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var imageFileNames = Set<String>()

        for contextURL in contextURLs where contextURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: contextURL),
                  let context = try? self.decoder.decode(ScreenshotConversationContext.self, from: data)
            else {
                continue
            }

            do {
                try Self.validate(imageFileName: context.imageFileName)
                imageFileNames.insert(context.imageFileName)
            } catch ScreenshotConversationContextStoreError.unsafeImageFileName {
                continue
            }
        }

        return imageFileNames
    }

    private func removeIfPresent(_ url: URL) throws {
        guard self.fileManager.fileExists(atPath: url.path) else {
            return
        }
        try self.fileManager.removeItem(at: url)
    }
}
