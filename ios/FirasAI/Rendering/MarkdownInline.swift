import Foundation
import SwiftUI
import UIKit

/// Marks a run of an inline string as **mathematics**, and carries the expression that produced it.
///
/// The value is the raw span exactly as `MathScanner` stashed it, delimiters included, so the run
/// can be turned back into a `MathScanner.Span` — and therefore into a typeset glyph — anywhere
/// downstream, without the block scanner and the renderer having to agree on an order.
///
/// It exists because the alternative failed in the way the owner reported: with the equation
/// flattened to plain characters and nothing else, the only thing telling a renderer "this is an
/// equation" was *a font*, and the code path that paints a font also paints a code plate. A
/// mathematics run now says what it is.
enum FirasMathAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "firasMath"
}

/// Inline markdown → `AttributedString`, with the math taken out of harm's way first.
///
/// `marked` and LaTeX want the same characters, and so do Foundation's markdown parser and LaTeX:
/// left alone it reads `x_1 … y_2` as emphasis and eats the backslashes out of `\frac`. So
/// `MathScanner` stashes every equation behind a Private-Use-Area sentinel **before** parsing, and
/// the flattened Unicode form is put back **after**, tagged with `FirasMathAttribute`.
///
/// Structure and colour are separated on purpose: `structured` produces a palette-free string that
/// `MarkdownRenderer` can cache across a theme change, and `styled` paints it at render time.
/// `composed` is the third step and the only one that knows about typesetting: where a glyph has
/// been drawn for a mathematics run, it swaps the Unicode approximation for the real thing.
enum MarkdownInline {

    /// Frozen entry point: parse and paint in one step.
    static func attributed(_ text: String, lang: AppLanguage, palette: FirasPalette) -> AttributedString {
        styled(structured(text, lang: lang), palette: palette)
    }

    /// Parse only. No colours — nothing here goes stale when the theme changes.
    static func structured(_ text: String, lang: AppLanguage) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        let (protected, spans) = MathScanner.protect(text)

        var result: AttributedString
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: protected, options: options) {
            result = parsed
        } else {
            // A malformed inline construct must never cost the reader the sentence.
            result = AttributedString(MathScanner.restore(protected, spans: spans))
            return result
        }

        substituteMath(&result, spans: spans)
        return result
    }

    /// Paint an already-parsed string. Idempotent, so a cached block can be re-styled every frame.
    ///
    /// **A mathematics run is not a code run.** It was being drawn as one — monospace, on
    /// `surfaceSunken`'s darker plate — and the owner's note was exact: «اللون الي خلف اللاتكس
    /// خليه مطابق للون المحادثة». So math is given nothing at all here: no face, no ground, no
    /// ink of its own. It inherits the paragraph it sits in, which is the conversation's own
    /// ground and the conversation's own ink, and in a heading it inherits the heading.
    static func styled(_ source: AttributedString, palette: FirasPalette) -> AttributedString {
        var out = source
        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []

        for run in out.runs {
            let isMath = run[FirasMathAttribute.self] != nil
            // Checked in this order on purpose: an equation that also carries `.code` — from a
            // backtick the parser paired across the sentinel — is mathematics first.
            if !isMath, let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            }
            if run.link != nil { linkRanges.append(run.range) }
        }

        for range in codeRanges {
            out[range].font = Font.system(.callout, design: .monospaced)
            out[range].foregroundColor = palette.textPrimary
            out[range].backgroundColor = palette.surfaceSunken
        }
        for range in linkRanges {
            out[range].foregroundColor = palette.accent
            // Spelled out on purpose: SwiftUI and UIKit both extend `AttributeDynamicLookup` here,
            // and `.single` alone is ambiguous between `Text.LineStyle` and `NSUnderlineStyle`.
            out[range].underlineStyle = Text.LineStyle.single
        }
        return out
    }

    /// Plain text of an inline string — for direction detection and accessibility labels.
    static func plainText(_ source: AttributedString) -> String {
        String(source.characters)
    }

    // MARK: - Math

    private static func substituteMath(_ target: inout AttributedString, spans: [String]) {
        guard !spans.isEmpty else { return }
        for (index, raw) in spans.enumerated() {
            let token = MathScanner.token(index)
            guard let range = target.range(of: token) else { continue }
            guard let span = MathScanner.span(for: raw) else {
                target.replaceSubrange(range, with: AttributedString(raw))
                continue
            }
            let flattened = MathText.unicode(span.tex)
            let body = span.isRecovered ? span.raw : (flattened.isEmpty ? span.tex : flattened)
            var replacement = AttributedString(isolated(body))
            replacement[FirasMathAttribute.self] = span.raw
            target.replaceSubrange(range, with: replacement)
        }
    }

    /// An equation is an LTR island in an RTL river. The isolate does here what `dir="ltr"` does on
    /// the web: the formula keeps its own order — a leading minus stays on the left of the number,
    /// `x ↦ π/2 − x` stays in that order — and it cannot drag the Arabic sentence around it. An
    /// expression that genuinely contains Arabic (a `\text{…}` group) gets the first-strong
    /// isolate instead, so the Arabic inside it still reads right to left.
    private static func isolated(_ body: String) -> String {
        let opener: Character = containsArabic(body) ? "\u{2068}" : "\u{2066}"
        return String(opener) + body + "\u{2069}"
    }

    private static func containsArabic(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 0x0600 && v <= 0x06FF) || (v >= 0x0750 && v <= 0x077F) { return true }
            if (v >= 0xFB50 && v <= 0xFDFF) || (v >= 0xFE70 && v <= 0xFEFF) { return true }
        }
        return false
    }

    // MARK: - Typesetting inline

    /// Every mathematics run of an inline string, in reading order.
    ///
    /// The caller uses this to ask `MathIsland` for the glyphs it already drew — the whole-message
    /// priming pass sends inline spans as well as display ones, so by the time a paragraph is laid
    /// out its formulas are usually already bitmaps waiting to be collected.
    static func mathSpans(in source: AttributedString) -> [MathScanner.Span] {
        var found: [MathScanner.Span] = []
        for run in source.runs {
            guard let raw = run[FirasMathAttribute.self], let span = MathScanner.span(for: raw) else { continue }
            found.append(span)
        }
        return found
    }

    /// The string as one `Text`, with every mathematics run that has a glyph drawn as that glyph.
    ///
    /// This is the piece a single `AttributedString` cannot express: an attributed string has no
    /// attachment, but `Text` composes, and `Text` interpolates an `Image`. So the paragraph is
    /// cut at each equation and reassembled — prose, glyph, prose — into one `Text` that still
    /// wraps, still selects, and still takes the paragraph's font everywhere except the bitmap.
    ///
    /// Anything without a glyph keeps the Unicode form it already had. Nothing here can leave a
    /// hole: a miss is not an error, it is the fallback still being on screen.
    static func composed(_ source: AttributedString, glyphs: [String: MathGlyph]) -> Text {
        guard !glyphs.isEmpty else { return Text(source) }

        var pieces: [Text] = []
        var cursor = source.startIndex
        var used = false

        for run in source.runs {
            guard let raw = run[FirasMathAttribute.self],
                  let span = MathScanner.span(for: raw),
                  let glyph = glyphs[span.id],
                  fitsInline(glyph),
                  run.range.lowerBound >= cursor else { continue }
            if cursor < run.range.lowerBound {
                pieces.append(Text(AttributedString(source[cursor..<run.range.lowerBound])))
            }
            pieces.append(picture(glyph))
            cursor = run.range.upperBound
            used = true
        }

        guard used else { return Text(source) }
        if cursor < source.endIndex {
            pieces.append(Text(AttributedString(source[cursor..<source.endIndex])))
        }

        var out = Text(verbatim: "")
        for piece in pieces { out = out + piece }
        return out
    }

    /// A bitmap cannot be broken across two lines, so an equation wider than a phone's text column
    /// stays text — where it wraps — and only the short ones, which is nearly all inline maths,
    /// become glyphs. The height bound catches a display equation that arrived inline.
    private static let maximumInlineWidth: CGFloat = 240
    private static let maximumInlineHeight: CGFloat = 120

    private static func fitsInline(_ glyph: MathGlyph) -> Bool {
        let size = glyph.image.size
        guard size.width > 1, size.height > 1 else { return false }
        return size.width <= maximumInlineWidth && size.height <= maximumInlineHeight
    }

    /// The glyph, sitting on the sentence's baseline.
    ///
    /// An image in a `Text` rests its *bottom edge* on the baseline, so a fraction — whose bottom
    /// half belongs below the line — floats. `MathIsland` measured where the equation's own
    /// baseline is inside the bitmap, and everything under it is the depth the image has to be
    /// dropped by.
    private static func picture(_ glyph: MathGlyph) -> Text {
        // `.original` is not decoration. This `Text` is drawn under the paragraph's
        // `.foregroundStyle`, and a template image inside a `Text` is painted in that ink — which
        // would replace the equation with a solid rectangle of `textPrimary`.
        let image = Image(uiImage: glyph.image)
            .renderingMode(.original)
            .interpolation(.high)
            .antialiased(true)
        let depth = max(0, glyph.image.size.height - glyph.baseline)
        return Text("\(image)").baselineOffset(-depth)
    }
}
