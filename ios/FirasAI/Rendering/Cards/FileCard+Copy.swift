import SwiftUI

/// Everything a file card says, and the per-format facts behind it.

// MARK: - Formats

/// The formats the site can make (`fileFormatMeta`, `app.js:3010`) plus the two the app's own
/// exporter adds. A format outside this list is a plate that says the file cannot be opened here,
/// which is honest; a wrong icon is not.
enum FileCardKind {

    static func isKnown(_ format: String) -> Bool {
        !normalised(format).isEmpty
    }

    static func symbol(_ format: String) -> String {
        switch normalised(format) {
        case "pdf": return "doc.richtext"
        case "docx": return "doc.text"
        case "xlsx": return "tablecells"
        case "pptx": return "rectangle.on.rectangle"
        case "csv": return "list.bullet.rectangle"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "md": return "doc.plaintext"
        case "txt": return "doc"
        default: return "doc"
        }
    }

    static func label(_ format: String) -> LText {
        switch normalised(format) {
        case "pdf": return FileCardCopy.labelPdf
        case "docx": return FileCardCopy.labelDocx
        case "xlsx": return FileCardCopy.labelXlsx
        case "pptx": return FileCardCopy.labelPptx
        case "csv": return FileCardCopy.labelCsv
        case "html": return FileCardCopy.labelHtml
        case "md": return FileCardCopy.labelMarkdown
        case "txt": return FileCardCopy.labelText
        default: return FileCardCopy.labelGeneric
        }
    }

    /// The web's `fileName*` fallbacks, verbatim.
    static func fallbackName(_ format: String) -> String {
        switch normalised(format) {
        case "pdf": return "firas-document.pdf"
        case "docx": return "firas-document.docx"
        case "xlsx": return "firas-data.xlsx"
        case "pptx": return "firas-presentation.pptx"
        case "csv": return "firas-data.csv"
        case "html": return "firas-document.html"
        case "md": return "firas-document.md"
        case "txt": return "firas-document.txt"
        default: return "firas-document"
        }
    }

    /// What a file of this format is counted in: pages, sheets or slides.
    static func unit(_ count: Int, format: String, lang: AppLanguage) -> String {
        switch normalised(format) {
        case "pptx":
            return ArabicPlurals.count(
                count, lang,
                zero: FileCardCopy.slidesZero, one: FileCardCopy.slidesOne,
                two: FileCardCopy.slidesTwo, few: FileCardCopy.slidesFew,
                many: FileCardCopy.slidesMany, other: FileCardCopy.slidesOther
            )
        case "xlsx", "csv":
            return ArabicPlurals.count(
                count, lang,
                zero: FileCardCopy.sheetsZero, one: FileCardCopy.sheetsOne,
                two: FileCardCopy.sheetsTwo, few: FileCardCopy.sheetsFew,
                many: FileCardCopy.sheetsMany, other: FileCardCopy.sheetsOther
            )
        default:
            return ArabicPlurals.count(
                count, lang,
                zero: FileCardCopy.pagesZero, one: FileCardCopy.pagesOne,
                two: FileCardCopy.pagesTwo, few: FileCardCopy.pagesFew,
                many: FileCardCopy.pagesMany, other: FileCardCopy.pagesOther
            )
        }
    }

    /// `word`, `.PDF`, `xls` and friends folded onto the eight names above; `""` when unknown.
    static func normalised(_ format: String) -> String {
        var raw = format.trimmingCharacters(in: .whitespaces).lowercased()
        while raw.hasPrefix(".") { raw.removeFirst() }
        switch raw {
        case "pdf": return "pdf"
        case "docx", "doc", "word": return "docx"
        case "xlsx", "xls", "excel": return "xlsx"
        case "pptx", "ppt", "powerpoint": return "pptx"
        case "csv": return "csv"
        case "html", "htm": return "html"
        case "md", "markdown": return "md"
        case "txt", "text": return "txt"
        default: return ""
        }
    }

    /// `340 كيلوبايت`, `١٫٤ ميغابايت`. Latin digits in English, Arabic-Indic in Arabic, and the
    /// number is wrapped as one left-to-right atom so it cannot be split by the text around it.
    static func size(_ bytes: Int, lang: AppLanguage) -> String {
        guard bytes > 0 else { return "" }
        if bytes < 1_024 {
            return ArabicText.count(bytes, lang) + " " + FileCardCopy.unitBytes(lang)
        }
        if bytes < 1_024 * 1_024 {
            let kilobytes = max(1, Int((Double(bytes) / 1_024).rounded()))
            return ArabicText.count(kilobytes, lang) + " " + FileCardCopy.unitKilobytes(lang)
        }
        let tenths = max(1, Int((Double(bytes) / (1_024 * 1_024) * 10).rounded()))
        let whole = tenths / 10
        let fraction = tenths % 10
        let separator = lang == .arabic ? "\u{066B}" : "."
        let number = fraction == 0
            ? ArabicText.count(whole, lang)
            : ArabicText.count(whole, lang) + separator + ArabicText.count(fraction, lang)
        return number + " " + FileCardCopy.unitMegabytes(lang)
    }
}

// MARK: - Derived card text

extension FileCard {

    /// The AI-chosen name (`resolveFileName`, `app.js:30333`), falling back to the title and then
    /// to the web's own generic name for the format.
    var displayName: String {
        if let name = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let extensionName = FileCardKind.normalised(meta.format)
            return extensionName.isEmpty ? title : title + "." + extensionName
        }
        return FileCardKind.fallbackName(meta.format)
    }

    /// `مستند PDF · ١٢ صفحة · ٣٤٠ كيلوبايت`.
    var factsLine: String {
        var parts: [String] = [FileCardKind.label(meta.format)(lang)]
        if let pages = meta.pages, pages > 0 {
            parts.append(FileCardKind.unit(pages, format: meta.format, lang: lang))
        }
        if let sizeBytes, sizeBytes > 0 {
            parts.append(isolated(FileCardKind.size(sizeBytes, lang: lang)))
        }
        if let subtitle = meta.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty, parts.count < 3 {
            parts.append(subtitle)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The stage sentence. A client-side pipeline stage wins; otherwise the durable long file's own
    /// stage word (`app.js:41348`), whose planning line also covers `queued` — that is the work the
    /// server is about to start.
    var stageText: String {
        if let stage { return stage.label(lang) }
        switch (progress?.stage ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "writing": return FileCardCopy.longWriting(lang)
        case "qa": return FileCardCopy.longReviewing(lang)
        default: return FileCardCopy.longPlanning(lang)
        }
    }

    /// The page being written right now, when the server names it.
    var workingSubtitle: String {
        guard let title = progress?.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return "" }
        return title
    }

    var pagesDone: Int { max(0, progress?.pagesDone ?? 0) }

    var pagesTotal: Int {
        guard let progress else { return 0 }
        if progress.pagesTotal > 0 { return progress.pagesTotal }
        return progress.targetPages > 0 ? progress.targetPages : 0
    }

    /// `nil` when there is nothing honest to draw — an indeterminate stage gets the activity label
    /// and no bar, never a bar frozen at zero.
    var fraction: Double? {
        guard let progress else { return nil }
        if progress.percent > 0 { return min(1, Double(progress.percent) / 100) }
        guard pagesTotal > 0, pagesDone > 0 else { return nil }
        return min(1, Double(pagesDone) / Double(pagesTotal))
    }

    var counterText: String {
        guard pagesTotal > 0 else { return ArabicText.count(pagesDone, lang) }
        return ArabicText.count(pagesDone, lang) + " / " + ArabicText.count(pagesTotal, lang)
    }

    var percentText: String {
        let value = ArabicText.count(Int(((fraction ?? 0) * 100).rounded()), lang)
        return lang == .arabic ? value + "\u{066A}" : value + "%"
    }

    /// One left-to-right atom inside an Arabic line (`U+2066 … U+2069`).
    private func isolated(_ value: String) -> String {
        guard lang == .arabic, !value.isEmpty else { return value }
        return "\u{2066}" + value + "\u{2069}"
    }
}

// MARK: - Copy

/// `web-chat-ux.md` Appendix A (`fileReady`, `fileDownload`, `fileLabel*`, `fileName*`) and §8.4
/// (`fileCreating`, `fileStageText`) — Arabic verbatim. The long-file stage lines are
/// `app.js:41348`. Everything else is marked **[new]**: the web has no file card with an Open, a
/// Save-to-Files or a size on it, because a browser has no Files app to save into.
enum FileCardCopy {
    static let ready = LText(ar: "الملف جاهز", en: "File ready")
    static let download = LText(ar: "تنزيل", en: "Download")
    /// **[new]**
    static let open = LText(ar: "افتح", en: "Open")
    /// **[new]**
    static let saveToFiles = LText(ar: "حفظ في الملفات", en: "Save to Files")
    /// **[new]**
    static let stopping = LText(ar: "يُوقف…", en: "Stopping…")
    static let unavailable = LText(
        ar: "هذا الملف غير متاح للفتح هنا.",
        en: "This file cannot be opened here."
    )

    static let labelPdf = LText(ar: "مستند PDF", en: "PDF document")
    static let labelDocx = LText(ar: "مستند Word", en: "Word document")
    static let labelXlsx = LText(ar: "جدول Excel", en: "Excel spreadsheet")
    static let labelPptx = LText(ar: "عرض PowerPoint", en: "PowerPoint slides")
    static let labelCsv = LText(ar: "ملف CSV", en: "CSV file")
    /// **[new]** — the web's `downloadHtml` / `downloadMarkdown` / `downloadText` labels, reused.
    static let labelHtml = LText(ar: "صفحة HTML", en: "HTML page")
    static let labelMarkdown = LText(ar: "ملف Markdown", en: "Markdown file")
    static let labelText = LText(ar: "نص عادي (TXT)", en: "Plain text (TXT)")
    static let labelGeneric = LText(ar: "ملف", en: "File")

    static let stageCreating = LText(ar: "جاري إنشاء الملف…", en: "Creating your file…")
    static let stageExtract = LText(
        ar: "يقرأ الصورة ويستخرج كل المحتوى…",
        en: "Reading the image & extracting everything…"
    )
    static let stagePlan = LText(ar: "يخطّط لهيكل الملف…", en: "Planning the file…")
    static let stageContent = LText(ar: "يكتب المحتوى…", en: "Writing the content…")
    static let stageValidate = LText(
        ar: "يراجع الدقة والبنية والمعادلات…",
        en: "Checking accuracy, structure & equations…"
    )
    static let stageAssemble = LText(ar: "يجمّع ويُخرج باحتراف…", en: "Assembling & polishing…")

    static let longPlanning = LText(ar: "يخطط هيكل الملف…", en: "Planning the file's structure…")
    static let longWriting = LText(ar: "يكتب صفحات الملف…", en: "Writing the file's pages…")
    static let longReviewing = LText(
        ar: "يراجع ويجمّع الملف…",
        en: "Reviewing and assembling the file…"
    )

    static let pagesZero = LText(ar: "بلا صفحات", en: "%ld pages")
    static let pagesOne = LText(ar: "صفحة واحدة", en: "%ld page")
    static let pagesTwo = LText(ar: "صفحتان", en: "%ld pages")
    static let pagesFew = LText(ar: "%ld صفحات", en: "%ld pages")
    static let pagesMany = LText(ar: "%ld صفحة", en: "%ld pages")
    static let pagesOther = LText(ar: "%ld صفحة", en: "%ld pages")

    /// **[new]** — a deck is counted in slides, not pages.
    static let slidesZero = LText(ar: "بلا شرائح", en: "%ld slides")
    static let slidesOne = LText(ar: "شريحة واحدة", en: "%ld slide")
    static let slidesTwo = LText(ar: "شريحتان", en: "%ld slides")
    static let slidesFew = LText(ar: "%ld شرائح", en: "%ld slides")
    static let slidesMany = LText(ar: "%ld شريحة", en: "%ld slides")
    static let slidesOther = LText(ar: "%ld شريحة", en: "%ld slides")

    /// **[new]** — a workbook is counted in sheets.
    static let sheetsZero = LText(ar: "بلا أوراق", en: "%ld sheets")
    static let sheetsOne = LText(ar: "ورقة واحدة", en: "%ld sheet")
    static let sheetsTwo = LText(ar: "ورقتان", en: "%ld sheets")
    static let sheetsFew = LText(ar: "%ld أوراق", en: "%ld sheets")
    static let sheetsMany = LText(ar: "%ld ورقة", en: "%ld sheets")
    static let sheetsOther = LText(ar: "%ld ورقة", en: "%ld sheets")

    /// **[new]**
    static let unitBytes = LText(ar: "بايت", en: "bytes")
    static let unitKilobytes = LText(ar: "كيلوبايت", en: "KB")
    static let unitMegabytes = LText(ar: "ميغابايت", en: "MB")
}
