import AppKit
import CoreGraphics
import Foundation

struct CaptureSelection: Equatable, Sendable {
    static let minimumDimension: CGFloat = 8

    let rect: CGRect
    let displayID: CGDirectDisplayID?

    init?(
        start: CGPoint,
        end: CGPoint,
        displayID: CGDirectDisplayID?,
        minimumDimension: CGFloat = CaptureSelection.minimumDimension)
    {
        self.init(
            rect: CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)),
            displayID: displayID,
            minimumDimension: minimumDimension)
    }

    init?(
        rect: CGRect,
        displayID: CGDirectDisplayID?,
        minimumDimension: CGFloat = CaptureSelection.minimumDimension)
    {
        let normalized = rect.standardized
        guard normalized.width >= minimumDimension,
              normalized.height >= minimumDimension,
              normalized.width.isFinite,
              normalized.height.isFinite,
              normalized.origin.x.isFinite,
              normalized.origin.y.isFinite
        else {
            return nil
        }
        self.rect = normalized
        self.displayID = displayID
    }
}

@MainActor
protocol CaptureAreaSelecting: AnyObject {
    func selectArea() async throws -> CaptureSelection?
    func cancel()
}

@MainActor
final class CaptureSelectionController: CaptureAreaSelecting {
    private var panels: [CaptureSelectionPanel] = []
    private var continuation: CheckedContinuation<CaptureSelection?, any Error>?

    func selectArea() async throws -> CaptureSelection? {
        if self.continuation != nil {
            self.cancel()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.presentSelectionPanels()
        }
    }

    func cancel() {
        self.finish(with: nil)
    }

    private func presentSelectionPanels() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            self.finish(with: nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        self.panels = screens.map { screen in
            let panel = CaptureSelectionPanel(screen: screen)
            let selectionView = CaptureSelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                displayID: Self.displayID(for: screen),
                onComplete: { [weak self, weak panel] localRect, displayID in
                    guard let self, let panel else { return }
                    let globalRect = panel.convertToScreen(localRect)
                    guard let selection = CaptureSelection(rect: globalRect, displayID: displayID) else {
                        return
                    }
                    self.finish(with: selection)
                },
                onCancel: { [weak self] in
                    self?.finish(with: nil)
                })
            panel.contentView = selectionView
            panel.makeFirstResponder(selectionView)
            panel.orderFrontRegardless()
            return panel
        }
        self.panels.last?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(with selection: CaptureSelection?) {
        let continuation = self.continuation
        self.continuation = nil
        for panel in self.panels {
            panel.orderOut(nil)
            panel.close()
        }
        self.panels.removeAll()
        NSCursor.arrow.set()
        continuation?.resume(returning: selection)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        self.setFrame(screen.frame, display: false)
        self.level = .screenSaver
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }
}

private final class CaptureSelectionView: NSView {
    private let displayID: CGDirectDisplayID?
    private let onComplete: (CGRect, CGDirectDisplayID?) -> Void
    private let onCancel: () -> Void
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    init(
        frame: CGRect,
        displayID: CGDirectDisplayID?,
        onComplete: @escaping (CGRect, CGDirectDisplayID?) -> Void,
        onCancel: @escaping () -> Void)
    {
        self.displayID = displayID
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        self.window?.makeKey()
        self.window?.makeFirstResponder(self)
        let point = self.convert(event.locationInWindow, from: nil)
        self.startPoint = point
        self.currentPoint = point
        self.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard self.startPoint != nil else { return }
        self.currentPoint = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint = self.startPoint else { return }
        let endPoint = self.convert(event.locationInWindow, from: nil)
        guard let localSelection = CaptureSelection(
            start: startPoint,
            end: endPoint,
            displayID: self.displayID)
        else {
            self.startPoint = nil
            self.currentPoint = nil
            self.needsDisplay = true
            return
        }
        self.onComplete(localSelection.rect, self.displayID)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            self.onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let overlay = NSBezierPath(rect: self.bounds)
        if let selectionRect = self.selectionRect {
            overlay.appendRect(selectionRect)
        }
        overlay.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        overlay.fill()

        guard let selectionRect = self.selectionRect else { return }
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y))
    }
}
