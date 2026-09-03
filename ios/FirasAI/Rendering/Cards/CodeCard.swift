import SwiftUI
import UIKit

/// The ```` ```firas-code ```` deliverable card (`web-chat-ux.md §8.6`,
/// `server-code-brainask.md §4.6–4.7`).
///
/// Always LTR — a file is a file in every language. The head carries the three dots, the filename,
/// the language label and the line count; the foot carries the web's exact action set: wrap toggle,
/// Preview (html/svg only), Copy, Download and Continue, plus the `الكود غير مكتمل؟` hint.
///
/// The body is drawn here rather than by `CodeBlockView` because the wrap toggle has to switch
/// between a horizontally scrolling and a wrapping layout, and a nested `CodeBlockView` would put a
/// second head with a second Copy button inside this one.
struct CodeCard: View {

    private let meta: CodeMeta
    private let code: String
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let isStreaming: Bool
    private let motionOn: Bool
    private let onPreview: ((String, String?) -> Void)?
    private let onContinue: (() -> Void)?

    @State private var wrapped: Bool?
    @State private var expanded = false
    @State private var copied = false
    @State private var shareURL: URL?
    @State private var isSharing = false

    init(
        meta: CodeMeta,
        code: String,
        palette: FirasPalette,
        lang: AppLanguage,
        isStreaming: Bool = false,
        motionOn: Bool = true,
        onPreview: ((String, String?) -> Void)? = nil,
        onContinue: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.code = code
        self.palette = palette
        self.lang = lang
        self.isStreaming = isStreaming
        self.motionOn = motionOn
        self.onPreview = onPreview
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            prose(meta.intro)
            card
            prose(meta.outro)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isSharing) {
            CodeCardShareSheet(items: shareURL.map { [$0] } ?? [])
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            divider
            bodyArea
            divider
            actions
            if onContinue != nil {
                divider
                continueHint
            }
        }
        .surfaceCard(palette)
        .forceLTR()
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(height: 1)
    }

    private var head: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(palette.borderStrong)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)

            Text(displayName)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if isStreaming {
                FirasActivityLabel(
                    text: CodeCardCopy.writing(lang),
                    palette: palette,
                    motionOn: motionOn
                )
            } else {
                Text(languageLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.accentSoft))

                Text(lineCountLabel)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
        .background(palette.surfaceSunken)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyArea: some View {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(CodeCardCopy.emptyBody(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
        } else {
            codeText
                .overlay(alignment: .bottom) { fade }
        }
    }

    @ViewBuilder
    private var codeText: some View {
        if isWrapped {
            highlighted
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                highlighted
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
    }

    private var highlighted: some View {
        Text(CodeHighlighter.highlight(shownCode, language: meta.lang, palette: palette))
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var fade: some View {
        if isCollapsed {
            LinearGradient(
                colors: [palette.surface.opacity(0), palette.surface],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 42)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isCollapsible {
                    action(title: collapseTitle, symbol: expanded ? "chevron.up" : "chevron.down", tint: palette.accent) {
                        expanded.toggle()
                    }
                }

                action(title: wrapTitle, symbol: "text.alignleft", tint: palette.textSecondary) {
                    wrapped = !isWrapped
                }

                if canPreview {
                    action(title: CodeCardCopy.preview(lang), symbol: "play.rectangle", tint: palette.textSecondary) {
                        onPreview?(code, meta.lang)
                    }
                }

                action(
                    title: copyTitle,
                    symbol: copied ? "checkmark" : "doc.on.doc",
                    tint: copied ? palette.success : palette.textSecondary
                ) {
                    copyCode()
                }

                action(
                    title: Strings.Common.download(lang),
                    symbol: "square.and.arrow.down",
                    tint: palette.textSecondary
                ) {
                    presentShare()
                }

                if let onContinue {
                    action(
                        title: CodeCardCopy.continueLabel(lang),
                        symbol: "arrow.turn.down.right",
                        tint: palette.accent
                    ) {
                        onContinue()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(palette.surfaceSunken)
    }

    private var collapseTitle: String {
        expanded ? CodeCardCopy.showLess(lang) : CodeCardCopy.showMore(lang)
    }

    private var wrapTitle: String {
        isWrapped ? CodeCardCopy.noWrap(lang) : CodeCardCopy.wrap(lang)
    }

    private var copyTitle: String {
        copied ? CodeCardCopy.codeCopied(lang) : Strings.Common.copy(lang)
    }

    private func action(
        title: String,
        symbol: String,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Capsule().fill(palette.surface))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private var continueHint: some View {
        HStack(spacing: 8) {
            Text(CodeCardCopy.cutOff(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
            Spacer(minLength: 6)
            Button {
                onContinue?()
            } label: {
                Text(CodeCardCopy.continueCode(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(palette.surface)
    }

    // MARK: - Prose

    @ViewBuilder
    private func prose(_ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(FirasType.prose(lang, scale: .medium).font)
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: text, fallback: lang)
        }
    }

    // MARK: - Derived

    private static let collapsedLineLimit = 14
    private static let wrapThreshold = 140

    private var lines: [String] { code.components(separatedBy: "\n") }

    private var lineCount: Int {
        var count = 1
        for character in code where character == "\n" { count += 1 }
        return count
    }

    /// The web's default: wrapped as soon as one line is longer than 140 characters.
    private var isWrapped: Bool {
        if let wrapped { return wrapped }
        for line in lines where line.count > CodeCard.wrapThreshold { return true }
        return false
    }

    private var isCollapsible: Bool { lineCount > CodeCard.collapsedLineLimit }

    private var isCollapsed: Bool { isCollapsible && !expanded }

    private var shownCode: String {
        guard isCollapsed else { return code }
        return lines.prefix(CodeCard.collapsedLineLimit).joined(separator: "\n")
    }

    /// The web sniffs the source as well as the tag, because a model labels a whole HTML document
    /// `code` often enough to matter — `previewKindOf` (`app.js:35551`). One authority for that
    /// question, shared with the inline code box.
    private var canPreview: Bool {
        guard onPreview != nil else { return false }
        // Only the two kinds the full-screen viewer actually renders: a Preview button that opens
        // a sheet showing the same source again would be a lie.
        guard let kind = HTMLPreviewCard.Document.kind(language: meta.lang ?? meta.ext, code: code) else {
            return false
        }
        return kind == .html || kind == .svg
    }

    private var displayName: String {
        if let name = meta.name, !name.isEmpty { return name }
        if let title = meta.title, !title.isEmpty { return title }
        return CodeCardCopy.untitled(lang)
    }

    /// The fence's own `label` when it has one, else the language tag in the casing developers
    /// expect — the same table the inline code box prints.
    private var languageLabel: String {
        if let title = meta.title, !title.isEmpty, meta.name != nil { return title }
        return CodeHighlighter.label(for: meta.lang ?? meta.ext)
    }

    private var lineCountLabel: String {
        ArabicPlurals.count(
            lineCount, lang,
            zero: CodeCardCopy.linesZero, one: CodeCardCopy.linesOne, two: CodeCardCopy.linesTwo,
            few: CodeCardCopy.linesFew, many: CodeCardCopy.linesMany, other: CodeCardCopy.linesOther
        )
    }

    private var downloadName: String {
        if let name = meta.name, !name.isEmpty { return CodeCard.sanitized(name) }
        let ext = meta.ext ?? meta.lang ?? "txt"
        return "firas-code." + CodeCard.sanitized(ext)
    }

    // MARK: - Actions (work)

    private func copyCode() {
        UIPasteboard.general.string = code
        Haptics.select()
        copied = true
        let flag = $copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            flag.wrappedValue = false
        }
    }

    /// The whole file is already in memory, so the temp write is a few tens of kilobytes on the
    /// main thread — the same work `UIPasteboard` above does, and far below a dropped frame.
    private func presentShare() {
        shareURL = CodeCard.writeTemporaryFile(named: downloadName, contents: code)
        isSharing = shareURL != nil
        if shareURL == nil { Haptics.error() }
    }

    private static func writeTemporaryFile(named name: String, contents: String) -> URL? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("firas-code", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name.isEmpty ? "firas-code.txt" : name)
        guard let data = contents.data(using: .utf8) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    private static let forbiddenNameCharacters: Set<Character> = [
        "/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"
    ]

    private static func sanitized(_ raw: String) -> String {
        var out = ""
        for character in raw where !forbiddenNameCharacters.contains(character) { out.append(character) }
        return String(out.trimmingCharacters(in: .whitespaces).prefix(60))
    }
}

// MARK: - Share sheet

/// A share sheet for the one file this card can hand over. It is file-private so no other card
/// depends on it.
private struct CodeCardShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Copy

/// `app.js:6820-6889`, verbatim.
private enum CodeCardCopy {
    static let wrap = LText(ar: "لفّ الأسطر", en: "Wrap")
    static let noWrap = LText(ar: "لا تلفّ", en: "No wrap")
    static let preview = LText(ar: "معاينة", en: "Preview")
    static let codeCopied = LText(ar: "تم نسخ الكود", en: "Code copied")
    static let continueLabel = LText(ar: "كمّل", en: "Continue")
    static let cutOff = LText(ar: "الكود غير مكتمل؟", en: "Code cut off?")
    static let continueCode = LText(ar: "كمّل الكود", en: "Continue code")
    static let writing = LText(ar: "يكتب الكود…", en: "Writing code…")

    static let showMore = LText(ar: "عرض المزيد", en: "Show more")
    static let showLess = LText(ar: "عرض أقل", en: "Show less")
    static let untitled = LText(ar: "ملف كود", en: "Code file")
    static let emptyBody = LText(ar: "لا يوجد كود في هذه البطاقة.", en: "This card carries no code.")

    static let linesZero = LText(ar: "لا أسطر", en: "%ld lines")
    static let linesOne = LText(ar: "سطر واحد", en: "%ld line")
    static let linesTwo = LText(ar: "سطران", en: "%ld lines")
    static let linesFew = LText(ar: "%ld أسطر", en: "%ld lines")
    static let linesMany = LText(ar: "%ld سطرًا", en: "%ld lines")
    static let linesOther = LText(ar: "%ld سطر", en: "%ld lines")
}
