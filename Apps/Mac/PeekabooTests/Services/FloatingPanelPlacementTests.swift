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
    func `When neither side fits the side with more raw space is selected before clamping`() {
        let visible = CGRect(x: 0, y: 0, width: 900, height: 900)
        let origin = FloatingPanelPlacement.origin(
            selectionRect: CGRect(x: 350, y: 300, width: 200, height: 100),
            visibleFrame: visible,
            panelSize: self.panel)

        #expect(origin.x == 16)
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

    @Test
    func `Normalization chooses the screen with the greatest intersection and clamps both axes`() throws {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let normalized = try #require(FloatingPanelGeometry.normalizedFrame(
            CGRect(x: -200, y: -500, width: 800, height: 1200),
            screens: [left, right],
            fallbackScreen: nil))

        #expect(normalized == CGRect(x: 16, y: 16, width: 800, height: 1048))
    }

    @Test
    func `Normalization uses fallback for an offscreen frame and preserves negative coordinates`() throws {
        let fallback = CGRect(x: -1440, y: -20, width: 1440, height: 900)

        let normalized = try #require(FloatingPanelGeometry.normalizedFrame(
            CGRect(x: 5000, y: 5000, width: 460, height: 600),
            screens: [fallback, CGRect(x: 0, y: 0, width: 1440, height: 900)],
            fallbackScreen: fallback))

        #expect(normalized == CGRect(x: -476, y: 264, width: 460, height: 600))
    }

    @Test
    func `Normalization shrinks below standard minimum only for an unusually small screen`() throws {
        let tinyScreen = CGRect(x: 20, y: 30, width: 300, height: 220)

        let normalized = try #require(FloatingPanelGeometry.normalizedFrame(
            CGRect(x: 0, y: 0, width: 100, height: 100),
            screens: [tinyScreen],
            fallbackScreen: nil))

        #expect(normalized == CGRect(x: 36, y: 46, width: 268, height: 188))
    }

    @Test
    func `Normalization returns nil when no screens are available`() {
        #expect(FloatingPanelGeometry.normalizedFrame(
            CGRect(x: 0, y: 0, width: 460, height: 600),
            screens: [],
            fallbackScreen: nil) == nil)
    }

    @Test
    func `A stale fallback screen is ignored after that display disappears`() throws {
        let remainingScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let staleScreen = CGRect(x: -1440, y: 0, width: 1440, height: 900)

        let normalized = try #require(FloatingPanelGeometry.normalizedFrame(
            CGRect(x: 5_000, y: 5_000, width: 460, height: 600),
            screens: [remainingScreen],
            fallbackScreen: staleScreen))

        #expect(normalized == CGRect(x: 964, y: 284, width: 460, height: 600))
    }
}
