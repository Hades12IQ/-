import Foundation

/// A document, composed as a web page so that WebKit can print it.
///
/// The renderer this replaces drew a document into a `CGContext` by hand, which is to say it was a
/// print engine written from scratch — and every part of a print engine failed in turn: the margin,
/// then the page breaks, then the tables, then Arabic, then the mathematics. WebKit already is a
/// print engine, it ships on the device, and it typesets KaTeX. So a document is now a page, and
/// `DocumentPrinter` prints it.
///
/// Two rules hold everything here together.
///
/// **Every block picks its own direction.** A document is not left-to-right or right-to-left; each
/// of its paragraphs is. An English quotation inside an Arabic research paper keeps its own
/// direction, its own bullet side and its own punctuation, and a code listing is always left to
/// right whatever surrounds it. `ExportOOXML.isRightToLeft` already answers that question for Word,
/// and asking it the same way here is what keeps the two exports from disagreeing about the same
/// paragraph.
///
/// **Model output is untrusted text.** Every character of it is escaped on the way in, and the only
/// content a script ever sees is a JSON payload built by `JSONSerialization`. There is no path in
/// this file by which an answer can inject markup into the page it is being printed on.
enum DocumentHTML {

    /// What the printer waits for. The page sets it once the mathematics has been typeset, so a PDF
    /// is never taken of a document whose equations are still source.
    static let readyFlag = "firasDocumentReady"

    // MARK: - Composition

    /// One complete page: the template's stylesheet, the document's furniture, and its content.
    ///
    /// - Parameters:
    ///   - markdown: the document body, as the model wrote it.
    ///   - title: the heading of the cover, and the PDF's own title.
    ///   - subtitle: an optional line under it.
    ///   - template: which of the website's five looks to wear.
    ///   - lang: the fallback direction, used only for a block with no strong character in it.
    ///   - attribution: the line at the foot of the last page. **Empty for a document the reader
    ///     asked Firas to design** — that document is theirs, and a footer advertising the tool
    ///     would be a letterhead on someone else's letter. A conversation export is *from* Firas
    ///     and passes one.
    static func page(
        markdown: String,
        title: String,
        subtitle: String,
        template: DocTemplate,
        lang: AppLanguage,
        attribution: String
    ) -> String {
        /* THE ANCHOR COUNTER BELONGS TO A COMPOSITION, so it is reset by the thing that composes.
           `DocumentPrinter` also resets it, but the printer runs AFTER this — it was clearing the
           count the next document would start from, which is right only for as long as every
           composed page is immediately printed. The moment one is composed and not printed, or
           two are composed before either goes to the printer, every anchor in the second document
           is numbered past the end of its own contents page and every link in it is dead. */
        headingCount = 0

        let arabic = ExportOOXML.isRightToLeft(markdown, fallback: lang == .arabic)
        let blocks = DocumentHTML.blocks(from: markdown, lang: lang)

        var body = ""
        body += cover(title: title, subtitle: subtitle, template: template, arabic: arabic)
        if template.showsTableOfContents {
            body += tableOfContents(blocks, arabic: arabic)
        }
        body += "<main class=\"doc-body\">\n"
        for block in blocks {
            body += html(for: block, lang: lang, template: template)
        }
        body += "</main>\n"
        if !attribution.isEmpty {
            body += "<footer class=\"doc-attribution\">" + escape(attribution) + "</footer>\n"
        }

        return shell(
            body: body,
            css: template.css,
            arabic: arabic,
            title: title
        )
    }

    // MARK: - The shell

    /// `<head>` through `</html>`.
    ///
    /// KaTeX comes from the app's own bundle over `firas-katex://katex/`, served by
    /// `MathIslandAssets` — the same handler and the same pinned 0.16.11 build the transcript uses,
    /// so an equation looks identical in the conversation and in the file. Nothing here reaches the
    /// network: a document must print on a plane.
    private static func shell(body: String, css: String, arabic: Bool, title: String) -> String {
        let scheme = MathIslandAssets.scheme + "://katex/"
        var out = "<!DOCTYPE html>\n"
        out += "<html lang=\"" + (arabic ? "ar" : "en") + "\" dir=\"" + (arabic ? "rtl" : "ltr") + "\">\n"
        out += "<head>\n<meta charset=\"utf-8\">\n"
        out += documentCSP + "\n"
        out += "<title>" + escape(title) + "</title>\n"
        out += "<link rel=\"stylesheet\" href=\"" + scheme + "katex.min.css\">\n"
        out += "<style>\n" + documentFontCSS + "\n" + css + "\n</style>\n"
        out += "<script src=\"" + scheme + "katex.min.js\"></script>\n"
        out += "<script src=\"" + scheme + "mhchem.min.js\"></script>\n"
        out += "</head>\n<body>\n"
        out += body
        out += mathScript()
        out += "</body>\n</html>\n"
        return out
    }

    /// Typesets every `<span data-tex>` and `<div data-tex>` the composer left behind, then raises
    /// the ready flag.
    ///
    /// The flag is raised on the way out of a `try`/`finally`, so a single expression KaTeX refuses
    /// cannot leave the printer waiting for a page that will never say it is done: a document with
    /// one bad formula prints with that formula as source and everything else typeset.
    private static func mathScript() -> String {
        var out = "<script>\n"
        out += "(function () {\n"
        out += MathIslandAssets.typesettingScript + "\n"
        out += "  function draw(node) {\n"
        out += "    var tex = node.getAttribute('data-tex') || '';\n"
        out += "    var display = node.getAttribute('data-display') === '1';\n"
        out += "    try {\n"
        out += "      if (attempt(tidy(tex), display, node, '#b3261e') || attempt(repair(tex), display, node, '#b3261e')) return;\n"
        out += "      katex.render(tex, node, { displayMode: display, throwOnError: false, strict: false, trust:false, output:'html', macros:copyMacros() });\n"
        out += "    } catch (e) {\n"
        out += "      node.textContent = tex;\n"
        out += "    }\n"
        out += "  }\n"
        out += "  try {\n"
        out += "    var nodes = document.querySelectorAll('[data-tex]');\n"
        out += "    for (var i = 0; i < nodes.length; i++) { draw(nodes[i]); }\n"
        out += "  } catch (e) {}\n"
        out += "  function finish() { window." + readyFlag + " = true; }\n"
        out += "  if (document.fonts && document.fonts.ready) {\n"
        out += "    document.fonts.ready.then(finish).catch(finish);\n"
        out += "  } else {\n"
        out += "    finish();\n"
        out += "  }\n"
        out += "})();\n"
        out += "</script>\n"
        return out
    }

    // MARK: - Furniture

    private static func cover(title: String, subtitle: String, template: DocTemplate, arabic: Bool) -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var out = "<header class=\"doc-cover doc-cover--" + template.slug + "\">\n"
        out += "<h1 class=\"doc-title\">" + escape(title) + "</h1>\n"
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            out += "<p class=\"doc-subtitle\">" + escape(trimmed) + "</p>\n"
        }
        out += "</header>\n"
        return out
    }

    /// Headings two and three, in order, each pointing at the anchor `html(for:)` gave it.
    ///
    /// The website omits this for the ministry paper — an exam does not open with a contents page —
    /// and `DocTemplate.showsTableOfContents` carries that rule rather than repeating it here.
    private static func tableOfContents(_ blocks: [MDBlock], arabic: Bool) -> String {
        var rows: [String] = []
        var index = 0
        for heading in headings(in: blocks) {
            guard heading.level >= 2, heading.level <= 3 else { continue }
            let plain = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }
            index += 1
            rows.append(
                "<li class=\"doc-toc__item doc-toc__item--l\(heading.level)\">"
                    + "<a href=\"#h\(index)\">" + escape(plain) + "</a></li>"
            )
        }
        guard rows.count >= 2 else { return "" }
        var out = "<nav class=\"doc-toc\">\n"
        out += "<h2 class=\"doc-toc__head\">" + escape(arabic ? "المحتويات" : "Contents") + "</h2>\n"
        out += "<ol class=\"doc-toc__list\">\n" + rows.joined(separator: "\n") + "\n</ol>\n"
        out += "</nav>\n"
        return out
    }

    /// Every heading in the document, in the order `html(for:)` will reach them.
    ///
    /* THE TWO WALKS HAVE TO BE ONE WALK. The contents page numbers its links `#h1, #h2, …` and
       `heading(level:_:lang:)` numbers the anchors with a counter of its own; they agree only for
       as long as both see the same headings in the same order. This one used to read the top level
       and stop, while the renderer descends into a quote and into every list item — so one
       `> ## عنوان` anywhere in a document silently pushed every anchor after it one ahead of the
       link that points at it, and the reader tapped a contents entry and landed on the wrong
       section, or on nothing. Depth-first, quote children then list items, in exactly the order
       `html(for:)` emits them. */
    private static func headings(in blocks: [MDBlock]) -> [(level: Int, text: String)] {
        var found: [(level: Int, text: String)] = []
        collect(blocks, into: &found)
        return found
    }

    private static func collect(_ blocks: [MDBlock], into found: inout [(level: Int, text: String)]) {
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                found.append((level: level, text: String(text.characters)))
            case .quote(let children):
                collect(children, into: &found)
            case .list(_, _, let items):
                for item in items { collect(item, into: &found) }
            default:
                continue
            }
        }
    }

    // MARK: - Parsing

    /// The app's own block parser, reused. A second markdown implementation would drift from the
    /// transcript's within a week, and the reader would find a document that disagrees with the
    /// answer it was made from.
    static func blocks(from markdown: String, lang: AppLanguage) -> [MDBlock] {
        MarkdownBlocks.split(markdown, streaming: false).map {
            MarkdownBlocks.parse($0, lang: lang)
        }
    }

    // MARK: - Escaping

    /// Everything the model wrote passes through this before it reaches the page.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
