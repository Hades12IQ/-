import SwiftUI
import UIKit

/// The file editor.
///
/// A `UITextView`, never a `TextEditor`: SwiftUI has no way to switch off smart quotes and smart
/// dashes, and an iOS keyboard with Smart Punctuation on turns `"` into `“ ”` and `--` into `—`
/// while you type code (`audit-ios-agent-code.md §B.3 C3`). The buffer lives in the text view and
/// its coordinator, never in the store: the store is written on a 900 ms idle debounce so a
/// keystroke does not re-render the workspace (`C4`, `web-code-ux.md §5.3`).
struct CodeEditorView: View {

    /// The save pill the workspace shows next to the project name.
    enum SaveState: String, Sendable {
        case saved, editing, saving

        var title: LText {
            switch self {
            case .saved: return Strings.CodeUI.saveStateSaved
            case .editing: return Strings.CodeUI.saveStateEditing
            case .saving: return Strings.CodeUI.saveStateSaving
            }
        }
    }

    private let env: AppEnvironment
    private let explicitPath: String?
    private let onSaveState: ((SaveState) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var link = CodeEditorLink()
    @State private var saveState: SaveState = .saved
    @State private var caretLine = 1
    @State private var caretColumn = 1

    /// `path` defaults to the store's selection so the workspace can write `CodeEditorView(env:)`.
    init(env: AppEnvironment, path: String? = nil, onSaveState: ((SaveState) -> Void)? = nil) {
        self.env = env
        self.explicitPath = path
        self.onSaveState = onSaveState
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var skin: CodeEditorTheme { CodeEditorTheme.skin(for: env.prefs.theme) }
    private var resolvedPath: String? { explicitPath ?? env.code.selectedPath }

    private var file: CodeFile? {
        guard let path = resolvedPath, let project = env.code.project else { return nil }
        return project.files.first { $0.path == path }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surfaceSunken)
            .onDisappear { link.coordinator?.commitPending() }
    }

    @ViewBuilder
    private var content: some View {
        if env.code.project == nil {
            loadingState
        } else if let file {
            editor(for: file)
        } else if resolvedPath != nil {
            missingState
        } else {
            emptyState
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 14) {
            SkeletonView(
                kind: .transcript,
                palette: palette,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            )
            Text(verbatim: Strings.CodeUI.editorLoading(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        EmptyStateView(
            title: Strings.CodeUI.editorEmptyTitle(lang),
            subtitle: Strings.CodeUI.editorEmptyBody(lang),
            buttonTitle: nil,
            palette: palette,
            action: nil
        )
        .frame(maxHeight: .infinity)
    }

    private var missingState: some View {
        EmptyStateView(
            title: Strings.CodeUI.editorMissing(lang),
            subtitle: nil,
            buttonTitle: nil,
            palette: palette,
            action: nil
        )
        .frame(maxHeight: .infinity)
    }

    // MARK: - Editor

    private func editor(for file: CodeFile) -> some View {
        VStack(spacing: 0) {
            CodeTextViewRepresentable(
                text: file.content,
                path: file.path,
                skin: skin,
                fontSize: 13 * env.prefs.fontScale.factor,
                commentCommandTitle: Strings.CodeUI.commentToggle(lang),
                link: link,
                onEdit: { markEditing() },
                onCommit: { text in commit(path: file.path, text: text) },
                onCaret: { line, column in
                    caretLine = line
                    caretColumn = column
                }
            )
            .accessibilityLabel(Text(verbatim: Strings.CodeUI.editorAccessibility.fmt(lang, file.path)))

            statusBar(for: file)
        }
    }

    private func statusBar(for file: CodeFile) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: positionText)
                .forceLTR()
            Text(verbatim: CodeEditorTheme.languageLabel(forExtension: file.ext))
            Text(verbatim: Self.sizeText(file.content))
                .forceLTR()
            Spacer(minLength: 0)
            savePill
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(palette.textMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(palette.surfaceSunken)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    private var savePill: some View {
        Text(verbatim: saveState.title(lang))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(saveState == .saved ? palette.codeOk : palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(saveState == .saved ? palette.accentSoft : palette.surface)
            }
    }

    private var positionText: String {
        Strings.CodeUI.lineLabel(lang) + " " + String(caretLine)
            + ", " + Strings.CodeUI.columnLabel(lang) + " " + String(caretColumn)
    }

    private static func sizeText(_ content: String) -> String {
        let bytes = content.utf8.count
        if bytes < 1024 { return String(bytes) + " B" }
        return String(format: "%.1f KB", locale: nil, Double(bytes) / 1024)
    }

    // MARK: - Commit

    private func markEditing() {
        guard saveState != .editing else { return }
        saveState = .editing
        onSaveState?(.editing)
    }

    private func commit(path: String, text: String) {
        saveState = .saving
        onSaveState?(.saving)
        env.code.updateFile(path: path, content: text)
        let report = onSaveState
        let state = $saveState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                guard state.wrappedValue == .saving else { return }
                state.wrappedValue = .saved
                report?(.saved)
            }
        }
    }
}

// MARK: - Link

/// A non-isolated box so the SwiftUI view can reach the coordinator it does not own — the pending
/// edit has to be flushed when the pane goes away.
final class CodeEditorLink {
    weak var coordinator: CodeTextViewRepresentable.Coordinator?
    init() {}
}

// MARK: - Representable

struct CodeTextViewRepresentable: UIViewRepresentable {

    let text: String
    let path: String
    let skin: CodeEditorTheme
    let fontSize: CGFloat
    let commentCommandTitle: String
    let link: CodeEditorLink
    let onEdit: () -> Void
    let onCommit: (String) -> Void
    let onCaret: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        link.coordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> CodeUITextView {
        let view = CodeUITextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textAlignment = .left
        view.semanticContentAttribute = .forceLeftToRight
        view.isFindInteractionEnabled = true
        view.textContainer.lineFragmentPadding = 0
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: CodeUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.textView = view
        coordinator.skin = skin
        coordinator.onEdit = onEdit
        coordinator.onCommit = onCommit
        coordinator.onCaret = onCaret

        let ext = Self.fileExtension(of: path)
        coordinator.fileExtension = ext
        view.commentPrefix = Self.commentPrefix(for: ext)
        view.commentCommandTitle = commentCommandTitle
        let styleChanged = view.apply(skin: skin, fontSize: fontSize)

        if coordinator.path != path {
            coordinator.commitPending()
            coordinator.path = path
            coordinator.storeText = text
            view.text = text
            view.markLinesDirty()
            view.selectedRange = NSRange(location: 0, length: 0)
            coordinator.highlightNow()
            coordinator.reportCaret()
            return
        }

        if text != coordinator.storeText {
            coordinator.storeText = text
            if text != view.text {
                let caret = view.selectedRange.location
                let previous = view.text ?? ""
                view.text = text
                let length = (text as NSString).length
                view.markLinesDirty()
                /* A FILE BEING WRITTEN HAS TO SCROLL ITSELF. While Firas Code builds live, this
                   branch fires several times a second with the file GROWING — the new text has the
                   old text as its prefix. Restoring the caret to where it was (0 on a file just
                   opened) left the reader staring at the first screenful while the code appeared
                   somewhere below the fold, which reads as nothing happening at all.

                   Only when the reader is NOT editing: a caret in a file someone is typing in is
                   theirs, and moving it would be far worse than not following. */
                let isGrowing = !previous.isEmpty && text.hasPrefix(previous)
                if !view.isFirstResponder && isGrowing {
                    view.selectedRange = NSRange(location: length, length: 0)
                    view.scrollRangeToVisible(NSRange(location: length, length: 0))
                } else {
                    view.selectedRange = NSRange(location: min(caret, length), length: 0)
                }
                coordinator.highlightNow()
                return
            }
        }

        if styleChanged {
            coordinator.highlightNow()
        }
    }

    // MARK: Helpers

    static func fileExtension(of path: String) -> String {
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return "" }
        return String(path[path.index(after: dot)...]).lowercased()
    }

    static func commentPrefix(for ext: String) -> String {
        switch ext {
        case "py", "sh", "bash", "zsh", "yml", "yaml", "rb", "toml": return "# "
        case "html", "htm", "xml", "svg", "md", "markdown", "": return ""
        default: return "// "
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UITextViewDelegate {

        var path: String = ""
        var storeText: String = ""
        var fileExtension: String = ""
        var skin: CodeEditorTheme = .dark
        var onEdit: () -> Void = {}
        var onCommit: (String) -> Void = { _ in }
        var onCaret: (Int, Int) -> Void = { _, _ in }
        weak var textView: CodeUITextView?

        private var highlightToken = 0
        private var commitToken = 0

        func textViewDidChange(_ textView: UITextView) {
            (textView as? CodeUITextView)?.markLinesDirty()
            onEdit()
            scheduleHighlight()
            scheduleCommit()
            reportCaret()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.setNeedsDisplay()
            reportCaret()
        }

        func reportCaret() {
            guard let view = textView else { return }
            let position = view.caretPosition()
            onCaret(position.line, position.column)
        }

        /// The buffer is written to the store after 900 ms of quiet (`web-code-ux.md §5.3`).
        private func scheduleCommit() {
            commitToken += 1
            let token = commitToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.commitToken == token else { return }
                    self.commitPending()
                }
            }
        }

        func commitPending() {
            guard let view = textView else { return }
            let text = view.text ?? ""
            guard text != storeText else { return }
            storeText = text
            onCommit(text)
        }

        /// Colours settle 150 ms after the last keystroke; typing itself never re-tokenizes.
        private func scheduleHighlight() {
            highlightToken += 1
            let token = highlightToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.highlightToken == token else { return }
                    self.highlightNow()
                }
            }
        }

        func highlightNow() {
            guard let view = textView else { return }
            let storage = view.textStorage
            let source = storage.string
            let full = NSRange(location: 0, length: storage.length)
            let font = view.codeFont

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: skin.plain], range: full)
            for token in skin.tokens(in: source, ext: fileExtension) {
                guard token.range.location >= 0,
                      NSMaxRange(token.range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: token.color, range: token.range)
            }
            storage.endEditing()
            view.typingAttributes = [.font: font, .foregroundColor: skin.plain]
            view.setNeedsDisplay()
        }
    }
}

// MARK: - The text view

/// `UITextView` with a line-number gutter, an active-line tint and a `⌘/` comment command.
final class CodeUITextView: UITextView {

    var skin: CodeEditorTheme = .dark
    private(set) var codeFont: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var commentPrefix: String = "// "
    var commentCommandTitle: String = "Toggle comment"

    private var gutterWidth: CGFloat = 40
    private var lineStarts: [Int] = [0]
    private var lineStartsDirty = true
    private var appliedFontSize: CGFloat = 0
    private var appliedBackground: UIColor?

    /// Returns `true` when the base style changed and the caller must re-run the highlighter
    /// (setting `font` or `textColor` on a `UITextView` re-attributes the whole buffer).
    func apply(skin newSkin: CodeEditorTheme, fontSize: CGFloat) -> Bool {
        let sameFont = abs(appliedFontSize - fontSize) < 0.01
        let sameSkin = appliedBackground === newSkin.background
        skin = newSkin
        tintColor = newSkin.cursor
        guard !(sameFont && sameSkin) else { return false }

        appliedFontSize = fontSize
        appliedBackground = newSkin.background
        codeFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        gutterWidth = max(34, fontSize * 3)
        backgroundColor = newSkin.background
        font = codeFont
        textColor = newSkin.plain
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 28, right: 14)
        typingAttributes = [.font: codeFont, .foregroundColor: newSkin.plain]
        setNeedsDisplay()
        return true
    }

    func markLinesDirty() {
        lineStartsDirty = true
        setNeedsDisplay()
    }

    /// Caret line and column, both 1-based, from the cached line table.
    func caretPosition() -> (line: Int, column: Int) {
        if lineStartsDirty { rebuildLineStarts() }
        let length = (text ?? "").utf16.count
        let location = min(max(0, selectedRange.location), length)
        let line = lineNumber(for: location)
        let start = lineStarts[min(max(0, line - 1), lineStarts.count - 1)]
        return (line, max(1, location - start + 1))
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        drawActiveLine()
        super.draw(rect)
        drawGutter(rect)
    }

    private func drawActiveLine() {
        guard isEditable, let context = UIGraphicsGetCurrentContext() else { return }
        let source = (text ?? "") as NSString
        let location = min(max(0, selectedRange.location), source.length)
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.y += textContainerInset.top
        lineRect.origin.x = 0
        lineRect.size.width = max(bounds.width, contentSize.width)
        if lineRect.height <= 0 { lineRect.size.height = codeFont.lineHeight }
        context.setFillColor(skin.activeLine.cgColor)
        context.fill(lineRect)
    }

    private func drawGutter(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(skin.gutterBackground.cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height))

        if lineStartsDirty { rebuildLineStarts() }

        let source = (text ?? "") as NSString
        let caretLine = lineNumber(for: min(max(0, selectedRange.location), source.length))
        let inset = textContainerInset.top
        let width = gutterWidth
        let numberFont = UIFont.monospacedDigitSystemFont(
            ofSize: max(9, codeFont.pointSize - 2),
            weight: .regular
        )
        let visible = CGRect(
            x: 0,
            y: rect.minY - inset,
            width: max(textContainer.size.width, 1),
            height: rect.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentRange, _ in
            let characterRange = self.layoutManager.characterRange(
                forGlyphRange: fragmentRange,
                actualGlyphRange: nil
            )
            let start = min(characterRange.location, source.length)
            let paragraph = source.lineRange(for: NSRange(location: start, length: 0))
            guard start == paragraph.location else { return }
            let number = self.lineNumber(for: start)
            let color = number == caretLine ? self.skin.gutterActiveText : self.skin.gutterText
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            let origin = CGPoint(
                x: max(2, width - size.width - 8),
                y: usedRect.minY + inset + max(0, (usedRect.height - size.height) / 2)
            )
            label.draw(at: origin, withAttributes: attributes)
        }
    }

    private func rebuildLineStarts() {
        var starts: [Int] = [0]
        var index = 0
        for unit in (text ?? "").utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        lineStarts = starts
        lineStartsDirty = false
    }

    private func lineNumber(for location: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        guard !commentPrefix.isEmpty else { return nil }
        let command = UIKeyCommand(
            input: "/",
            modifierFlags: .command,
            action: #selector(toggleCommentCommand)
        )
        command.title = commentCommandTitle
        return [command]
    }

    @objc private func toggleCommentCommand() {
        let prefix = commentPrefix
        guard !prefix.isEmpty else { return }
        let source = (text ?? "") as NSString
        let location = min(max(0, selectedRange.location), source.length)
        let length = min(max(0, selectedRange.length), source.length - location)
        let block = source.lineRange(for: NSRange(location: location, length: length))
        let rows = source.substring(with: block).components(separatedBy: "\n")
        let token = prefix.trimmingCharacters(in: .whitespaces)

        var commentedEverywhere = true
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !trimmed.hasPrefix(token) { commentedEverywhere = false }
        }

        let output = rows.map { row -> String in
            if row.trimmingCharacters(in: .whitespaces).isEmpty { return row }
            return commentedEverywhere
                ? Self.uncomment(row, token: token)
                : Self.comment(row, prefix: prefix)
        }
        let replacement = output.joined(separator: "\n")
        textStorage.replaceCharacters(in: block, with: replacement)
        selectedRange = NSRange(location: block.location, length: (replacement as NSString).length)
        markLinesDirty()
        delegate?.textViewDidChange?(self)
    }

    private static func comment(_ row: String, prefix: String) -> String {
        let indent = row.prefix { $0 == " " || $0 == "\t" }
        return String(indent) + prefix + String(row.dropFirst(indent.count))
    }

    private static func uncomment(_ row: String, token: String) -> String {
        guard !token.isEmpty, let range = row.range(of: token) else { return row }
        var stripped = row
        var upper = range.upperBound
        if upper < stripped.endIndex, stripped[upper] == " " {
            upper = stripped.index(after: upper)
        }
        stripped.removeSubrange(range.lowerBound..<upper)
        return stripped
    }
}
