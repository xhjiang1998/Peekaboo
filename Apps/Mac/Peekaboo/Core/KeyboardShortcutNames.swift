//
//  KeyboardShortcutNames.swift
//  Peekaboo
//

import AppKit
import KeyboardShortcuts

enum PeekabooShortcutDefaults {
    static let captureAndAsk = KeyboardShortcuts.Shortcut(.q, modifiers: [.option])
    static let captureAndAskDisplayText = "⌥Q"
}

extension KeyboardShortcuts.Name {
    static let captureAndAsk = Self("captureAndAsk", initial: PeekabooShortcutDefaults.captureAndAsk)
    static let togglePopover = Self("togglePopover", initial: .init(.space, modifiers: [.command, .shift]))
    static let showMainWindow = Self("showMainWindow", initial: .init(.p, modifiers: [.command, .shift]))
    static let showInspector = Self("showInspector", initial: .init(.i, modifiers: [.command, .shift]))
}
