import SwiftUI

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
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(FirasType.scaled(17, scale: fontScale))
            .foregroundStyle(palette.textPrimary)
            .tint(palette.accent)
            .lineLimit(1...6)
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .submitLabel(sendOnReturn ? .send : .return)
            .focused(isFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .bidiIsland(for: text, fallback: lang)
            .onSubmit {
                guard sendOnReturn else { return }
                onSubmit()
            }
            .onKeyPress(.upArrow) { onKey(.up) ? .handled : .ignored }
            .onKeyPress(.downArrow) { onKey(.down) ? .handled : .ignored }
            .onKeyPress(.escape) { onKey(.escape) ? .handled : .ignored }
            .onKeyPress(.tab) { onKey(.accept) ? .handled : .ignored }
            .accessibilityLabel(Text(placeholder))
    }
}
