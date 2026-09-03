import SwiftUI
import UIKit
import Observation
import OSLog

/// Turns an answer, a whole conversation or an assembled long file into a real file: a PDF, a Word
/// document, an Excel workbook, a PowerPoint deck, a CSV, an HTML page, Markdown, plain text or a
/// picture — every format the website can make (`web-chat-ux.md` Appendix A — export).
///
/// The Office formats are written as genuine OOXML packages, not as renamed HTML, so what the share
/// sheet hands over opens in Word, Numbers, Pages, Google Docs and Files' own preview.
///
/// Math never leaves as LaTeX: every protected span goes through `MathText.unicode` first, so a
/// pasted paragraph reads as `∫₀^π sin x dx`, not as `\int_0^{\pi}`.
///
/// Nothing is written into the user's documents: every export lands in a temp directory and the
/// share sheet — or the Files picker — decides where it really goes.
@MainActor
@Observable
final class ExportController {

    // MARK: - Formats

    /// Declaration order is menu order, and it is the web's: the document people ask for first,
    /// then the picture that travels in a chat thread, then the Office family, then the raw text.
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case pdf
        case image
        case docx
        case xlsx
        case pptx
        case csv
        case html
        case markdown
        case text

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .image: return "png"
            case .docx: return "docx"
            case .xlsx: return "xlsx"
            case .pptx: return "pptx"
            case .csv: return "csv"
            case .html: return "html"
            case .markdown: return "md"
            case .text: return "txt"
            }
        }

        /// Verbatim from the web's `downloadPdf` / `downloadImage` / `downloadWord` /
        /// `downloadExcel` / `downloadPpt` / `downloadHtml` / `downloadMarkdown` / `downloadText`
        /// and the file card's `fileLabelCsv`.
        var label: LText {
            switch self {
            case .pdf: return LText(ar: "ملف PDF", en: "PDF document")
            case .image: return LText(ar: "صورة", en: "Image")
            case .docx: return LText(ar: "مستند Word", en: "Word document")
            case .xlsx: return LText(ar: "جدول Excel", en: "Excel spreadsheet")
            case .pptx: return LText(ar: "عرض PowerPoint", en: "PowerPoint slides")
            case .csv: return LText(ar: "ملف CSV", en: "CSV file")
            case .html: return LText(ar: "صفحة HTML", en: "HTML page")
            case .markdown: return LText(ar: "ملف Markdown", en: "Markdown file")
            case .text: return LText(ar: "نص عادي (TXT)", en: "Plain text (TXT)")
            }
        }

        var symbol: String {
            switch self {
            case .pdf: return "doc.richtext"
            case .image: return "photo"
            case .docx: return "doc.text"
            case .xlsx: return "tablecells"
            case .pptx: return "rectangle.on.rectangle"
            case .csv: return "list.bullet.rectangle"
            case .html: return "chevron.left.forwardslash.chevron.right"
            case .markdown: return "doc.plaintext"
            case .text: return "doc"
            }
        }

        /// The format a ```` ```firas-file ```` fence names, when this build can write it.
        static func named(_ raw: String) -> Format? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "pdf": return .pdf
            case "docx", "doc", "word": return .docx
            case "xlsx", "xls", "excel": return .xlsx
            case "pptx", "ppt", "powerpoint": return .pptx
            case "csv": return .csv
            case "html", "htm": return .html
            case "md", "markdown": return .markdown
            case "txt", "text": return .text
            case "png", "image": return .image
            default: return nil
            }
        }
    }

    /// A finished export. `Identifiable` so a caller can drive `.sheet(item:)` straight from it.
    struct Export: Identifiable, Equatable, Sendable {
        let id: UUID
        let url: URL
        let format: Format
        /// The file's real size on disk — what the card shows next to the page count.
        let byteCount: Int

        init(id: UUID = UUID(), url: URL, format: Format, byteCount: Int) {
            self.id = id
            self.url = url
            self.format = format
            self.byteCount = byteCount
        }
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
        _ = await produce(format, markdown: markdown, title: title, publish: true)
    }

    /// The whole conversation as one document — the transcript the web's chat-export button
    /// produces, in the conversation's own language.
    func export(_ format: Format, conversation: ChatConversation) async {
        let lang = ExportTranscript.language(of: conversation, fallback: env.prefs.lang)
        let markdown = ExportTranscript.markdown(conversation, lang: lang)
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        await export(format, markdown: markdown, title: title)
    }

    /// Builds the document a ```` ```firas-file ```` card names and returns it without touching
    /// `result` — the card opens it in QuickLook, shares it or saves it to Files itself.
    func document(for meta: FileMeta, markdown: String, title: String) async -> Export? {
        let format = Format.named(meta.format) ?? .pdf
        let raw = meta.name ?? meta.title ?? title
        let name = ExportText.withoutExtension(raw)
        return await produce(format, markdown: markdown, title: name, publish: false)
    }

    func clear() {
        result = nil
        lastError = nil
    }

    // MARK: - The one path every export takes

    private func produce(
        _ format: Format,
        markdown: String,
        title: String,
        publish: Bool
    ) async -> Export? {
        guard !isWorking else { return nil }

        let lang = env.prefs.lang
        let source = ExportText.flattenMath(markdown)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = ExportCopy.empty
            env.toasts.show(ExportCopy.empty(lang), isError: true)
            return nil
        }

        isWorking = true
        lastError = nil
        if publish { result = nil }
        // One turn of the runloop so the caller's spinner paints before a long render blocks it.
        await Task.yield()

        let heading = ExportText.documentTitle(title, markdown: source)
        let url = ExportText.temporaryURL(
            name: ExportText.safeFilename(heading),
            extension: format.fileExtension
        )

        let wrote: Bool
        switch format {
        case .pdf:
            wrote = writePDF(markdown: source, title: heading, to: url)
        case .image:
            wrote = writePNG(markdown: source, title: heading, to: url)
        case .docx, .xlsx, .pptx, .csv, .html, .markdown, .text:
            let kind = format.rawValue
            wrote = await Task.detached(priority: .userInitiated) {
                exportBuildDocument(kind: kind, markdown: source, title: heading, to: url)
            }.value
        }

        isWorking = false
        guard wrote else {
            lastError = ExportCopy.unavailable
            env.toasts.show(ExportCopy.unavailable(lang), isError: true)
            return nil
        }

        let export = Export(url: url, format: format, byteCount: ExportText.byteCount(of: url))
        if publish {
            result = export
            Haptics.select()
        }
        return export
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
                drawsIslands: false,
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
        defer {
            MarkdownRenderer.invalidate(messageID: messageID)
            MathBlockView.invalidate(messageID: messageID)
        }

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
        defer {
            MarkdownRenderer.invalidate(messageID: messageID)
            MathBlockView.invalidate(messageID: messageID)
        }

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
}

/// Every text and Office format, built off the main actor: a 200-page document is a megabyte of XML
/// to assemble and none of it belongs on the thread that is drawing the spinner.
///
/// A free function taking the format's raw name, not a member taking `Format`: it runs inside a
/// detached task and must carry none of the controller's main-actor isolation with it.
private func exportBuildDocument(kind: String, markdown: String, title: String, to url: URL) -> Bool {
    switch kind {
    case "markdown":
        return exportWriteText(markdown, to: url)
    case "text":
        return exportWriteText(ExportText.plain(markdown), to: url)
    case "html":
        let blocks = ExportMarkdown.blocks(from: markdown)
        return exportWriteText(ExportWeb.document(title: title, blocks: blocks), to: url)
    case "csv":
        let blocks = ExportMarkdown.blocks(from: markdown)
        let sheets = ExportSheets.sheets(title: title, blocks: blocks, outlineName: title)
        return exportWriteText(ExportSheets.csv(sheets: sheets), to: url)
    case "docx":
        let blocks = ExportMarkdown.blocks(from: markdown)
        return ExportWord.write(title: title, blocks: blocks, to: url)
    case "xlsx":
        let blocks = ExportMarkdown.blocks(from: markdown)
        let sheets = ExportSheets.sheets(title: title, blocks: blocks, outlineName: title)
        return ExportSheets.write(title: title, sheets: sheets, to: url)
    case "pptx":
        let blocks = ExportMarkdown.blocks(from: markdown)
        let slides = ExportSlides.slides(title: title, blocks: blocks)
        return ExportSlides.write(title: title, slides: slides, to: url)
    default:
        return false
    }
}

/// Writes UTF-8 text. A free function, not a member: it is called from a detached task and must not
/// carry the controller's main-actor isolation with it.
private func exportWriteText(_ text: String, to url: URL) -> Bool {
    do {
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    } catch {
        Log.ui.error("export write failed: \(String(describing: error), privacy: .public)")
        return false
    }
}
