import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
struct FloatingPanelDragHandleTests {
    @Test
    func singleClickStartsSystemDragAndDoubleClickRequestsDefaultSize() {
        #expect(FloatingPanelDragHandleView.action(forClickCount: 1) == .drag)
        #expect(FloatingPanelDragHandleView.action(forClickCount: 2) == .resetToDefaultSize)
    }
}
