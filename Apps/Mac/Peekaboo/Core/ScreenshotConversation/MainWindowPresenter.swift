import AppKit
import Foundation

@MainActor
protocol MainWindowPresenting: AnyObject {
    func forceShow(sessionID: String)
}

@MainActor
final class MainWindowPresenter: MainWindowPresenting {
    typealias RetryScheduler = (
        _ delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void) -> Void

    private static let retryDelay: TimeInterval = 0.05
    private static let maximumLookupAttempts = 10

    private let sessionStore: SessionStore
    private let showDock: () -> Void
    private let activateApp: () -> Void
    private let openWindow: () -> Void
    private let bringWindowToFront: () -> Bool
    private let scheduleRetry: RetryScheduler

    init(
        sessionStore: SessionStore,
        showDock: @escaping () -> Void,
        activateApp: @escaping () -> Void,
        openWindow: @escaping () -> Void,
        bringWindowToFront: @escaping () -> Bool,
        scheduleRetry: @escaping RetryScheduler)
    {
        self.sessionStore = sessionStore
        self.showDock = showDock
        self.activateApp = activateApp
        self.openWindow = openWindow
        self.bringWindowToFront = bringWindowToFront
        self.scheduleRetry = scheduleRetry
    }

    convenience init(
        sessionStore: SessionStore,
        openWindow: @escaping () -> Void)
    {
        self.init(
            sessionStore: sessionStore,
            showDock: {
                DockIconManager.shared.temporarilyShowDock()
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            },
            openWindow: openWindow,
            bringWindowToFront: {
                Self.bringExistingWindowToFront()
            },
            scheduleRetry: { delay, operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        operation()
                    }
                }
            })
    }

    func forceShow(sessionID: String) {
        guard let session = self.sessionStore.session(id: sessionID) else { return }
        self.sessionStore.selectSession(session)
        self.showDock()
        self.activateApp()

        guard !self.bringWindowToFront() else { return }
        self.openWindow()
        self.retryWindowLookup(remainingAttempts: Self.maximumLookupAttempts - 1)
    }

    private func retryWindowLookup(remainingAttempts: Int) {
        guard remainingAttempts > 0 else { return }
        self.scheduleRetry(Self.retryDelay) { [weak self] in
            guard let self else { return }
            guard !self.bringWindowToFront() else { return }
            self.retryWindowLookup(remainingAttempts: remainingAttempts - 1)
        }
    }

    private static func bringExistingWindowToFront() -> Bool {
        guard let window = NSApp.windows.first(where: {
            AgentSessionUI.identifiesSessionWindow(
                identifier: $0.identifier?.rawValue,
                title: $0.title)
        }) else {
            return false
        }

        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
