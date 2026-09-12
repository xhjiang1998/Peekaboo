import CoreGraphics
import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct FloatingPanelGeometryStoreTests {
    @Test
    func geometryRoundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let store = FloatingPanelGeometryStore(defaults: defaults)
        let frame = CGRect(x: -720, y: 42, width: 640, height: 520)

        store.saveFrame(frame)

        #expect(store.loadFrame() == frame)
    }

    @Test
    func invalidPersistedGeometryIsIgnored() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        for size in [
            CGSize(width: -1, height: 600),
            CGSize(width: 460, height: -1),
        ] {
            defaults.removePersistentDomain(forName: #function)
            defaults.set(
                ["x": 10, "y": 20, "width": size.width, "height": size.height],
                forKey: FloatingPanelGeometryStore.storageKey)

            #expect(FloatingPanelGeometryStore(defaults: defaults).loadFrame() == nil)
        }
    }
}
