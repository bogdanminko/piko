import AppKit
import SwiftUI

/// Who the keyboard belongs to.
///
/// Two rules, both learned the same way — by a field that appeared, looked
/// ready to type in, and then sent every keystroke to the chat.
///
/// **Ask a tick late.** A focus request made while the field is still being
/// placed is dropped by AppKit without a word. Every editor in this app is
/// entered by the same click that creates it, so the request always lands in
/// exactly that window.
///
/// **Never take the caret out of a field somebody is typing in.** The workspace
/// composer pulls focus to itself when it appears and after every answer, which
/// is right — typing on that screen is nearly always talking to the chat — but
/// renaming a conversation and correcting a transcript line happen beside it,
/// and those fields must be allowed to keep what they were given.
@MainActor
enum FieldFocus {
    /// Set a `@FocusState` once the field it belongs to is actually on screen.
    static func take(_ focus: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            focus()
        }
    }

    /// True while a text field anywhere in the key window holds the caret.
    /// Read through AppKit on purpose: `@FocusState` only ever answers for the
    /// view that declared it, and the question here is about another one.
    static var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }
}
