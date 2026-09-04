import SwiftUI
import UIKit

/// One equation, in place, typeset.
///
/// The owner's report was «اللاتكس ما تتحول عدل، تتحول شكل غريب و تختفي» — a formula renders while
/// the answer streams and then disappears. Three rules hold that shut, and this view is where two
/// of them are visible:
///
/// * Open streamed expressions use a balanced, display-only scanner preview. The last successful
///   glyph stays visible while the next prefix renders; preview text never changes the message.
/// * **An equation that rendered is never removed.** Bitmaps are keyed by the expression and the
///   theme, not by the message, so end of stream, a regenerate, a version switch and a theme change
///   all leave what is on screen exactly where it is.
/// * **And a miss asks again.** The one thing that *can* take a bitmap away is the island's own
///   LRU, and «من اروح لغير محادثة و ارجع، نصهم يرجعون لاتكس عادي» was what that looked like: the
///   `.task` below fires once, when the row appears, so a row that was already laid out when its
///   glyph was evicted went back to the Unicode form with nothing left in the app able to ask for
///   it. `MathIsland.glyph(for:style:)` now re-opens its own request whenever it comes up empty,
///   so this view's `.task` is the *first* ask rather than the only one.
/// * **And a launch that drew nothing asks anyway.** «من اطلع من التطبيق و ارجع تختفي المعادلات».
///   The rule above has a floor under it that is easy to miss: a *read* is what re-opens a
///   request, and a read happens when this view's `body` runs again, and `body` runs again when
///   the island's observed store changes. A launch whose very first page failed — the coldest
///   page there is, raised while the scene is still coming up — changes nothing in that store, so
///   no row here is ever laid out a second time and no miss is ever seen. Nothing this view can
///   do would help; the island therefore keeps its own timers (`scheduleRecovery`, `grantAmnesty`)
///   and asks on the reader's behalf. Both are counted, so a phone that genuinely cannot typeset
///   settles on the Unicode form below rather than on a page that reloads for ever.
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
    private let streaming: Bool
    @State private var previousGlyph: MathGlyph?
    @State private var previousStyle: String?
    @Environment(\.firasTextSelection) private var selection

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
        motionOn: Bool = true,
        streaming: Bool = false
    ) {
        self.tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isDisplay = display
        self.messageID = messageID
        self.palette = palette
        self.lang = lang
        self.fontScale = fontScale
        self.background = background ?? palette.background
        self.motionOn = motionOn
        self.streaming = streaming
    }

    var body: some View {
        let style = MathIslandStyle(palette: palette, background: background, fontScale: fontScale)
        let identifier = MathScanner.identifier(tex: tex, isDisplay: isDisplay)
        let typesettable = MathScanner.isTypesettable(tex)
        let glyph: MathGlyph? = typesettable
            ? MathIsland.shared.glyph(for: identifier, style: style)
            : nil
        // Flattened once per body, not once per label: a landing bitmap redraws every math row on
        // screen, and `MathText.unicode` is a full pass over the expression.
        let unicode = MathText.unicode(tex)
        let line = unicode.isEmpty ? tex : unicode

        let visibleGlyph = glyph ?? (streaming && previousStyle == style.key ? previousGlyph : nil)
        return layout(visibleGlyph, line: line)
            .transaction { $0.animation = nil }
            .onChange(of: glyph.map { ObjectIdentifier($0.image) }, initial: true) {
                if let glyph { previousGlyph = glyph; previousStyle = style.key }
            }
            .contextMenu {
                Button(lang == .arabic ? "نسخ" : "Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = line
                }
                if let selection {
                    Button(lang == .arabic ? "اسأل فِراس" : "Ask Firas", systemImage: "text.bubble") {
                        selection.ask(line)
                    }
                }
            }
            .task(id: identifier + "|" + style.key) { await request(style) }
    }

    /// `.task` runs when the row appears and whenever its id changes, so a row that scrolled away
    /// and came back asks again — which is what lets the island's LRU evict without stranding a
    /// visible equation.
    private func request(_ style: MathIslandStyle) {
        // The message batches and replaces its live preview; a second request here would
        // promote an obsolete prefix into the normal queue on every streamed character.
        guard !streaming else { return }
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

    /// The offline path, and the path a half-arrived equation takes: `MathText.unicode`, LTR,
    /// centred in mono when the equation owns its line and in the sentence's own face when it
    /// stands inside one. This is what the reader sees first and what they keep if KaTeX never
    /// arrives — never an empty box.
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
            // No plate and no monospace: an equation standing in a sentence is mathematics, not
            // code. «اللون الي خلف اللاتكس خليه مطابق للون المحادثة» — it sits on the
            // conversation's own ground, in the conversation's own face, and only the direction
            // is its own.
            Text(verbatim: line)
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
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
        fontScale: FontScale = .medium,
        persist: Bool = false
    ) {
        guard !markdown.isEmpty else { return }
        let style = MathIslandStyle(
            palette: palette,
            background: background ?? palette.background,
            fontScale: fontScale
        )
        MathIsland.shared.prime(markdown: markdown, messageID: messageID, style: style, persist: persist)
    }

    /// Regenerate, version switch, edit, end of stream.
    ///
    /// This deliberately does **not** drop bitmaps. It used to, and that was the reported bug: the
    /// chat calls it the instant `isStreaming` goes false, the rows are still on screen and never
    /// ask again, so every equation of the answer reverted to its Unicode form at exactly the
    /// moment the reader started reading it. A glyph is keyed by the expression it draws, so text
    /// changing under a message id cannot make one wrong — new text simply has new keys. All this
    /// clears is the failure state, so an answer that arrived while the network was down gets
    /// another try — and, with it, every equation the island had given up on: an expression that
    /// spent its attempts on a bad page is not the same thing as one KaTeX refused, and only the
    /// second of those is meant to be permanent.
    ///
    /// Note what this cannot reach. It is called when a stream ENDS, so a conversation opened from
    /// cold — no stream, no regenerate, nothing to end — never calls it at all. That is why the
    /// island carries its own recovery rather than waiting to be told.
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
