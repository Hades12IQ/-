import SwiftUI
import UIKit

/// An opaque code box: always LTR, mono 13, a header carrying the language and — when the fence
/// named one — the filename, a copy button, a collapse for long listings, and horizontal scrolling
/// that stays inside the box instead of widening the transcript.
///
/// When the block is something the app can actually render — a page, a figure, a stylesheet, a
/// script, a JSON document — the box hands itself to `HTMLPreviewCard`, which adds the
/// `معاينة / الكود` toggle over the same listing. That is why a fenced ```` ```html ```` block in
/// chat now shows a live page and not only its source, with no sheet in the way.
///
/// A caller that already owns a preview surface (a full-screen viewer with its own toggle) passes
/// `allowsInlinePreview: false` and gets the plain box.
struct CodeBlockView: View {

    private let code: String
    private let language: String?
    private let palette: FirasPalette
    private let collapsible: Bool
    private let lang: AppLanguage
    private let onPreview: ((String, String?) -> Void)?
    private let filename: String?
    private let companions: [HTMLPreviewCard.Document.Companion]
    private let allowsInlinePreview: Bool

    @State private var expanded = false
    @State private var copied = false
    @State private var shareURL: URL?
    @State private var isSharing = false

    init(
        code: String,
        language: String?,
        palette: FirasPalette,
        collapsible: Bool,
        lang: AppLanguage = .arabic,
        onPreview: ((String, String?) -> Void)? = nil,
        filename: String? = nil,
        companions: [HTMLPreviewCard.Document.Companion] = [],
        allowsInlinePreview: Bool = true
    ) {
        self.code = code
        self.language = language
        self.palette = palette
        self.collapsible = collapsible
        self.lang = lang
        self.onPreview = onPreview
        self.filename = filename
        self.companions = companions
        self.allowsInlinePreview = allowsInlinePreview
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        if allowsInlinePreview, let kind = HTMLPreviewCard.Document.kind(language: language, code: code) {
            HTMLPreviewCard(
                code: code,
                language: language,
                filename: filename,
                kind: kind,
                companions: companions,
                palette: palette,
                lang: lang,
                collapsible: collapsible
            )
        } else {
            plainBox
        }
    }

    private var plainBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            CodeListing(
                code: code,
                language: language,
                palette: palette,
                wrapped: false,
                lineLimit: shownLineLimit,
                fadesTail: isCollapsed
            )
            if isCollapsible {
                divider
                expandButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .forceLTR()
        .sheet(isPresented: $isSharing) {
            CodeBlockShareSheet(items: shareURL.map { [$0] } ?? [])
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(CodeHighlighter.label(for: language))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
                .fixedSize()

            if let name = trimmedFilename {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.border)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if canCallOutPreview {
                Button {
                    onPreview?(code, language)
                } label: {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel(Text(CodeBlockCopy.preview(lang)))
            }

            downloadButton
            copyButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(palette.surfaceSunken)
    }

    /// «ولا بيها تصدير». The box could always copy and could never hand the file over, so a
    /// listing anyone wanted to KEEP had to be pasted into something else first. Icon-only on
    /// purpose: Copy already spends a word on the same row, and a second label pushes the language
    /// off the line on a narrow phone.
    private var downloadButton: some View {
        Button(action: presentShare) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary)
        .accessibilityLabel(Text(Strings.Common.download(lang)))
    }

    private var copyButton: some View {
        Button(action: copyCode) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(copied ? Strings.Common.copied(lang) : Strings.Common.copy(lang))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? palette.success : palette.textSecondary)
        .accessibilityLabel(Text(Strings.Common.copy(lang)))
    }

    private var expandButton: some View {
        Button {
            expanded.toggle()
            Haptics.select()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(expanded ? CodeBlockCopy.showLess(lang) : CodeBlockCopy.showMore(lang))
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .background(palette.surfaceSunken)
    }

    // MARK: - Derived

    /// The collapse a caller asked for.
    private static let collapsedLineLimit = 16
    /// The collapse nobody asked for but everybody needs: a four-hundred-line listing owns the
    /// whole screen otherwise, even inside a viewer that opted out.
    private static let hardCeiling = 150
    private static let hardShownLimit = 60

    private var lineCount: Int {
        var count = 1
        for character in code where character == "\n" { count += 1 }
        return count
    }

    private var isCollapsible: Bool {
        if collapsible { return lineCount > CodeBlockView.collapsedLineLimit }
        return lineCount > CodeBlockView.hardCeiling
    }

    private var isCollapsed: Bool { isCollapsible && !expanded }

    private var shownLineLimit: Int? {
        guard isCollapsed else { return nil }
        return collapsible ? CodeBlockView.collapsedLineLimit : CodeBlockView.hardShownLimit
    }

    private var trimmedFilename: String? {
        guard let filename else { return nil }
        let cleaned = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The old sheet route stays for callers that hand one in and that did not take the inline
    /// card — a plain box with a Preview button is still better than no preview at all.
    private var canCallOutPreview: Bool {
        guard onPreview != nil else { return false }
        guard let kind = HTMLPreviewCard.Document.kind(language: language, code: code) else {
            return false
        }
        return kind == .html || kind == .svg
    }

    // MARK: - Actions

    private func copyCode() {
        UIPasteboard.general.string = code
        Haptics.select()
        copied = true
        let flag = $copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            flag.wrappedValue = false
        }
    }

    /// The whole listing is already in memory, so the temporary write is a few tens of kilobytes on
    /// the main thread — the same work the pasteboard above does, and far below a dropped frame.
    /// This is `CodeCard.presentShare` deliberately repeated rather than shared: that card is a
    /// `firas-code` deliverable with its own filename and extension from the wire, and this box has
    /// only a language tag to go on.
    private func presentShare() {
        Haptics.select()
        let url = CodeBlockView.writeTemporaryFile(named: downloadName, contents: code)
        shareURL = url
        isSharing = url != nil
        if url == nil { Haptics.error() }
    }

    /// The fence's own filename when it named one, else a name built from the language — never
    /// `code.txt` for a file the reader can see is Python.
    private var downloadName: String {
        if let name = trimmedFilename {
            let cleaned = CodeBlockView.sanitized(name)
            if !cleaned.isEmpty { return cleaned }
        }
        return "firas-code." + CodeBlockView.fileExtension(for: language)
    }

    private static func fileExtension(for language: String?) -> String {
        switch CodeHighlighter.normalized(language) {
        case "html", "htm", "xhtml": return "html"
        case "xml": return "xml"
        case "svg": return "svg"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "js", "javascript", "mjs", "cjs", "node": return "js"
        case "jsx": return "jsx"
        case "ts", "typescript": return "ts"
        case "tsx": return "tsx"
        case "json", "jsonc", "json5", "geojson": return "json"
        case "py", "python", "python3", "py3": return "py"
        case "c", "h": return "c"
        case "cpp", "c++", "cc", "cxx", "hpp", "hh": return "cpp"
        case "objc", "objectivec": return "m"
        case "java": return "java"
        case "kt", "kotlin": return "kt"
        case "cs", "csharp", "c#": return "cs"
        case "swift": return "swift"
        case "sql", "mysql", "postgres", "postgresql", "sqlite", "plsql", "tsql": return "sql"
        case "sh", "bash", "zsh", "shell": return "sh"
        case "go", "golang": return "go"
        case "rs", "rust": return "rs"
        case "php": return "php"
        case "rb", "ruby": return "rb"
        case "dart": return "dart"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "ini": return "ini"
        case "md", "markdown": return "md"
        case "diff", "patch": return "diff"
        case "vue": return "vue"
        case "svelte": return "svelte"
        default: return "txt"
        }
    }

    private static let forbiddenNameCharacters: Set<Character> = [
        "/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"
    ]

    private static func sanitized(_ raw: String) -> String {
        var out = ""
        for character in raw where !forbiddenNameCharacters.contains(character) { out.append(character) }
        return String(out.trimmingCharacters(in: .whitespaces).prefix(60))
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
}

// MARK: - Share sheet

/// File-private so no other view depends on it, exactly as `CodeCard` keeps its own.
private struct CodeBlockShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - The listing

/// The highlighted body of a code box, shared by the plain box and by the code side of
/// `HTMLPreviewCard` so the two can never drift apart.
///
/// Horizontal scrolling lives here and nowhere else: the text is laid out at its natural width
/// inside a `ScrollView` that is itself pinned to the card, so a two-hundred-column line scrolls
/// within the box and never widens the answer around it.
struct CodeListing: View {

    let code: String
    let language: String?
    let palette: FirasPalette
    let wrapped: Bool
    /// `nil` shows the whole listing; a number shows that many lines.
    let lineLimit: Int?
    let fadesTail: Bool

    var body: some View {
        listing(for: shownCode)
            .overlay(alignment: .bottom) { fade }
    }

    @ViewBuilder
    private func listing(for shown: String) -> some View {
        if wrapped {
            text(shown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                text(shown)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func text(_ shown: String) -> some View {
        Text(CodeHighlighter.highlight(shown, language: language, palette: palette))
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var fade: some View {
        if fadesTail {
            LinearGradient(
                colors: [palette.surface.opacity(0), palette.surface],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 42)
            .allowsHitTesting(false)
        }
    }

    private var shownCode: String {
        guard let lineLimit, lineLimit > 0 else { return code }
        var kept = 0
        var end = code.startIndex
        var index = code.startIndex
        while index < code.endIndex {
            if code[index] == "\n" {
                kept += 1
                if kept >= lineLimit {
                    end = index
                    return String(code[code.startIndex..<end])
                }
            }
            index = code.index(after: index)
        }
        return code
    }
}

// MARK: - Copy

/// Labels the frozen `Strings.Common` table does not carry. They stay `LText` so the view never
/// holds a bare Arabic literal, and the Arabic is the wording the web already uses.
enum CodeBlockCopy {
    static let showMore = LText(ar: "عرض المزيد", en: "Show more")
    static let showLess = LText(ar: "عرض أقل", en: "Show less")
    static let preview = LText(ar: "معاينة", en: "Preview")
    static let code = LText(ar: "الكود", en: "Code")
    static let refresh = LText(ar: "تحديث", en: "Refresh")
    static let run = LText(ar: "شغّل المعاينة", en: "Run the preview")
    static let running = LText(ar: "يُحضّر المعاينة…", en: "Preparing the preview…")
    static let heavyTitle = LText(ar: "صفحة كبيرة", en: "A large page")
    static let heavyBody = LText(
        ar: "هذا المستند كبير، فلا يُشغَّل من تلقاء نفسه. اضغط لتشغيله.",
        en: "This document is large, so it does not run on its own. Tap to run it."
    )
    static let failedTitle = LText(ar: "تعذّرت المعاينة", en: "The preview failed")
    static let failedBody = LText(
        ar: "لم تُحمَّل الصفحة. جرّب التحديث، أو اقرأ الكود.",
        en: "The page did not load. Try refreshing, or read the code."
    )
    static let taller = LText(ar: "تكبير", en: "Taller")
    static let shorter = LText(ar: "تصغير", en: "Shorter")
    static let sandboxNote = LText(
        ar: "تعمل الصفحة داخل معاينة معزولة بلا إنترنت.",
        en: "The page runs inside an isolated preview with no network."
    )
}
