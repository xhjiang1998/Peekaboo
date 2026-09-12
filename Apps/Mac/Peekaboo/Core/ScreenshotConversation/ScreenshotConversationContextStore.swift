import Foundation

enum ScreenshotCaptureAnalysisState: String, Codable, Equatable, Sendable {
    case pending
    case analyzing
    case ready
    case failed
    case skipped
}

struct ScreenshotCapture: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let imageFileName: String
    let createdAt: Date
    var analysisState: ScreenshotCaptureAnalysisState
    let assistantMessageID: UUID
}

struct ScreenshotConversationContext: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let imageFileName: String
    let createdAt: Date
    var captures: [ScreenshotCapture]

    init(
        schemaVersion: Int,
        sessionID: UUID,
        imageFileName: String,
        createdAt: Date,
        captures: [ScreenshotCapture])
    {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.imageFileName = imageFileName
        self.createdAt = createdAt
        self.captures = captures
    }

    init(sessionID: UUID, imageFileName: String, createdAt: Date) {
        self.init(
            schemaVersion: 1,
            sessionID: sessionID,
            imageFileName: imageFileName,
            createdAt: createdAt,
            captures: [])
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, imageFileName, createdAt, captures
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.schemaVersion = schemaVersion
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.imageFileName = try container.decode(String.self, forKey: .imageFileName)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        if schemaVersion >= 2 {
            self.captures = try container.decodeIfPresent([ScreenshotCapture].self, forKey: .captures) ?? []
        } else {
            self.captures = []
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.imageFileName, forKey: .imageFileName)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.captures, forKey: .captures)
    }
}

enum ScreenshotConversationContextStoreError: Error, Equatable {
    case mismatchedSessionID
    case unsafeImageFileName
    case unsafeFileType
    case fileTooLarge
    case contextTooLarge
    case contextNotFound
    case captureNotFound
    case duplicateCaptureID
    case legacyContextRequiresMigration
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
        let root = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootDirectory = root
        self.contextsDirectory = root.appendingPathComponent("contexts", isDirectory: true)
        self.imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
    }

    @discardableResult
    func save(imageData: Data, for sessionID: UUID) throws -> ScreenshotConversationContext {
        try self.validateImageSize(imageData)
        try self.createDirectoriesIfNeeded()
        let imageFileName = Self.rootImageFileName(for: sessionID)
        let context = ScreenshotConversationContext(
            sessionID: sessionID,
            imageFileName: imageFileName,
            createdAt: Date())
        let imageURL = self.imagesDirectory.appendingPathComponent(imageFileName)
        try self.writeImageThenContext(imageData, imageURL: imageURL, context: context)
        return context
    }

    @discardableResult
    func save(
        imageData: Data,
        for sessionID: UUID,
        captureID: UUID,
        assistantMessageID: UUID,
        createdAt: Date = Date()) throws -> ScreenshotConversationContext
    {
        try self.validateImageSize(imageData)
        try self.createDirectoriesIfNeeded()
        let imageFileName = Self.rootImageFileName(for: sessionID)
        let context = ScreenshotConversationContext(
            schemaVersion: 2,
            sessionID: sessionID,
            imageFileName: imageFileName,
            createdAt: createdAt,
            captures: [ScreenshotCapture(
                id: captureID,
                imageFileName: imageFileName,
                createdAt: createdAt,
                analysisState: .pending,
                assistantMessageID: assistantMessageID)])
        let imageURL = self.imagesDirectory.appendingPathComponent(imageFileName)
        try self.writeImageThenContext(imageData, imageURL: imageURL, context: context)
        return context
    }

    @discardableResult
    func append(
        imageData: Data,
        captureID: UUID,
        assistantMessageID: UUID,
        to sessionID: UUID,
        createdAt: Date = Date()) throws -> ScreenshotConversationContext
    {
        try self.validateImageSize(imageData)
        guard var context = try self.context(for: sessionID) else {
            throw ScreenshotConversationContextStoreError.contextNotFound
        }
        guard context.schemaVersion >= 2 else {
            throw ScreenshotConversationContextStoreError.legacyContextRequiresMigration
        }
        guard !context.captures.contains(where: { $0.id == captureID }) else {
            throw ScreenshotConversationContextStoreError.duplicateCaptureID
        }
        let imageFileName = Self.nestedImageFileName(for: sessionID, captureID: captureID)
        context.captures.append(ScreenshotCapture(
            id: captureID,
            imageFileName: imageFileName,
            createdAt: createdAt,
            analysisState: .pending,
            assistantMessageID: assistantMessageID))
        let sessionDirectory = self.imagesDirectory.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true)
        try self.createPrivateDirectory(at: sessionDirectory)
        let imageURL = self.imagesDirectory.appendingPathComponent(imageFileName)
        do {
            try self.writeImageThenContext(imageData, imageURL: imageURL, context: context)
        } catch {
            try? self.removeEmptyDirectoryIfPresent(sessionDirectory)
            throw error
        }
        return context
    }

    @discardableResult
    func updateAnalysisState(
        _ state: ScreenshotCaptureAnalysisState,
        for captureID: UUID,
        in sessionID: UUID) throws -> ScreenshotConversationContext
    {
        guard var context = try self.context(for: sessionID) else {
            throw ScreenshotConversationContextStoreError.contextNotFound
        }
        guard let captureIndex = context.captures.firstIndex(where: { $0.id == captureID }) else {
            throw ScreenshotConversationContextStoreError.captureNotFound
        }
        context.captures[captureIndex].analysisState = state
        try self.write(context: context)
        return context
    }

    @discardableResult
    func replaceContext(_ context: ScreenshotConversationContext) throws -> ScreenshotConversationContext {
        try Self.validate(context: context)
        try self.createDirectoriesIfNeeded()
        try self.write(context: context)
        return context
    }

    @discardableResult
    func removeCapture(_ captureID: UUID, from sessionID: UUID) throws -> ScreenshotConversationContext? {
        guard var context = try self.context(for: sessionID) else {
            throw ScreenshotConversationContextStoreError.contextNotFound
        }
        guard let captureIndex = context.captures.firstIndex(where: { $0.id == captureID }) else {
            throw ScreenshotConversationContextStoreError.captureNotFound
        }
        if context.captures.count == 1 {
            try self.removeContext(for: sessionID)
            return nil
        }
        let capture = context.captures.remove(at: captureIndex)
        try self.write(context: context)
        try self.removeIfPresent(self.imageURL(for: capture.imageFileName))
        try self.removeEmptySessionDirectory(for: sessionID)
        return context
    }

    func context(for sessionID: UUID) throws -> ScreenshotConversationContext? {
        let url = self.contextURL(for: sessionID)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        let context = try self.decoder.decode(
            ScreenshotConversationContext.self,
            from: self.readRegularFile(at: url, maximumBytes: Self.maximumContextBytes))
        guard context.sessionID == sessionID else {
            throw ScreenshotConversationContextStoreError.mismatchedSessionID
        }
        try Self.validate(context: context)
        return context
    }

    func imageData(for sessionID: UUID) throws -> Data? {
        guard let context = try self.context(for: sessionID) else { return nil }
        return try self.readImageIfPresent(fileName: context.imageFileName)
    }

    func imageData(for sessionID: UUID, captureID: UUID) throws -> Data? {
        guard let context = try self.context(for: sessionID) else { return nil }
        guard let capture = context.captures.first(where: { $0.id == captureID }) else {
            throw ScreenshotConversationContextStoreError.captureNotFound
        }
        return try self.readImageIfPresent(fileName: capture.imageFileName)
    }

    func hasImage(for sessionID: UUID) throws -> Bool {
        guard let context = try self.context(for: sessionID) else { return false }
        let imageURL = self.imageURL(for: context.imageFileName)
        guard self.fileManager.fileExists(atPath: imageURL.path) else { return false }
        try self.validateRegularFile(at: imageURL, maximumBytes: Self.maximumImageBytes)
        return true
    }

    func removeContext(for sessionID: UUID) throws {
        let context = try self.context(for: sessionID)
        if let context {
            var imageFileNames = Set(context.captures.map(\.imageFileName))
            imageFileNames.insert(context.imageFileName)
            for imageFileName in imageFileNames {
                try self.removeIfPresent(self.imageURL(for: imageFileName))
            }
            try self.removeEmptySessionDirectory(for: sessionID)
        }
        try self.removeIfPresent(self.contextURL(for: sessionID))
    }

    @discardableResult
    func cleanupOrphanedImages() throws -> [String] {
        try self.createDirectoriesIfNeeded()
        let referencedImages = try self.referencedImageFileNames()
        var removedFileNames: [String] = []
        let rootURLs = try self.fileManager.contentsOfDirectory(
            at: self.imagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        for url in rootURLs {
            if url.pathExtension.lowercased() == "png" {
                let fileName = url.lastPathComponent
                if !referencedImages.contains(fileName) {
                    try self.fileManager.removeItem(at: url)
                    removedFileNames.append(fileName)
                }
                continue
            }
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  (try? self.isDirectoryWithoutFollowingSymbolicLinks(url)) == true
            else { continue }
            let nestedURLs = try self.fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            for nestedURL in nestedURLs where nestedURL.pathExtension.lowercased() == "png" {
                let relativePath = "\(url.lastPathComponent.lowercased())/\(nestedURL.lastPathComponent)"
                if !referencedImages.contains(relativePath) {
                    try self.fileManager.removeItem(at: nestedURL)
                    removedFileNames.append(relativePath)
                }
            }
            try self.removeEmptyDirectoryIfPresent(url)
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
                  (try? Self.validate(context: context)) != nil
            else {
                try self.fileManager.removeItem(at: contextURL)
                continue
            }
            guard !sessionIDs.contains(sessionID) else { continue }
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

    private static func rootImageFileName(for sessionID: UUID) -> String {
        "\(sessionID.uuidString.lowercased()).png"
    }

    private static func nestedImageFileName(for sessionID: UUID, captureID: UUID) -> String {
        "\(sessionID.uuidString.lowercased())/\(captureID.uuidString.lowercased()).png"
    }

    private static func validate(context: ScreenshotConversationContext) throws {
        try Self.validateRootImageFileName(context.imageFileName)
        guard context.schemaVersion >= 2 else {
            guard context.captures.isEmpty else {
                throw ScreenshotConversationContextStoreError.unsafeImageFileName
            }
            return
        }
        guard context.imageFileName == Self.rootImageFileName(for: context.sessionID) else {
            throw ScreenshotConversationContextStoreError.unsafeImageFileName
        }
        guard Set(context.captures.map(\.id)).count == context.captures.count else {
            throw ScreenshotConversationContextStoreError.duplicateCaptureID
        }
        for (index, capture) in context.captures.enumerated() {
            if index == 0, capture.imageFileName == context.imageFileName { continue }
            guard capture.imageFileName == Self.nestedImageFileName(
                for: context.sessionID,
                captureID: capture.id)
            else {
                throw ScreenshotConversationContextStoreError.unsafeImageFileName
            }
        }
    }

    private static func validateRootImageFileName(_ imageFileName: String) throws {
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

    private func imageURL(for imageFileName: String) -> URL {
        self.imagesDirectory.appendingPathComponent(imageFileName, isDirectory: false)
    }

    private func createDirectoriesIfNeeded() throws {
        try self.createPrivateDirectory(at: self.rootDirectory)
        try self.createPrivateDirectory(at: self.contextsDirectory)
        try self.createPrivateDirectory(at: self.imagesDirectory)
    }

    private func createPrivateDirectory(at url: URL) throws {
        if url.standardizedFileURL.path != self.rootDirectory.standardizedFileURL.path {
            try self.validateManagedParentHierarchy(for: url)
        }
        try self.fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.validateManagedDirectory(url)
        try self.fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
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
                let context = try? self.decoder.decode(
                    ScreenshotConversationContext.self,
                    from: data),
                (try? Self.validate(context: context)) != nil
            else { continue }
            imageFileNames.insert(context.imageFileName)
            imageFileNames.formUnion(context.captures.map(\.imageFileName))
        }
        return imageFileNames
    }

    private func writeImageThenContext(
        _ imageData: Data,
        imageURL: URL,
        context: ScreenshotConversationContext) throws
    {
        try self.validateManagedParentHierarchy(for: imageURL)
        try imageData.write(to: imageURL, options: .atomic)
        try self.setPrivateFilePermissions(at: imageURL)
        do {
            try self.write(context: context)
        } catch {
            try? self.fileManager.removeItem(at: imageURL)
            throw error
        }
    }

    private func write(context: ScreenshotConversationContext) throws {
        try Self.validate(context: context)
        let contextData = try self.encoder.encode(context)
        guard contextData.count <= Self.maximumContextBytes else {
            throw ScreenshotConversationContextStoreError.contextTooLarge
        }
        let contextURL = self.contextURL(for: context.sessionID)
        try self.validateManagedParentHierarchy(for: contextURL)
        try contextData.write(to: contextURL, options: .atomic)
        try self.setPrivateFilePermissions(at: contextURL)
    }

    private func readImageIfPresent(fileName: String) throws -> Data? {
        let imageURL = self.imageURL(for: fileName)
        guard self.fileManager.fileExists(atPath: imageURL.path) else { return nil }
        return try self.readRegularFile(
            at: imageURL,
            maximumBytes: Self.maximumImageBytes)
    }

    private func validateImageSize(_ imageData: Data) throws {
        guard imageData.count <= Self.maximumImageBytes else {
            throw ScreenshotConversationContextStoreError.fileTooLarge
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard self.fileManager.fileExists(atPath: url.path) else { return }
        try self.validateManagedParentHierarchy(for: url)
        try self.fileManager.removeItem(at: url)
    }

    private func removeEmptySessionDirectory(for sessionID: UUID) throws {
        try self.removeEmptyDirectoryIfPresent(
            self.imagesDirectory.appendingPathComponent(
                sessionID.uuidString.lowercased(),
                isDirectory: true))
    }

    private func removeEmptyDirectoryIfPresent(_ url: URL) throws {
        guard self.fileManager.fileExists(atPath: url.path) else { return }
        try self.validateManagedParentHierarchy(for: url)
        try self.validateManagedDirectory(url)
        if try self.fileManager.contentsOfDirectory(atPath: url.path).isEmpty {
            try self.fileManager.removeItem(at: url)
        }
    }

    private func setPrivateFilePermissions(at url: URL) throws {
        try self.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }

    private func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try self.validateManagedParentHierarchy(for: url)
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

    private func isDirectoryWithoutFollowingSymbolicLinks(_ url: URL) throws -> Bool {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private func validateManagedDirectory(_ url: URL) throws {
        guard try self.isDirectoryWithoutFollowingSymbolicLinks(url) else {
            throw ScreenshotConversationContextStoreError.unsafeFileType
        }
    }

    private func validateManagedParentHierarchy(for url: URL) throws {
        let rootPath = self.rootDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw ScreenshotConversationContextStoreError.unsafeImageFileName
        }

        var directory = url.deletingLastPathComponent().standardizedFileURL
        var directories: [URL] = []
        while directory.path != rootPath {
            guard directory.path.hasPrefix(rootPath + "/") else {
                throw ScreenshotConversationContextStoreError.unsafeImageFileName
            }
            directories.append(directory)
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else {
                throw ScreenshotConversationContextStoreError.unsafeImageFileName
            }
            directory = parent
        }
        directories.append(self.rootDirectory.standardizedFileURL)
        for managedDirectory in directories.reversed() {
            try self.validateManagedDirectory(managedDirectory)
        }
    }
}
