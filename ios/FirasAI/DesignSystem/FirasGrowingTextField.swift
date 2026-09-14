import SwiftUI
import UIKit
import Perception

/// Keeps the current multiline field on modern iOS. The older native text view supplies growing
/// height, focus, return handling and hardware keys without depending on iOS16/17 SwiftUI APIs.
struct FirasGrowingTextField: View {
    @Binding private var text: String
    private let placeholder: String
    private let minLines: Int
    private let maxLines: Int
    private let pointSize: CGFloat
    private let palette: FirasPalette
    private let isFocused: FocusState<Bool>.Binding
    private let sendOnReturn: Bool
    private let onSubmit: () -> Void
    private let onKey: (ComposerKey) -> Bool
    private let selection: Binding<NSRange>?
    private let highlightedRanges: [NSRange]
    private let onLargePaste: ((String) -> Bool)?
    @State private var measuredHeight: CGFloat

    init(text: Binding<String>, placeholder: String, minLines: Int = 1, maxLines: Int = 6,
         pointSize: CGFloat = 17, palette: FirasPalette, isFocused: FocusState<Bool>.Binding,
         sendOnReturn: Bool = false, onSubmit: @escaping () -> Void = {},
         onKey: @escaping (ComposerKey) -> Bool = { _ in false },
         selection: Binding<NSRange>? = nil, highlightedRanges: [NSRange] = [],
         onLargePaste: ((String) -> Bool)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.minLines = max(1, minLines)
        self.maxLines = max(max(1, minLines), maxLines)
        self.pointSize = pointSize
        self.palette = palette
        self.isFocused = isFocused
        self.sendOnReturn = sendOnReturn
        self.onSubmit = onSubmit
        self.onKey = onKey
        self.selection = selection
        self.highlightedRanges = highlightedRanges
        self.onLargePaste = onLargePaste
        _measuredHeight = State(initialValue: UIFont.systemFont(ofSize: pointSize).lineHeight * CGFloat(max(1, minLines)))
    }

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 17.0, *), !FirasCompatibility.forceLegacyUI, selection == nil {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: pointSize))
                    .foregroundStyle(palette.textPrimary)
                    .tint(palette.accent)
                    .lineLimit(minLines...maxLines)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(false)
                    .submitLabel(sendOnReturn ? .send : .return)
                    .focused(isFocused)
                    .onSubmit { if sendOnReturn { onSubmit() } }
                    .onKeyPress(.upArrow) { onKey(.up) ? .handled : .ignored }
                    .onKeyPress(.downArrow) { onKey(.down) ? .handled : .ignored }
                    .onKeyPress(.escape) { onKey(.escape) ? .handled : .ignored }
                    .onKeyPress(.tab) { onKey(.accept) ? .handled : .ignored }
            } else {
                FirasLegacyGrowingEditor(text: $text, measuredHeight: $measuredHeight,
                    placeholder: placeholder, minLines: minLines, maxLines: maxLines, pointSize: pointSize,
                    palette: palette, focus: isFocused, focusRequested: isFocused.wrappedValue,
                    sendOnReturn: sendOnReturn, onSubmit: onSubmit, onKey: onKey,
                    selection: selection, highlightedRanges: highlightedRanges, onLargePaste: onLargePaste)
                    .frame(height: measuredHeight)
            }
        }
        .accessibilityLabel(Text(placeholder))
    }
}

private struct FirasLegacyGrowingEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let pointSize: CGFloat
    let palette: FirasPalette
    let focus: FocusState<Bool>.Binding
    let focusRequested: Bool
    let sendOnReturn: Bool
    let onSubmit: () -> Void
    let onKey: (ComposerKey) -> Bool
    let selection: Binding<NSRange>?
    let highlightedRanges: [NSRange]
    let onLargePaste: ((String) -> Bool)?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FirasGrowingInputView {
        let view = FirasGrowingInputView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.textAlignment = .natural
        view.onHeight = { [weak coordinator = context.coordinator] height in
            guard let coordinator, abs(coordinator.parent.measuredHeight - height) > 0.5 else { return }
            coordinator.parent.measuredHeight = height
        }
        return view
    }

    func updateUIView(_ view: FirasGrowingInputView, context: Context) {
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        context.coordinator.parent = self
        view.font = .systemFont(ofSize: pointSize)
        if selection == nil { view.textColor = UIColor(palette.textPrimary) }
        view.tintColor = UIColor(palette.accent)
        view.placeholder.text = placeholder
        view.placeholder.font = view.font
        view.placeholder.textColor = .placeholderText
        view.placeholder.textAlignment = layoutDirection == .rightToLeft ? .right : .left
        view.minLines = minLines
        view.maxLines = maxLines
        view.isEditable = isEnabled
        view.isSelectable = isEnabled
        view.isUserInteractionEnabled = isEnabled
        view.wantsFocus = focusRequested && isEnabled
        view.returnKeyType = sendOnReturn ? .send : .default
        view.handleKey = onKey
        view.handleLargePaste = onLargePaste
        view.accessibilityLabel = placeholder
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            view.selectedRange = NSRange(location: start, length: min(selection.length, length - start))
        }
        if let range = selection?.wrappedValue, view.markedTextRange == nil,
           range.location <= (view.text as NSString).length,
           range.length <= (view.text as NSString).length - range.location,
           view.selectedRange != range {
            view.selectedRange = range
        }
        if selection != nil, view.markedTextRange == nil {
            view.styleSkillNames(highlightedRanges, accent: UIColor(palette.accent), normal: UIColor(palette.textPrimary))
        }
        view.placeholder.isHidden = !view.text.isEmpty
        view.setNeedsLayout()
        DispatchQueue.main.async { [weak view] in view?.applyFocus() }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FirasLegacyGrowingEditor
        var updating = false
        init(_ parent: FirasLegacyGrowingEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            parent.text = textView.text
            textViewDidChangeSelection(textView)
            (textView as? FirasGrowingInputView)?.placeholder.isHidden = !textView.text.isEmpty
            textView.setNeedsLayout()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let range = textView.markedTextRange == nil ? textView.selectedRange : NSRange(location: NSNotFound, length: 0)
            if parent.selection?.wrappedValue != range { parent.selection?.wrappedValue = range }
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focus.wrappedValue { parent.focus.wrappedValue = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focus.wrappedValue { parent.focus.wrappedValue = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil, parent.onKey(.accept) { return false }
            if text == "\n", parent.sendOnReturn, textView.markedTextRange == nil {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

private final class FirasGrowingInputView: UITextView {
    let placeholder = UILabel()
    var minLines = 1
    var maxLines = 6
    var wantsFocus = false
    var onHeight: ((CGFloat) -> Void)?
    var handleKey: ((ComposerKey) -> Bool)?
    var handleLargePaste: ((String) -> Bool)?
    private var lastHeight: CGFloat = 0
    private var styledText = ""
    private var styledRanges: [NSRange] = []
    private var styledAccent: UIColor?
    private var styledNormal: UIColor?

    override func paste(_ sender: Any?) {
        // Read the clipboard only in the user's paste action, never on appearance or focus.
        if let handleLargePaste, let text = UIPasteboard.general.string,
           PastedTextItem.shouldCollapse(text), handleLargePaste(text) { return }
        super.paste(sender)
    }

    func styleSkillNames(_ ranges: [NSRange], accent: UIColor, normal: UIColor) {
        guard text != styledText || ranges != styledRanges || accent != styledAccent || normal != styledNormal else { return }
        styledText = text; styledRanges = ranges; styledAccent = accent; styledNormal = normal
        let selection = selectedRange
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: normal, range: NSRange(location: 0, length: textStorage.length))
        for range in ranges where range.location >= 0 && NSMaxRange(range) <= textStorage.length {
            textStorage.addAttribute(.foregroundColor, value: accent, range: range)
        }
        textStorage.endEditing()
        typingAttributes[.foregroundColor] = normal
        selectedRange = selection
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.numberOfLines = 1
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }

    func applyFocus() {
        guard window != nil else { return }
        if wantsFocus && !isFirstResponder { becomeFirstResponder() }
        else if !wantsFocus && isFirstResponder { resignFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let font else { return }
        placeholder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font.lineHeight)
        let wanted = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let minimum = font.lineHeight * CGFloat(minLines)
        let maximum = font.lineHeight * CGFloat(maxLines)
        let height = ceil(min(maximum, max(minimum, wanted)))
        let scrolls = wanted > maximum + 0.5
        if isScrollEnabled != scrolls { isScrollEnabled = scrolls }
        if abs(lastHeight - height) > 0.5 {
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeight?(height) }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            guard markedTextRange == nil,
                  press.key?.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty != false else { continue }
            guard let characters = press.key?.charactersIgnoringModifiers else { continue }
            let key: ComposerKey?
            switch characters {
            case UIKeyCommand.inputUpArrow: key = .up
            case UIKeyCommand.inputDownArrow: key = .down
            case UIKeyCommand.inputEscape: key = .escape
            case "\t": key = .accept
            default: key = nil
            }
            if let key, handleKey?(key) == true { remaining.remove(press) }
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
}

#if DEBUG
@MainActor
enum FirasGrowingInputReliabilityChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        let editor = FirasGrowingInputView()
        editor.frame = CGRect(x: 0, y: 0, width: 220, height: 22)
        editor.font = .systemFont(ofSize: 17)
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.minLines = 1
        editor.maxLines = 3
        let draft = String(repeating: "Arabic سَ 👩‍💻 mathematics\n", count: 20)
        editor.text = draft
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        if !editor.isScrollEnabled || editor.text != draft {
            failures.append("legacy-growing-input-lost-multilingual-text-or-did-not-scroll-after-its-line-limit")
        }
        editor.text = "سَ 👩‍💻"
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        if editor.isScrollEnabled || editor.text != "سَ 👩‍💻" {
            failures.append("legacy-growing-input-did-not-shrink-back-to-one-line")
        }
        return failures
    }
}
#endif
