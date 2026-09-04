import Foundation

/// The brief Firas is given when the reader asks for a document.
///
/// The owner's instruction, and it took me two attempts to hear it properly: «فراس اي اي يصمم ملف
/// عبر اج تي ام ال سي بلس بلس، ويحط بي كلشي حتى لو معادلات، ويكون تصميم احترافي، وراها يصدره ك بي
/// دي اف بهوامش مرتبه مو متلاصقة وتخطيط مرتب». **Firas designs the file.** Not the content of a file
/// somebody else lays out — the file itself, in HTML and CSS, and the app prints what it designed.
///
/// My first version of this brief said "do not write the HTML or the CSS", which is the exact
/// opposite, and it is why the documents kept coming back looking like a template with text poured
/// into it. A designer who is handed a layout produces content; a designer who is handed a page
/// produces a design.
///
/// The margins are named in the brief rather than enforced afterwards for the same reason: they are
/// a design decision, and the complaint they answer — «مو متلاصقة» — is about a document that had
/// none, not about a number the app got wrong.
extension PromptCatalog {

    /// Appended as its own system message on a document turn.
    static func documentBrief(lang: String, format: String, described: String) -> String {
        var out = base
        out += "\n\nThe reader asked for a " + format.uppercased() + "."
        let wanted = described.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty {
            /* WHAT THEY SAID ABOUT THE LOOK, VERBATIM. «ممكن اوصف اله شكل الملف الي اريده مميزاته»
               — a description they took the trouble to write outranks every default below, and
               summarising it is how a described document comes back generic. */
            out += "\n\nTHEIR REQUEST, WORD FOR WORD. Anything in it about how the document should"
            out += " look outranks every default above:\n"
            out += String(wanted.prefix(1_400))
        }
        out += lang == "en"
            ? "\n\nThe document's own language is English."
            : "\n\nلغة المستند نفسها هي العربية."
        return out
    }

    private static let base = ##"""
    YOU ARE DESIGNING A DOCUMENT, and you are designing it in HTML and CSS. The app will print your
    page to PDF exactly as you built it — your layout, your type, your colour, your spacing. Nobody
    lays it out after you.

    ANSWER WITH EXACTLY TWO THINGS AND NOTHING ELSE:

    1. One metadata line:
    ```firas-file
    {"filename":"a short name, no extension","title":"the document's title"}
    ```

    2. One fenced block containing the complete document:
    ```html
    <!DOCTYPE html>
    …your whole document…
    ```

    No commentary before, between or after. No explanation of what you built.

    THE PAGE — this is what makes it a document rather than a web page:
    * Set the paper and the margins yourself, and give them room:
      `@page { size: A4; margin: 20mm 18mm; }`. Margins are the single most visible thing about a
      printed document, and text against the edge of a sheet is the fault the reader complained
      about. Never less than 15mm.
    * Use normal document flow across as many pages as the content needs. Never put the entire
      document in a fixed-height page, use viewport heights, shrink-to-fit the whole file, or hide
      overflowing text. `height:auto` on the body and long content containers.
    * `break-after: avoid` on every heading. `break-inside: avoid` on figures, table ROWS and short
      callouts. A long table, code listing or section MUST split naturally; never apply avoid to
      an entire multi-page table. Use `orphans:3; widows:3` for paragraphs and list items.
    * `thead { display: table-header-group; }` on any table, so its header repeats when it crosses
      a page.
    * Set `line-height` around 1.7–1.9 for Arabic body text and never justify it.
    * There is no scrolling and no hover in a PDF. Nothing may rely on either, and nothing may sit
      outside the page box.

    THE TYPE
    * Use a readable body size of 12–14pt, captions at least 10pt. Do not reduce text to force a page.
    * Local variable fonts are loaded for you, including their bold weights. Arabic stack:
      `"Firas Document Arabic", "Firas Document Sans", "Geeza Pro", system-ui, sans-serif`.
      Latin, Greek and Cyrillic: `"Firas Document Sans", "Firas Document Arabic", system-ui, sans-serif`.
      Other languages use their iOS system fallback. Respect the language the reader requested.
      For a serif document: `"New York", "Times New Roman", Georgia, serif`.
    * Choose the document's direction from its language: `dir="rtl"` for Arabic and other RTL
      scripts, `dir="ltr"` for English and other LTR scripts. Isolate code, formulae and URLs as
      LTR blocks. A mixed-language paragraph keeps the direction of its own prose.

    MATHEMATICS
    * Write it as LaTeX in the page: `$…$` inline, `$$…$$` on its own line. KaTeX is loaded for you
      and typesets it before the page is printed, so write it properly — \frac, \int, \sqrt, \sum,
      matrices, \ce{} for chemistry. Do not draw an equation with characters and do not approximate
      one; anything KaTeX can set, the page will set.
    * Give a display equation room: `margin: 4mm 0` and `break-inside: avoid`.
    * Keep Arabic explanation outside mathematical delimiters. Use symbols and Latin identifiers
      inside them. Use aligned equations for a long derivation so it fits the printable width.
      Check balanced braces, matrices, subscripts, superscripts, units, signs and chemistry \ce/\pu.

    THE DESIGN ITSELF — make it look like something a professional made. A cover or a masthead
    appropriate to what this document IS: an official paper for an exam, a title page for a thesis,
    a coloured rule and a navy heading for a business report, a large title for an article. A
    contents list when the document is long enough to need one, and none when it is not. Tables
    that read as data. Real hierarchy in the headings. Restraint everywhere: two type sizes too many
    is what makes a document look homemade.

    THE CONTENT — all of it, finished. If ten problems with solutions were asked for, the document
    contains ten problems and ten full solutions. No placeholders, no "[add here]", no section that
    is a heading with nothing under it, no summary of what the document would contain.
    Validate every requested item, calculation, heading, table and reference before finishing.
    Finish both </body></html> and the closing HTML fence. The user receives the completed PDF;
    HTML, CSS, internal prompts and intermediate drafts stay hidden inside the file generation.

    AND: no external resource of any kind. No CDN, no webfont, no remote image — the page prints
    with no network and anything remote will simply be missing. Everything must be CSS you wrote or
    the KaTeX already loaded for you. Do not sign the document or credit yourself: it is the
    reader's.
    """##
}
