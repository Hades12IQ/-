import SwiftUI
import UIKit

/// An opaque code card: always LTR, mono 13, a language tag, copy, and — inside a deliverable
/// card — a 14-line collapse so a 400-line file does not own the whole transcript.
///
/// No `WKWebView` ever lives in a transcript row: `onPreview` hands the code to a sheet instead.
struct CodeBlockView: View {

    private let code: String
    private let language: String?
    private let palette: FirasPalette
    private let collapsible: Bool
    private let lang: AppLanguage
    private let onPreview: ((String, String?) -> Void)?

    @State private var expanded = false
    @State private var copied = false

    init(
        code: String,
        language: String?,
        palette: FirasPalette,
        collapsible: Bool,
        lang: AppLanguage = .arabic,
        onPreview: ((String, String?) -> Void)? = nil
    ) {
        self.code = code
        self.language = language
        self.palette = palette
        self.collapsible = collapsible
        self.lang = lang
        self.onPreview = onPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
            codeArea
            if isCollapsible {
                expandButton
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .forceLTR()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(languageLabel)
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            Spacer(minLength: 8)
            if canPreview {
                Button {
                    onPreview?(code, language)
                } label: {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 34, height: 30)
                .accessibilityLabel(Text(CodeBlockCopy.preview(lang)))
            }
            Button(action: copyCode) {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(copied ? Strings.Common.copied(lang) : Strings.Common.copy(lang))
                        .font(FirasType.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? palette.success : palette.textSecondary)
            .frame(minHeight: 30)
            .accessibilityLabel(Text(Strings.Common.copy(lang)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(palette.surfaceSunken)
    }

    // MARK: - Code

    private var codeArea: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(CodeHighlighter.highlight(shownCode, language: language, palette: palette))
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .overlay(alignment: .bottom) {
            if isCollapsible, !expanded {
                LinearGradient(
                    colors: [palette.surface.opacity(0), palette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 44)
                .allowsHitTesting(false)
            }
        }
    }

    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(expanded ? CodeBlockCopy.showLess(lang) : CodeBlockCopy.showMore(lang))
                    .font(FirasType.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .background(palette.surfaceSunken)
    }

    // MARK: - Derived

    private static let collapsedLineLimit = 14

    private var lineCount: Int {
        var count = 1
        for character in code where character == "\n" { count += 1 }
        return count
    }

    private var isCollapsible: Bool {
        collapsible && lineCount > CodeBlockView.collapsedLineLimit
    }

    private var shownCode: String {
        guard isCollapsible, !expanded else { return code }
        let lines = code.components(separatedBy: "\n")
        return lines.prefix(CodeBlockView.collapsedLineLimit).joined(separator: "\n")
    }

    private var canPreview: Bool {
        guard onPreview != nil else { return false }
        switch (language ?? "").lowercased() {
        case "html", "htm", "svg": return true
        default: return false
        }
    }

    private var languageLabel: String {
        let key = (language ?? "").lowercased()
        switch key {
        case "": return "CODE"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "js", "mjs", "cjs", "jsx", "javascript": return "JavaScript"
        case "ts", "tsx", "typescript": return "TypeScript"
        case "json", "jsonc", "json5": return "JSON"
        case "py", "python", "python3": return "Python"
        case "xml": return "XML"
        case "svg": return "SVG"
        case "md", "markdown": return "Markdown"
        case "txt", "text": return "Text"
        case "swift": return "Swift"
        case "sh", "bash", "zsh", "shell", "console": return "Shell"
        default: return key.uppercased()
        }
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
}

/// Two labels the frozen `Strings.Common` table does not carry. They stay `LText` so the view
/// never holds a bare Arabic literal, and the Arabic is the wording the web already uses.
private enum CodeBlockCopy {
    static let showMore = LText(ar: "عرض المزيد", en: "Show more")
    static let showLess = LText(ar: "عرض أقل", en: "Show less")
    static let preview = LText(ar: "معاينة", en: "Preview")
}
