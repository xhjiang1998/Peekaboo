import AppKit
import PeekabooCore
import SwiftUI

struct FloatingScreenshotChatView: View {
    enum ConversationRegion: Hashable {
        case header
        case scrollableConversation
        case status
        case composer
    }

    static let cardWidth: CGFloat = 460
    static let conversationRegions: [ConversationRegion] = [
        .header,
        .scrollableConversation,
        .status,
        .composer,
    ]

    @Environment(SessionStore.self) private var sessionStore
    @Environment(ScreenshotConversationService.self) private var screenshotConversationService

    let state: FloatingScreenshotChatState
    let onClose: () -> Void
    let onHorizontalDrag: (_ translation: CGFloat, _ startX: CGFloat) -> Void

    var body: some View {
        Group {
            if let session = self.session {
                self.conversationCard(session: session)
            } else {
                self.unavailableCard
            }
        }
        .frame(width: Self.cardWidth)
        .modernBackground(style: .hudWindow, cornerRadius: 18)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var session: ConversationSession? {
        guard let sessionID = self.state.currentContext?.sessionID else { return nil }
        return self.sessionStore.session(id: sessionID)
    }

    private func conversationCard(session: ConversationSession) -> some View {
        VStack(spacing: 0) {
            ForEach(Self.conversationRegions, id: \.self) { region in
                switch region {
                case .header:
                    FloatingScreenshotChatHeader(
                        modelName: self.modelName(for: session),
                        isPreviewExpanded: self.state.isPreviewExpanded,
                        onClose: self.onClose,
                        onTogglePreview: self.state.togglePreview,
                        onHorizontalDrag: self.onHorizontalDrag)
                    Divider()
                case .scrollableConversation:
                    self.conversationContent(session: session)
                case .status:
                    self.statusView(sessionID: session.id)
                case .composer:
                    Divider()
                    ScreenshotFollowUpComposer(
                        sessionID: session.id,
                        placeholder: self.placeholder(for: session.id),
                        canSubmit: self.canSubmit(sessionID: session.id),
                        isBusy: self.isBusy(sessionID: session.id))
                        .id(session.id)
                }
            }
        }
    }

    private func conversationContent(session: ConversationSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ScreenshotPreviewCard(
                        sessionID: session.id,
                        isExpanded: self.state.isPreviewExpanded)
                        .id("screenshot-preview-\(session.id)")

                    ForEach(session.messages) { message in
                        DetailedMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onAppear {
                self.scrollToLatestMessage(in: session, proxy: proxy)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation {
                    self.scrollToLatestMessage(in: session, proxy: proxy)
                }
            }
        }
    }

    @ViewBuilder
    private func statusView(sessionID: String) -> some View {
        let route = self.screenshotConversationService.route(for: sessionID)
        let status = self.screenshotConversationService.status(for: sessionID)

        if route == .screenshotContextMissing {
            ScreenshotAnalysisErrorBanner(
                message: "原截图已丢失，请重新截图",
                retry: nil)
                .id("screenshot-context-missing")
        } else if case let .failed(message) = status {
            ScreenshotAnalysisErrorBanner(
                message: message,
                retry: {
                    Task {
                        try? await self.screenshotConversationService.analyze(sessionID: sessionID)
                    }
                })
                .id("screenshot-analysis-error")
        } else if self.isBusy(sessionID: sessionID) {
            ScreenshotConversationProgressView(isCancelling: status == .cancelling)
                .id("screenshot-progress")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var unavailableCard: some View {
        VStack(spacing: 0) {
            FloatingScreenshotChatHeader(
                modelName: nil,
                isPreviewExpanded: false,
                onClose: self.onClose,
                onTogglePreview: {},
                onHorizontalDrag: self.onHorizontalDrag)

            Divider()

            Label("截图会话不可用，请重新截图", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private func modelName(for session: ConversationSession) -> String? {
        session.modelName.isEmpty ? nil : session.modelName
    }

    private func isBusy(sessionID: String) -> Bool {
        let status = self.screenshotConversationService.status(for: sessionID)
        return status == .analyzing || status == .cancelling
    }

    private func canSubmit(sessionID: String) -> Bool {
        self.screenshotConversationService.route(for: sessionID) == .screenshotAvailable &&
            !self.isBusy(sessionID: sessionID)
    }

    private func placeholder(for sessionID: String) -> String {
        let route = self.screenshotConversationService.route(for: sessionID)
        let status = self.screenshotConversationService.status(for: sessionID)
        if status == .cancelling {
            return "正在停止分析…"
        } else if self.isBusy(sessionID: sessionID) {
            return "正在分析截图…"
        } else if route == .screenshotContextMissing {
            return "原截图已丢失，请重新截图"
        } else {
            return "继续追问这张截图…"
        }
    }

    private func scrollToLatestMessage(in session: ConversationSession, proxy: ScrollViewProxy) {
        if let lastMessage = session.messages.last {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

private struct FloatingScreenshotChatHeader: View {
    let modelName: String?
    let isPreviewExpanded: Bool
    let onClose: () -> Void
    let onTogglePreview: () -> Void
    let onHorizontalDrag: (_ translation: CGFloat, _ startX: CGFloat) -> Void

    @State private var windowBox = WeakFloatingWindowBox()
    @State private var dragStartX: CGFloat?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("截图分析")
                        .font(.headline)
                    if let modelName {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .gesture(self.dragGesture)
            .background {
                FloatingWindowReader { window in
                    self.windowBox.window = window
                }
            }

            Button(action: self.onTogglePreview, label: {
                Image(systemName: self.isPreviewExpanded ? "chevron.up" : "chevron.down")
            })
            .buttonStyle(.plain)
            .help(self.isPreviewExpanded ? "折叠截图" : "展开截图")

            Button(action: self.onClose, label: {
                Image(systemName: "xmark")
            })
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if self.dragStartX == nil {
                    self.dragStartX = self.windowBox.window?.frame.minX
                }
                guard let dragStartX = self.dragStartX else { return }
                self.onHorizontalDrag(value.translation.width, dragStartX)
            }
            .onEnded { _ in
                self.dragStartX = nil
            }
    }
}

@MainActor
private final class WeakFloatingWindowBox {
    weak var window: NSWindow?
}

private struct FloatingWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(onWindowChange: self.onWindowChange)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = self.onWindowChange
    }
}

private final class WindowReaderView: NSView {
    var onWindowChange: (NSWindow?) -> Void

    init(onWindowChange: @escaping (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.onWindowChange(self.window)
    }
}
