import AppKit
import ImageIO
import SwiftUI

struct ScreenshotCaptureStatusPresentation: Equatable {
    let title: String
    let systemImage: String
    let offersRecovery: Bool

    init(state: ScreenshotCaptureAnalysisState) {
        switch state {
        case .pending:
            self.init(title: "等待中", systemImage: "clock", offersRecovery: false)
        case .analyzing:
            self.init(title: "分析中", systemImage: "sparkles", offersRecovery: false)
        case .ready:
            self.init(title: "已完成", systemImage: "checkmark.circle.fill", offersRecovery: false)
        case .failed:
            self.init(title: "失败", systemImage: "exclamationmark.triangle.fill", offersRecovery: true)
        case .skipped:
            self.init(title: "已跳过", systemImage: "forward.fill", offersRecovery: false)
        }
    }

    private init(title: String, systemImage: String, offersRecovery: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.offersRecovery = offersRecovery
    }
}

struct ScreenshotCaptureBrowser: View {
    @Environment(ScreenshotConversationService.self) private var screenshotConversationService

    let sessionID: String
    let selectedCaptureID: UUID?
    let isExpanded: Bool
    let onSelectCapture: (UUID) -> Void

    var body: some View {
        let captures = self.screenshotConversationService.captures(sessionID: self.sessionID)
        let selectedCapture = captures.first(where: { $0.captureID == self.selectedCaptureID }) ?? captures.last
        VStack(alignment: .leading, spacing: 10) {
            if captures.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(captures) { capture in
                            ScreenshotCaptureThumbnailButton(
                                sessionID: self.sessionID,
                                capture: capture,
                                isSelected: capture.captureID == selectedCapture?.captureID,
                                onSelect: { self.onSelectCapture(capture.captureID) })
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            ScreenshotPreviewCard(
                sessionID: self.sessionID,
                captureID: selectedCapture?.captureID,
                isExpanded: self.isExpanded)

            if let selectedCapture,
               ScreenshotCaptureStatusPresentation(state: selectedCapture.analysisState).offersRecovery
            {
                HStack(spacing: 12) {
                    Label("这张截图分析失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("跳过") {
                        Task {
                            try? await self.screenshotConversationService.skipFailedCapture(
                                sessionID: self.sessionID,
                                captureID: selectedCapture.captureID)
                        }
                    }
                    .buttonStyle(.link)
                    Button("重试") {
                        Task {
                            try? await self.screenshotConversationService.retryCapture(
                                sessionID: self.sessionID,
                                captureID: selectedCapture.captureID)
                        }
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct ScreenshotCaptureThumbnailButton: View {
    let sessionID: String
    let capture: ScreenshotCaptureDescriptor
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(ScreenshotConversationService.self) private var screenshotConversationService
    @State private var thumbnail: NSImage?

    var body: some View {
        let status = ScreenshotCaptureStatusPresentation(state: self.capture.analysisState)
        Button(action: self.onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("截图 \(self.capture.index)")
                    .font(.caption.weight(.semibold))
                Label(status.title, systemImage: status.systemImage)
                    .font(.caption2)
                    .foregroundStyle(self.capture.analysisState == .failed ? Color.red : Color.secondary)
            }
            .padding(6)
            .background(
                self.isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(self.isSelected ? Color.accentColor : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("截图 \(self.capture.index)，\(status.title)")
        .task(id: self.capture.captureID) {
            self.thumbnail = nil
            guard let data = try? self.screenshotConversationService.imageData(
                sessionID: self.sessionID,
                captureID: self.capture.captureID)
            else { return }
            self.thumbnail = Self.downsampledImage(data, maximumPixelSize: 160)
        }
    }

    private static func downsampledImage(_ data: Data, maximumPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct ScreenshotPreviewCard: View {
    static let collapsedHeight: CGFloat = 100
    static let expandedMaximumHeight: CGFloat = 280

    @Environment(ScreenshotConversationService.self) private var screenshotConversationService

    let sessionID: String
    var captureID: UUID?
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
        .task(id: "\(self.sessionID)-\(self.captureID?.uuidString ?? "legacy")") {
            self.imageData = nil
            if let captureID {
                self.imageData = try? self.screenshotConversationService.imageData(
                    sessionID: self.sessionID,
                    captureID: captureID)
            } else {
                self.imageData = try? self.screenshotConversationService.imageData(for: self.sessionID)
            }
        }
    }

    init(sessionID: String, captureID: UUID? = nil, isExpanded: Bool) {
        self.sessionID = sessionID
        self.captureID = captureID
        self.isExpanded = isExpanded
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
                // The service exposes a sanitized status message to the UI. Do not log
                // provider errors here because they may contain response bodies or URLs.
            }
        }
    }
}
