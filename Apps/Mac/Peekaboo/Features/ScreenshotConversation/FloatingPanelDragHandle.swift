import AppKit
import SwiftUI

struct FloatingPanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingPanelDragHandleView {
        FloatingPanelDragHandleView()
    }

    func updateNSView(_ nsView: FloatingPanelDragHandleView, context: Context) {}
}

final class FloatingPanelDragHandleView: NSView {
    enum Action: Equatable {
        case drag
        case resetToDefaultSize
    }

    static func action(forClickCount clickCount: Int) -> Action {
        clickCount == 2 ? .resetToDefaultSize : .drag
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        switch Self.action(forClickCount: event.clickCount) {
        case .resetToDefaultSize:
            (window as? FloatingScreenshotChatPanel)?.requestDefaultSizeReset()
        case .drag:
            window.performDrag(with: event)
        }
    }
}
