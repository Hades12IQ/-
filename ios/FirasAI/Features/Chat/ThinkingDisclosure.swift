import SwiftUI

/// The reasoning panel: `التفكير` with a chevron that rotates 90°, closed by default.
///
/// Only ever shown when the tier reasons and the text is non-empty (`web-chat-ux.md §4`). While the
/// reasoning is still arriving and the panel is closed, the head reads `فِراس يفكّر…` so the reader
/// knows something is happening without the raw thought stream being pushed at them.
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
        VStack(alignment: .leading, spacing: 8) {
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Chat.thinkLabel(lang)))
        .accessibilityValue(Text(open ? Strings.Common.done(lang) : Strings.Chat.thinkLabel(lang)))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Body

    private func panel(of text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(FirasType.scaled(14, scale: scale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 6 : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .bidiIsland(for: text, fallback: lang)
        }
        .frame(maxHeight: 320)
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .transition(.opacity)
    }
}
