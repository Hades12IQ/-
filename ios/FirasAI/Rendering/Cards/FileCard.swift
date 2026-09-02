import SwiftUI

/// The ```` ```firas-file ```` deliverable card (`web-chat-ux.md §8.5`,
/// `server-chat-jobs-chats.md §4.3`).
///
/// Three states, all real: the streaming loader while the answer is still being written (one line
/// per pipeline stage), the ready card (format glyph, AI-chosen filename, format label, page count,
/// an Open target and a Download button), and a muted plate when the fence named a format this
/// build cannot open.
struct FileCard: View {

    /// The document pipeline's stages (`web-chat-ux.md §8.4`, `fileStageText`). `creating` is the
    /// generic label the web shows before the first stage arrives.
    enum Stage: String, Sendable, Equatable, CaseIterable {
        case creating
        case extract
        case plan
        case content
        case validate
        case assemble

        var label: LText {
            switch self {
            case .creating: return FileCardCopy.stageCreating
            case .extract: return FileCardCopy.stageExtract
            case .plan: return FileCardCopy.stagePlan
            case .content: return FileCardCopy.stageContent
            case .validate: return FileCardCopy.stageValidate
            case .assemble: return FileCardCopy.stageAssemble
            }
        }

        /// The server's stage word, whatever case it arrives in.
        init(raw: String) {
            self = Stage(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .creating
        }
    }

    private let meta: FileMeta
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let stage: Stage?
    private let motionOn: Bool
    private let onOpen: (() -> Void)?
    private let onExport: (() -> Void)?

    init(
        meta: FileMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        stage: Stage? = nil,
        motionOn: Bool = true,
        onOpen: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.stage = stage
        self.motionOn = motionOn
        self.onOpen = onOpen
        self.onExport = onExport
    }

    var body: some View {
        content
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let stage {
            loading(stage)
        } else if meta.format.isEmpty {
            unavailable
        } else {
            ready
        }
    }

    // MARK: - Ready

    private var ready: some View {
        HStack(spacing: 12) {
            glyph
            details
            Spacer(minLength: 8)
            downloadButton
        }
        .padding(12)
        .frame(minHeight: 72)
        .surfaceCard(palette)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(FileCardCopy.ready(lang) + " — " + displayName))
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(palette.accent)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accentSoft)
            )
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(subtitleLine)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: subtitleLine, fallback: lang)
    }

    @ViewBuilder
    private var downloadButton: some View {
        if let onExport {
            Button(action: onExport) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(FileCardCopy.download(lang))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(palette.accent))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(FileCardCopy.download(lang)))
        }
    }

    // MARK: - Loading

    private func loading(_ stage: Stage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(palette.textMuted)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
                )
                .accessibilityHidden(true)

            FirasActivityLabel(
                text: stage.label(lang),
                palette: palette,
                motionOn: motionOn
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: stage.label(lang), fallback: lang)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minHeight: 72)
        .surfaceCard(palette)
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 18))
                .foregroundStyle(palette.textMuted)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
                )
                .accessibilityHidden(true)

            Text(FileCardCopy.unavailable(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: FileCardCopy.unavailable(lang), fallback: lang)
        }
        .padding(12)
        .frame(minHeight: 72)
        .surfaceCard(palette)
    }

    // MARK: - Derived

    private var format: String { meta.format.lowercased() }

    private var symbol: String {
        switch format {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text"
        case "xlsx", "xls": return "tablecells"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "csv": return "list.bullet.rectangle"
        default: return "doc"
        }
    }

    private var displayName: String {
        if let name = meta.name, !name.isEmpty { return name }
        if let title = meta.title, !title.isEmpty { return title }
        switch format {
        case "pdf": return "firas-document.pdf"
        case "docx", "doc": return "firas-document.docx"
        case "xlsx", "xls": return "firas-data.xlsx"
        case "pptx", "ppt": return "firas-presentation.pptx"
        case "csv": return "firas-data.csv"
        default: return "firas-document"
        }
    }

    private var formatLabel: String {
        switch format {
        case "pdf": return FileCardCopy.labelPdf(lang)
        case "docx", "doc": return FileCardCopy.labelDocx(lang)
        case "xlsx", "xls": return FileCardCopy.labelXlsx(lang)
        case "pptx", "ppt": return FileCardCopy.labelPptx(lang)
        case "csv": return FileCardCopy.labelCsv(lang)
        default: return format.uppercased()
        }
    }

    private var subtitleLine: String {
        var parts: [String] = [formatLabel]
        if let pages = meta.pages, pages > 0 {
            parts.append(
                ArabicPlurals.count(
                    pages,
                    lang,
                    zero: FileCardCopy.pagesZero,
                    one: FileCardCopy.pagesOne,
                    two: FileCardCopy.pagesTwo,
                    few: FileCardCopy.pagesFew,
                    many: FileCardCopy.pagesMany,
                    other: FileCardCopy.pagesOther
                )
            )
        }
        if let subtitle = meta.subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Copy

/// `web-chat-ux.md` Appendix A (`fileReady`, `fileDownload`, `fileLabel*`) and §8.4
/// (`fileCreating`, `fileStageText`) — Arabic verbatim. The stage lines have no published English
/// twin in the report, so the English here is a faithful translation of the Arabic.
private enum FileCardCopy {
    static let ready = LText(ar: "الملف جاهز", en: "File ready")
    static let download = LText(ar: "تنزيل", en: "Download")
    static let unavailable = LText(
        ar: "هذا الملف غير متاح للفتح هنا.",
        en: "This file cannot be opened here."
    )

    static let labelPdf = LText(ar: "مستند PDF", en: "PDF document")
    static let labelDocx = LText(ar: "مستند Word", en: "Word document")
    static let labelXlsx = LText(ar: "جدول Excel", en: "Excel spreadsheet")
    static let labelPptx = LText(ar: "عرض PowerPoint", en: "PowerPoint slides")
    static let labelCsv = LText(ar: "ملف CSV", en: "CSV file")

    static let stageCreating = LText(ar: "جاري إنشاء الملف…", en: "Creating your file…")
    static let stageExtract = LText(
        ar: "يقرأ الصورة ويستخرج كل المحتوى…",
        en: "Reading the image and pulling out every piece of content…"
    )
    static let stagePlan = LText(ar: "يخطّط لهيكل الملف…", en: "Planning the file's structure…")
    static let stageContent = LText(ar: "يكتب المحتوى…", en: "Writing the content…")
    static let stageValidate = LText(
        ar: "يراجع الدقة والبنية والمعادلات…",
        en: "Checking accuracy, structure and equations…"
    )
    static let stageAssemble = LText(ar: "يجمّع ويُخرج باحتراف…", en: "Assembling and exporting…")

    static let pagesZero = LText(ar: "بلا صفحات", en: "%ld pages")
    static let pagesOne = LText(ar: "صفحة واحدة", en: "%ld page")
    static let pagesTwo = LText(ar: "صفحتان", en: "%ld pages")
    static let pagesFew = LText(ar: "%ld صفحات", en: "%ld pages")
    static let pagesMany = LText(ar: "%ld صفحة", en: "%ld pages")
    static let pagesOther = LText(ar: "%ld صفحة", en: "%ld pages")
}
