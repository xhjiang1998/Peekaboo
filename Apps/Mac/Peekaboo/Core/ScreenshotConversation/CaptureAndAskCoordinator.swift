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

    var userMessage: String {
        switch self {
        case .screenRecordingDenied:
            "需要屏幕录制权限才能截取选区。"
        case .selectionFailed:
            "无法开始截图选区，请重试。"
        case .captureFailed:
            "截图失败，请重试。"
        case .conversationFailed:
            "无法保存截图，请检查磁盘空间后重试。"
        case .analysisFailed:
            "AI 分析失败，请在会话中重试。"
        }
    }
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
    private let reportFailure: (CaptureAndAskFailure) -> Void
    private var captureTask: Task<Void, Never>?
    private var latestSessionID: String?

    init(
        permissionCheck: @escaping PermissionCheck,
        selectArea: @escaping AreaSelector,
        resolveCaptureRect: @escaping CaptureRectResolver,
        captureArea: @escaping AreaCapture,
        createConversation: @escaping ConversationCreator,
        presentWindow: @escaping WindowPresenter,
        analyze: @escaping ConversationAnalyzer,
        cancelSelection: @escaping () -> Void = {},
        reportFailure: @escaping (CaptureAndAskFailure) -> Void = { _ in })
    {
        self.permissionCheck = permissionCheck
        self.selectArea = selectArea
        self.resolveCaptureRect = resolveCaptureRect
        self.captureArea = captureArea
        self.createConversation = createConversation
        self.presentWindow = presentWindow
        self.analyze = analyze
        self.cancelSelection = cancelSelection
        self.reportFailure = reportFailure
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
            },
            reportFailure: { failure in
                Self.showFailureAlert(failure)
            })
    }

    func startCapture() {
        guard self.captureTask == nil else { return }
        self.captureTask = Task { [weak self] in
            guard let self else { return }
            let sessionID = await self.prepareCapture()
            self.captureTask = nil
            guard let sessionID else { return }
            Task { [weak self] in
                await self?.performAnalysis(sessionID: sessionID)
            }
        }
    }

    func cancelCapture() {
        self.cancelSelection()
        self.captureTask?.cancel()
        self.captureTask = nil
        self.state = .idle
    }

    func performCapture() async {
        guard let sessionID = await self.prepareCapture() else { return }
        await self.performAnalysis(sessionID: sessionID)
    }

    private func prepareCapture() async -> String? {
        self.latestSessionID = nil
        guard await self.permissionCheck() else {
            self.fail(.screenRecordingDenied)
            return nil
        }

        self.state = .selecting
        let selection: CaptureSelection
        do {
            guard let selectedArea = try await self.selectArea() else {
                self.state = .idle
                return nil
            }
            selection = selectedArea
        } catch {
            self.fail(.selectionFailed)
            return nil
        }

        guard !Task.isCancelled else {
            self.state = .idle
            return nil
        }

        self.state = .capturing
        let imageData: Data
        do {
            imageData = try await self.captureArea(self.resolveCaptureRect(selection.rect))
        } catch {
            self.fail(.captureFailed)
            return nil
        }

        let sessionID: String
        do {
            sessionID = try self.createConversation(imageData)
        } catch {
            self.fail(.conversationFailed)
            return nil
        }

        self.latestSessionID = sessionID
        self.state = .presenting(sessionID: sessionID)
        self.presentWindow(sessionID)
        self.state = .analyzing(sessionID: sessionID)
        return sessionID
    }

    private func performAnalysis(sessionID: String) async {
        do {
            try await self.analyze(sessionID)
            guard !Task.isCancelled else {
                if self.latestSessionID == sessionID {
                    self.state = .idle
                }
                return
            }
            if self.latestSessionID == sessionID {
                self.state = .ready(sessionID: sessionID)
            }
        } catch is CancellationError {
            if self.latestSessionID == sessionID {
                self.state = .idle
            }
        } catch {
            if self.latestSessionID == sessionID {
                self.fail(.analysisFailed, showsAlert: false)
            }
        }
    }

    private func fail(_ failure: CaptureAndAskFailure, showsAlert: Bool = true) {
        self.state = .failed(failure)
        if showsAlert {
            self.reportFailure(failure)
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

    private static func showFailureAlert(_ failure: CaptureAndAskFailure) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure == .screenRecordingDenied ? "需要屏幕录制权限" : "截图 AI 未完成"
        alert.informativeText = failure.userMessage
        if failure == .screenRecordingDenied {
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
        } else {
            alert.addButton(withTitle: "好")
        }
        let response = alert.runModal()
        guard failure == .screenRecordingDenied,
              response == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
