import Foundation

/// One block of a document, as markup.
///
/// The direction decision lives here rather than on the document, because that is the whole point:
/// an English paragraph inside an Arabic paper keeps its own direction and its own bullet side, and
/// a code listing is left to right whatever surrounds it. A block with no strong character in it —
/// a row of numbers, a bare formula — inherits the document's language rather than flipping to
/// Latin, which is the mistake the Word writer made for months.
extension DocumentHTML {

    static func html(for block: MDBlock, lang: AppLanguage, template: DocTemplate) -> String {
        switch block {
        case .paragraph(let text):
            return paragraph(text, lang: lang)

        case .heading(let level, let text):
            return heading(level: level, text, lang: lang)

        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items, lang: lang, template: template)

        case .quote(let blocks):
            var inner = ""
            for child in blocks { inner += html(for: child, lang: lang, template: template) }
            return "<blockquote class=\"doc-quote\">\n" + inner + "</blockquote>\n"

        case .table(let header, let rows):
            return table(header: header, rows: rows, lang: lang)

        case .code(let language, let source):
            return code(language: language, source: source)

        case .rule:
            return "<hr class=\"doc-rule\">\n"

        case .mathDisplay(let tex):
            return math(tex, display: true)

        case .fence(let fence):
            return fenceBlock(fence, lang: lang)

        case .raw(let text):
            return paragraph(AttributedString(text), lang: lang)
        }
    }

    // MARK: - Text

    /// A paragraph, with its inline equations left as `data-tex` for KaTeX to draw in place.
    private static func paragraph(_ text: AttributedString, lang: AppLanguage) -> String {
        let plain = String(text.characters)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "<p class=\"doc-p\"" + dir(plain, lang: lang) + ">" + inline(plain) + "</p>\n"
    }

    /// Headings two and three carry the anchor the contents page points at. The counter is shared
    /// with `tableOfContents` by construction: both walk the same block list in the same order.
    private static func heading(level: Int, _ text: AttributedString, lang: AppLanguage) -> String {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "" }
        let clamped = min(max(level, 1), 6)
        var anchor = ""
        if clamped >= 2, clamped <= 3 {
            headingCount += 1
            anchor = " id=\"h\(headingCount)\""
        }
        return "<h\(clamped) class=\"doc-h doc-h--\(clamped)\"" + anchor + dir(plain, lang: lang) + ">"
            + inline(plain) + "</h\(clamped)>\n"
    }

    /// Counts only the headings a contents entry is made for, so the anchors and the entries agree.
    /// Reset by `DocumentPrinter` before each document; a stale count would only misnumber anchors,
    /// never lose content.
    nonisolated(unsafe) static var headingCount = 0

    private static func list(
        ordered: Bool,
        start: Int,
        items: [[MDBlock]],
        lang: AppLanguage,
        template: DocTemplate
    ) -> String {
        guard !items.isEmpty else { return "" }
        let tag = ordered ? "ol" : "ul"
        let sample = items.compactMap { $0.first }.compactMap(plainText).joined(separator: " ")
        var out = "<" + tag + " class=\"doc-list\""
        if ordered, start != 1 { out += " start=\"\(start)\"" }
        out += dir(sample, lang: lang) + ">\n"
        for item in items {
            var inner = ""
            for child in item { inner += html(for: child, lang: lang, template: template) }
            out += "<li class=\"doc-li\">" + inner + "</li>\n"
        }
        out += "</" + tag + ">\n"
        return out
    }

    // MARK: - Table

    /// A table breaks across pages only between rows, and its header repeats when it does —
    /// `thead` is what tells the print engine that, and it is the reason a table in a printed
    /// document must be a real `<table>` rather than a grid of boxes.
    private static func table(header: [MDTableCell], rows: [[MDTableCell]], lang: AppLanguage) -> String {
        guard !header.isEmpty || !rows.isEmpty else { return "" }
        let sample = (header.map(\.plain) + rows.flatMap { $0.map(\.plain) }).joined(separator: " ")
        var out = "<table class=\"doc-table\"" + dir(sample, lang: lang) + ">\n"
        if !header.isEmpty {
            out += "<thead><tr>"
            for cell in header {
                out += "<th" + align(cell.align) + ">" + inline(cell.plain) + "</th>"
            }
            out += "</tr></thead>\n"
        }
        if !rows.isEmpty {
            out += "<tbody>\n"
            for row in rows {
                out += "<tr>"
                for cell in row {
                    out += "<td" + align(cell.align) + ">" + inline(cell.plain) + "</td>"
                }
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        out += "</table>\n"
        return out
    }

    /// GFM writes its markers as physical left and right; in a document whose every block picks its
    /// own direction they can only mean start and end, which is what `MDTableAlign` already decided.
    private static func align(_ value: MDTableAlign) -> String {
        switch value {
        case .natural: return ""
        case .start: return " class=\"doc-cell--start\""
        case .center: return " class=\"doc-cell--center\""
        case .end: return " class=\"doc-cell--end\""
        }
    }

    // MARK: - Code

    /// Always left to right, never wrapped by direction, and never folded.
    ///
    /// The native renderer printed a listing through the same collapsing view the transcript uses,
    /// so anything over sixteen lines reached the page as sixteen lines, a fade, and a «عرض المزيد»
    /// button nobody can press in a PDF. A document gets the whole listing.
    private static func code(language: String?, source: String) -> String {
        guard !source.isEmpty else { return "" }
        let label = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "<figure class=\"doc-code\" dir=\"ltr\">\n"
        if !label.isEmpty {
            out += "<figcaption class=\"doc-code__lang\">" + escape(label) + "</figcaption>\n"
        }
        out += "<pre class=\"doc-pre\"><code>" + escape(source) + "</code></pre>\n"
        out += "</figure>\n"
        return out
    }

    // MARK: - Mathematics

    /// The equation as source, for KaTeX to replace in the page.
    ///
    /// This is the whole reason the pipeline moved to HTML. The native renderer could only draw the
    /// Unicode approximation — `frac1n` where a fraction belonged — because a CGContext has no
    /// notion of a fraction. Here the same KaTeX build that typesets the transcript typesets the
    /// page, and a document's mathematics is finally the mathematics.
    private static func math(_ tex: String, display: Bool) -> String {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tag = display ? "div" : "span"
        let cls = display ? "doc-math doc-math--display" : "doc-math"
        return "<" + tag + " class=\"" + cls + "\" dir=\"ltr\""
            + " data-tex=\"" + escape(trimmed) + "\""
            + " data-display=\"" + (display ? "1" : "0") + "\">"
            + escape(trimmed) + "</" + tag + ">\n"
    }

    /// Inline text: everything escaped, and each equation handed to KaTeX where it stands.
    ///
    /// `MathScanner` is the app's one authority on what counts as mathematics, so a document and a
    /// conversation never disagree about whether `$5` is a price or a formula.
    private static func inline(_ text: String) -> String {
        let protected = MathScanner.protect(text)
        guard !protected.spans.isEmpty else { return escape(text) }

        /* ESCAPE FIRST, SUBSTITUTE SECOND. The sentinels `protect` leaves behind are
           Private-Use-Area scalars, which no HTML escape touches - so the whole string can be
           escaped as the untrusted text it is, and the markup put in afterwards where the
           sentinels sit. Doing it the other way round would escape the markup. */
        var out = escape(protected.text)
        for (index, raw) in protected.spans.enumerated() {
            let token = MathScanner.token(index)
            guard out.contains(token) else { continue }
            let markup: String
            if let span = MathScanner.span(for: raw) {
                markup = math(span.tex, display: span.isDisplay)
            } else {
                // Not parseable as mathematics after all: it goes back as the text it was.
                markup = escape(raw)
            }
            out = out.replacingOccurrences(of: token, with: markup)
        }
        return out
    }

    // MARK: - Cards

    /// A card in a document is its content, not its chrome: a document cannot offer a Play button
    /// or a Regenerate. Each becomes a labelled line naming what it was, which is what the
    /// transcript exporter already settled on.
    private static func fenceBlock(_ fence: FirasFence, lang: AppLanguage) -> String {
        switch fence {
        case .code(let meta, let body):
            return code(language: meta.lang, source: body)
        case .file(let meta):
            return labelled(lang == .arabic ? "ملف" : "File", meta.name ?? meta.title ?? "", lang: lang)
        case .image(let meta):
            return labelled(lang == .arabic ? "صورة" : "Picture", meta.prompt, lang: lang)
        case .video(let meta):
            return labelled(lang == .arabic ? "مقطع" : "Clip", meta.prompt, lang: lang)
        case .music(let meta):
            return labelled(lang == .arabic ? "أغنية" : "Song", meta.title ?? meta.prompt, lang: lang)
        case .agent(let job):
            return labelled(lang == .arabic ? "مهمة" : "Mission", job.title, lang: lang)
        case .project(let project):
            return labelled(lang == .arabic ? "مشروع" : "Project", project.name, lang: lang)
        case .deck(let deck):
            return labelled(lang == .arabic ? "عرض تقديمي" : "Presentation", deck.title, lang: lang)
        case .ask, .sources, .plot:
            return ""
        }
    }

    private static func labelled(_ label: String, _ value: String, lang: AppLanguage) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "<p class=\"doc-p doc-p--label\"" + dir(trimmed, lang: lang) + ">"
            + "<strong>" + escape(label) + ":</strong> " + escape(trimmed) + "</p>\n"
    }

    // MARK: - Direction

    /// The block's own direction, or the document's when the block has no opinion.
    private static func dir(_ text: String, lang: AppLanguage) -> String {
        ExportOOXML.isRightToLeft(text, fallback: lang == .arabic) ? " dir=\"rtl\"" : " dir=\"ltr\""
    }

    private static func plainText(_ block: MDBlock) -> String? {
        switch block {
        case .paragraph(let text): return String(text.characters)
        case .heading(_, let text): return String(text.characters)
        case .raw(let text): return text
        default: return nil
        }
    }
}
