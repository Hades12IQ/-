import SwiftUI
import UIKit

/// One equation, in place, typeset.
///
/// The owner's report was «اللاتكس ما تتحول عدل، تتحول شكل غريب و تختفي» — a formula renders while
/// the answer streams and then disappears. Three rules hold that shut, and this view is where two
/// of them are visible:
///
/// * **Never typeset an unclosed delimiter.** `MathScanner.spans` only returns runs whose closing
///   delimiter has arrived, and `MathScanner.isTypesettable` refuses a half-streamed expression
///   here as well, so an equation still being typed stays plain text until it is whole.
/// * **An equation that rendered is never removed.** Bitmaps are keyed by the expression and the
///   theme, not by the message, so end of stream, a regenerate, a version switch and a theme change
///   all leave what is on screen exactly where it is.
///
/// While a formula is being drawn — and forever, if the CDN is unreachable — the `MathText.unicode`
/// form is on screen. The equation is never blank, never an error box, and never a spinner.
struct MathBlockView: View {

    private let tex: String
    private let isDisplay: Bool
    private let messageID: String
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let fontScale: FontScale
    private let background: Color
    private let motionOn: Bool

    /// - Parameters:
    ///   - tex: the bare expression, with no delimiters (`MDBlock.mathDisplay` carries exactly this).
    ///   - display: `$$…$$` / `\[…\]` are display; `$…$` / `\(…\)` are inline.
    ///   - messageID: the answer this equation belongs to. Carried for the caller's bookkeeping;
    ///     the glyph cache is keyed by the expression, so the same formula is drawn once.
    ///   - background: the colour the equation sits on, so the bitmap composites invisibly.
    init(
        tex: String,
        display: Bool,
        messageID: String,
        palette: FirasPalette,
        lang: AppLanguage,
        fontScale: FontScale = .medium,
        background: Color? = nil,
        motionOn: Bool = true
    ) {
        self.tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isDisplay = display
        self.messageID = messageID
        self.palette = palette
        self.lang = lang
        self.fontScale = fontScale
        self.background = background ?? palette.background
        self.motionOn = motionOn
    }

    var body: some View {
        let style = MathIslandStyle(palette: palette, background: background, fontScale: fontScale)
        let identifier = MathScanner.identifier(tex: tex, isDisplay: isDisplay)
        let typesettable = MathScanner.isTypesettable(tex)
        let glyph: MathGlyph? = typesettable
            ? MathIsland.shared.glyph(for: identifier, style: style)
            : nil
        let fade: Animation? = motionOn ? Animation.easeOut(duration: 0.16) : nil
        // Flattened once per body, not once per label: a landing bitmap redraws every math row on
        // screen, and `MathText.unicode` is a full pass over the expression.
        let unicode = MathText.unicode(tex)
        let line = unicode.isEmpty ? tex : unicode

        return layout(glyph, line: line)
            .animation(fade, value: glyph != nil)
            .task(id: identifier + "|" + style.key) { await request(style) }
    }

    /// `.task` runs when the row appears and whenever its id changes, so a row that scrolled away
    /// and came back asks again — which is what lets the island's LRU evict without stranding a
    /// visible equation.
    private func request(_ style: MathIslandStyle) {
        guard !tex.isEmpty, MathScanner.isTypesettable(tex) else { return }
        MathIsland.shared.request([MathIslandItem(tex: tex, isDisplay: isDisplay)], style: style)
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ glyph: MathGlyph?, line: String) -> some View {
        if let glyph {
            typeset(glyph, line: line)
        } else {
            flattened(line)
        }
    }

    /// An LTR island in an RTL river: the formula keeps its own direction, the sentence keeps its
    /// own. Display equations centre and, when one is wider than the column, scroll sideways
    /// instead of shrinking — the same behaviour `.katex-display { overflow-x: auto }` gives the
    /// web.
    @ViewBuilder
    private func typeset(_ glyph: MathGlyph, line: String) -> some View {
        let picture = Image(uiImage: glyph.image)
            .interpolation(.high)
            .antialiased(true)
        let spoken = spokenText(line)

        if isDisplay {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    picture
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    picture.padding(.horizontal, 2)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .forceLTR()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
        } else {
            picture
                .alignmentGuide(.firstTextBaseline) { _ in glyph.baseline }
                .forceLTR()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    /// The offline path, and the path a half-arrived equation takes: `MathText.unicode` in mono,
    /// LTR, centred when the equation owns its line. This is what the reader sees first and what
    /// they keep if KaTeX never arrives — never an empty box.
    @ViewBuilder
    private func flattened(_ line: String) -> some View {
        let spoken = spokenText(line)

        if line.isEmpty {
            EmptyView()
        } else if isDisplay {
            Text(verbatim: line)
                .font(FirasType.mono)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
                .forceLTR()
                .accessibilityLabel(Text(verbatim: spoken))
        } else {
            Text(verbatim: line)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .background(palette.backgroundSubtle)
                .forceLTR()
                .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    /// VoiceOver never reads a bitmap: it reads the flattened equation, in the reader's language.
    private func spokenText(_ line: String) -> String {
        Strings.Math.equation(lang) + ": " + (line.isEmpty ? tex : line)
    }
}

// MARK: - Whole-message entry point

extension MathBlockView {

    /// Collect **every complete** math span of a message and hand them to the island in one batch.
    ///
    /// Calling this once, where the answer's markdown is known, is what turns N equations into one
    /// page load: by the time the blocks are laid out, the glyphs are already on their way, and
    /// nothing renders a second web view. Safe to call on every streamed tick — spans already drawn
    /// are skipped, and an unterminated `$$` is not a span yet.
    @MainActor
    static func prime(
        markdown: String,
        messageID: String,
        palette: FirasPalette,
        background: Color? = nil,
        fontScale: FontScale = .medium
    ) {
        guard !markdown.isEmpty else { return }
        let style = MathIslandStyle(
            palette: palette,
            background: background ?? palette.background,
            fontScale: fontScale
        )
        MathIsland.shared.prime(markdown: markdown, messageID: messageID, style: style)
    }

    /// Regenerate, version switch, edit, end of stream.
    ///
    /// This deliberately does **not** drop bitmaps. It used to, and that was the reported bug: the
    /// chat calls it the instant `isStreaming` goes false, the rows are still on screen and never
    /// ask again, so every equation of the answer reverted to its Unicode form at exactly the
    /// moment the reader started reading it. A glyph is keyed by the expression it draws, so text
    /// changing under a message id cannot make one wrong — new text simply has new keys. All this
    /// clears is the failure state, so an answer that arrived while the network was down gets
    /// another try.
    @MainActor
    static func invalidate(messageID: String) {
        MathIsland.shared.allowRetry()
    }

    /// Sign-out and "delete my data" wipe every rendered equation with everything else.
    @MainActor
    static func invalidateAll() {
        MathIsland.shared.reset()
    }
}

// MARK: - Strings

extension Strings {
    enum Math {
        /// Read before the equation itself by VoiceOver, never shown on screen.
        static let equation = LText(ar: "معادلة", en: "Equation")
    }
}
