import Foundation
import UIKit

/// The seam between a document and the print engine.
///
/// One entry point, two callers, and a distinction the API refuses to let anyone get wrong by
/// accident: a document the reader asked Firas to **design** carries no attribution, and an export
/// of a **conversation** does. The first is the reader's own document — a footer advertising the
/// tool on it would be a letterhead on somebody else's letter. The second genuinely is from Firas.
///
/// Every path here can answer `nil`, and every caller keeps the renderer it already has. That is
/// deliberate and it is the rule this whole file is written around: the reader asked for a file, so
/// the reader gets a file, even on the day WebKit refuses to make a good one.
extension ExportController {

    /// Who the document belongs to, which is the only thing that decides whether it is signed.
    enum DocumentOrigin: Sendable {
        /// The reader asked Firas to design this. Unsigned.
        case designed
        /// An export of a conversation. Signed, as it always has been.
        case conversation
    }

    /// A composed page for this document, ready for the printer.
    ///
    /// Kept separate from `documentPDF` so the picture export and any future surface compose the
    /// page exactly once and identically — the deck viewer learned that lesson the hard way.
    func documentPage(
        markdown: String,
        title: String,
        subtitle: String = "",
        template: DocTemplate? = nil,
        origin: DocumentOrigin,
        lang: AppLanguage
    ) -> String {
        /* IF FIRAS DESIGNED IT, PRINT WHAT FIRAS DESIGNED. This is the whole point of the
           document path: the model is asked for a page in HTML and CSS, and the app's job is
           to print it — not to lay it out a second time. Composing from markdown is what an
           EXPORT needs, because a transcript has no author to design it, and it remains the
           fallback for a document whose answer came back as prose. */
        /* AND ONLY FOR A DESIGNED DOCUMENT. A transcript can perfectly well contain a code
           answer with an ```html fence in it, and taking that fence for the design would print
           one answer's markup in place of the whole conversation. `origin` already carries the
           distinction that decides this. */
        if case .designed = origin, let authored = DocumentHTML.authored(in: markdown) {
            return DocumentHTML.printable(authored: authored)
        }
        let resolved = template ?? DocTemplate.resolve(from: title + "\n" + markdown)
        return DocumentHTML.page(
            markdown: markdown,
            title: title,
            subtitle: subtitle,
            template: resolved,
            lang: lang,
            attribution: attribution(for: origin, lang: lang)
        )
    }

    /// The PDF, printed by WebKit, or `nil` — in which case the caller falls back.
    func documentPDF(
        markdown: String,
        title: String,
        subtitle: String = "",
        template: DocTemplate? = nil,
        origin: DocumentOrigin,
        lang: AppLanguage
    ) async -> Data? {
        let html = documentPage(
            markdown: markdown,
            title: title,
            subtitle: subtitle,
            template: template,
            origin: origin,
            lang: lang
        )
        let printer = DocumentPrinter()
        let data = await printer.pdf(html: html)
        recordDocumentDiagnostics(printer.diagnostics)
        return data
    }

    /// The same page as one tall picture, for the image export.
    func documentImage(
        markdown: String,
        title: String,
        subtitle: String = "",
        template: DocTemplate? = nil,
        origin: DocumentOrigin,
        lang: AppLanguage
    ) async -> UIImage? {
        let html = documentPage(
            markdown: markdown,
            title: title,
            subtitle: subtitle,
            template: template,
            origin: origin,
            lang: lang
        )
        return await DocumentPrinter().image(html: html)
    }

    // MARK: - Signing

    /// «ماكو حقوق فراس اي اي لان هو تصميم» — the owner's rule, encoded once.
    private func attribution(for origin: DocumentOrigin, lang: AppLanguage) -> String {
        switch origin {
        case .designed:
            return ""
        case .conversation:
            return lang == .arabic ? "صُدِّر من فِراس AI" : "Exported from Firas AI"
        }
    }
}
