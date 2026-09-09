import AppKit
import SwiftUI

struct ScreenshotPreviewCard: View {
    static let collapsedHeight: CGFloat = 100
    static let expandedMaximumHeight: CGFloat = 280

    @Environment(ScreenshotConversationService.self) private var screenshotConversationService

    let sessionID: String
    let isExpanded: Bool

    @State private var imageData: Data?

    var body: some View {
        Group {
            if let imageData, let image = NSImage(data: imageData) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("截图上下文", systemImage: "viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: 560,
                            maxHeight: self.isExpanded ? Self.expandedMaximumHeight : Self.collapsedHeight,
                            alignment: .leading)
                        .frame(
                            height: self.isExpanded ? nil : Self.collapsedHeight,
                            alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Label("原截图已丢失，请重新截图", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: self.sessionID) {
            self.imageData = nil
            self.imageData = try? self.screenshotConversationService.imageData(for: self.sessionID)
        }
    }
}

struct ScreenshotConversationProgressView: View {
    let isCancelling: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(self.isCancelling ? "正在停止分析…" : "正在分析截图…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScreenshotAnalysisErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(self.message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

struct ScreenshotFollowUpComposer: View {
    @Environment(ScreenshotConversationService.self) private var screenshotConversationService

    let sessionID: String
    let placeholder: String
    let canSubmit: Bool
    let isBusy: Bool

    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(self.placeholder, text: self.$inputText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit {
                    self.submitInput()
                }

            if self.canStop {
                Button(action: {
                    self.screenshotConversationService.cancel(sessionID: self.sessionID)
                }, label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                })
                .buttonStyle(.plain)
                .help("停止分析")
            }

            Button(action: self.submitInput, label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(self.normalizedInput.isEmpty ? .secondary : .accentColor)
            })
            .buttonStyle(.plain)
            .disabled(self.normalizedInput.isEmpty || !self.canSubmit || self.isBusy)
        }
        .padding(12)
    }

    static func normalizedInput(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedInput: String {
        Self.normalizedInput(self.inputText)
    }

    private var canStop: Bool {
        self.screenshotConversationService.status(for: self.sessionID) == .analyzing
    }

    private func submitInput() {
        let input = self.normalizedInput
        guard !input.isEmpty, self.canSubmit, !self.isBusy else { return }

        self.inputText = ""
        Task {
            do {
                try await self.screenshotConversationService.sendFollowUp(
                    input,
                    sessionID: self.sessionID)
            } catch {
                print("Screenshot follow-up failed: \(error.localizedDescription)")
            }
        }
    }
}
