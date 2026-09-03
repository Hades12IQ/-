import Foundation
import OSLog
import UIKit

/// The picture, printed through the same engine as the page.
///
/// `writePicture` in `ExportController.swift` draws the card by hand into a bitmap — a print engine
/// written from scratch — and it carries none of what the document gained on the day the PDF
/// stopped being drawn that way: no typeset mathematics, no table that is a real table, no Arabic
/// shaped by anything but a `Text` view. The page is already composed for the PDF. This renders
/// that same page as one tall snapshot, so the picture a reader sends in a chat and the file they
/// hand in are the same document, set the same way.
///
/// **Nothing here is a cliff.** Every path answers `nil`, and `nil` means the caller keeps the
/// renderer it already has: the reader asked for a picture and gets a picture even on the day
/// WebKit refuses to make a good one.
///
/// **A picture has no second page.** The PDF spills onto page two; a snapshot cannot, and
/// `DocumentPrinter` stops measuring at 16 000 points. Past that the page is not paginated, it is
/// cut — so a cut is detected here and reported through `onTrimmed`, because «الصورة طويلة فظهرت
/// مقصوصة» said out loud is a document, and said silently is a bug the reader discovers alone.
extension ExportController {

    /// The document as one picture, written to `url`, or `nil` when WebKit will not make one.
    ///
    /// Takes exactly what `documentPage` takes, and for the same reason: the page is composed in
    /// one place, once, and the picture must not be a second opinion about what the document is.
    ///
    /// - Parameters:
    ///   - onTrimmed: called, on the main actor, when the picture came out cut at the printer's
    ///     ceiling. The caller owns the toast because it owns the toast queue; the copy it wants is
    ///     `ExportPictureCopy.trimmed`, which already names the format that holds the rest.
    /// - Returns: `url` when the file is on disk, `nil` when the caller should fall back.
    func printedPicture(
        markdown: String,
        title: String,
        subtitle: String = "",
        template: DocTemplate? = nil,
        origin: DocumentOrigin,
        lang: AppLanguage,
        to url: URL,
        onTrimmed: () -> Void
    ) async -> URL? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        /* WHAT THE MODEL DESIGNED, IF IT DESIGNED ANYTHING. `documentPage` asks this same question
           and prints the model's own markup when the answer is yes; it is asked again here, the
           same way, because the two things this file does to a page — give it a margin on screen,
           and drop a title the cover already carries — are both wrong to do to somebody else's
           design. */
        let design: String?
        if case .designed = origin {
            design = DocumentHTML.authored(in: markdown)
        } else {
            design = nil
        }

        let body = design == nil
            ? PicturePaper.withoutRepeatedTitle(markdown, title: title)
            : markdown

        var html = documentPage(
            markdown: body,
            title: title,
            subtitle: subtitle,
            template: template,
            origin: origin,
            lang: lang
        )
        if PicturePaper.needsPaper(design: design) {
            html = PicturePaper.withScreenPaper(html)
        }

        guard let image = await snapshot(of: html, at: PicturePaper.scales(for: body)) else {
            return nil
        }

        guard let data = image.pngData(), !data.isEmpty else {
            Log.ui.error("document picture: png encoding failed")
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.ui.error("document picture write failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Told, never merely cut. The file is still handed over — a picture of the first fourteen
        // pages is worth having — but the reader learns in the same breath that it stops.
        if PicturePaper.wasClipped(image) { onTrimmed() }
        return url
    }

    /// One snapshot of the page, at the first scale that produces one.
    ///
    /// A fresh `DocumentPrinter` per attempt on purpose: the printer builds a window, a web view
    /// and a scheme handler for one page and tears all three down when it answers, so there is
    /// nothing here to reuse and a second attempt on a torn-down printer would be a bug rather than
    /// an optimisation.
    private func snapshot(of html: String, at scales: [CGFloat]) async -> UIImage? {
        for scale in scales {
            if let image = await DocumentPrinter().image(html: html, scale: scale) {
                return image
            }
            Log.ui.error("document picture: no snapshot at \(Int(scale), privacy: .public)x")
        }
        return nil
    }
}

// MARK: - The paper a picture is printed on

/// The three things that separate a *picture* of the page from a *print* of it: how big a bitmap to
/// ask for, where the margin comes from when there is no sheet to have one, and how to tell after
/// the fact that the page was taller than the printer would go.
private enum PicturePaper {

    /* TWO NUMBERS THAT LIVE IN ANOTHER FILE. `DocumentPrinter` lays the page out 794 points wide —
       A4 at 96 dpi, which is what a browser means by A4 — and clamps its snapshot at 16 000 points
       tall. Both are private to that file and neither is reported back with the image, so the only
       evidence left that a page was cut is the shape of the picture itself: a snapshot preserves
       the aspect of the rect it was taken from, whatever scale it was taken at. If those constants
       ever move, these move with them — or better, `image(html:scale:)` starts answering with the
       height it actually took, and this arithmetic disappears. */
    static let printerWidth: CGFloat = 794
    static let printerCeiling: CGFloat = 16_000

    /// @2x for a document short enough to be certain of, @1x for everything else — and @1x again
    /// if the first attempt came back with nothing.
    ///
    /// The clamp is not a matter of taste: 16 000 points is 16 000 pixels at @1x, just under the
    /// 16 384 a graphics device will accept in one texture. The same page at @2x asks for 32 000,
    /// and a snapshot that large fails — or, worse, comes back part blank. The height cannot be
    /// known before the page has been laid out, so it is estimated from the source: at 11.5pt down
    /// a 658-point column a character is worth roughly half a point of height, so 8 000 characters
    /// is some 4 000 points — a document that cannot come near the ceiling even if that estimate is
    /// out by a factor of two. Anything longer prints at the scale the ceiling was chosen for.
    ///
    /// The second entry is the retry, and it is not the same request twice: a page WebKit would not
    /// snapshot at 1 588 pixels wide it may well snapshot at 794, which is a quarter of the memory.
    static func scales(for markdown: String) -> [CGFloat] {
        markdown.count > 8_000 ? [1] : [2, 1]
    }

    /// Whether the app owes this page a margin on screen.
    ///
    /// **The margin lives in `@page`, and `@page` is a print rule.** `doc-base.css` sets
    /// `body { margin: 0 }` and puts every millimetre of the sheet's margin in `@page`, which is
    /// exactly right for the printer and means nothing at all to a snapshot: photographed as it
    /// stands, the composed page has Arabic running into both edges of the picture — «ما مفصول بين
    /// الفوق والجوة», the same complaint that started all of this, arriving by a different door.
    ///
    /// A page the model authored is the one exception, and only when it set `@page` itself:
    /// `DocumentHTML.printable(authored:)` reads that as "this design has decided the paper" and
    /// declines to supply one, so this declines too. A design that left the paper to the app is
    /// given a margin here for the same reason it is given one there.
    static func needsPaper(design: String?) -> Bool {
        guard let design else { return true }
        return !design.lowercased().contains("@page")
    }

    /// The composed page with a margin that exists on a screen.
    ///
    /// Injected before `</head>` so it lands after the template's own stylesheet and wins on equal
    /// specificity, and wrapped in `@media screen` so that a page which somehow reaches the printer
    /// after passing through here is not given its margin twice. The values are `doc-base`'s own:
    /// any other number would be an invention, and this one is already the sheet the same document
    /// prints on.
    static func withScreenPaper(_ html: String) -> String {
        let style = "<style>@media screen { body { padding: 20mm 18mm 22mm; } }</style>\n"
        guard let head = html.range(of: "</head>") else {
            // No head to inject into — the parser will foster this into the body, where it still
            // applies. A picture with a margin beats a correctness argument about where CSS lives.
            return html + "\n" + style
        }
        return html.replacingCharacters(in: head, with: style + "</head>")
    }

    /// Whether the picture is the page, or only the top of it.
    ///
    /// The snapshot keeps the proportions of the rect it was taken from, so the page's own height
    /// in points comes back out of the image's aspect whatever scale it was taken at — and a page
    /// that arrives exactly as tall as the ceiling is a page that was cut off there. A document
    /// that genuinely ends within a few points of the clamp is told it was trimmed when it was not;
    /// that is the harmless half of the mistake, and the other half is unforgivable.
    static func wasClipped(_ image: UIImage) -> Bool {
        guard image.size.width > 1, image.size.height > 1 else { return false }
        let points = image.size.height / image.size.width * printerWidth
        return points >= printerCeiling - 8
    }

    /// The transcript's markdown with its opening `# title` removed, when the cover is about to
    /// print those same words above it.
    ///
    /// `ExportTranscript.stream` opens every conversation with `# <title>`, and `DocumentHTML.page`
    /// sets that title on the cover as well — so the picture would carry the same line twice, once
    /// at 24pt and once at 18. The PDF has the same double, and the same rule belongs there; it is
    /// done here because here is the file that may be edited.
    ///
    /// Only ever a level-one heading, only ever the first block, and only when the two texts are
    /// the same after the bidi marks the transcript writes in front of an Arabic title are taken
    /// out — a document whose first heading merely resembles its title keeps it.
    static func withoutRepeatedTitle(_ markdown: String, title: String) -> String {
        let wanted = normalised(title)
        guard !wanted.isEmpty else { return markdown }

        var lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count,
              let heading = MarkdownBlocks.headingLevel(lines[index]),
              heading.level == 1,
              normalised(heading.text) == wanted
        else {
            return markdown
        }
        lines.removeSubrange(0...index)
        return lines.joined(separator: "\n")
    }

    /// The comparable shape of a title: no bidi controls, no line breaks, no run of spaces.
    ///
    /// The transcript prefixes an Arabic title with an RLM so the `#` does not drag it leftwards,
    /// and flattens the newlines a stored title may contain. The conversation's own `title` carries
    /// neither. Comparing them raw would find them different every time and this whole rule would
    /// quietly never fire.
    private static func normalised(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            if bidiControls.contains(scalar) { continue }
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                out.unicodeScalars.append(" ")
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LRM, RLM, ALM and the four isolates — every invisible the transcript is allowed to write.
    private static let bidiControls: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{061C}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]
}
