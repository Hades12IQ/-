import Foundation

/// `.docx` — a real WordprocessingML package, not a renamed HTML file.
///
/// Word is the format the owner names first (`مستند Word`), and an Arabic Word document that opens
/// left-to-right is worse than no document: every paragraph carries `w:bidi`, every run carries
/// `w:rtl`, and the section itself is right-to-left when the document's own text is Arabic. Headings
/// are real styles, so the reader gets a working navigation pane; tables are real `w:tbl` grids with
/// their own borders, so they survive a paste into another document.
enum ExportWord {

    private static let mainNamespace =
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// Builds the package for `blocks` and writes it to `url`.
    static func write(title: String, blocks: [ExportBlock], to url: URL) -> Bool {
        let rtl = ExportOOXML.isRightToLeft(title + " " + sampleText(blocks))
        var parts: [ExportOOXML.Part] = []
        parts.append(ExportOOXML.Part("[Content_Types].xml", contentTypes()))
        parts.append(ExportOOXML.Part("_rels/.rels", packageRelationships()))
        parts.append(
            ExportOOXML.Part("docProps/core.xml", ExportOOXML.coreProperties(title: title))
        )
        parts.append(
            ExportOOXML.Part("word/_rels/document.xml.rels", documentRelationships())
        )
        parts.append(ExportOOXML.Part("word/styles.xml", styles(rtl: rtl)))
        parts.append(
            ExportOOXML.Part("word/document.xml", document(title: title, blocks: blocks, rtl: rtl))
        )
        return ExportOOXML.write(parts: parts, to: url)
    }

    private static func sampleText(_ blocks: [ExportBlock]) -> String {
        var sample = ""
        for block in blocks {
            switch block {
            case .heading(_, let spans), .paragraph(let spans), .bullet(_, let spans),
                 .numbered(_, _, let spans), .quote(let spans):
                sample += ExportMarkdown.plain(spans)
                sample += " "
            case .table(let header, _):
                sample += header.joined(separator: " ")
                sample += " "
            case .code, .math, .rule:
                // None of the three has an opinion about the document's language, and an equation
                // full of Latin letters would vote loudly for the wrong one.
                continue
            }
            if sample.count > 4_000 { break }
        }
        return sample
    }

    // MARK: - Package scaffolding

    private static func contentTypes() -> String {
        var out = ExportOOXML.declaration
        out += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        out += "<Default Extension=\"rels\""
        out += " ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        out += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        out += "<Override PartName=\"/word/document.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        out += "<Override PartName=\"/word/styles.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
        out += "<Override PartName=\"/docProps/core.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-package.core-properties+xml\"/>"
        out += "</Types>"
        return out
    }

    private static func packageRelationships() -> String {
        ExportOOXML.relationships([
            ("rId1", ExportOOXML.officeRelationships + "/officeDocument", "word/document.xml"),
            (
                "rId2",
                ExportOOXML.relationshipsNamespace + "/metadata/core-properties",
                "docProps/core.xml"
            )
        ])
    }

    private static func documentRelationships() -> String {
        ExportOOXML.relationships([
            ("rId1", ExportOOXML.officeRelationships + "/styles", "styles.xml")
        ])
    }

    // MARK: - Styles

    /// Title, four heading levels, a quote, a code style and the list paragraph. The Arabic face is
    /// named explicitly (`w:cs`) so Word does not fall back to a Latin font with no Arabic glyphs
    /// and render the whole document as boxes.
    private static func styles(rtl: Bool) -> String {
        var out = ExportOOXML.declaration
        out += "<w:styles xmlns:w=\""
        out += mainNamespace
        out += "\">"

        out += "<w:docDefaults><w:rPrDefault><w:rPr>"
        out += "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Arial\"/>"
        out += "<w:sz w:val=\"24\"/><w:szCs w:val=\"26\"/>"
        if rtl { out += "<w:rtl/>" }
        out += "</w:rPr></w:rPrDefault>"
        out += "<w:pPrDefault><w:pPr>"
        if rtl { out += "<w:bidi/>" }
        out += "<w:spacing w:after=\"160\" w:line=\"300\" w:lineRule=\"auto\"/>"
        out += "</w:pPr></w:pPrDefault></w:docDefaults>"

        out += style(id: "Normal", name: "Normal", isDefault: true, extra: "")

        var titleExtra = "<w:pPr>"
        titleExtra += bidi(rtl)
        titleExtra += "<w:spacing w:before=\"0\" w:after=\"300\"/></w:pPr>"
        titleExtra += "<w:rPr><w:b/><w:bCs/><w:sz w:val=\"56\"/><w:szCs w:val=\"56\"/></w:rPr>"
        out += style(id: "Title", name: "Title", isDefault: false, extra: titleExtra)

        // `w:keepNext` is the same rule the PDF paginator follows: a heading alone at the foot of a
        // page is a heading that has lost its section. Element order inside `w:pPr` and `w:rPr` is
        // the schema's, not ours — Word forgives a wrong order, Pages and Google Docs do not, and
        // "the file will not open" is the one export failure with no workaround.
        let headingSizes = [36, 30, 26, 24]
        for level in 1...4 {
            let size = String(headingSizes[level - 1])
            var extra = "<w:pPr><w:keepNext/><w:keepLines/>"
            extra += bidi(rtl)
            extra += "<w:spacing w:before=\"320\" w:after=\"140\"/><w:outlineLvl w:val=\""
            extra += String(level - 1)
            extra += "\"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val=\""
            extra += size
            extra += "\"/><w:szCs w:val=\""
            extra += size
            extra += "\"/></w:rPr>"
            out += style(
                id: "Heading" + String(level),
                name: "heading " + String(level),
                isDefault: false,
                extra: extra
            )
        }

        var quoteExtra = "<w:pPr>"
        quoteExtra += bidi(rtl)
        quoteExtra += "<w:ind w:left=\"420\" w:right=\"420\"/></w:pPr>"
        quoteExtra += "<w:rPr><w:i/><w:iCs/></w:rPr>"
        out += style(id: "Quote", name: "Quote", isDefault: false, extra: quoteExtra)

        // `w:bidi w:val="0"` and not a missing `w:bidi`: the document defaults above turn bidi on
        // for an Arabic file, and a paragraph that merely declines to repeat it still inherits it.
        // A code listing dragged to the right edge with its runs marked right-to-left is the
        // «كلشي مرتب» complaint in its purest form.
        var codeExtra = "<w:pPr><w:keepLines/><w:bidi w:val=\"0\"/>"
        codeExtra += "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
        codeExtra += "<w:jc w:val=\"left\"/></w:pPr>"
        codeExtra += "<w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\""
        codeExtra += " w:cs=\"Courier New\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"
        codeExtra += "<w:rtl w:val=\"0\"/></w:rPr>"
        out += style(id: "FirasCode", name: "Firas Code", isDefault: false, extra: codeExtra)

        // An equation is not a sentence: it is centred, it has air above and below it, and it is
        // set in the face Word itself uses for mathematics, so `∫₀^π` looks like an integral and
        // not like a paragraph that happened to contain a strange character.
        var mathExtra = "<w:pPr><w:keepLines/><w:bidi w:val=\"0\"/>"
        mathExtra += "<w:spacing w:before=\"240\" w:after=\"240\"/>"
        mathExtra += "<w:jc w:val=\"center\"/></w:pPr>"
        mathExtra += "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\""
        mathExtra += " w:cs=\"Cambria Math\"/><w:sz w:val=\"26\"/><w:szCs w:val=\"26\"/>"
        mathExtra += "<w:rtl w:val=\"0\"/></w:rPr>"
        out += style(id: "FirasMath", name: "Firas Math", isDefault: false, extra: mathExtra)

        // No indent in the style: a list item states its own, at its own depth and on its own
        // start edge, because an English bullet inside an Arabic document indents from the left
        // while the Arabic ones around it indent from the right.
        var listExtra = "<w:pPr>"
        listExtra += bidi(rtl)
        listExtra += "<w:spacing w:after=\"80\"/>"
        listExtra += "</w:pPr>"
        out += style(id: "ListParagraph", name: "List Paragraph", isDefault: false, extra: listExtra)

        out += "</w:styles>"
        return out
    }

    private static func style(id: String, name: String, isDefault: Bool, extra: String) -> String {
        var out = "<w:style w:type=\"paragraph\""
        if isDefault { out += " w:default=\"1\"" }
        out += " w:styleId=\""
        out += id
        out += "\"><w:name w:val=\""
        out += name
        out += "\"/><w:qFormat/>"
        out += extra
        out += "</w:style>"
        return out
    }

    /// `<w:bidi/>` when the paragraph is Arabic, `<w:bidi w:val="0"/>` when it is not.
    ///
    /// The negative form is the important one. An Arabic document turns bidi on in `docDefaults`,
    /// and a paragraph that merely omits `w:bidi` inherits it — so an English answer inside an
    /// Arabic transcript, a code listing and an equation would all be dragged to the right edge
    /// unless they say, in as many words, that they are not right-to-left.
    private static func bidi(_ rtl: Bool) -> String {
        rtl ? "<w:bidi/>" : "<w:bidi w:val=\"0\"/>"
    }

    /// An indent on the paragraph's *start* edge, spelled physically because that is what Word
    /// reads. The far side is pinned to zero so a direct override cannot leave the style's own
    /// indent standing on the other edge and indent the line twice.
    private static func indentation(_ twips: Int, rtl: Bool) -> String {
        var out = "<w:ind w:left=\""
        out += rtl ? "0" : String(twips)
        out += "\" w:right=\""
        out += rtl ? String(twips) : "0"
        out += "\"/>"
        return out
    }

    // MARK: - Document body

    private static func document(title: String, blocks: [ExportBlock], rtl: Bool) -> String {
        var body = ""
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty {
            body += paragraph(spans: [ExportInline(text: heading)], style: "Title", rtl: rtl)
        }

        // The transcript opens with its own `# title`, and the web's `ensureFileTitle` derives a
        // single answer's title from its first heading the same way. Either way the words would
        // otherwise appear twice in a row, once as the title and once as a heading under it.
        var remaining = blocks[...]
        if !heading.isEmpty, case .heading(let level, let spans)? = remaining.first, level <= 3,
           ExportMarkdown.plain(spans).trimmingCharacters(in: .whitespacesAndNewlines) == heading {
            remaining = remaining.dropFirst()
        }

        for block in remaining {
            // Direction PER PARAGRAPH, not per document: an English answer inside an Arabic
            // transcript is an English paragraph, and dragging its bullet to the right edge
            // because the thread around it is Arabic is the bug this avoids.
            let blockRTL = direction(of: block, document: rtl)
            switch block {
            case .heading(let level, let spans):
                let name = "Heading" + String(min(4, max(1, level)))
                body += paragraph(spans: spans, style: name, rtl: blockRTL)

            case .paragraph(let spans):
                body += paragraph(spans: spans, style: "Normal", rtl: blockRTL)

            case .bullet(let depth, let spans):
                var marked = [ExportInline(text: bulletMarker(depth) + " ")]
                marked.append(contentsOf: spans)
                body += paragraph(spans: marked, style: "ListParagraph", rtl: blockRTL, indent: depth)

            case .numbered(let depth, let number, let spans):
                var marked = [ExportInline(text: String(number) + ". ")]
                marked.append(contentsOf: spans)
                body += paragraph(spans: marked, style: "ListParagraph", rtl: blockRTL, indent: depth)

            case .quote(let spans):
                body += paragraph(spans: spans, style: "Quote", rtl: blockRTL)

            case .code(_, let source):
                for line in source.components(separatedBy: "\n") {
                    // A code line is always left to right, whatever the prose around it does.
                    let run = ExportInline(text: line.isEmpty ? " " : line, code: true)
                    body += paragraph(spans: [run], style: "FirasCode", rtl: false)
                }
                // The listing's own lines sit tight against each other, so the gap after the last
                // one has to come from somewhere: an empty paragraph, exactly as after a table.
                body += "<w:p/>"

            case .math(let text, _):
                // Left to right and centred, like every equation in every language.
                body += paragraph(
                    spans: [ExportInline(text: text)],
                    style: "FirasMath",
                    rtl: false
                )

            case .table(let header, let rows):
                body += table(header: header, rows: rows, rtl: blockRTL)

            case .rule:
                body += "<w:p><w:pPr><w:pBdr>"
                body += "<w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C9CDD3\"/>"
                body += "</w:pBdr></w:pPr></w:p>"
            }
        }

        // A4, with the same two-centimetre margin the PDF is set with — `w:bidi` last, where the
        // schema puts it.
        var section = "<w:sectPr>"
        section += "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
        section += "<w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\""
        section += " w:header=\"709\" w:footer=\"709\" w:gutter=\"0\"/>"
        if rtl { section += "<w:bidi/>" }
        section += "</w:sectPr>"

        var out = ExportOOXML.declaration
        out += "<w:document xmlns:w=\""
        out += mainNamespace
        out += "\"><w:body>"
        out += body
        out += section
        out += "</w:body></w:document>"
        return out
    }

    /// One block's own direction, falling back to the document's. `ExportOOXML` owns the rule so
    /// the Word writer and the HTML writer cannot drift into two answers.
    private static func direction(of block: ExportBlock, document rtl: Bool) -> Bool {
        ExportOOXML.isRightToLeft(block, fallback: rtl)
    }

    private static func bulletMarker(_ depth: Int) -> String {
        switch depth {
        case 0: return "\u{2022}"
        case 1: return "\u{25E6}"
        default: return "\u{25AA}"
        }
    }

    private static func paragraph(
        spans: [ExportInline],
        style: String,
        rtl: Bool,
        indent: Int? = nil
    ) -> String {
        // `w:pPr` children follow the schema's sequence — pStyle, bidi, ind — because Pages and
        // Google Docs validate it even where Word shrugs.
        var properties = "<w:pStyle w:val=\""
        properties += style
        properties += "\"/>"
        properties += bidi(rtl)
        if let indent {
            properties += indentation(420 + max(0, indent) * 340, rtl: rtl)
        }

        var out = "<w:p><w:pPr>"
        out += properties
        out += "</w:pPr>"
        for span in spans {
            out += run(span, rtl: rtl)
        }
        out += "</w:p>"
        return out
    }

    /// One run. `w:rPr` children are in schema order — rFonts, b, bCs, i, iCs, sz, szCs, rtl — and
    /// `w:rtl` is always written, on or off: an Arabic document marks every run right-to-left in
    /// `docDefaults`, and a run of code or of English that only *omits* the flag still inherits it.
    private static func run(_ span: ExportInline, rtl: Bool) -> String {
        guard !span.text.isEmpty else { return "" }
        var properties = ""
        if span.code {
            properties += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\""
            properties += " w:cs=\"Courier New\"/>"
        }
        if span.bold { properties += "<w:b/><w:bCs/>" }
        if span.italic { properties += "<w:i/><w:iCs/>" }
        if span.code { properties += "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>" }
        // A code run is left to right whatever the sentence around it is doing.
        properties += (rtl && !span.code) ? "<w:rtl/>" : "<w:rtl w:val=\"0\"/>"

        var out = "<w:r><w:rPr>"
        out += properties
        out += "</w:rPr>"
        out += "<w:t xml:space=\"preserve\">"
        out += ExportOOXML.escapeInline(span.text)
        out += "</w:t></w:r>"
        return out
    }

    // MARK: - Tables

    private static func table(header: [String], rows: [[String]], rtl: Bool) -> String {
        let widest = rows.map(\.count).max() ?? 0
        let columns = max(header.count, widest)
        guard columns > 0 else { return "" }

        var borders = "<w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            borders += "<w:"
            borders += edge
            borders += " w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"C9CDD3\"/>"
        }
        borders += "</w:tblBorders>"

        // `w:bidiVisual` precedes `w:tblW` in the schema, and a cell margin is what stops the text
        // sitting against the rule — the same complaint the page margin answers, one scale down.
        var out = "<w:tbl><w:tblPr>"
        if rtl { out += "<w:bidiVisual/>" }
        out += "<w:tblW w:w=\"5000\" w:type=\"pct\"/>"
        out += borders
        out += "<w:tblCellMar>"
        out += "<w:top w:w=\"60\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/>"
        out += "<w:bottom w:w=\"60\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/>"
        out += "</w:tblCellMar>"
        out += "</w:tblPr><w:tblGrid>"
        let width = String(max(600, 9638 / columns))
        for _ in 0..<columns {
            out += "<w:gridCol w:w=\""
            out += width
            out += "\"/>"
        }
        out += "</w:tblGrid>"

        if !header.isEmpty {
            out += row(cells: header, columns: columns, rtl: rtl, isHeader: true)
        }
        for entry in rows {
            out += row(cells: entry, columns: columns, rtl: rtl, isHeader: false)
        }
        out += "</w:tbl>"
        // Word needs a paragraph after a table or the next block merges into it.
        out += "<w:p/>"
        return out
    }

    private static func row(cells: [String], columns: Int, rtl: Bool, isHeader: Bool) -> String {
        var out = "<w:tr>"
        if isHeader { out += "<w:trPr><w:tblHeader/></w:trPr>" }
        for column in 0..<columns {
            let text = column < cells.count ? cells[column] : ""
            out += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/>"
            if isHeader {
                out += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F4F7\"/>"
            }
            out += "</w:tcPr>"
            out += paragraph(
                spans: [ExportInline(text: text, bold: isHeader)],
                style: "Normal",
                rtl: rtl
            )
            out += "</w:tc>"
        }
        out += "</w:tr>"
        return out
    }
}
