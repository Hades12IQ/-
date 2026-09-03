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
    }

    private static let bodyLinesPerSlide = 7

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

            case .rule:
                continue
            }
        }
        commit()

        if built.isEmpty {
            built = [Slide(title: title, lines: [])]
        }
        return Array(built.prefix(200))
    }

    // MARK: - Package

    static func write(title: String, slides: [Slide], to url: URL) -> Bool {
        let usable = slides.isEmpty ? [Slide(title: title, lines: [])] : slides

        var parts: [ExportOOXML.Part] = []
        parts.append(ExportOOXML.Part("[Content_Types].xml", contentTypes(count: usable.count)))
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
                    slideRelationships()
                )
            )
        }
        return ExportOOXML.write(parts: parts, to: url)
    }

    // MARK: - One slide

    private static func slide(_ slide: Slide) -> String {
        var sample = slide.title
        sample += " "
        sample += slide.lines.joined(separator: " ")
        let rtl = ExportOOXML.isRightToLeft(sample)

        var shapes = textShape(
            id: 2,
            name: "Title",
            x: 838_200,
            y: 640_080,
            width: 10_515_600,
            height: 1_325_563,
            paragraphs: [slide.title],
            size: 3_600,
            bold: true,
            rtl: rtl
        )
        if !slide.lines.isEmpty {
            shapes += textShape(
                id: 3,
                name: "Body",
                x: 838_200,
                y: 2_133_600,
                width: 10_515_600,
                height: 3_602_038,
                paragraphs: slide.lines,
                size: 2_000,
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
