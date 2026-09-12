import SwiftUI
import Perception
import Perception

/// A hardware key the composer may want before the text field sees it.
enum ComposerKey: Sendable, Equatable {
    case up
    case down
    case accept
    case escape
}

/// The composer's text entry (`web-chat-ux.md §7.1`, `design-brief.md §7.3`).
///
/// One to six lines, growing with the draft. Direction is re-decided from the draft's own first
/// strong character on every keystroke, so an Arabic sentence types right-to-left inside the
/// permanently left-to-right shell and an English one does not (`ARCHITECTURE.md §2.8`).
///
/// Return inserts a newline unless Settings → `الإرسال بمفتاح Enter` is on; `⌘↩` always sends and is
/// owned by the send button, not by this view.
struct ComposerField: View {

    @Binding private var text: String
    private let placeholder: String
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let fontScale: FontScale
    private let sendOnReturn: Bool
    private let isFocused: FocusState<Bool>.Binding
    private let onSubmit: () -> Void
    private let onKey: (ComposerKey) -> Bool

    init(
        text: Binding<String>,
        placeholder: String,
        palette: FirasPalette,
        lang: AppLanguage,
        fontScale: FontScale,
        sendOnReturn: Bool,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void,
        onKey: @escaping (ComposerKey) -> Bool
    ) {
        self._text = text
        self.placeholder = placeholder
        self.palette = palette
        self.lang = lang
        self.fontScale = fontScale
        self.sendOnReturn = sendOnReturn
        self.isFocused = isFocused
        self.onSubmit = onSubmit
        self.onKey = onKey
    }

    var body: some View {
        WithPerceptionTracking {
        WithPerceptionTracking {
            FirasGrowingTextField(text: $text, placeholder: placeholder, pointSize: 17 * fontScale.factor,
                palette: palette, isFocused: isFocused, sendOnReturn: sendOnReturn,
                onSubmit: onSubmit, onKey: onKey)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .bidiIsland(for: text, fallback: lang)
            .accessibilityLabel(Text(placeholder))
        }
        }
    }
}
