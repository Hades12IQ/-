import SwiftUI
import UIKit

/// Putting the keyboard away.
///
/// The composer's `@FocusState` is private to `ComposerView`, and the thing a person taps to
/// dismiss — the conversation above it — lives in a different view entirely. Rather than thread a
/// focus binding through every screen, this asks UIKit to resign whatever is first responder, which
/// is what "tap outside the keyboard" means on every other iOS app.
///
/// Two ways in, because one is never enough:
///   * dragging the transcript down (`.scrollDismissesKeyboard(.interactively)`, already on the
///     transcript) — the gesture people expect, but it needs something scrollable, so it does
///     nothing on an empty conversation;
///   * tapping anywhere that is not a control — this file.
enum Keyboard {

    /// Resign the current first responder. Safe to call when nothing is focused.
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct DismissKeyboardOnTap: ViewModifier {

    func body(content: Content) -> some View {
        content
            /* `simultaneousGesture`, not `onTapGesture`: a plain tap gesture on a container competes
               with the buttons inside it and wins often enough to make a message's copy button feel
               dead. A simultaneous tap runs alongside them, so a tap on a button both presses the
               button and puts the keyboard away — which is what should happen anyway.

               `count: 1` with no `contentShape` on purpose: this must not make empty space
               hit-testable, only listen where the content already is. */
            .simultaneousGesture(
                TapGesture(count: 1).onEnded { Keyboard.dismiss() }
            )
    }
}

extension View {

    /// Tapping this view puts the keyboard away, without stealing taps from the controls inside it.
    func dismissesKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTap())
    }
}
