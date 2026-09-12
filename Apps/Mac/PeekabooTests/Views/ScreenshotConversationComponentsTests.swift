import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
struct ScreenshotConversationComponentsTests {
    @Test(arguments: [
        (ScreenshotCaptureAnalysisState.pending, "等待中", "clock"),
        (ScreenshotCaptureAnalysisState.analyzing, "分析中", "sparkles"),
        (ScreenshotCaptureAnalysisState.ready, "已完成", "checkmark.circle.fill"),
        (ScreenshotCaptureAnalysisState.failed, "失败", "exclamationmark.triangle.fill"),
        (ScreenshotCaptureAnalysisState.skipped, "已跳过", "forward.fill"),
    ])
    func captureStateHasStableAccessiblePresentation(
        state: ScreenshotCaptureAnalysisState,
        title: String,
        symbol: String)
    {
        let presentation = ScreenshotCaptureStatusPresentation(state: state)
        #expect(presentation.title == title)
        #expect(presentation.systemImage == symbol)
    }

    @Test
    func onlyFailedCapturesExposeRecoveryActions() {
        #expect(ScreenshotCaptureStatusPresentation(state: .failed).offersRecovery)
        #expect(!ScreenshotCaptureStatusPresentation(state: .pending).offersRecovery)
        #expect(!ScreenshotCaptureStatusPresentation(state: .analyzing).offersRecovery)
        #expect(!ScreenshotCaptureStatusPresentation(state: .ready).offersRecovery)
        #expect(!ScreenshotCaptureStatusPresentation(state: .skipped).offersRecovery)
    }
}
