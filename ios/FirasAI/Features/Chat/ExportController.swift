import SwiftUI
import UIKit
import Observation
import OSLog

/// Turns an answer (or a whole assembled long file) into a file the OS share sheet can hand on:
/// Markdown, plain text, a paginated PDF rendered from `MarkdownView`, or a PNG of the same view
/// (`web-chat-ux.md` Appendix A — export).
///
/// Math never leaves as LaTeX: every protected span goes through `MathText.unicode` first, so a
/// pasted paragraph reads as `∫₀^π sin x dx`, not as `\int_0^{\pi}`.
///
/// Nothing is written into the user's documents: every export lands in a temp directory and the
/// share sheet decides where it really goes.
@MainActor
@Observable
final class ExportController {

    // MARK: - Formats

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case text
        case pdf
        case image

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .text: return "txt"
            case .pdf: return "pdf"
            case .image: return "png"
            }
        }

        /// Verbatim from the web's `downloadMarkdown` / `downloadText` / `downloadPdf` /
        /// `downloadImage` entries.
        var label: LText {
            switch self {
            case .markdown: return LText(ar: "ملف Markdown", en: "Markdown file")
            case .text: return LText(ar: "نص عادي (TXT)", en: "Plain text (TXT)")
            case .pdf: return LText(ar: "ملف PDF", en: "PDF document")
            case .image: return LText(ar: "صورة", en: "Image")
            }
        }

        var symbol: String {
            switch self {
            case .markdown: return "doc.plaintext"
            case .text: return "doc.text"
            case .pdf: return "doc.richtext"
            case .image: return "photo"
            }
        }
    }

    /// A finished export. `Identifiable` so a caller can drive `.sheet(item:)` straight from it.
    struct Export: Identifiable, Equatable, Sendable {
        let id: UUID
        let url: URL
        let format: Format
    }

    // MARK: - State

    private let env: AppEnvironment

    private(set) var isWorking = false
    private(set) var lastError: LText?
    /// Settable so a view can bind `.sheet(item:)` to it and clear it on dismiss.
    var result: Export?

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Exporting

    /// Writes `markdown` in `format` to a temp file and publishes it as `result`. Failures toast
    /// with the web's `formatUnavailable` / `exportEmpty` copy and leave `result` untouched.
    func export(_ format: Format, markdown: String, title: String) async {
        guard !isWorking else { return }

        let lang = env.prefs.lang
        let source = ExportText.flattenMath(markdown)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = ExportCopy.empty
            env.toasts.show(ExportCopy.empty(lang), isError: true)
            return
        }

        isWorking = true
        lastError = nil
        result = nil
        // One turn of the runloop so the caller's spinner paints before a long render blocks it.
        await Task.yield()

        let url = ExportController.temporaryURL(
            name: ExportText.safeFilename(title),
            extension: format.fileExtension
        )
        let wrote: Bool
        switch format {
        case .markdown:
            wrote = ExportController.write(text: source, to: url)
        case .text:
            wrote = ExportController.write(text: ExportText.plain(source), to: url)
        case .pdf:
            wrote = writePDF(markdown: source, title: title, to: url)
        case .image:
            wrote = writePNG(markdown: source, title: title, to: url)
        }

        isWorking = false
        if wrote {
            result = Export(id: UUID(), url: url, format: format)
            Haptics.select()
        } else {
            lastError = ExportCopy.unavailable
            env.toasts.show(ExportCopy.unavailable(lang), isError: true)
        }
    }

    func clear() {
        result = nil
        lastError = nil
    }

    // MARK: - Rendered formats

    /// Exports always render on a light palette: a black PDF page is not a document.
    private var exportPalette: FirasPalette {
        env.prefs.theme.isLight ? env.prefs.palette : FirasTheme.light.palette
    }

    @ViewBuilder
    private func documentView(
        markdown: String,
        title: String,
        width: CGFloat,
        palette: FirasPalette,
        paintsBackground: Bool,
        messageID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: title, fallback: env.prefs.lang)
            }
            MarkdownView(
                markdown: markdown,
                messageID: messageID,
                streaming: false,
                lang: env.prefs.lang,
                palette: palette,
                prefs: env.prefs,
                onFence: { _ in nil }
            )
        }
        .frame(width: width, alignment: .leading)
        .padding(paintsBackground ? 24 : 0)
        .background(paintsBackground ? palette.background : Color.clear)
        .environment(\.layoutDirection, LayoutDirection.leftToRight)
    }

    /// A4 at 72 dpi with a 36 pt margin, paginated by translating the same rendered content up one
    /// usable page height per page.
    private func writePDF(markdown: String, title: String, to url: URL) -> Bool {
        let messageID = "firas-export-" + UUID().uuidString
        defer { MarkdownRenderer.invalidate(messageID: messageID) }

        let pageSize = CGSize(width: 595, height: 842)
        let margin: CGFloat = 36
        let usableWidth = pageSize.width - margin * 2
        let usableHeight = pageSize.height - margin * 2

        let content = documentView(
            markdown: markdown,
            title: title,
            width: usableWidth,
            palette: exportPalette,
            paintsBackground: false,
            messageID: messageID
        )

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: usableWidth, height: nil)

        var wrote = false
        renderer.render { size, draw in
            guard size.width > 0, size.height > 0, size.height.isFinite else { return }
            var box = CGRect(origin: .zero, size: pageSize)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            let raw = Int((size.height / usableHeight).rounded(.up))
            let pageCount = max(1, min(500, raw))
            for index in 0..<pageCount {
                pdf.beginPDFPage(nil)
                pdf.saveGState()
                // Content row r sits at PDF y = size.height - r; page `index` must show rows
                // [index·H, (index+1)·H] inside [margin, margin + H].
                pdf.translateBy(
                    x: margin,
                    y: margin + (CGFloat(index + 1) * usableHeight) - size.height
                )
                draw(pdf)
                pdf.restoreGState()
                pdf.endPDFPage()
            }
            pdf.closePDF()
            wrote = true
        }
        return wrote && FileManager.default.fileExists(atPath: url.path)
    }

    private func writePNG(markdown: String, title: String, to url: URL) -> Bool {
        let messageID = "firas-export-" + UUID().uuidString
        defer { MarkdownRenderer.invalidate(messageID: messageID) }

        let width: CGFloat = 760
        let content = documentView(
            markdown: markdown,
            title: title,
            width: width,
            palette: exportPalette,
            paintsBackground: true,
            messageID: messageID
        )

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        // A long answer at @2x is a bitmap nobody has memory for; long ones drop to @1x.
        renderer.scale = markdown.count > 6_000 ? 1 : 2

        guard let image = renderer.uiImage, let data = image.pngData() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.ui.error("export png failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Files

    private static func write(text: String, to url: URL) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            Log.ui.error("export write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func temporaryURL(name: String, extension ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirasExports", isDirectory: true)
        _ = try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(name + "." + ext, isDirectory: false)
    }
}

// MARK: - The OS share sheet

/// `UIActivityViewController` as a sheet body. Used by every screen that produces a temp file —
/// the export menu, the long-file reader, the share-link sheet.
struct FirasActivitySheet: UIViewControllerRepresentable {

    private let items: [Any]

    init(url: URL) {
        self.items = [url]
    }

    init(text: String) {
        self.items = [text]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Text shaping

/// Everything that has to happen to markdown before it becomes a file.
private enum ExportText {

    /// `$…$`, `$$…$$`, `\(…\)`, `\[…\]` → Unicode maths, through the one scanner.
    static func flattenMath(_ markdown: String) -> String {
        let protected = MathScanner.protect(markdown)
        guard !protected.spans.isEmpty else { return markdown }
        let flattened = protected.spans.map { span -> String in
            let unicode = MathText.unicode(span)
            return unicode.isEmpty ? span : unicode
        }
        return MathScanner.restore(protected.text, spans: flattened)
    }

    /// Markdown → readable plain text: fences keep their contents, decorations go.
    static func plain(_ markdown: String) -> String {
        var output: [String] = []
        var insideFence = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                output.append(rawLine)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                output.append("")
                continue
            }
            output.append(strippingInlineMarkers(strippingBlockMarkers(rawLine)))
        }

        return output.joined(separator: "\n")
    }

    private static func strippingBlockMarkers(_ line: String) -> String {
        var working = Substring(line)
        let indent = working.prefix(while: { $0 == " " || $0 == "\t" })
        working = working.dropFirst(indent.count)

        while working.first == ">" {
            working = working.dropFirst()
            if working.first == " " { working = working.dropFirst() }
        }
        if working.first == "#" {
            let hashes = working.prefix(while: { $0 == "#" })
            if hashes.count <= 6 {
                working = working.dropFirst(hashes.count)
                if working.first == " " { working = working.dropFirst() }
            }
        }
        if working.hasPrefix("- ") || working.hasPrefix("* ") || working.hasPrefix("+ ") {
            return String(indent) + "• " + String(working.dropFirst(2))
        }
        return String(indent) + String(working)
    }

    private static func strippingInlineMarkers(_ line: String) -> String {
        var working = expandingLinks(line)
        working = working.replacingOccurrences(of: "**", with: "")
        working = working.replacingOccurrences(of: "__", with: "")
        working = working.replacingOccurrences(of: "`", with: "")
        return working
    }

    /// `[label](target)` → `label (target)`. Hand-written: a bare-slash regex literal is off in
    /// Swift 5 language mode, and `NSRegularExpression` around Arabic is a trap.
    private static func expandingLinks(_ line: String) -> String {
        guard line.contains("]("), line.contains("[") else { return line }
        var output = ""
        var rest = Substring(line)

        while let open = rest.firstIndex(of: "[") {
            output += String(rest[rest.startIndex..<open])
            let afterOpen = rest.index(after: open)
            guard afterOpen <= rest.endIndex,
                  let close = rest[afterOpen...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(" else {
                output += "["
                rest = rest[afterOpen...]
                continue
            }
            let bodyStart = rest.index(close, offsetBy: 2)
            guard let paren = rest[bodyStart...].firstIndex(of: ")") else {
                output += "["
                rest = rest[afterOpen...]
                continue
            }
            let label = String(rest[afterOpen..<close])
            let target = String(rest[bodyStart..<paren])
            if label.isEmpty {
                output += target
            } else if target.isEmpty {
                output += label
            } else {
                output += label + " (" + target + ")"
            }
            rest = rest[rest.index(after: paren)...]
        }

        output += String(rest)
        return output
    }

    /// A name a file system and a share sheet both accept. Arabic letters survive.
    static func safeFilename(_ title: String) -> String {
        var output = ""
        for character in title {
            if character.isLetter || character.isNumber {
                output.append(character)
            } else if character == " " || character == "-" || character == "_" {
                output.append("-")
            }
            if output.count >= 48 { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "firas" : trimmed
    }
}

// MARK: - Copy

/// Verbatim `exportEmpty` / `formatUnavailable` / `download` / `preparing` from the web STR table.
private enum ExportCopy {
    static let empty = LText(ar: "لا يوجد محتوى للتصدير.", en: "Nothing to export.")
    static let unavailable = LText(
        ar: "هذا التنسيق غير متاح حاليًا.",
        en: "That format is unavailable right now."
    )
}
