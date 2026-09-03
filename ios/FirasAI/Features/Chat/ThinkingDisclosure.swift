import SwiftUI

/// The reasoning disclosure: one muted line with a chevron, closed by default.
///
/// It is a line of text, not a panel. The body used to open into a filled sunken box with its own
/// border and its own 320 pt scroll view — a coloured slab in the middle of the answer, and a second
/// vertical scroller nested inside the transcript's own, which stole the drag whenever a finger
/// happened to start on it. Now it opens inline under a hairline rule on the leading edge, the way a
/// quoted aside reads in a document, and the transcript keeps every scroll gesture.
///
/// Only ever shown when the tier reasons and the text is non-empty (`web-chat-ux.md §4`). While the
/// reasoning is still arriving and the disclosure is closed, the line reads `فِراس يفكّر…` so the
/// reader knows something is happening without the raw thought stream being pushed at them.
struct ThinkingDisclosure: View {

    private let reasoning: String
    private let isLive: Bool
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let scale: FontScale
    private let motionOn: Bool

    @State private var open = false

    init(
        reasoning: String,
        isLive: Bool,
        palette: FirasPalette,
        lang: AppLanguage,
        scale: FontScale,
        motionOn: Bool
    ) {
        self.reasoning = reasoning
        self.isLive = isLive
        self.palette = palette
        self.lang = lang
        self.scale = scale
        self.motionOn = motionOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            if open {
                panel(of: reasoning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Head

    private var head: some View {
        Button {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                open.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(palette.textMuted)

                if isLive && !open {
                    FirasActivityLabel(
                        text: Strings.Chat.thinkingLive(lang),
                        palette: palette,
                        motionOn: motionOn
                    )
                } else {
                    Text(Strings.Chat.thinkLabel(lang))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Chat.thinkLabel(lang)))
        .accessibilityValue(Text(open ? Strings.Common.done(lang) : Strings.Chat.thinkLabel(lang)))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Body

    /// The rule and the text share one bidi island, so in Arabic the rule lands on the right — the
    /// leading edge of the language — without a mirrored copy of this layout.
    private func panel(of text: String) -> some View {
        Text(text)
            .font(FirasType.scaled(14, scale: scale))
            .foregroundStyle(palette.textSecondary)
            .lineSpacing(lang == .arabic ? 6 : 4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.border)
                    .frame(width: 2)
            }
            .bidiIsland(for: text, fallback: lang)
            .transition(.opacity)
    }
}
