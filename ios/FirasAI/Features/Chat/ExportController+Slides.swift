import Foundation

/// `.pptx` — a real PresentationML deck, 16:9.
///
/// Every shape carries its own geometry rather than inheriting a placeholder, so the deck needs one
/// master and one blank layout and nothing can go missing between them. Arabic paragraphs are
/// `rtl="1"` and right-aligned; a Latin deck is left-aligned. Nothing is inherited from a theme a
/// viewer might not resolve — every run names its own colour and typeface.
enum ExportSlides {

    static let drawingNamespace =
        "http://schemas.openxmlformats.org/drawingml/2006/main"

    static let presentationNamespace =
        "http://schemas.openxmlformats.org/presentationml/2006/main"

    /// One slide: a heading and the lines under it.
    struct Slide: Sendable {
        var title: String
        var lines: [String]
        var layout: String = "content"
        var notes: String = ""
        var accent: String? = nil
        var authored: Bool = false
    }

    private static let bodyLinesPerSlide = 7

    /// The ceiling is real — a deck is one XML part plus two relationship parts per slide, and a
    /// four-thousand-slide package is a file nothing opens — but it is six times what it was, and
    /// crossing it is now *said*. The old `prefix(200)` threw the rest of a long conversation away
    /// without a word, which is the one thing an export must never do.
    private static let maximumSlides = 1_200

    /// The current server authoring contract: `#` names the deck, `##` is a divider and
    /// `###` starts one actual slide. Metadata lines never become audience-facing prose.
    /// This entry point is only for designed Office artifacts; transcript export is unchanged.
    static func officeSlides(title: String, markdown: String, expectedCount: Int? = nil,
                             accent: String? = nil) throws -> [Slide] {
        var result: [Slide] = []
        var current: Slide?
        var content: [String] = []
        var fenced = false
        let allowed = ["content", "stats", "comparison", "process", "timeline", "cards", "quote", "hero", "section"]
        let color = accent?.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil ? nil : accent
        func commit() throws {
            guard var slide = current else { return }
            let parsed = ExportMarkdown.blocks(from: content.joined(separator: "\n"))
            for block in parsed {
                switch block {
                case .heading(_, let spans), .paragraph(let spans), .quote(let spans):
                    let text = ExportMarkdown.plain(spans).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { slide.lines.append(text) }
                case .bullet(_, let spans): slide.lines.append("• " + ExportMarkdown.plain(spans))
                case .numbered(_, let number, let spans): slide.lines.append(String(number) + ". " + ExportMarkdown.plain(spans))
                case .table(let header, let rows):
                    if !header.isEmpty { slide.lines.append(header.joined(separator: " · ")) }
                    slide.lines.append(contentsOf: rows.map { $0.joined(separator: " · ") })
                case .code(_, let body): slide.lines.append(contentsOf: body.components(separatedBy: "\n"))
                case .math(let text, _): slide.lines.append(text)
                case .rule: break
                }
            }
            // Keep the exact requested slide count. Never silently create overflow slides, clip
            // source rows, or force a full page of prose into an unreadable presentation.
            guard slide.lines.count <= 18, slide.lines.joined(separator: " ").utf16.count <= 2_400 else {
                throw OfficeDocumentError.invalidResult
            }
            result.append(slide)
            current = nil; content = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); if current != nil { content.append(raw) }; continue }
            if !fenced, line.hasPrefix("## ") || line.hasPrefix("### ") {
                try commit()
                let divider = line.hasPrefix("## ")
                let heading = String(line.dropFirst(divider ? 3 : 4)).trimmingCharacters(in: .whitespaces)
                guard !heading.isEmpty else { throw OfficeDocumentError.invalidResult }
                current = Slide(title: ExportText.flattenMath(heading), lines: [],
                    layout: divider ? "section" : "content", accent: color, authored: true)
                continue
            }
            if current == nil { continue } // The one top-level deck title is metadata, not a slide.
            if !fenced, line.hasPrefix("Layout:") {
                let layout = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased()
                if allowed.contains(layout) { current?.layout = layout }
                continue
            }
            if !fenced, line.hasPrefix("Notes:") {
                let note = ExportText.flattenMath(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
                if var slide = current {
                    slide.notes += (slide.notes.isEmpty ? "" : "\n") + note
                    current = slide
                }
                continue
            }
            if !fenced, ["Stat:", "Col:", "Step:", "Card:", "Quote:"].contains(where: { line.hasPrefix($0) }),
               let colon = line.firstIndex(of: ":") {
                // Preserve values and labels as editable slide text, without authoring protocol.
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " | ", with: " — ").replacingOccurrences(of: "; ", with: " · ")
                content.append(value)
                continue
            }
            if !fenced, line.hasPrefix("Chart:") {
                let json = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard let bytes = json.data(using: .utf8),
                      let chart = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let labels = chart["labels"] as? [String], let values = chart["data"] as? [NSNumber],
                      !labels.isEmpty, labels.count == values.count, labels.count <= 12 else {
                    throw OfficeDocumentError.invalidResult
                }
                if let heading = chart["title"] as? String, !heading.isEmpty { content.append(heading) }
                for (label, value) in zip(labels, values) {
                    guard value.doubleValue.isFinite else { throw OfficeDocumentError.invalidResult }
                    content.append(label + ": " + value.stringValue)
                }
                continue
            }
            content.append(raw)
        }
        guard !fenced else { throw OfficeDocumentError.invalidResult }
        try commit()
        guard !result.isEmpty, result.count <= maximumSlides,
              expectedCount == nil || result.count == expectedCount else { throw OfficeDocumentError.invalidResult }
        return result
    }

    // MARK: - Turning an answer into slides

    static func slides(title: String, blocks: [ExportBlock]) -> [Slide] {
        var built: [Slide] = []
        var currentTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []

        func commit() {
            let heading = currentTitle.isEmpty ? title : currentTitle
            guard !heading.isEmpty || !lines.isEmpty else { return }
            if lines.isEmpty {
                built.append(Slide(title: heading, lines: []))
                return
            }
            var start = 0
            var page = 1
            while start < lines.count {
                let end = min(lines.count, start + bodyLinesPerSlide)
                var name = heading
                if page > 1 {
                    name += " ("
                    name += String(page)
                    name += ")"
                }
                built.append(Slide(title: name, lines: Array(lines[start..<end])))
                start = end
                page += 1
            }
        }

        for block in blocks {
            switch block {
            case .heading(let level, let spans):
                let text = ExportMarkdown.plain(spans)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if level <= 3 {
                    commit()
                    currentTitle = text
                    lines = []
                } else {
                    lines.append(text)
                }

            case .paragraph(let spans), .quote(let spans):
                let text = ExportMarkdown.plain(spans)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }

            case .bullet(_, let spans):
                let text = ExportMarkdown.plain(spans)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("\u{2022} " + text) }

            case .numbered(_, let number, let spans):
                let text = ExportMarkdown.plain(spans)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(String(number) + ". " + text) }

            case .table(let header, let rows):
                if !header.isEmpty { lines.append(header.joined(separator: " \u{00B7} ")) }
                for row in rows.prefix(12) {
                    lines.append(row.joined(separator: " \u{00B7} "))
                }

            case .code(_, let body):
                for line in body.components(separatedBy: "\n").prefix(12) where !line.isEmpty {
                    lines.append(line)
                }

            case .math(let text, _):
                if !text.isEmpty { lines.append(text) }

            case .rule:
                continue
            }
        }
        commit()

        if built.isEmpty {
            built = [Slide(title: title, lines: [])]
        }
        guard built.count > maximumSlides else { return built }

        // Over the ceiling: keep everything that fits and spend the last slide saying what did
        // not, in the deck's own language and with the count spelled out. A reader who is told
        // «حُذفت ٣٤٠ شريحة» can go and get the PDF; a reader who is told nothing cannot.
        let dropped = built.count - (maximumSlides - 1)
        let lang: AppLanguage = documentLanguage(built)
        var kept = Array(built.prefix(maximumSlides - 1))
        kept.append(
            Slide(
                title: Copy.moreTitle(lang),
                lines: [Copy.more.fmt(lang, ArabicText.count(dropped, lang))]
            )
        )
        return kept
    }

    /// The deck's own language, read from the slides themselves — the same rule the transcript
    /// uses, and not the interface's: an Arabic thread exported from an English session is Arabic.
    private static func documentLanguage(_ slides: [Slide]) -> AppLanguage {
        var sample = ""
        for slide in slides.prefix(40) {
            sample += slide.title
            sample += " "
            sample += slide.lines.joined(separator: " ")
            if sample.count > 4_000 { break }
        }
        return ExportOOXML.isRightToLeft(sample) ? .arabic : .english
    }

    // MARK: - Copy

    /// No web twin: the site's deck export has no ceiling to report.
    ///
    /// The count comes after a label rather than before a noun, because Arabic agrees a counted
    /// noun with its number four different ways and `٣ شريحة` is wrong in one of them. The label
    /// form is right for every count, which is the same trick `ExportTranscript.pair` uses.
    private enum Copy {
        static let moreTitle = LText(ar: "بقية العرض غير مُدرَجة", en: "The rest is not here")
        static let more = LText(
            ar: "الشرائح المحذوفة: %@ — العرض أطول مما يفتحه PowerPoint بسلاسة. نزّل المحادثة بصيغة PDF أو Word لقراءتها كاملة.",
            en: "Slides left out: %@ — the deck ran longer than PowerPoint opens comfortably. Export the PDF or the Word document to read all of it."
        )
    }

    // MARK: - Package

    static func write(title: String, slides: [Slide], to url: URL) -> Bool {
        let usable = slides.isEmpty ? [Slide(title: title, lines: [])] : slides

        var parts: [ExportOOXML.Part] = []
        let notesOverrides = usable.enumerated().filter { !$0.element.notes.isEmpty }.map {
            "<Override PartName=\"/ppt/notesSlides/notesSlide\($0.offset + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/>"
        }.joined()
        let types = contentTypes(count: usable.count).replacingOccurrences(of: "</Types>", with: notesOverrides + "</Types>")
        parts.append(ExportOOXML.Part("[Content_Types].xml", types))
        parts.append(ExportOOXML.Part("_rels/.rels", packageRelationships()))
        parts.append(
            ExportOOXML.Part("docProps/core.xml", ExportOOXML.coreProperties(title: title))
        )
        parts.append(ExportOOXML.Part("ppt/presentation.xml", presentation(count: usable.count)))
        parts.append(
            ExportOOXML.Part(
                "ppt/_rels/presentation.xml.rels",
                presentationRelationships(count: usable.count)
            )
        )
        parts.append(ExportOOXML.Part("ppt/slideMasters/slideMaster1.xml", slideMaster()))
        parts.append(
            ExportOOXML.Part("ppt/slideMasters/_rels/slideMaster1.xml.rels", masterRelationships())
        )
        parts.append(ExportOOXML.Part("ppt/slideLayouts/slideLayout1.xml", slideLayout()))
        parts.append(
            ExportOOXML.Part("ppt/slideLayouts/_rels/slideLayout1.xml.rels", layoutRelationships())
        )
        parts.append(ExportOOXML.Part("ppt/theme/theme1.xml", theme()))

        for (index, entry) in usable.enumerated() {
            parts.append(
                ExportOOXML.Part(
                    "ppt/slides/slide" + String(index + 1) + ".xml",
                    slide(entry)
                )
            )
            parts.append(
                ExportOOXML.Part(
                    "ppt/slides/_rels/slide" + String(index + 1) + ".xml.rels",
                    entry.notes.isEmpty ? slideRelationships() : slideRelationships().replacingOccurrences(of: "</Relationships>",
                        with: "<Relationship Id=\"rIdNotes\" Type=\"" + ExportOOXML.officeRelationships
                            + "/notesSlide\" Target=\"../notesSlides/notesSlide" + String(index + 1) + ".xml\"/></Relationships>")
                )
            )
            if !entry.notes.isEmpty {
                parts.append(ExportOOXML.Part("ppt/notesSlides/notesSlide" + String(index + 1) + ".xml", notesDocument(entry.notes)))
                parts.append(ExportOOXML.Part("ppt/notesSlides/_rels/notesSlide" + String(index + 1) + ".xml.rels",
                    ExportOOXML.declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                        + "<Relationship Id=\"rId1\" Type=\"" + ExportOOXML.officeRelationships + "/slide\" Target=\"../slides/slide"
                        + String(index + 1) + ".xml\"/></Relationships>"))
            }
        }
        return ExportOOXML.write(parts: parts, to: url)
    }

    // MARK: - One slide

    private static func slide(_ slide: Slide) -> String {
        var sample = slide.title
        sample += " "
        sample += slide.lines.joined(separator: " ")
        let rtl = ExportOOXML.isRightToLeft(sample)

        let hero = slide.authored && ["section", "hero", "quote"].contains(slide.layout)
        var shapes = textShape(
            id: 2,
            name: "Title",
            x: 838_200,
            y: hero ? 1_750_000 : 640_080,
            width: 10_515_600,
            height: 1_325_563,
            paragraphs: [slide.title],
            size: hero ? 4_200 : 3_600,
            bold: true,
            rtl: rtl
        )
        if slide.authored, let color = slide.accent {
            shapes = "<p:sp><p:nvSpPr><p:cNvPr id=\"90\" name=\"Accent\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"
                + "<p:spPr><a:xfrm><a:off x=\"838200\" y=\"420000\"/><a:ext cx=\"1200000\" cy=\"50000\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val=\"" + color
                + "\"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>" + shapes
        }
        if slide.authored, ["comparison", "cards", "stats", "process", "timeline"].contains(slide.layout),
           (2...6).contains(slide.lines.count) {
            let columns = slide.lines.count <= 3 ? slide.lines.count : 3
            let rows = (slide.lines.count + columns - 1) / columns
            let gap = 260_000, width = (10_515_600 - (columns - 1) * gap) / columns
            let height = (3_900_000 - (rows - 1) * gap) / rows
            for (index, line) in slide.lines.enumerated() {
                let column = rtl ? columns - 1 - index % columns : index % columns
                shapes += textShape(id: index + 3, name: "Item" + String(index + 1),
                    x: 838_200 + column * (width + gap), y: 2_133_600 + (index / columns) * (height + gap),
                    width: width, height: height, paragraphs: [line], size: 2_400, bold: false, rtl: rtl)
            }
        } else if !slide.lines.isEmpty {
            shapes += textShape(
                id: 3,
                name: "Body",
                x: 838_200,
                y: hero ? 3_250_000 : 2_133_600,
                width: 10_515_600,
                height: hero ? 2_700_000 : 3_900_000,
                paragraphs: slide.lines,
                size: slide.authored && slide.lines.count <= 6 ? 2_400 : 2_000,
                bold: false,
                rtl: rtl
            )
        }

        var out = ExportOOXML.declaration
        out += "<p:sld xmlns:a=\""
        out += drawingNamespace
        out += "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships
        out += "\" xmlns:p=\""
        out += presentationNamespace
        out += "\"><p:cSld><p:spTree>"
        out += "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        out += "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/>"
        out += "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        out += shapes
        out += "</p:spTree></p:cSld>"
        out += "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
        return out
    }

    /// A real PowerPoint notes part: narration is available to the presenter but never printed
    /// into the audience slide. The relationship points back to exactly its owning slide.
    private static func notesDocument(_ text: String) -> String {
        let shape = textShape(id: 2, name: "Notes", x: 0, y: 0, width: 6_858_000, height: 9_144_000,
            paragraphs: text.components(separatedBy: "\n"), size: 1_200, bold: false,
            rtl: ExportOOXML.isRightToLeft(text))
            .replacingOccurrences(of: "<p:nvPr/>", with: "<p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr>")
        var out = ExportOOXML.declaration
        out += "<p:notes xmlns:a=\"" + drawingNamespace + "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships + "\" xmlns:p=\"" + presentationNamespace
        out += "\"><p:cSld><p:spTree>"
        out += "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        out += "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/>"
        out += "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        out += shape
        out += "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
        return out
    }

    private static func textShape(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        paragraphs: [String],
        size: Int,
        bold: Bool,
        rtl: Bool
    ) -> String {
        var body = ""
        for text in paragraphs {
            body += paragraph(text, size: size, bold: bold, rtl: rtl)
        }
        if body.isEmpty {
            body = paragraph("", size: size, bold: bold, rtl: rtl)
        }

        var out = "<p:sp><p:nvSpPr><p:cNvPr id=\""
        out += String(id)
        out += "\" name=\""
        out += name
        out += "\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
        out += "<p:spPr><a:xfrm><a:off x=\""
        out += String(x)
        out += "\" y=\""
        out += String(y)
        out += "\"/><a:ext cx=\""
        out += String(width)
        out += "\" cy=\""
        out += String(height)
        out += "\"/></a:xfrm>"
        out += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
        out += "<p:txBody><a:bodyPr wrap=\"square\" anchor=\"t\"><a:normAutofit/></a:bodyPr>"
        out += "<a:lstStyle/>"
        out += body
        out += "</p:txBody></p:sp>"
        return out
    }

    private static func paragraph(_ text: String, size: Int, bold: Bool, rtl: Bool) -> String {
        var properties = "<a:pPr algn=\""
        properties += rtl ? "r" : "l"
        properties += "\""
        if rtl { properties += " rtl=\"1\"" }
        properties += "/>"

        guard !text.isEmpty else {
            var empty = "<a:p>"
            empty += properties
            empty += "</a:p>"
            return empty
        }

        var out = "<a:p>"
        out += properties
        out += "<a:r><a:rPr lang=\""
        out += rtl ? "ar-SA" : "en-US"
        out += "\" sz=\""
        out += String(size)
        out += "\""
        if bold { out += " b=\"1\"" }
        out += " dirty=\"0\"><a:solidFill><a:srgbClr val=\""
        out += bold ? "111418" : "2B3138"
        out += "\"/></a:solidFill>"
        out += "<a:latin typeface=\"Calibri\"/><a:cs typeface=\"Arial\"/></a:rPr>"
        out += "<a:t>"
        out += ExportOOXML.escapeInline(text)
        out += "</a:t></a:r></a:p>"
        return out
    }


}
