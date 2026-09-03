import Foundation

/// `.html` — one self-contained page (`downloadHtml` / `صفحة HTML` on the web).
///
/// No stylesheet link, no font request, no script: a file that renders identically in ten years and
/// in an offline browser. `dir` is decided per block, so an Arabic document reads right to left with
/// its code samples and URLs still running left to right.
enum ExportWeb {

    static func document(title: String, blocks: [ExportBlock]) -> String {
        let rtl = ExportOOXML.isRightToLeft(title + " " + sample(blocks))
        var body = ""
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty {
            body += "<h1>" + ExportOOXML.escapeInline(heading) + "</h1>\n"
        }

        var listBuffer: [String] = []
        var listOrdered = false

        func flushList() {
            guard !listBuffer.isEmpty else { return }
            let tag = listOrdered ? "ol" : "ul"
            body += "<" + tag + ">\n" + listBuffer.joined(separator: "\n") + "\n</" + tag + ">\n"
            listBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block {
            case .bullet(_, let spans):
                if listOrdered { flushList() }
                listOrdered = false
                listBuffer.append("<li>" + inline(spans) + "</li>")
                continue
            case .numbered(_, _, let spans):
                if !listOrdered { flushList() }
                listOrdered = true
                listBuffer.append("<li>" + inline(spans) + "</li>")
                continue
            default:
                flushList()
            }

            switch block {
            case .heading(let level, let spans):
                let tag = "h" + String(min(6, max(2, level + 1)))
                body += "<" + tag + ">" + inline(spans) + "</" + tag + ">\n"
            case .paragraph(let spans):
                body += "<p>" + inline(spans) + "</p>\n"
            case .quote(let spans):
                body += "<blockquote><p>" + inline(spans) + "</p></blockquote>\n"
            case .code(let language, let source):
                let cls = language.isEmpty ? "" : " data-lang=\"" + ExportOOXML.escapeInline(language) + "\""
                body += "<pre dir=\"ltr\"" + cls + "><code>"
                    + ExportOOXML.escape(source) + "</code></pre>\n"
            case .table(let header, let rows):
                body += table(header: header, rows: rows)
            case .rule:
                body += "<hr>\n"
            case .bullet, .numbered:
                continue
            }
        }
        flushList()

        var page = "<!doctype html>\n<html lang=\""
        page += rtl ? "ar" : "en"
        page += "\" dir=\""
        page += rtl ? "rtl" : "ltr"
        page += "\">\n<head>\n"
        page += "<meta charset=\"utf-8\">\n"
        page += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        page += "<title>"
        page += ExportOOXML.escapeInline(heading.isEmpty ? "Firas AI" : heading)
        page += "</title>\n<style>"
        page += style
        page += "</style>\n</head>\n<body>\n<main>\n"
        page += body
        page += "</main>\n</body>\n</html>\n"
        return page
    }

    private static func sample(_ blocks: [ExportBlock]) -> String {
        var text = ""
        for block in blocks {
            switch block {
            case .heading(_, let spans), .paragraph(let spans), .bullet(_, let spans),
                 .numbered(_, _, let spans), .quote(let spans):
                text += ExportMarkdown.plain(spans) + " "
            case .table(let header, _):
                text += header.joined(separator: " ") + " "
            case .code, .rule:
                continue
            }
            if text.count > 4_000 { break }
        }
        return text
    }

    private static func inline(_ spans: [ExportInline]) -> String {
        var html = ""
        for span in spans {
            var text = ExportOOXML.escapeInline(span.text)
            if span.code { text = "<code>" + text + "</code>" }
            if span.bold { text = "<strong>" + text + "</strong>" }
            if span.italic { text = "<em>" + text + "</em>" }
            html += text
        }
        return html
    }

    private static func table(header: [String], rows: [[String]]) -> String {
        var html = "<table>\n"
        if !header.isEmpty {
            html += "<thead><tr>"
            for cell in header {
                html += "<th>" + ExportOOXML.escapeInline(cell) + "</th>"
            }
            html += "</tr></thead>\n"
        }
        html += "<tbody>\n"
        for row in rows {
            html += "<tr>"
            for cell in row {
                html += "<td>" + ExportOOXML.escapeInline(cell) + "</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    /// Deliberately small and neutral — the document has to look like a document, not like the app.
    private static let style = """
    :root{color-scheme:light}
    *{box-sizing:border-box}
    body{margin:0;background:#fff;color:#111418;\
    font:16px/1.75 -apple-system,BlinkMacSystemFont,'Segoe UI',Tahoma,Arial,sans-serif}
    main{max-width:44rem;margin:0 auto;padding:2.5rem 1.25rem 4rem}
    h1{font-size:2rem;line-height:1.25;margin:0 0 1.5rem}
    h2{font-size:1.5rem;line-height:1.3;margin:2.25rem 0 .75rem}
    h3{font-size:1.2rem;margin:1.75rem 0 .5rem}
    h4,h5,h6{font-size:1.05rem;margin:1.5rem 0 .5rem}
    p{margin:0 0 1rem}
    ul,ol{margin:0 0 1rem;padding-inline-start:1.5rem}
    li{margin:.25rem 0}
    blockquote{margin:1rem 0;padding-inline-start:1rem;\
    border-inline-start:3px solid #1F6F6B;color:#3d4550}
    hr{border:0;border-top:1px solid #e3e6ea;margin:2rem 0}
    pre{direction:ltr;text-align:left;overflow-x:auto;background:#f6f7f9;\
    border:1px solid #e3e6ea;border-radius:8px;padding:.9rem 1rem;margin:0 0 1rem}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em}
    pre code{font-size:.85rem;line-height:1.6}
    table{border-collapse:collapse;width:100%;margin:0 0 1.25rem;font-size:.95rem}
    th,td{border:1px solid #dfe3e8;padding:.5rem .65rem;text-align:start;vertical-align:top}
    th{background:#f2f4f7;font-weight:600}
    """
}
