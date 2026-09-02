//
//  KeyboardShortcutNames.swift
//  Peekaboo
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureAndAsk = Self("captureAndAsk", initial: .init(.a, modifiers: [.command, .option]))
    static let togglePopover = Self("togglePopover", initial: .init(.space, modifiers: [.command, .shift]))
    static let showMainWindow = Self("showMainWindow", initial: .init(.p, modifiers: [.command, .shift]))
    static let showInspector = Self("showInspector", initial: .init(.i, modifiers: [.command, .shift]))
}
