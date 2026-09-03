import Foundation
import SwiftUI

/// Inline markdown → `AttributedString`, with the math taken out of harm's way first.
///
/// `marked` and LaTeX want the same characters, and so do Foundation's markdown parser and LaTeX:
/// left alone it reads `x_1 … y_2` as emphasis and eats the backslashes out of `\frac`. So
/// `MathScanner` stashes every equation behind a Private-Use-Area sentinel **before** parsing, and
/// the flattened Unicode form is put back **after**.
///
/// Structure and colour are separated on purpose: `structured` produces a palette-free string that
/// `MarkdownRenderer` can cache across a theme change, and `styled` paints it at render time.
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
    static func styled(_ source: AttributedString, palette: FirasPalette) -> AttributedString {
        var out = source
        var codeRanges: [Range<AttributedString.Index>] = []
        var mathRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []

        for run in out.runs {
            // Annotated on purpose: SwiftUI and UIKit both extend `AttributeDynamicLookup` with a
            // `font` key, and an unannotated read of one is ambiguous between `Font` and `UIFont`.
            let font: Font? = run.font
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            } else if font != nil {
                // `structured` sets a font on exactly one thing: a flattened equation.
                mathRanges.append(run.range)
            }
            if run.link != nil { linkRanges.append(run.range) }
        }

        for range in codeRanges {
            out[range].font = Font.system(.callout, design: .monospaced)
            out[range].foregroundColor = palette.textPrimary
            out[range].backgroundColor = palette.surfaceSunken
        }
        for range in mathRanges {
            out[range].foregroundColor = palette.textPrimary
            out[range].backgroundColor = palette.backgroundSubtle
        }
        for range in linkRanges {
            out[range].foregroundColor = palette.accent
            // Spelled out for the same reason as `font` above: `.single` alone matches both
            // `Text.LineStyle` and `NSUnderlineStyle`.
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
            let flattened = MathText.unicode(raw)
            let text = flattened.isEmpty ? raw : flattened
            var replacement = AttributedString(text)
            // An equation is an LTR island in an RTL river; mono keeps the glyph widths honest.
            replacement.font = Font.system(.body, design: .monospaced)
            target.replaceSubrange(range, with: replacement)
        }
    }
}
