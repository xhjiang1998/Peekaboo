import KeyboardShortcuts
import Testing
@testable import Peekaboo

@Suite(.serialized, .tags(.unit, .fast))
struct KeyboardShortcutNamesTests {
    @Test
    func `capture and ask defaults to option q`() {
        #expect(PeekabooShortcutDefaults.captureAndAsk == .init(.q, modifiers: [.option]))
        #expect(KeyboardShortcuts.Name.captureAndAsk.initialShortcut == PeekabooShortcutDefaults.captureAndAsk)
    }

    @Test
    func `saved custom shortcut overrides option q default`() {
        let previousShortcut = KeyboardShortcuts.getShortcut(for: .captureAndAsk)
        defer {
            KeyboardShortcuts.setShortcut(previousShortcut, for: .captureAndAsk)
        }

        let customShortcut = KeyboardShortcuts.Shortcut(.r, modifiers: [.command, .shift])
        KeyboardShortcuts.setShortcut(customShortcut, for: .captureAndAsk)

        #expect(KeyboardShortcuts.getShortcut(for: .captureAndAsk) == customShortcut)
        #expect(KeyboardShortcuts.Name.captureAndAsk.initialShortcut == PeekabooShortcutDefaults.captureAndAsk)
    }
}
