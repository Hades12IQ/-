import SwiftUI

/// The principal toolbar pill: the model the next turn will use.
///
/// Icon + short name + chevron on a `.floating` capsule. Max wears the purple `maxTier*` tokens; with
/// *Differentiate Without Colour* on it also spells its badge out, because on that setting the purple
/// is the only thing that distinguishes it (`design-brief.md §7.4`, `web-chat-ux.md §3.3`).
struct TierPill: View {

    private let tier: ModelTier
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var pop: CGFloat = 1

    init(
        tier: ModelTier,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        action: @escaping () -> Void
    ) {
        self.tier = tier
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .scaleEffect(pop)
        .onChange(of: tier) { _, _ in bounce() }
        .accessibilityLabel(Text(Strings.Chat.modelPickerHint(lang)))
        .accessibilityValue(Text(tier.label(lang)))
        .accessibilityHint(Text(tier.tagline(lang)))
    }

    // MARK: - Pieces

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: tier.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            Text(tier.short(lang))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)

            if differentiateWithoutColor, let badge = tier.badge {
                Text(badge(lang))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay {
                        Capsule(style: .continuous).stroke(textColor.opacity(0.5), lineWidth: 1)
                    }
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            if tier == .max {
                Capsule(style: .continuous).fill(palette.maxTierBg)
            }
        }
        .firasGlass(.floating, palette: palette, in: AnyShape(Capsule(style: .continuous)))
        .frame(minHeight: 44)
        .contentShape(Capsule(style: .continuous))
    }

    private var textColor: Color {
        switch tier {
        case .max: return palette.maxTierText
        case .ultra: return palette.accent
        case .mini, .pro: return palette.textPrimary
        }
    }

    private var iconColor: Color {
        switch tier {
        case .max: return palette.maxTierDot
        case .ultra: return palette.accent
        case .mini, .pro: return palette.textSecondary
        }
    }

    // MARK: - The pop

    private func bounce() {
        guard motionOn else { return }
        withAnimation(FirasMotion.tierPop) { pop = 1.06 }
        withAnimation(FirasMotion.tierPop.delay(0.18)) { pop = 1 }
    }
}
