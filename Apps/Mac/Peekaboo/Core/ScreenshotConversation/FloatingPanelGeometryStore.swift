import CoreGraphics
import Foundation

@MainActor
protocol FloatingPanelGeometryStoring: AnyObject {
    func loadFrame() -> CGRect?
    func saveFrame(_ frame: CGRect)
}

@MainActor
final class FloatingPanelGeometryStore: FloatingPanelGeometryStoring {
    static let storageKey = "peekaboo.floatingScreenshotChat.frame.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadFrame() -> CGRect? {
        guard let values = self.defaults.dictionary(forKey: Self.storageKey),
              let x = Self.number(in: values, key: "x"),
              let y = Self.number(in: values, key: "y"),
              let width = Self.number(in: values, key: "width"),
              let height = Self.number(in: values, key: "height")
        else {
            return nil
        }

        let frame = CGRect(x: x, y: y, width: width, height: height)
        return FloatingPanelGeometry.isValidFrame(frame) ? frame : nil
    }

    func saveFrame(_ frame: CGRect) {
        guard FloatingPanelGeometry.isValidFrame(frame) else { return }
        self.defaults.set(
            [
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
            ],
            forKey: Self.storageKey)
    }

    private static func number(in values: [String: Any], key: String) -> CGFloat? {
        guard let value = values[key] as? NSNumber else { return nil }
        let result = CGFloat(value.doubleValue)
        return result.isFinite ? result : nil
    }
}
