import KeyboardShortcuts
import Testing
@testable import Peekaboo

@Suite(.tags(.unit, .fast))
struct KeyboardShortcutNamesTests {
    @Test
    func `capture and ask defaults to option q`() {
        #expect(PeekabooShortcutDefaults.captureAndAsk == .init(.q, modifiers: [.option]))
        #expect(KeyboardShortcuts.getShortcut(for: .captureAndAsk) == PeekabooShortcutDefaults.captureAndAsk)
    }
}
