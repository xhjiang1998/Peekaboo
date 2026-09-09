import Foundation

struct ScreenshotConversationContext: Codable, Equatable, Sendable {
    let sessionID: UUID
    let imageFileName: String
    let createdAt: Date
}

enum ScreenshotConversationContextStoreError: Error, Equatable {
    case mismatchedSessionID
    case unsafeImageFileName
    case unsafeFileType
    case fileTooLarge
}

@MainActor
final class ScreenshotConversationContextStore {
    static let maximumImageBytes = 50 * 1024 * 1024
    static let maximumContextBytes = 64 * 1024

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
        guard imageData.count <= Self.maximumImageBytes else {
            throw ScreenshotConversationContextStoreError.fileTooLarge
        }
        try self.createDirectoriesIfNeeded()

        let imageFileName = Self.imageFileName(for: sessionID)
        let context = ScreenshotConversationContext(
            sessionID: sessionID,
            imageFileName: imageFileName,
            createdAt: Date())
        let imageURL = self.imagesDirectory.appendingPathComponent(imageFileName, isDirectory: false)
        let contextURL = self.contextURL(for: sessionID)

        try imageData.write(to: imageURL, options: .atomic)
        try self.setPrivateFilePermissions(at: imageURL)

        do {
            let contextData = try self.encoder.encode(context)
            try contextData.write(to: contextURL, options: .atomic)
            try self.setPrivateFilePermissions(at: contextURL)
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
            from: self.readRegularFile(at: url, maximumBytes: Self.maximumContextBytes))
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
        return try self.readRegularFile(at: imageURL, maximumBytes: Self.maximumImageBytes)
    }

    func hasImage(for sessionID: UUID) throws -> Bool {
        guard let context = try self.context(for: sessionID) else {
            return false
        }
        let imageURL = self.imagesDirectory.appendingPathComponent(
            context.imageFileName,
            isDirectory: false)
        guard self.fileManager.fileExists(atPath: imageURL.path) else { return false }
        try self.validateRegularFile(at: imageURL, maximumBytes: Self.maximumImageBytes)
        return true
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
                      from: self.readRegularFile(
                          at: contextURL,
                          maximumBytes: Self.maximumContextBytes)),
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
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.fileManager.createDirectory(
            at: self.contextsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.fileManager.createDirectory(
            at: self.imagesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for directory in [self.rootDirectory, self.contextsDirectory, self.imagesDirectory] {
            try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func referencedImageFileNames() throws -> Set<String> {
        let contextURLs = try self.fileManager.contentsOfDirectory(
            at: self.contextsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var imageFileNames = Set<String>()

        for contextURL in contextURLs where contextURL.pathExtension.lowercased() == "json" {
            guard let data = try? self.readRegularFile(
                at: contextURL,
                maximumBytes: Self.maximumContextBytes),
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

    private func setPrivateFilePermissions(at url: URL) throws {
        try self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try self.validateRegularFile(at: url, maximumBytes: maximumBytes)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func validateRegularFile(at url: URL, maximumBytes: Int) throws {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ScreenshotConversationContextStoreError.unsafeFileType
        }
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
        guard fileSize <= UInt64(maximumBytes) else {
            throw ScreenshotConversationContextStoreError.fileTooLarge
        }
    }
}
