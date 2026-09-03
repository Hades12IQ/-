import SwiftUI
import UIKit

/// One equation, in place, typeset.
///
/// The owner's report was `لاتكس ما يتحول` — the app was showing `MathText.unicode`, which produces
/// correct glyphs but not the layout the website draws with KaTeX. This view draws the KaTeX
/// rendering when there is one, and the Unicode form when there is not; there is no third state.
///
/// It asks `MathIsland.island(for: messageID)`, so **every equation of one message is typeset by one
/// web view** even though the call site is per block: the island coalesces the requests that arrive
/// in the same run loop into a single page, snapshots each formula, and throws the page away. A row
/// only ever holds a bitmap.
///
/// While that is happening — and forever, if the CDN is unreachable — the Unicode form is on screen.
/// The equation is never blank, never an error box, and never a spinner.
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
    ///   - messageID: the island key. Every block of one answer must pass the same value.
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
        let island = MathIsland.island(for: messageID)
        let style = MathIslandStyle(palette: palette, background: background, fontScale: fontScale)
        let identifier = MathScanner.identifier(tex: tex, isDisplay: isDisplay)
        let glyph: MathGlyph? = tex.isEmpty ? nil : island.glyph(for: identifier)
        let fade: Animation? = motionOn ? Animation.easeOut(duration: 0.16) : nil

        return layout(glyph)
            .animation(fade, value: glyph != nil)
            .task(id: identifier + "|" + style.key) { await request(style) }
    }

    /// `.task` hands over a `@Sendable` closure, which does not inherit this view's main-actor
    /// isolation — so the island is asked from a method that does, exactly as the media cards do
    /// with their `await load()`.
    private func request(_ style: MathIslandStyle) {
        guard !tex.isEmpty else { return }
        MathIsland
            .island(for: messageID)
            .request([MathIslandItem(tex: tex, isDisplay: isDisplay)], style: style)
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ glyph: MathGlyph?) -> some View {
        if let glyph {
            typeset(glyph)
        } else {
            flattened
        }
    }

    /// An LTR island in an RTL river: the formula keeps its own direction, the sentence keeps its
    /// own. Display equations centre and, when one is wider than the column, scroll sideways
    /// instead of shrinking — the same behaviour `.katex-display { overflow-x: auto }` gives the
    /// web.
    @ViewBuilder
    private func typeset(_ glyph: MathGlyph) -> some View {
        let picture = Image(uiImage: glyph.image)
            .interpolation(.high)
            .antialiased(true)

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
            .accessibilityLabel(Text(verbatim: spokenText))
        } else {
            picture
                .alignmentGuide(.firstTextBaseline) { _ in glyph.baseline }
                .forceLTR()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenText))
        }
    }

    /// The offline path, kept exactly as it was: `MathText.unicode` in mono, LTR, centred when the
    /// equation owns its line. This is what the reader sees first and what they keep if KaTeX never
    /// arrives.
    @ViewBuilder
    private var flattened: some View {
        let unicode = MathText.unicode(tex)
        let line = unicode.isEmpty ? tex : unicode

        if isDisplay {
            Text(verbatim: line)
                .font(FirasType.mono)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
                .forceLTR()
                .accessibilityLabel(Text(verbatim: spokenText))
        } else {
            Text(verbatim: line)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 2)
                .background(palette.backgroundSubtle)
                .forceLTR()
                .accessibilityLabel(Text(verbatim: spokenText))
        }
    }

    /// VoiceOver never reads a bitmap: it reads the flattened equation, in the reader's language.
    private var spokenText: String {
        let unicode = MathText.unicode(tex)
        return Strings.Math.equation(lang) + ": " + (unicode.isEmpty ? tex : unicode)
    }
}

// MARK: - Whole-message entry point

extension MathBlockView {

    /// Collect **every** math span of a message and hand them to its island in one batch.
    ///
    /// Calling this once, where the answer's markdown is known, is what turns N equations into one
    /// page load: by the time the blocks are laid out, the glyphs are already on their way, and
    /// nothing renders a second web view. Safe to call repeatedly while a message streams — spans
    /// already rendered are skipped, and an unterminated `$$` is not a span yet.
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
        MathIsland.island(for: messageID).prime(markdown: markdown, style: style)
    }

    /// Regenerate, version switch, edit: drop the bitmaps of text that no longer exists.
    @MainActor
    static func invalidate(messageID: String) {
        MathIsland.invalidate(messageID: messageID)
    }

    /// Sign-out and "delete my data" wipe every rendered equation with everything else.
    @MainActor
    static func invalidateAll() {
        MathIsland.invalidateAll()
    }
}

// MARK: - Strings

extension Strings {
    enum Math {
        /// Read before the equation itself by VoiceOver, never shown on screen.
        static let equation = LText(ar: "معادلة", en: "Equation")
    }
}
