import Foundation

/// A document the MODEL designed, printed as it was written.
///
/// This is the owner's instruction and it is not the same as the composer beside it: «فراس اي اي
/// يصمم ملف عبر اج تي ام ال سي بلس بلس ويحط بي كلشي حتى لو معادلات ويكون تصميم احترافي وراها يصدره
/// ك بي دي اف». Firas designs the file — its layout, its type, its colour, its cover — in HTML and
/// CSS, and the app's only job is to print what it designed.
///
/// The composer stays for the other path: an EXPORT of a conversation is a transcript, and a
/// transcript has no author to design it. Two different things, two different routes.
///
/// What this adds to the model's document, and it is deliberately almost nothing:
/// * KaTeX, so `$…$` in the design is typeset rather than left as source. The model cannot load it
///   itself — the page has no network — so the app hands it in.
/// * The ready flag the printer waits on.
/// * A `@page` rule ONLY when the design has none, because a document with no page size prints at
///   whatever the engine assumes and that is how a beautiful design comes out cropped.
/// Everything else is the model's and is left exactly as written.
extension DocumentHTML {

    /// The HTML the model wrote, if it wrote any.
    ///
    /// Two shapes are accepted, because a model asked for a document will produce either: a fenced
    /// ```html block, or a bare document that opens with `<!DOCTYPE` or `<html`. Anything else is
    /// not a design and the caller composes from markdown instead.
    static func authored(in markdown: String) -> String? {
        if let fenced = fencedHTML(in: markdown) { return fenced }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(200).lowercased()
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return trimmed }
        return nil
    }

    /// The first ```html fence, whole.
    private static func fencedHTML(in markdown: String) -> String? {
        var lineStart = markdown.startIndex
        var opened: (marker: Character, bodyStart: String.Index)?
        var body = ""

        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let next = lineEnd == markdown.endIndex ? markdown.endIndex : markdown.index(after: lineEnd)

            if let open = opened {
                if let first = trimmed.first, first == open.marker, trimmed.count >= 3,
                   trimmed.allSatisfy({ $0 == open.marker }) {
                    return body.isEmpty ? nil : body
                }
                body += line + "\n"
            } else if let first = trimmed.first, first == "`" || first == "~", trimmed.count >= 3 {
                var name = Substring(trimmed)
                while let head = name.first, head == first { name = name.dropFirst() }
                let label = name.trimmingCharacters(in: .whitespaces).lowercased()
                if label == "html" || label == "html5" {
                    opened = (first, next)
                }
            }

            if lineEnd == markdown.endIndex { break }
            lineStart = next
        }
        // An unterminated fence is still a document: the model ran out of room, not out of design.
        return body.isEmpty ? nil : body
    }

    /// The model's document, with the three things it cannot provide for itself put in.
    static func printable(authored html: String) -> String {
        var out = html
        let scheme = MathIslandAssets.scheme + "://katex/"

        let assets = [
            "<link rel=\"stylesheet\" href=\"" + scheme + "katex.min.css\">",
            "<script src=\"" + scheme + "katex.min.js\"></script>",
            "<script src=\"" + scheme + "mhchem.min.js\"></script>",
        ].joined(separator: "\n")

        /* A PAGE SIZE ONLY IF THE DESIGN HAS NONE. A model that wrote its own `@page` has decided
           the paper, and overruling it would crop the design it built to that size. */
        let paper = html.lowercased().contains("@page")
            ? ""
            : "\n<style>@page { size: A4; margin: 18mm 16mm; }</style>"

        let injection = assets + paper

        if let head = out.range(of: "</head>", options: .caseInsensitive) {
            out.replaceSubrange(head, with: injection + "\n</head>")
        } else if let openBody = out.range(of: "<body", options: .caseInsensitive) {
            // No head at all: put the assets in front of the body and let the parser build one.
            out.replaceSubrange(openBody, with: injection + "\n<body")
        } else {
            out = injection + "\n" + out
        }

        /* THE MATHEMATICS, AND THE FLAG THE PRINTER WAITS ON. Appended rather than injected into
           the model's own scripts: whatever it wrote runs first and untouched, and this runs after
           the document is parsed. `renderMathInElement` walks the design wherever the equations
           happen to be, because the app does not know how the model laid them out. */
        out += mathAndReadyScript()
        return out
    }

    private static func mathAndReadyScript() -> String {
        var out = "\n<script>\n"
        out += "(function () {\n"
        out += "  function tex(node) {\n"
        out += "    var raw = node.getAttribute('data-tex') || node.textContent || '';\n"
        out += "    var display = node.getAttribute('data-display') === '1'\n"
        out += "      || (node.tagName || '').toLowerCase() === 'div';\n"
        out += "    try { katex.render(raw, node, { displayMode: display, throwOnError: false, strict: false }); }\n"
        out += "    catch (e) { node.textContent = raw; }\n"
        out += "  }\n"
        out += "  try {\n"
        // A design may mark its equations either way: an explicit attribute, or the delimiters.
        out += "    var marked = document.querySelectorAll('[data-tex]');\n"
        out += "    for (var i = 0; i < marked.length; i++) { tex(marked[i]); }\n"
        out += "    if (window.renderMathInElement) {\n"
        out += "      renderMathInElement(document.body, {\n"
        out += "        delimiters: [\n"
        out += "          { left: '$$', right: '$$', display: true },\n"
        out += "          { left: '\\\\[', right: '\\\\]', display: true },\n"
        out += "          { left: '$', right: '$', display: false },\n"
        out += "          { left: '\\\\(', right: '\\\\)', display: false }\n"
        out += "        ],\n"
        out += "        throwOnError: false\n"
        out += "      });\n"
        out += "    }\n"
        out += "  } catch (e) {}\n"
        out += "  function finish() { window." + readyFlag + " = true; }\n"
        out += "  if (document.fonts && document.fonts.ready) {\n"
        out += "    document.fonts.ready.then(finish).catch(finish);\n"
        out += "  } else { finish(); }\n"
        out += "})();\n"
        out += "</script>\n"
        return out
    }
}
