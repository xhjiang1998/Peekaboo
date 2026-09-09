import CoreGraphics
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
struct FloatingPanelPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panel = CGSize(width: 460, height: 600)

    @Test
    func `A fully fitting panel is placed to the right of the selection`() {
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: 100, y: 300, width: 300, height: 200),
            visibleFrame: self.visible,
            panelSize: self.panel)

        #expect(origin.x == 412)
    }

    @Test
    func `When the right side does not fit a fully fitting panel is placed to the left`() {
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: 900, y: 300, width: 300, height: 200),
            visibleFrame: self.visible,
            panelSize: self.panel)

        #expect(origin.x == 428)
    }

    @Test
    func `Panel origin is clamped to the visible frame margin`() {
        #expect(FloatingPanelPlacement.clampedX(
            -200,
            visibleFrame: self.visible,
            panelWidth: 460) == 16)
    }

    @Test
    func `Negative display coordinates are preserved when placing the panel`() {
        let visible = CGRect(x: -1440, y: -20, width: 1440, height: 900)
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: -1300, y: 300, width: 200, height: 100),
            visibleFrame: visible,
            panelSize: self.panel)

        #expect(origin.x == -1088)
    }

    @Test
    func `Panel is clamped below the menu bar when aligned selection top is too high`() {
        let visible = CGRect(x: 0, y: -20, width: 1440, height: 800)
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: 100, y: -500, width: 200, height: 100),
            visibleFrame: visible,
            panelSize: self.panel)

        #expect(origin.y == -4)
    }

    @Test
    func `Panel is clamped above the Dock when aligned selection top is too low`() {
        let visible = CGRect(x: 0, y: -20, width: 1440, height: 800)
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: 100, y: 700, width: 200, height: 100),
            visibleFrame: visible,
            panelSize: self.panel)

        #expect(origin.y == 164)
    }
}
