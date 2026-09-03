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
/// Math never leaves as LaTeX. Where a format can *typeset* — the PDF and the picture, which hand
/// the document to SwiftUI — the equations are drawn, and this file asks the KaTeX island for the
/// bitmaps and waits for them before it measures a single block. Where a format cannot, every
/// protected span goes through `MathText.unicode`, so a pasted paragraph reads as `∫₀^π sin x dx`
/// and never as `\int_0^{\pi}`. The flattening happens per block, at the point of use; handing a
/// writer text whose equations were already reduced is how the two formats that could have drawn
/// them ended up printing symbols.
///
/// ## The owner's report: «فاشل»
///
/// A PDF of ten integrals came out with the text against the top and bottom edges of the sheet, the
/// mathematics flattened, and nothing set apart from anything else. Three separate causes, all
/// fixed here: the pagination drew every page's content on every page with nothing clipping it, so
/// the margin could not be empty whatever it was set to; the document was flattened before it ever
/// reached the renderer; and the whole answer was one block, so a page break fell wherever the
/// arithmetic said and never between two paragraphs.
///
/// Nothing is written into the user's documents: every export lands in a temp directory and the
/// share sheet — or the Files picker — decides where it really goes.
///
/// ## The owner's report: «لازم كلشي»
///
/// A conversation export used to reach the writers as one pre-flattened `String`, and each writer
/// then decided for itself how much of it to keep — the workbook, most destructively, kept only the
/// tables and threw the prose away. There is now exactly one path: `Source.conversation` →
/// `ExportTranscript.forEachTurn` → the writer, turn by turn in order, question and answer
/// alternating. A ten-turn conversation reaches every one of the nine writers as ten questions and
/// ten answers, and no writer is given the option of a shortcut.
///
/// Nothing is assembled as one enormous string either. `.md` and `.txt` are streamed to the file a
/// turn at a time; the Office formats parse a turn at a time; and the two *rendered* formats are
/// laid out one block at a time, so what is alive at once is one page, not one document. A picture
/// too tall for a bitmap becomes several pictures rather than one with its foot cut off.
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

        /// What choosing this actually gets you. A format picker that lists nine file extensions
        /// asks the reader to already know the answer; this line is the difference between a menu
        /// and a decision, and it says what the file is *for*, never what it is called.
        var detail: LText {
            switch self {
            case .pdf:
                return LText(
                    ar: "يقرأه أي جهاز، ويطبع كما هو. الخيار الآمن للتسليم والأرشفة.",
                    en: "Reads and prints the same everywhere. The safe one to hand in or file away."
                )
            case .image:
                return LText(
                    ar: "بطاقة واحدة تُرسَل في أي محادثة — السؤال فوق الجواب، بعلامة فِراس.",
                    en: "One card to send in a chat — the question above the answer, with the Firas mark."
                )
            case .docx:
                return LText(
                    ar: "يفتح في Word وPages للتحرير، بعناوين حقيقية وجداول قابلة للنسخ.",
                    en: "Opens in Word and Pages to edit, with real headings and tables you can copy."
                )
            case .xlsx:
                return LText(
                    ar: "المحادثة كاملة في ورقة، وكل جدول في ورقته — للفرز والحساب.",
                    en: "The whole conversation on one sheet, each table on its own — to sort and total."
                )
            case .pptx:
                return LText(
                    ar: "شريحة لكل عنوان، جاهزة للعرض والتعديل.",
                    en: "A slide per heading, ready to present and edit."
                )
            case .csv:
                return LText(
                    ar: "نص مفصول بفواصل، تقرأه أي أداة — بلا تنسيق.",
                    en: "Comma-separated text any tool can read — no formatting."
                )
            case .html:
                return LText(
                    ar: "صفحة واحدة مكتفية بذاتها، تُفتح في أي متصفح وبلا إنترنت.",
                    en: "One self-contained page that opens in any browser, offline."
                )
            case .markdown:
                return LText(
                    ar: "المصدر كما هو — للمحررين وأنظمة الملاحظات وGit.",
                    en: "The source as it is — for editors, note systems and Git."
                )
            case .text:
                return LText(
                    ar: "حروف فقط، بلا زخرفة. المعادلات تخرج كرموز تُقرأ.",
                    en: "Letters only, nothing else. Equations come out as readable symbols."
                )
            }
        }

        /// The three questions a reader is actually choosing between: *to read*, *to work on*, *to
        /// keep*. The picker is grouped by these, which is why nine rows do not read as a list.
        enum Family: String, CaseIterable, Identifiable, Sendable {
            case read
            case edit
            case raw

            var id: String { rawValue }

            var title: LText {
                switch self {
                case .read: return LText(ar: "للقراءة والمشاركة", en: "To read and share")
                case .edit: return LText(ar: "للعمل عليه", en: "To work on")
                case .raw: return LText(ar: "النص الخام", en: "The raw text")
                }
            }
        }

        var family: Family {
            switch self {
            case .pdf, .image, .html: return .read
            case .docx, .xlsx, .pptx: return .edit
            case .csv, .markdown, .text: return .raw
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
        /// Every file the export produced, in reading order, `url` first.
        ///
        /// One entry for everything except a picture of a long thread, which comes out as several
        /// PNGs rather than as one with its foot cut off. A caller that shares only `url` shares
        /// page one; `FirasActivitySheet(export:)` hands over all of them.
        let pages: [URL]

        init(id: UUID = UUID(), url: URL, format: Format, byteCount: Int, pages: [URL] = []) {
            self.id = id
            self.url = url
            self.format = format
            self.byteCount = byteCount
            self.pages = pages.isEmpty ? [url] : pages
        }
    }

    // MARK: - State

    private let env: AppEnvironment

    private(set) var isWorking = false
    private(set) var lastError: LText?
    /// Settable so a view can bind `.sheet(item:)` to it and clear it on dismiss.
    var result: Export?

    /// The files the last picture export wrote, page one first. Handed straight to `Export.pages`
    /// and cleared on the next run; nothing outside `produce` reads it, so nothing observes it.
    @ObservationIgnored private var picturePages: [URL] = []

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Exporting

    /// Writes `markdown` in `format` to a temp file and publishes it as `result`. Failures toast
    /// with the web's `formatUnavailable` / `exportEmpty` copy and leave `result` untouched.
    ///
    /// **One answer, not a conversation.** This is the per-answer download and the file a
    /// ```` ```firas-file ```` card promises. A caller that means "the whole thread" must use
    /// `export(_:conversation:)` — a document assembled here can only ever contain what it was
    /// handed, which is precisely the confusion the owner reported.
    func export(_ format: Format, markdown: String, title: String) async {
        _ = await produce(format, source: .document(markdown: markdown), title: title, publish: true)
    }

    /// The whole conversation as one document — every turn, in order, question and answer
    /// alternating, from the first to the last.
    func export(_ format: Format, conversation: ChatConversation) async {
        let lang = ExportTranscript.language(of: conversation, fallback: env.prefs.lang)
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await produce(
            format,
            source: .conversation(conversation, lang),
            title: title,
            publish: true
        )
    }

    /// Builds the document a ```` ```firas-file ```` card names and returns it without touching
    /// `result` — the card opens it in QuickLook, shares it or saves it to Files itself.
    func document(for meta: FileMeta, markdown: String, title: String) async -> Export? {
        let format = Format.named(meta.format) ?? .pdf
        let raw = meta.name ?? meta.title ?? title
        let name = ExportText.withoutExtension(raw)
        return await produce(format, source: .document(markdown: markdown), title: name, publish: false)
    }

    func clear() {
        result = nil
        lastError = nil
    }

    // MARK: - What is being exported

    /// The two things an export can be. Everything below branches on this once and never again.
    private enum Source {
        /// One answer, or one assembled long file.
        case document(markdown: String)
        /// A whole thread, in the document's own language — which is not the interface's.
        case conversation(ChatConversation, AppLanguage)
    }

    /// The document as a printed page, or `nil` when WebKit will not make one.
    ///
    /// Only `.pdf` goes this way for now: the picture export paginates at turn boundaries and
    /// that logic has no counterpart in a single tall page yet. `Source` is private to this
    /// file, which is why the unwrapping happens here rather than in the document extension.
    private func printedPDF(source: Source, title: String, lang: AppLanguage) async -> Data? {
        let markdown: String
        let origin: DocumentOrigin
        let documentLang: AppLanguage
        switch source {
        case .document(let body):
            markdown = body
            /* UNSIGNED. A single document is one the reader asked Firas to design, and it is
               theirs: «ماكو حقوق فراس اي اي لان هو تصميم». */
            origin = .designed
            documentLang = lang
        case .conversation(let conversation, let conversationLang):
            markdown = ExportTranscript.markdown(conversation, lang: conversationLang)
            // A transcript IS from Firas, and keeps the line it has always carried.
            origin = .conversation
            documentLang = conversationLang
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return await documentPDF(
            markdown: markdown,
            title: title,
            origin: origin,
            lang: documentLang
        )
    }

    // MARK: - The one path every export takes

    private func produce(
        _ format: Format,
        source: Source,
        title: String,
        publish: Bool
    ) async -> Export? {
        guard !isWorking else { return nil }

        let lang = env.prefs.lang
        guard let input = buildInput(for: source) else {
            lastError = ExportCopy.empty
            env.toasts.show(ExportCopy.empty(lang), isError: true)
            return nil
        }

        isWorking = true
        lastError = nil
        picturePages = []
        if publish { result = nil }
        // One turn of the runloop so the caller's spinner paints before a long render blocks it.
        await Task.yield()
        defer { isWorking = false }

        let heading = documentHeading(title, input: input)
        let url = ExportText.temporaryURL(
            name: ExportText.safeFilename(heading),
            extension: format.fileExtension
        )

        let wrote: Bool
        switch format {
        case .pdf, .image:
            // The two rendered formats are the only ones that can carry a *typeset* equation, and
            // the island draws with a web view, which never rasterises into a PDF page. So the
            // glyphs are asked for and waited on here, before a single block is measured; what
            // does not arrive in time falls back to the Unicode form, which is what the document
            // would have carried anyway.
            await primeMath(input.mathSources, palette: exportPalette)
            /* THE PAGE FIRST, THE HAND-WRITTEN RENDERER SECOND.
               `writePDF` below measures and packs blocks into a CGContext by hand - a print
               engine written from scratch, and every part of one failed in turn: the margin,
               the page breaks, tables across a break, Arabic, and above all the mathematics,
               which a CGContext has no notion of and could only ever approximate in Unicode.
               WebKit is a print engine, it is on the device, and it typesets the same KaTeX
               build the transcript uses. So the document is composed as a page and printed.
               It stays a fallback rather than a replacement on purpose: if WebKit answers with
               nothing, the reader still gets the file they asked for. */
            if format == .pdf,
               let printed = await printedPDF(source: source, title: heading, lang: lang),
               (try? printed.write(to: url, options: .atomic)) != nil {
                wrote = true
            } else {
                wrote = format == .pdf
                    ? writePDF(input: input, title: heading, to: url)
                    : writePicture(input: input, title: heading, to: url)
            }
        case .docx, .xlsx, .pptx, .csv, .html, .markdown, .text:
            let kind = format.rawValue
            wrote = await Task.detached(priority: .userInitiated) {
                exportBuildDocument(kind: kind, input: input, title: heading, to: url)
            }.value
        }

        guard wrote else {
            lastError = ExportCopy.unavailable
            env.toasts.show(ExportCopy.unavailable(lang), isError: true)
            return nil
        }

        let export = Export(
            url: url,
            format: format,
            byteCount: ExportText.byteCount(of: url),
            pages: picturePages
        )
        picturePages = []
        if publish {
            result = export
            Haptics.select()
        }
        return export
    }

    // MARK: - Typeset mathematics

    /// Ask the KaTeX island for every display equation the document contains, and wait — briefly —
    /// for the bitmaps.
    ///
    /// `MarkdownView` draws an equation from `MathIsland`'s cache when a bitmap is there and from
    /// `MathText.unicode` when it is not, and during an export it is told not to draw islands at
    /// all, so nothing would ever put a bitmap in that cache. This does. The palette matters: an
    /// export renders light even when the app is dark, and a glyph is keyed by the colour it was
    /// drawn in, so the ones cached from reading the answer on a dark screen are the wrong ones.
    ///
    /// Every failure path ends the same way and none of them is an error: no network, a blocked
    /// CDN, an expression KaTeX refuses, or simply a slow one. The document then carries `∫₀^π`
    /// instead of a typeset integral, which is exactly what it carried before this existed.
    private func primeMath(_ sources: [String], palette: FirasPalette) async {
        let style = MathIslandStyle(
            palette: palette,
            background: palette.background,
            fontScale: env.prefs.fontScale
        )
        /* TWO LISTS, AND THE DISPLAY ONE IS ASKED FOR FIRST. The island renders in the order it
           was handed, twelve equations to a page load, and this function gives up after a fixed
           patience — so position in this array is not bookkeeping, it is which equations the
           document actually gets. Collecting inline spans in reading order alongside the display
           blocks put a paragraph's worth of `$…$` ahead of the `$$…$$` beneath it: the ceiling
           could be spent before the last block was reached, and even under the ceiling the
           display glyphs were queued behind hundreds of inline ones and were still unrendered
           when the wait ran out. Both endings are the same ending — an equation that has been
           typeset in every PDF this app has ever written comes out as `∫₀^π` instead. Display
           blocks are the ones the export can certainly draw (`MathBlockView` reads the cache
           whether or not islands are drawn), so they are never behind anything. */
        var display: [MathIslandItem] = []
        var inline: [MathIslandItem] = []
        var seen: Set<String> = []
        let ceiling = ExportController.mathCeiling
        outer: for source in sources {
            for chunk in ExportController.flowChunks(of: source) {
                if let tex = ExportController.displayTex(chunk), MathScanner.isTypesettable(tex) {
                    let item = MathIslandItem(tex: tex, isDisplay: true)
                    if seen.insert(item.id).inserted {
                        display.append(item)
                        // The island's queue stops at 240; asking for more is asking for nothing.
                        if display.count >= ceiling { break outer }
                    }
                    continue
                }
                /* AND THE EQUATIONS INSIDE THE SENTENCES. Only whole `$$…$$` blocks were ever
                   asked for, so a display equation sitting inside a list item or a quote — which
                   `MarkdownBlocks.split` keeps inside its parent chunk, and which the renderer
                   still lays out through `MathBlockView` — was never primed and printed as its
                   Unicode approximation next to the properly typeset block above it.

                   The inline ones are collected too, but they are a hope rather than a promise:
                   `MarkdownView.inlineGlyphs` refuses to read the cache while `drawsIslands` is
                   false, which is exactly how every export renders. Until that gate is lifted an
                   inline `$…$` reaches the page as Unicode however well it was drawn here, so
                   these queue last and take only the room the display blocks left. */
                for span in MathScanner.spans(in: chunk) {
                    guard MathScanner.isTypesettable(span.tex) else { continue }
                    let item = MathIslandItem(tex: span.tex, isDisplay: span.isDisplay)
                    guard seen.insert(item.id).inserted else { continue }
                    if span.isDisplay {
                        display.append(item)
                        if display.count >= ceiling { break outer }
                    } else if inline.count < ceiling {
                        inline.append(item)
                    }
                }
            }
        }
        var items = display
        items.append(contentsOf: inline.prefix(max(0, ceiling - display.count)))
        guard !items.isEmpty else { return }

        MathIsland.shared.request(items, style: style)
        let started = Date()
        let patience = min(20.0, 3.0 + Double(items.count) * 0.3)
        while true {
            let waited = Date().timeIntervalSince(started)
            var landed = 0
            for item in items where MathIsland.shared.glyph(for: item.id, style: style) != nil {
                landed += 1
            }
            if landed == items.count { return }
            // Nothing at all after four seconds is a CDN that is not going to answer. Waiting the
            // rest of the patience out would only make the export feel broken as well as plain.
            if waited > 4, landed == 0 { return }
            if waited > patience { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Equations one export may ask the island to draw. The island's queue is 240 deep.
    private static let mathCeiling = 240

    /// The bare expression of a chunk that is a `$$…$$` block, read exactly the way
    /// `MarkdownBlocks.parse` reads it — so the glyph this asks for is the glyph the renderer
    /// will look up. Anything else is not an equation the renderer typesets.
    private static func displayTex(_ chunk: String) -> String? {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 else {
            return nil
        }
        let tex = String(trimmed.dropFirst(2).dropLast(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tex.isEmpty ? nil : tex
    }

    /// The source, checked for emptiness and reduced to the `Sendable` value the writers take.
    /// `nil` means there is nothing to export, which is the web's `exportEmpty`.
    private func buildInput(for source: Source) -> ExportBuildInput? {
        switch source {
        case .document(let markdown):
            // Handed on with its LaTeX intact. Flattening used to happen here, which meant the
            // PDF and the picture — the two formats that can *typeset* an equation — were given a
            // document whose equations had already been reduced to symbols. A single answer of ten
            // integrals could therefore never come out as anything but ten lines of grey text.
            // Each writer now flattens for itself, at the point where flattening is the right
            // answer, and no writer flattens more than one block at a time.
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .document(markdown)

        case .conversation(let conversation, let lang):
            guard ExportTranscript.isExportable(conversation) else { return nil }
            return .conversation(conversation, lang)
        }
    }

    /// The heading the file carries, and the name on disk.
    private func documentHeading(_ title: String, input: ExportBuildInput) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch input {
        case .document(let markdown):
            return ExportText.documentTitle("", markdown: markdown)
        case .conversation(let conversation, let lang):
            return ExportTranscript.header(conversation, lang: lang).title
        }
    }

    // MARK: - Rendered formats

    /// Exports always render on a light palette: a black PDF page is not a document.
    private var exportPalette: FirasPalette {
        env.prefs.theme.isLight ? env.prefs.palette : FirasTheme.light.palette
    }

    /// The document, split into the pieces a page break may fall between.
    ///
    /// `MarkdownBlocks.split` is the renderer's own splitter, so a unit here is exactly a block
    /// there: a fenced listing arrives whole, a table arrives whole, an equation arrives whole.
    /// Paginating between those is what stops a page break landing through the middle of a line.
    private static func flowChunks(of markdown: String) -> [String] {
        MarkdownBlocks.split(markdown, streaming: false).map(promotingLoneEquation)
    }

    /// A block that is nothing but one equation becomes a display equation, whatever delimiters it
    /// was written with.
    ///
    /// `$\int_0^{\pi/4} \sec^2 x\,dx$` alone on a line is not a sentence that happens to contain a
    /// symbol; it is the tenth of ten integrals. Inline math is flattened to Unicode by the
    /// renderer, display math is typeset — so this one rewrite is the difference between a page of
    /// grey text and a page of mathematics. Asked of the one scanner, so a line reading "$40" is
    /// never mistaken for one.
    private static func promotingLoneEquation(_ chunk: String) -> String {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("$$") else { return chunk }
        guard trimmed.hasPrefix("$") || trimmed.hasPrefix("\\(") || trimmed.hasPrefix("\\[") else {
            return chunk
        }
        let (protected, spans) = MathScanner.protect(trimmed)
        guard spans.count == 1,
              protected.trimmingCharacters(in: .whitespacesAndNewlines) == MathScanner.token(0)
        else {
            return chunk
        }
        let tex = MathText.stripDelimiters(spans[0])
        return tex.isEmpty ? chunk : "$$" + tex + "$$"
    }

    /// What one block is, read from its opening line with the renderer's own tests. Only the
    /// spacing above it and whether it keeps its successor depend on this.
    private enum FlowKind {
        case heading
        case paragraph
        case list
        case quote
        case code
        case table
        case math
        case rule
    }

    private static func kind(of chunk: String) -> FlowKind {
        let lines = chunk.components(separatedBy: "\n")
        let first = lines.first ?? chunk
        if MarkdownBlocks.fenceOpen(first) != nil { return .code }
        if MarkdownBlocks.displayMathOpens(first) { return .math }
        if MarkdownBlocks.isRule(first) { return .rule }
        if MarkdownBlocks.headingLevel(first) != nil { return .heading }
        if MarkdownBlocks.isQuote(first) { return .quote }
        if MarkdownBlocks.listMarker(first) != nil { return .list }
        if lines.count >= 2, first.contains("|"), MarkdownBlocks.isTableDelimiter(lines[1]) {
            return .table
        }
        return .paragraph
    }

    /// The air above one block. `MarkdownBlockRow` sets the same rhythm on screen; a page is
    /// slightly more generous than a scroll, because a page has an edge and a scroll does not.
    private static func spacing(before kind: FlowKind, lang: AppLanguage, scale: FontScale) -> CGFloat {
        switch kind {
        case .heading: return 22
        case .code, .table, .math: return 16
        case .rule: return 14
        case .paragraph, .list, .quote:
            return FirasType.proseParagraphSpacing(lang, scale: scale)
        }
    }

    /// The document's own title, set as a title and ruled off from what follows.
    private func titleBlock(
        _ title: String,
        lang: AppLanguage,
        palette: FirasPalette,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: title, fallback: lang)
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
        }
        .frame(width: width, alignment: .leading)
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }

    /// One block of the document, rendered on its own so a page break can fall in front of it.
    ///
    /// An Arabic document reads right to left, with `MarkdownView`'s per-block islands keeping
    /// code, URLs and equations running the other way inside it.
    private func flowBlock(
        markdown: String,
        lang: AppLanguage,
        palette: FirasPalette,
        width: CGFloat,
        messageID: String
    ) -> some View {
        MarkdownView(
            markdown: markdown,
            messageID: messageID,
            streaming: false,
            lang: lang,
            palette: palette,
            prefs: env.prefs,
            drawsIslands: false,
            onFence: { _ in nil }
        )
        .frame(width: width, alignment: .leading)
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }

    /// The document as paginable units: its title, then one per block.
    private func documentUnits(
        markdown: String,
        title: String,
        lang: AppLanguage,
        palette: FirasPalette,
        width: CGFloat,
        root: String,
        ids: inout [String]
    ) -> [ExportUnit] {
        var units: [ExportUnit] = []
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty {
            units.append(
                ExportUnit(
                    gap: 0,
                    keepsWithNext: true,
                    view: AnyView(titleBlock(heading, lang: lang, palette: palette, width: width))
                )
            )
        }

        var chunks = ExportController.flowChunks(of: markdown)
        // A single answer takes its title from its own first heading, so printing that heading
        // again directly under the title shows the same words twice. Word and the HTML page drop
        // it for the same reason.
        if !heading.isEmpty, let opening = chunks.first,
           let level = MarkdownBlocks.headingLevel(opening.components(separatedBy: "\n").first ?? opening),
           level.level <= 3,
           level.text.trimmingCharacters(in: .whitespacesAndNewlines) == heading {
            chunks.removeFirst()
        }

        let scale = env.prefs.fontScale
        for (index, chunk) in chunks.enumerated() {
            let id = root + "-b" + String(index)
            ids.append(id)
            let kind = ExportController.kind(of: chunk)
            let body: AnyView
            if kind == .code, let listing = ExportController.listing(in: chunk, lang: lang) {
                body = AnyView(
                    listingBlock(
                        code: listing.body,
                        language: listing.language,
                        palette: palette,
                        width: width
                    )
                )
            } else {
                body = AnyView(
                    flowBlock(
                        markdown: chunk,
                        lang: lang,
                        palette: palette,
                        width: width,
                        messageID: id
                    )
                )
            }
            units.append(
                ExportUnit(
                    gap: ExportController.spacing(before: kind, lang: lang, scale: scale),
                    // A heading with its section on the next page is not a heading.
                    keepsWithNext: kind == .heading,
                    view: body
                )
            )
        }
        return units
    }

    /// The language and body of a chunk that is a fenced listing, however it was fenced.
    private static func listing(in chunk: String, lang: AppLanguage) -> (language: String?, body: String)? {
        switch MarkdownBlocks.parse(chunk, lang: lang) {
        case .code(let language, let body):
            return (language, body)
        case .fence(let fence):
            guard case .code(let meta, let body) = fence else { return nil }
            return (meta.lang, body)
        default:
            return nil
        }
    }

    /// A fenced listing on a page: the whole listing, wrapped, never folded.
    ///
    /// `MarkdownView` hands a fence to `CodeBlockView` with `collapsible: true`, which is right on
    /// a screen — a sixty-line listing inside a chat turn should fold to sixteen — and wrong on a
    /// page, where the fold becomes sixteen lines, a fade, and an «عرض المزيد» button nobody can
    /// press. `CodeListing` is the same renderer with `lineLimit: nil`, and `wrapped: true` because
    /// a page cannot be scrolled sideways: a long line has to come back round, not fall off.
    private func listingBlock(
        code: String,
        language: String?,
        palette: FirasPalette,
        width: CGFloat
    ) -> some View {
        CodeListing(
            code: code,
            language: language,
            palette: palette,
            wrapped: true,
            lineLimit: nil,
            fadesTail: false
        )
        .frame(width: width, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .forceLTR()
    }

    /// A4 at 72 dpi, with a real margin on every page and a page break that never falls through
    /// the middle of a line.
    ///
    /// The old version rendered the whole document as one tall picture and drew *all* of it on
    /// every page, shifted up by a page height each time. Nothing clipped it, so the strip that
    /// belonged to the previous page filled the top margin and the strip belonging to the next
    /// filled the bottom one: whatever the margin was set to, the ink ran to both edges of the
    /// sheet. That is «ما مفصول بين الفوق والجوة», exactly.
    ///
    /// Now each block is measured, packed into pages, and drawn clipped to its own slot. The
    /// margin is empty because nothing is ever drawn into it, the last page ends where the
    /// document ends, and a heading, a table and a listing each arrive whole.
    private func writePDF(input: ExportBuildInput, title: String, to url: URL) -> Bool {
        let root = "firas-export-" + UUID().uuidString
        var ids: [String] = []
        defer {
            for id in ids { MarkdownRenderer.invalidate(messageID: id) }
            MathBlockView.invalidate(messageID: root)
        }

        let lang = input.language(fallback: env.prefs.lang)
        let palette = exportPalette
        let width = ExportPage.contentWidth

        // The heading is already the transcript's own `# title`, so a conversation does not get it
        // printed twice; a single answer has no title of its own and keeps the one it was given.
        let units = documentUnits(
            markdown: input.renderedMarkdown,
            title: input.isConversation ? "" : title,
            lang: lang,
            palette: palette,
            width: width,
            root: root,
            ids: &ids
        )
        guard !units.isEmpty else { return false }

        let layout = paginate(
            units,
            width: width,
            pageHeight: ExportPage.contentHeight,
            maximumPages: ExportPage.maximumPages
        )

        var box = CGRect(origin: .zero, size: ExportPage.size)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }

        var perPage: [[ExportSlot]] = Array(repeating: [], count: layout.pages)
        for slot in layout.slots where slot.page < layout.pages {
            perPage[slot.page].append(slot)
        }

        for page in 0..<layout.pages {
            pdf.beginPDFPage(nil)
            for slot in perPage[page] {
                draw(units[slot.unit], in: slot, width: width, into: pdf)
            }
            drawFooter(page: page, of: layout.pages, lang: lang, palette: palette, into: pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()

        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if layout.truncated {
            // The ceiling exists so a runaway thread cannot ask for a ten-thousand-page file. It
            // is still a document that stops early, and a document that stops early has to say so.
            env.toasts.show(
                ExportPaperCopy.tooLong.fmt(lang, ArabicText.count(ExportPage.maximumPages, lang))
            )
        }
        return true
    }

    // MARK: - Measuring and drawing one unit

    /// Packs the units onto pages, laying each one out once and only as far as the ceiling allows.
    private func paginate(
        _ units: [ExportUnit],
        width: CGFloat,
        pageHeight: CGFloat,
        maximumPages: Int
    ) -> ExportPagination.Layout {
        var known = [CGFloat?](repeating: nil, count: units.count)
        return ExportPagination.slots(
            count: units.count,
            gaps: units.map(\.gap),
            keepsWithNext: units.map(\.keepsWithNext),
            pageHeight: pageHeight,
            maximumPages: maximumPages
        ) { index in
            if let height = known[index] { return height }
            let height = measure(units[index], width: width)
            known[index] = height
            return height
        }
    }

    /// One unit's laid-out height, in points, at the document's own width.
    ///
    /// Measurement only: `render` is asked for the size and the drawing closure is not called, so
    /// nothing is rasterised here.
    private func measure(_ unit: ExportUnit, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: unit.view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in
            guard size.height.isFinite, size.height > 0 else { return }
            height = size.height
        }
        return height
    }

    /// Draws one unit — or one slice of an oversized one — into its slot, clipped to it.
    ///
    /// The clip is the whole point. Without it the parts of the unit that belong to another page
    /// are still painted, into the margin and past the edge of the sheet.
    private func draw(_ unit: ExportUnit, in slot: ExportSlot, width: CGFloat, into context: CGContext) {
        let renderer = ImageRenderer(content: unit.view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.render { size, paint in
            guard size.width > 0, size.height > 0, size.height.isFinite else { return }
            let top = ExportPage.contentTop - slot.top
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: ExportPage.margin,
                    y: top - slot.height,
                    width: width,
                    height: slot.height
                )
            )
            // `paint` puts the unit's first row at y = size.height in a bottom-left origin, so row
            // `slot.offset` lands on the top edge of the slot when the origin moves here.
            context.translateBy(x: ExportPage.margin, y: top - size.height + slot.offset)
            paint(context)
            context.restoreGState()
        }
    }

    /// `٣ / ١٢`, muted, inside the bottom margin — never in the text block. A single-page document
    /// has nothing to number and gets none.
    private func drawFooter(
        page: Int,
        of total: Int,
        lang: AppLanguage,
        palette: FirasPalette,
        into context: CGContext
    ) {
        guard total > 1 else { return }
        let label = ArabicText.count(page + 1, lang) + " / " + ArabicText.count(total, lang)
        let stamp = Text(verbatim: label)
            .font(.system(size: 9))
            .foregroundStyle(palette.textMuted)
            .frame(width: ExportPage.contentWidth, alignment: .center)
            .forceLTR()
        let renderer = ImageRenderer(content: stamp)
        renderer.proposedSize = ProposedViewSize(width: ExportPage.contentWidth, height: nil)
        renderer.render { size, paint in
            guard size.height > 0, size.height.isFinite else { return }
            context.saveGState()
            context.translateBy(x: ExportPage.margin, y: ExportPage.footerTop - size.height)
            paint(context)
            context.restoreGState()
        }
    }

    /// The picture the web calls `exportImage` — a branded card, not a screenshot.
    ///
    /// The composition is the site's: the mark and the wordmark on top, the question in its own
    /// tinted block under the label «السؤال», then the answer, on a 720-point white sheet with no
    /// footer — the site removed its own footer deliberately, because a shared page is the reader's
    /// and not an advertisement. A whole conversation repeats that block per turn.
    ///
    /// **A long thread comes out as several pictures, not as one with its foot cut off.** A card
    /// taller than one bitmap is broken between turns, and each page is its own PNG: nothing is
    /// lost, and each file still opens as a picture in a chat thread. Only a single turn taller
    /// than a whole page is ever cut, and the reader is told when that happens.
    ///
    /// Each page is drawn into a bitmap this file sizes rather than into `ImageRenderer.uiImage`,
    /// because `uiImage` will happily try to allocate whatever the content asks for: a long thread
    /// would be a hundred-megapixel request that fails as "that format is unavailable" on the
    /// device where it matters most.
    private func writePicture(input: ExportBuildInput, title: String, to url: URL) -> Bool {
        let root = "firas-export-" + UUID().uuidString
        var ids: [String] = []
        // Every id the card hands to a `MarkdownView`: a cache slot keyed on an export that has
        // already been written is a leak nothing will ever read.
        defer {
            for id in ids { MarkdownRenderer.invalidate(messageID: id) }
            MathBlockView.invalidate(messageID: root)
        }

        let lang = input.language(fallback: env.prefs.lang)
        let palette = exportPalette
        let width = ExportCard.contentWidth
        let units = cardUnits(
            input: input,
            title: title,
            lang: lang,
            palette: palette,
            width: width,
            root: root,
            ids: &ids
        )
        guard !units.isEmpty else { return false }

        let layout = paginate(
            units,
            width: width,
            pageHeight: ExportCard.pageHeight,
            maximumPages: ExportCard.maximumPages
        )

        var perPage: [[ExportSlot]] = Array(repeating: [], count: layout.pages)
        for slot in layout.slots where slot.page < layout.pages {
            perPage[slot.page].append(slot)
        }

        var written: [URL] = []
        var wanted = 0
        for page in 0..<layout.pages {
            let slots = perPage[page]
            guard !slots.isEmpty else { continue }
            wanted += 1
            let destination = ExportController.pageURL(url, page: page)
            guard writePicturePage(units: units, slots: slots, width: width, to: destination) else {
                break
            }
            written.append(destination)
        }
        guard let first = written.first else { return false }

        // The first page keeps the name the export was given; QuickLook, the share sheet and the
        // Files picker all open that one, and `Export.pages` carries the rest.
        if first != url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: first, to: url)
            written[0] = url
        }
        picturePages = written

        // A shorter export under the same name would otherwise leave the surplus pages of a longer
        // one lying beside it in the temp directory, where nothing will ever come back for them.
        var stale = written.count
        while stale < ExportCard.maximumPages {
            try? FileManager.default.removeItem(at: ExportController.pageURL(url, page: stale))
            stale += 1
        }

        if layout.truncated || written.count < wanted {
            // The web's `imgCardTrimmed` said the same thing about a single block that would not
            // fit; this says it about a thread that will not. Either way the reader is told, and
            // told which format does hold the rest — a silent crop is the version nobody forgives.
            env.toasts.show(ExportPictureCopy.trimmed(lang))
        }
        return true
    }

    /// One page of the picture: a white sheet exactly as tall as what it carries.
    private func writePicturePage(
        units: [ExportUnit],
        slots: [ExportSlot],
        width: CGFloat,
        to url: URL
    ) -> Bool {
        let used = slots.reduce(CGFloat(0)) { max($0, $1.top + $1.height) }
        let tall = ExportCard.padTop + used + ExportCard.padBottom
        guard tall > 1 else { return false }
        // @2x for a card that fits on a screen or two; a long one drops to @1x, because the
        // bitmap is the memory and doubling both axes quadruples it.
        let scale: CGFloat = (ExportCard.width * tall) > 1_400_000 ? 1 : 2
        let pixelWidth = Int((ExportCard.width * scale).rounded())
        let pixelHeight = Int((tall * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        guard let bitmap = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }

        bitmap.setFillColor(UIColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        bitmap.scaleBy(x: scale, y: scale)

        // Everything below is in points, with the page's own top at `tall`.
        let top = tall - ExportCard.padTop
        for slot in slots {
            let renderer = ImageRenderer(content: units[slot.unit].view)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            renderer.render { size, paint in
                guard size.width > 0, size.height > 0, size.height.isFinite else { return }
                let slotTop = top - slot.top
                bitmap.saveGState()
                bitmap.clip(
                    to: CGRect(
                        x: ExportCard.padSide,
                        y: slotTop - slot.height,
                        width: width,
                        height: slot.height
                    )
                )
                bitmap.translateBy(x: ExportCard.padSide, y: slotTop - size.height + slot.offset)
                paint(bitmap)
                bitmap.restoreGState()
            }
        }

        guard let image = bitmap.makeImage(),
              let data = UIImage(cgImage: image).pngData() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.ui.error("export png failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The card as paginable units: the mark and the title, then one per turn.
    private func cardUnits(
        input: ExportBuildInput,
        title: String,
        lang: AppLanguage,
        palette: FirasPalette,
        width: CGFloat,
        root: String,
        ids: inout [String]
    ) -> [ExportUnit] {
        var units: [ExportUnit] = []
        units.append(
            ExportUnit(
                gap: 0,
                keepsWithNext: true,
                view: AnyView(
                    ExportCardHead(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        lang: lang,
                        palette: palette,
                        width: width
                    )
                )
            )
        )
        for turn in input.cardTurns {
            let id = root + "-" + turn.id
            ids.append(id)
            units.append(
                ExportUnit(
                    gap: 22,
                    // A question with its answer on the next picture is half an exchange.
                    keepsWithNext: turn.isQuestion,
                    view: AnyView(
                        ExportCardTurnView(
                            text: turn.isQuestion
                                ? turn.text
                                : ExportController.promoted(turn.text),
                            isQuestion: turn.isQuestion,
                            lang: lang,
                            palette: palette,
                            prefs: env.prefs,
                            width: width,
                            messageID: id
                        )
                    )
                )
            )
        }
        return units
    }

    /// A turn's markdown with every lone equation promoted to a display one — the same rewrite the
    /// PDF makes block by block, put back together so `MarkdownView` can split it again itself.
    /// Without it the picture and the pass that asks for the glyphs would disagree about which
    /// equations are display equations, and the picture would set as text the ones it asked to
    /// have typeset.
    private static func promoted(_ markdown: String) -> String {
        let chunks = flowChunks(of: markdown)
        guard !chunks.isEmpty else { return markdown }
        return chunks.joined(separator: "\n\n")
    }

    /// `firas.png`, `firas-2.png`, `firas-3.png` — page one keeps the plain name.
    private static func pageURL(_ url: URL, page: Int) -> URL {
        guard page > 0 else { return url }
        let base = url.deletingPathExtension()
        let name = base.lastPathComponent + "-" + String(page + 1)
        return base
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension(url.pathExtension)
    }
}

// MARK: - The picture

/// The branded card an image export photographs — the web's `.imgcard`.
///
/// White sheet, 720 points wide, the mark and `Firas AI` across the top, then one block per turn:
/// the question under its own label in a tinted box, the answer as the document it is. No footer,
/// no date, no site — the same decision the web made when it deleted its own.
///
/// The sheet is no longer one view. It is the head plus one view per turn, so a thread too tall
/// for a single bitmap is broken *between turns* into several pictures instead of losing its foot.
private enum ExportCard {

    static let width: CGFloat = 720
    static let padSide: CGFloat = 32
    static let padTop: CGFloat = 28
    static let padBottom: CGFloat = 34
    static var contentWidth: CGFloat { width - padSide * 2 }

    /// 720 × 16 000 points is an eleven-megapixel bitmap at @1x, which is the most a phone should
    /// be asked to encode as a PNG. A card taller than that becomes the next page.
    static let pageHeight: CGFloat = 16_000
    /// Twelve of those is a very long conversation and about a hundred megapixels of PNG. Past it
    /// the reader is told to take the PDF.
    static let maximumPages = 12
}

/// The head of the picture: the mark, the wordmark, and the document's title under them.
private struct ExportCardHead: View {

    let title: String
    let lang: AppLanguage
    let palette: FirasPalette
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                FirasBrandMark(size: 24, palette: palette)
                Text(verbatim: "Firas AI")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .forceLTR()
                Spacer(minLength: 0)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: title, fallback: lang)
            }
        }
        .frame(width: width, alignment: .leading)
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }
}

/// One turn of the picture: a question in its own tinted box, or an answer typeset as a document.
private struct ExportCardTurnView: View {

    let text: String
    let isQuestion: Bool
    let lang: AppLanguage
    let palette: FirasPalette
    let prefs: PreferencesStore
    let width: CGFloat
    let messageID: String

    var body: some View {
        block
            .frame(width: width, alignment: .leading)
            .environment(
                \.layoutDirection,
                lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
            )
    }

    @ViewBuilder
    private var block: some View {
        if isQuestion {
            VStack(alignment: .leading, spacing: 6) {
                Text(ExportPictureCopy.question(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.surfaceSunken)
            )
            .bidiIsland(for: text, fallback: lang)
        } else {
            MarkdownView(
                markdown: text,
                messageID: messageID,
                streaming: false,
                lang: lang,
                palette: palette,
                prefs: prefs,
                drawsIslands: false,
                onFence: { _ in nil }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One block of the picture: a question to set in its own box, or an answer to typeset.
struct ExportCardTurn: Identifiable, Sendable, Equatable {
    let id: String
    let isQuestion: Bool
    let text: String
}

// MARK: - Paper

/// A4 at 72 dpi, and the margin the owner asked for.
private enum ExportPage {

    static let size = CGSize(width: 595, height: 842)

    /* 36 pt is half an inch, and at that width a line of Arabic sits against the edge of the sheet
       with nothing to breathe into — which is what a printed page looks like when it looks wrong.
       56 pt is close to the two-centimetre margin a document is normally set with, and it is the
       same margin the `.docx` writes into its `w:pgMar`. Everything below derives from it. */
    static let margin: CGFloat = 56

    static var contentWidth: CGFloat { size.width - margin * 2 }
    static var contentHeight: CGFloat { size.height - margin * 2 }
    /// The top of the text block, in the page's own bottom-left coordinates.
    static var contentTop: CGFloat { size.height - margin }
    /// The page number sits inside the bottom margin, clear of the text block above it.
    static let footerTop: CGFloat = 44

    /// Four hundred A4 pages is a book. Past it the file stops and the reader is told.
    static let maximumPages = 400
}

/// One indivisible piece of a paginated export: a title, a heading, a paragraph, a table, a
/// listing, an equation, one turn of a conversation.
private struct ExportUnit {
    /// The air above it when it is not the first thing on its page.
    let gap: CGFloat
    /// Whether it must not be the last thing on a page — a heading without its section under it,
    /// or a question without its answer.
    let keepsWithNext: Bool
    let view: AnyView
}

/// Where one unit — or one slice of an oversized one — is drawn.
private struct ExportSlot {
    let unit: Int
    let page: Int
    /// Distance from the top of the page's text block to the top of this slot.
    let top: CGFloat
    /// How far into the unit's own content this slot begins. Non-zero only for a unit that is
    /// taller than a whole page and had to be cut.
    let offset: CGFloat
    let height: CGFloat
}

/// Packing measured blocks onto pages.
///
/// Pure arithmetic over heights: no SwiftUI, no drawing, nothing to get wrong twice. A unit moves
/// to the next page rather than being cut, and the only thing ever cut is a unit that would not
/// fit on a page of its own — a table with two hundred rows, a listing the length of a file.
private enum ExportPagination {

    struct Layout {
        let slots: [ExportSlot]
        let pages: Int
        /// `true` when the page ceiling stopped the document short of its last block.
        let truncated: Bool
    }

    /// Heights arrive through `height(_:)` rather than as an array, and the difference is not
    /// tidiness: laying a block out is the expensive part of an export, and a three-hundred-turn
    /// thread has thousands of them past the page a reader will ever see. Asking one block at a
    /// time means the ceiling stops the *measuring* too, and `truncated` is then the truth rather
    /// than a guess. The caller memoises, so the block read ahead of is not laid out twice.
    static func slots(
        count: Int,
        gaps: [CGFloat],
        keepsWithNext: [Bool],
        pageHeight: CGFloat,
        maximumPages: Int,
        height: (Int) -> CGFloat
    ) -> Layout {
        // The two arrays are always built from one list of units, and the look-ahead indexes into
        // both. Checked anyway: a crash inside an export is a far worse outcome than a document
        // that comes out as one page and says so.
        guard pageHeight > 1, maximumPages > 0,
              gaps.count == count, keepsWithNext.count == count else {
            return Layout(slots: [], pages: 1, truncated: count > 0)
        }

        var slots: [ExportSlot] = []
        var page = 0
        var used: CGFloat = 0
        var truncated = false

        func turn() {
            page += 1
            used = 0
        }

        for index in 0..<count {
            let tall = height(index)
            guard tall > 0.5 else { continue }
            guard page < maximumPages else {
                truncated = true
                break
            }

            // Taller than a page on its own: it starts on a fresh page and is sliced.
            if tall > pageHeight {
                if used > 0 { turn() }
                var offset: CGFloat = 0
                while offset < tall - 0.5 {
                    guard page < maximumPages else {
                        truncated = true
                        break
                    }
                    let take = min(pageHeight, tall - offset)
                    slots.append(
                        ExportSlot(unit: index, page: page, top: 0, offset: offset, height: take)
                    )
                    offset += take
                    if offset < tall - 0.5 { turn() } else { used = take }
                }
                if truncated { break }
                continue
            }

            var gap = used > 0 ? gaps[index] : 0
            if used > 0, used + gap + tall > pageHeight {
                turn()
                gap = 0
            } else if used > 0, keepsWithNext[index], index + 1 < count {
                // A heading at the foot of a page with its section overleaf is not a heading, and
                // a question with its answer on the next picture is half an exchange. A fifth of a
                // page of whatever follows has to fit beside it, or both move together.
                let follow = min(height(index + 1), pageHeight * 0.2)
                if used + gap + tall + gaps[index + 1] + follow > pageHeight {
                    turn()
                    gap = 0
                }
            }
            guard page < maximumPages else {
                truncated = true
                break
            }
            slots.append(
                ExportSlot(unit: index, page: page, top: used + gap, offset: 0, height: tall)
            )
            used += gap + tall
        }

        let last = slots.map(\.page).max() ?? 0
        return Layout(slots: slots, pages: last + 1, truncated: truncated)
    }
}

// MARK: - The format picker

/// The export screen: nine formats, grouped by the question the reader is actually answering, each
/// saying what it is *for*.
///
/// A `Menu` of nine file extensions asks the reader to already know which one they want, which is
/// what the owner meant by «مو مرتب نفس الموقع» — the website's export menu is a laid-out list with
/// an icon and a name per row, and a phone menu strip of `.docx / .xlsx / .pptx` is not that. This
/// is a sheet, so a row has room for its own sentence.
///
/// Presented by whoever owns the toolbar; it decides nothing and holds nothing.
@MainActor
struct ExportFormatPicker: View {

    private let lang: AppLanguage
    private let palette: FirasPalette
    private let isWorking: Bool
    private let onPick: (ExportController.Format) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        lang: AppLanguage,
        palette: FirasPalette,
        isWorking: Bool = false,
        onPick: @escaping (ExportController.Format) -> Void
    ) {
        self.lang = lang
        self.palette = palette
        self.isWorking = isWorking
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ExportController.Format.Family.allCases) { family in
                    Section {
                        ForEach(formats(in: family)) { format in
                            row(format)
                        }
                    } header: {
                        Text(family.title(lang))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textMuted)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text(Strings.Chat.exportAs(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Strings.Common.cancel(lang)) { dismiss() }
                }
                // A long document takes a few seconds to set. Every row is disabled while it does,
                // and a row that has gone grey with nothing else on screen reads as broken.
                ToolbarItem(placement: .topBarLeading) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(palette.accent)
                    }
                }
            }
        }
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }

    private func formats(in family: ExportController.Format.Family) -> [ExportController.Format] {
        ExportController.Format.allCases.filter { $0.family == family }
    }

    private func row(_ format: ExportController.Format) -> some View {
        Button {
            Haptics.select()
            onPick(format)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: format.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.accent)
                    .frame(width: 26, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(format.label(lang))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text(format.detail(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(Text(format.label(lang)))
        .accessibilityHint(Text(format.detail(lang)))
    }
}

// MARK: - The writers' input

/// What a writer is given: one answer, or a whole conversation.
///
/// A file-scope enum and not a nested one, because it crosses into a detached task and must carry
/// no actor isolation with it. `ChatConversation` is `Sendable`, so the thread travels by value and
/// cannot be mutated underneath the writer that is halfway through it.
enum ExportBuildInput: Sendable {
    case document(String)
    case conversation(ChatConversation, AppLanguage)

    var isConversation: Bool {
        if case .conversation = self { return true }
        return false
    }

    func language(fallback: AppLanguage) -> AppLanguage {
        switch self {
        case .document: return fallback
        case .conversation(_, let lang): return lang
        }
    }

    /// The document as markdown, for the two formats that hand it to SwiftUI — **LaTeX intact**.
    /// They typeset what they are given; flattening it first is throwing the equations away on the
    /// way to the one place that could have drawn them. Everything else takes `blocks` or
    /// `streamText` instead and never builds this.
    var renderedMarkdown: String {
        switch self {
        case .document(let markdown):
            return markdown
        case .conversation(let conversation, let lang):
            return ExportTranscript.markdown(conversation, lang: lang)
        }
    }

    /// The answers' own markdown, for the pass that asks the island to draw their equations. A
    /// question never carries mathematics and a transcript's headings never do either, so neither
    /// is worth scanning.
    var mathSources: [String] {
        switch self {
        case .document(let markdown):
            return [markdown]
        case .conversation(let conversation, let lang):
            var out: [String] = []
            ExportTranscript.forEachTurn(conversation, lang: lang) { turn in
                guard !turn.isQuestion else { return }
                out.append(turn.body)
            }
            return out
        }
    }

    /// The turns the picture draws: a question in its own box, an answer typeset under it. A single
    /// answer is one block with no question above it — the caller that has one puts the question in
    /// the title.
    var cardTurns: [ExportCardTurn] {
        switch self {
        case .document(let markdown):
            return [ExportCardTurn(id: "a", isQuestion: false, text: markdown)]
        case .conversation(let conversation, let lang):
            var out: [ExportCardTurn] = []
            var index = 0
            ExportTranscript.forEachTurn(conversation, lang: lang) { turn in
                index += 1
                // A question is set as one plain paragraph in its own box — its markdown furniture
                // would fight the box. An answer keeps its markdown *and its LaTeX*, because the
                // picture typesets it exactly as the chat does.
                let text = turn.isQuestion
                    ? ExportText.plain(turn.body).trimmingCharacters(in: .whitespacesAndNewlines)
                    : turn.body
                guard !text.isEmpty else { return }
                out.append(
                    ExportCardTurn(id: String(index), isQuestion: turn.isQuestion, text: text)
                )
            }
            return out
        }
    }

    /// The document as ordered blocks — one turn at a time for a conversation, so a long thread is
    /// parsed in pieces and no `$…$` can pair across two answers.
    var blocks: [ExportBlock] {
        switch self {
        case .document(let markdown):
            return ExportMarkdown.blocks(from: markdown)
        case .conversation(let conversation, let lang):
            return ExportTranscript.blocks(conversation, lang: lang)
        }
    }

    /// The document as text, chunk by chunk. The header first, then one chunk per turn, so a
    /// three-hundred-turn thread reaches the file without ever existing whole in memory.
    func streamText(plain: Bool, _ emit: (String) throws -> Void) rethrows {
        switch self {
        case .document(let markdown):
            // `.md` and `.txt` are the two formats with nothing to typeset with, so this is where
            // an answer's equations become readable symbols.
            let flattened = ExportText.flattenMath(markdown)
            try emit(plain ? ExportText.plain(flattened) : flattened)
        case .conversation(let conversation, let lang):
            try ExportTranscript.stream(conversation, lang: lang) { chunk in
                let flattened = ExportText.flattenMath(chunk)
                try emit(plain ? ExportText.plain(flattened) : flattened)
            }
        }
    }
}

/// Every text and Office format, built off the main actor: a 200-page document is a megabyte of XML
/// to assemble and none of it belongs on the thread that is drawing the spinner.
///
/// A free function taking the format's raw name, not a member taking `Format`: it runs inside a
/// detached task and must carry none of the controller's main-actor isolation with it.
private func exportBuildDocument(
    kind: String,
    input: ExportBuildInput,
    title: String,
    to url: URL
) -> Bool {
    switch kind {
    case "markdown":
        return exportStreamText(input, plain: false, to: url)
    case "text":
        return exportStreamText(input, plain: true, to: url)
    case "html":
        return exportWriteText(ExportWeb.document(title: title, blocks: input.blocks), to: url)
    case "csv":
        let sheets = ExportSheets.sheets(
            title: title,
            blocks: input.blocks,
            outlineName: title,
            mode: input.isConversation ? .transcript : .document
        )
        return exportWriteText(ExportSheets.csv(sheets: sheets), to: url)
    case "docx":
        return ExportWord.write(title: title, blocks: input.blocks, to: url)
    case "xlsx":
        let sheets = ExportSheets.sheets(
            title: title,
            blocks: input.blocks,
            outlineName: title,
            mode: input.isConversation ? .transcript : .document
        )
        return ExportSheets.write(title: title, sheets: sheets, to: url)
    case "pptx":
        let slides = ExportSlides.slides(title: title, blocks: input.blocks)
        return ExportSlides.write(title: title, slides: slides, to: url)
    default:
        return false
    }
}

/// Writes the document a chunk at a time. The file handle is the buffer: nothing here concatenates.
private func exportStreamText(_ input: ExportBuildInput, plain: Bool, to url: URL) -> Bool {
    let manager = FileManager.default
    try? manager.removeItem(at: url)
    guard manager.createFile(atPath: url.path, contents: nil) else { return false }
    do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try input.streamText(plain: plain) { chunk in
            guard !chunk.isEmpty else { return }
            try handle.write(contentsOf: Data(chunk.utf8))
        }
        return true
    } catch {
        Log.ui.error("export stream failed: \(String(describing: error), privacy: .public)")
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

// MARK: - Copy

/// No web twin: a browser's print dialogue has no page ceiling to report.
enum ExportPaperCopy {
    static let tooLong = LText(
        ar: "المستند أطول من %@ صفحة، فتوقّف الملف عندها — نزّل الصيغة النصية أو Word لقراءته كاملًا.",
        en: "The document ran past %@ pages, so the file stops there — export the text or the Word document to read all of it."
    )
}

/// `imgCardQ` and `imgCardTrimmed` from the web STR table, verbatim.
enum ExportPictureCopy {
    static let question = LText(ar: "السؤال", en: "Question")
    static let trimmed = LText(
        ar: "الصورة طويلة فظهرت مقصوصة — نزّل المحادثة بصيغة PDF لقراءتها كاملة.",
        en: "The picture was too long and is clipped here — export the PDF to read it in full."
    )
}
