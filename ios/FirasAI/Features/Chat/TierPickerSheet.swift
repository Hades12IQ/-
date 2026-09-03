import SwiftUI

/// The model sheet reached from the principal `TierPill`.
///
/// Four rows, nothing locked, no plan copy — every tier is free (`web-chat-ux.md §3.2`). The Think
/// switch is hidden on Mini (it has no reasoning), and the response-style card carries the two modes
/// with their hints spelled out rather than the web's silent toggle (`design-brief.md §7.4`).
struct TierPickerSheet: View {

    private let prefs: PreferencesStore
    private let toasts: ToastCenter?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    init(env: AppEnvironment) {
        self.prefs = env.prefs
        self.toasts = env.toasts
    }

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        self.toasts = nil
    }

    var body: some View {
        let palette = prefs.palette
        let lang = prefs.lang
        let motionOn = FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion)

        return NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    tierCard(palette: palette, lang: lang, motionOn: motionOn)
                    thinkCard(palette: palette, lang: lang)
                    styleCard(palette: palette, lang: lang)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(Text(Strings.Chat.modelSheetTitle(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Common.done(lang)) { dismiss() }
                }
            }
        }
        .firasSheetBackground(palette)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { reveal(motionOn: motionOn) }
    }

    private func reveal(motionOn: Bool) {
        guard !appeared else { return }
        if motionOn {
            withAnimation(.snappy(duration: 0.42, extraBounce: 0.035)) { appeared = true }
        } else {
            withAnimation(FirasMotion.fade) { appeared = true }
        }
    }

    // MARK: - Tiers

    private func tierCard(palette: FirasPalette, lang: AppLanguage, motionOn: Bool) -> some View {
        SurfaceCard(palette: palette) {
            VStack(spacing: 0) {
                ForEach(ModelTier.allCases) { tier in
                    if tier != ModelTier.mini {
                        Rectangle().fill(palette.border).frame(height: 1).padding(.leading, 46)
                    }
                    tierRow(tier, palette: palette, lang: lang, motionOn: motionOn)
                }
            }
        }
    }

    private func tierRow(
        _ tier: ModelTier,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool
    ) -> some View {
        let selected = prefs.tier == tier
        return Button {
            pick(tier, motionOn: motionOn)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: tier.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accentInk(for: tier, palette: palette))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tier.label(lang))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        if let badge = tier.badge {
                            badgeView(badge(lang), tier: tier, palette: palette)
                        }
                    }
                    Text(tier.tagline(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? palette.accent : palette.borderStrong)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Text(tier.label(lang)))
        .accessibilityHint(Text(tier.tagline(lang)))
    }

    private func badgeView(_ text: String, tier: ModelTier, palette: FirasPalette) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tier == .max ? palette.maxTierDot : palette.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tier == .max ? palette.maxTierText : palette.accent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(tier == .max ? palette.maxTierBg : palette.accentSoft)
        }
    }

    private func accentInk(for tier: ModelTier, palette: FirasPalette) -> Color {
        switch tier {
        case .max: return palette.maxTierText
        case .ultra: return palette.accent
        case .mini, .pro: return palette.textSecondary
        }
    }

    private func pick(_ tier: ModelTier, motionOn: Bool) {
        guard prefs.tier != tier else {
            dismiss()
            return
        }
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            prefs.tier = tier
        }
        dismiss()
    }

    // MARK: - Think

    private func thinkCard(palette: FirasPalette, lang: AppLanguage) -> some View {
        @Bindable var bindable = prefs
        return Group {
            if prefs.tier.showThinking {
                SurfaceCard(palette: palette) {
                    Toggle(isOn: $bindable.thinkingEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Strings.Chat.thinkLabel(lang))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text((prefs.thinkingEnabled ? Strings.Chat.thinkOn : Strings.Chat.thinkOff)(lang))
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(palette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Response style

    private func styleCard(palette: FirasPalette, lang: AppLanguage) -> some View {
        @Bindable var bindable = prefs
        return SurfaceCard(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.Chat.responseStyle(lang))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Picker(selection: $bindable.responseMode) {
                    Text(Strings.Chat.modeAuto(lang)).tag(ResponseMode.auto)
                    Text(Strings.Chat.modePlan(lang)).tag(ResponseMode.plan)
                } label: {
                    Text(Strings.Chat.responseStyle(lang))
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(
                    (prefs.responseMode == .plan ? Strings.Chat.modePlanHint : Strings.Chat.modeAutoHint)(lang)
                )
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}
