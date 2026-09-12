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
        .frame(
            minWidth: FloatingPanelGeometry.minimumSize.width,
            minHeight: FloatingPanelGeometry.minimumSize.height)
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
                        onTogglePreview: self.state.togglePreview)
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
                    ScreenshotCaptureBrowser(
                        sessionID: session.id,
                        selectedCaptureID: self.state.selectedCaptureID,
                        isExpanded: self.state.isPreviewExpanded,
                        onSelectCapture: self.state.selectCapture)
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
            if !self.hasFailedCapture(sessionID: sessionID) {
                ScreenshotAnalysisErrorBanner(
                    message: message,
                    retry: {
                        Task {
                            try? await self.screenshotConversationService.retryAnalysis(sessionID: sessionID)
                        }
                    })
                    .id("screenshot-analysis-error")
            }
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
                onTogglePreview: {})

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
        self.screenshotConversationService.isBusy(sessionID: sessionID)
    }

    private func hasFailedCapture(sessionID: String) -> Bool {
        self.screenshotConversationService.captures(sessionID: sessionID)
            .contains(where: { $0.analysisState == .failed })
    }

    private func hasFailedStatus(sessionID: String) -> Bool {
        if case .failed = self.screenshotConversationService.status(for: sessionID) {
            return true
        }
        return false
    }

    private func canSubmit(sessionID: String) -> Bool {
        self.screenshotConversationService.route(for: sessionID) == .screenshotAvailable &&
            !self.isBusy(sessionID: sessionID) &&
            !self.hasFailedStatus(sessionID: sessionID)
    }

    private func placeholder(for sessionID: String) -> String {
        let route = self.screenshotConversationService.route(for: sessionID)
        let status = self.screenshotConversationService.status(for: sessionID)
        if status == .cancelling {
            return "正在停止分析…"
        } else if self.hasFailedCapture(sessionID: sessionID) {
            return "请先重试或跳过失败截图"
        } else if case .failed = status {
            return "请先重试失败的回答"
        } else if self.isBusy(sessionID: sessionID) {
            return "正在分析截图…"
        } else if route == .screenshotContextMissing {
            return "原截图已丢失，请重新截图"
        } else {
            return "继续追问当前会话…"
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
            .overlay {
                FloatingPanelDragHandle()
            }

            Button(action: self.onTogglePreview, label: {
                Image(systemName: self.isPreviewExpanded ? "chevron.up" : "chevron.down")
            })
            .buttonStyle(.plain)
            .help(self.isPreviewExpanded ? "折叠截图" : "展开截图")

            Button(action: self.onClose, label: {
                Image(systemName: "square.and.pencil")
            })
            .buttonStyle(.plain)
            .help("新会话")

            Button(action: self.onClose, label: {
                Image(systemName: "xmark")
            })
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

}
