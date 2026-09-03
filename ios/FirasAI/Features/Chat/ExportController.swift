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
/// turn at a time; the Office formats parse a turn at a time; only the two *rendered* formats — the
/// PDF and the picture, which hand the document to SwiftUI — need it whole, and the picture is
/// bounded so a three-hundred-turn thread cannot ask for a bitmap nobody has memory for.
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
        case .pdf:
            wrote = writePDF(input: input, title: heading, to: url)
        case .image:
            wrote = writePicture(input: input, title: heading, to: url)
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

        let export = Export(url: url, format: format, byteCount: ExportText.byteCount(of: url))
        if publish {
            result = export
            Haptics.select()
        }
        return export
    }

    /// The source, checked for emptiness and reduced to the `Sendable` value the writers take.
    /// `nil` means there is nothing to export, which is the web's `exportEmpty`.
    private func buildInput(for source: Source) -> ExportBuildInput? {
        switch source {
        case .document(let markdown):
            // A single answer is flattened here, once: it is one message, so no delimiter can
            // reach past it. A conversation is flattened per turn instead — see ExportTranscript.
            let flattened = ExportText.flattenMath(markdown)
            guard !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .document(flattened)

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

    /// A rendered export is one SwiftUI view, and it is not laid out left to right because the
    /// shell is: an Arabic document reads right to left, with `MarkdownView`'s per-block islands
    /// keeping code, URLs and equations running the other way inside it.
    @ViewBuilder
    private func documentView(
        markdown: String,
        title: String,
        lang: AppLanguage,
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
                    .bidiIsland(for: title, fallback: lang)
            }
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
        }
        .frame(width: width, alignment: .leading)
        .padding(paintsBackground ? 24 : 0)
        .background(paintsBackground ? palette.background : Color.clear)
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }

    /// A4 at 72 dpi with a 36 pt margin, paginated by translating the same rendered content up one
    /// usable page height per page.
    private func writePDF(input: ExportBuildInput, title: String, to url: URL) -> Bool {
        let messageID = "firas-export-" + UUID().uuidString
        defer {
            MarkdownRenderer.invalidate(messageID: messageID)
            MathBlockView.invalidate(messageID: messageID)
        }

        let pageSize = CGSize(width: 595, height: 842)
        /* 36 pt is half an inch, and at that width a line of Arabic sits against the edge of
           the sheet with nothing to breathe into — which is what a printed page looks like when
           it looks wrong. 56 pt is close to the two-centimetre margin a document is normally set
           with. Everything below derives from this, so the pagination follows it. */
        let margin: CGFloat = 56
        let usableWidth = pageSize.width - margin * 2
        let usableHeight = pageSize.height - margin * 2

        // The heading is already the transcript's own `# title`, so a conversation does not get it
        // printed twice; a single answer has no title of its own and keeps the one it was given.
        let content = documentView(
            markdown: input.renderedMarkdown,
            title: input.isConversation ? "" : title,
            lang: input.language(fallback: env.prefs.lang),
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

    /// The picture the web calls `exportImage` — a branded card, not a screenshot.
    ///
    /// The composition is the site's: the mark and the wordmark on top, the question in its own
    /// tinted block under the label «السؤال», then the answer, on a 720-point white sheet with no
    /// footer — the site removed its own footer deliberately, because a shared page is the reader's
    /// and not an advertisement. A whole conversation repeats that block per turn.
    ///
    /// It is drawn into a bitmap this file sizes rather than into `ImageRenderer.uiImage`, because
    /// `uiImage` will happily try to allocate whatever the content asks for: a long thread would be
    /// a hundred-megapixel request that fails as "that format is unavailable" on the device where
    /// it matters most.
    private func writePicture(input: ExportBuildInput, title: String, to url: URL) -> Bool {
        let messageID = "firas-export-" + UUID().uuidString
        let lang = input.language(fallback: env.prefs.lang)
        let turns = input.cardTurns
        // Every id the card hands to a `MarkdownView`, including the per-turn ones: a cache slot
        // keyed on an export that has already been written is a leak nothing will ever read.
        defer {
            for id in [messageID] + turns.map({ messageID + "-" + $0.id }) {
                MarkdownRenderer.invalidate(messageID: id)
                MathBlockView.invalidate(messageID: id)
            }
        }

        let palette = exportPalette
        let card = ExportCard(
            title: title,
            turns: turns,
            lang: lang,
            palette: palette,
            prefs: env.prefs,
            messageID: messageID
        )

        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: ExportCard.width, height: nil)

        var wrote = false
        var clipped = false
        renderer.render { size, draw in
            guard size.width > 0, size.height > 0, size.height.isFinite else { return }
            let ceiling = ExportCard.heightCeiling
            let tall = min(size.height, ceiling)
            clipped = size.height > ceiling + 1
            // @2x for a card that fits on a screen or two; a long one drops to @1x, because the
            // bitmap is the memory and doubling both axes quadruples it.
            let scale: CGFloat = (size.width * tall) > 1_400_000 ? 1 : 2
            let pixelWidth = Int((size.width * scale).rounded())
            let pixelHeight = Int((tall * scale).rounded())
            guard pixelWidth > 0, pixelHeight > 0 else { return }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            guard let bitmap = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }

            bitmap.setFillColor(UIColor.white.cgColor)
            bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            bitmap.scaleBy(x: scale, y: scale)
            // `draw` puts content row 0 at y = size.height in a bottom-left origin. Move the top of
            // the card to the top of the bitmap, so a clipped card loses its foot and not its head.
            bitmap.translateBy(x: 0, y: tall - size.height)
            draw(bitmap)

            guard let image = bitmap.makeImage(),
                  let data = UIImage(cgImage: image).pngData() else { return }
            do {
                try data.write(to: url, options: .atomic)
                wrote = true
            } catch {
                Log.ui.error("export png failed: \(String(describing: error), privacy: .public)")
            }
        }

        if wrote, clipped {
            // The web's `imgCardTrimmed` said the same thing about a single block that would not
            // fit; this says it about a thread that will not. Either way the reader is told, and
            // told which format does hold the rest — a silent crop is the version nobody forgives.
            env.toasts.show(ExportPictureCopy.trimmed(lang))
        }
        return wrote
    }
}

// MARK: - The picture

/// The branded card an image export photographs — the web's `.imgcard`.
///
/// White sheet, 720 points wide, the mark and `Firas AI` across the top, then one block per turn:
/// the question under its own label in a tinted box, the answer as the document it is. No footer,
/// no date, no site — the same decision the web made when it deleted its own.
private struct ExportCard: View {

    static let width: CGFloat = 720
    /// 720 × 16 000 points is an eleven-megapixel bitmap at @1x, which is the most a phone should
    /// be asked to encode as a PNG. Past it the card is clipped and the reader is told.
    static let heightCeiling: CGFloat = 16_000

    let title: String
    let turns: [ExportCardTurn]
    let lang: AppLanguage
    let palette: FirasPalette
    let prefs: PreferencesStore
    let messageID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: title, fallback: lang)
            }
            ForEach(turns) { turn in
                if turn.isQuestion {
                    question(turn)
                } else {
                    answer(turn)
                }
            }
        }
        .frame(width: ExportCard.width, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .background(Color.white)
        .environment(
            \.layoutDirection,
            lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            FirasBrandMark(size: 24, palette: palette)
            Text(verbatim: "Firas AI")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .forceLTR()
            Spacer(minLength: 0)
        }
    }

    private func question(_ turn: ExportCardTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ExportPictureCopy.question(lang))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(turn.text)
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
        .bidiIsland(for: turn.text, fallback: lang)
    }

    private func answer(_ turn: ExportCardTurn) -> some View {
        MarkdownView(
            markdown: turn.text,
            messageID: messageID + "-" + turn.id,
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

/// One block of the picture: a question to set in its own box, or an answer to typeset.
struct ExportCardTurn: Identifiable, Sendable, Equatable {
    let id: String
    let isQuestion: Bool
    let text: String
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

    /// The document as markdown, for the two formats that hand it to SwiftUI. Everything else takes
    /// `blocks` or `stream` instead and never builds this.
    var renderedMarkdown: String {
        switch self {
        case .document(let markdown):
            return markdown
        case .conversation(let conversation, let lang):
            return ExportTranscript.markdown(conversation, lang: lang)
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
                // would fight the box. An answer is typeset, because that is the document.
                let text = turn.isQuestion
                    ? ExportText.plain(turn.body).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ExportText.flattenMath(turn.body)
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
            try emit(plain ? ExportText.plain(markdown) : markdown)
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

/// `imgCardQ` and `imgCardTrimmed` from the web STR table, verbatim.
enum ExportPictureCopy {
    static let question = LText(ar: "السؤال", en: "Question")
    static let trimmed = LText(
        ar: "الصورة طويلة فظهرت مقصوصة — نزّل المحادثة بصيغة PDF لقراءتها كاملة.",
        en: "The picture was too long and is clipped here — export the PDF to read it in full."
    )
}
