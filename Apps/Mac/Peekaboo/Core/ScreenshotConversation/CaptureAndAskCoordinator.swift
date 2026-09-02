import AppKit
import CoreGraphics
import Foundation
import Observation
import PeekabooCore

enum CaptureAndAskFailure: Equatable, Sendable {
    case screenRecordingDenied
    case selectionFailed
    case captureFailed
    case conversationFailed
    case analysisFailed
}

enum CaptureAndAskState: Equatable, Sendable {
    case idle
    case selecting
    case capturing
    case presenting(sessionID: String)
    case analyzing(sessionID: String)
    case ready(sessionID: String)
    case failed(CaptureAndAskFailure)
}

@MainActor
protocol CaptureAndAskCoordinating: AnyObject {
    func startCapture()
}

@Observable
@MainActor
final class CaptureAndAskCoordinator: CaptureAndAskCoordinating {
    typealias PermissionCheck = () async -> Bool
    typealias AreaSelector = () async throws -> CaptureSelection?
    typealias CaptureRectResolver = (CGRect) -> CGRect
    typealias AreaCapture = (CGRect) async throws -> Data
    typealias ConversationCreator = (Data) throws -> String
    typealias WindowPresenter = (String) -> Void
    typealias ConversationAnalyzer = (String) async throws -> Void

    private(set) var state: CaptureAndAskState = .idle

    private let permissionCheck: PermissionCheck
    private let selectArea: AreaSelector
    private let resolveCaptureRect: CaptureRectResolver
    private let captureArea: AreaCapture
    private let createConversation: ConversationCreator
    private let presentWindow: WindowPresenter
    private let analyze: ConversationAnalyzer
    private let cancelSelection: () -> Void
    private var captureTask: Task<Void, Never>?

    init(
        permissionCheck: @escaping PermissionCheck,
        selectArea: @escaping AreaSelector,
        resolveCaptureRect: @escaping CaptureRectResolver,
        captureArea: @escaping AreaCapture,
        createConversation: @escaping ConversationCreator,
        presentWindow: @escaping WindowPresenter,
        analyze: @escaping ConversationAnalyzer,
        cancelSelection: @escaping () -> Void = {})
    {
        self.permissionCheck = permissionCheck
        self.selectArea = selectArea
        self.resolveCaptureRect = resolveCaptureRect
        self.captureArea = captureArea
        self.createConversation = createConversation
        self.presentWindow = presentWindow
        self.analyze = analyze
        self.cancelSelection = cancelSelection
    }

    convenience init(
        services: PeekabooServices,
        selector: any CaptureAreaSelecting,
        conversationService: ScreenshotConversationService,
        windowPresenter: any MainWindowPresenting)
    {
        self.init(
            permissionCheck: {
                await services.screenCapture.hasScreenRecordingPermission()
            },
            selectArea: {
                try await selector.selectArea()
            },
            resolveCaptureRect: { rect in
                Self.globalDisplayRect(fromAppKit: rect)
            },
            captureArea: { rect in
                let result = try await services.screenCapture.captureArea(
                    rect,
                    visualizerMode: .none,
                    scale: .logical1x)
                return result.imageData
            },
            createConversation: { imageData in
                try conversationService.createConversation(imageData: imageData).id
            },
            presentWindow: { sessionID in
                windowPresenter.forceShow(sessionID: sessionID)
            },
            analyze: { sessionID in
                try await conversationService.analyze(sessionID: sessionID)
            },
            cancelSelection: {
                selector.cancel()
            })
    }

    func startCapture() {
        guard self.captureTask == nil else { return }
        self.captureTask = Task { [weak self] in
            guard let self else { return }
            await self.performCapture()
            self.captureTask = nil
        }
    }

    func cancelCapture() {
        self.cancelSelection()
        self.captureTask?.cancel()
        self.captureTask = nil
        self.state = .idle
    }

    func performCapture() async {
        guard await self.permissionCheck() else {
            self.state = .failed(.screenRecordingDenied)
            return
        }

        self.state = .selecting
        let selection: CaptureSelection
        do {
            guard let selectedArea = try await self.selectArea() else {
                self.state = .idle
                return
            }
            selection = selectedArea
        } catch {
            self.state = .failed(.selectionFailed)
            return
        }

        guard !Task.isCancelled else {
            self.state = .idle
            return
        }

        self.state = .capturing
        let imageData: Data
        do {
            imageData = try await self.captureArea(self.resolveCaptureRect(selection.rect))
        } catch {
            self.state = .failed(.captureFailed)
            return
        }

        let sessionID: String
        do {
            sessionID = try self.createConversation(imageData)
        } catch {
            self.state = .failed(.conversationFailed)
            return
        }

        self.state = .presenting(sessionID: sessionID)
        self.presentWindow(sessionID)
        self.state = .analyzing(sessionID: sessionID)

        do {
            try await self.analyze(sessionID)
            guard !Task.isCancelled else {
                self.state = .idle
                return
            }
            self.state = .ready(sessionID: sessionID)
        } catch {
            self.state = .failed(.analysisFailed)
        }
    }

    private static func globalDisplayRect(fromAppKit rect: CGRect) -> CGRect {
        guard let primaryScreenFrame = NSScreen.screens.first?.frame else { return rect }
        return CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}
