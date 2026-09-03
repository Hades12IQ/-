import SwiftUI

/// Default model → reply style → reply behaviour → images
/// (`web-auth-account-settings.md §6.3`, `web-chat-ux.md §3.3–§6`).
///
/// The four tiers are rows, not a segmented control: each one carries a tagline, and four Arabic
/// taglines never fit in four segments (`design-brief.md §7.4`).
@MainActor
struct ChatSettingsView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            modelPanel
            stylePanel
            behaviourPanel
            imagesPanel
        }
    }

    // MARK: - Default model

    private var modelPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Chat.modelHeader(lang),
            subtitle: Strings.Settings.Chat.modelSub(lang),
            palette: palette,
            lang: lang
        ) {
            ForEach(ModelTier.allCases) { tier in
                if tier != .mini {
                    SettingsDivider(palette: palette)
                }
                SettingsChoiceRow(
                    title: tier.label(lang),
                    hint: tier.tagline(lang),
                    badge: tier.badge.map { $0(lang) },
                    symbol: tier.symbol,
                    selected: tier == env.prefs.tier,
                    palette: palette,
                    lang: lang
                ) {
                    guard tier != env.prefs.tier else { return }
                    Haptics.select()
                    withAnimation(FirasMotion.gated(FirasMotion.tierPop, motionOn: motionOn)) {
                        env.prefs.tier = tier
                    }
                    env.toasts.show(Strings.Settings.Chat.modelSet(lang))
                }
            }
        }
    }

    // MARK: - Reply style

    private var stylePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Chat.styleHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsChoiceRow(
                title: Strings.Settings.Chat.styleAuto(lang),
                hint: Strings.Settings.Chat.styleAutoHint(lang),
                badge: nil,
                symbol: "bolt.fill",
                selected: env.prefs.responseMode == .auto,
                palette: palette,
                lang: lang
            ) { select(mode: .auto) }

            SettingsDivider(palette: palette)

            SettingsChoiceRow(
                title: Strings.Settings.Chat.stylePlan(lang),
                hint: Strings.Settings.Chat.stylePlanHint(lang),
                badge: nil,
                symbol: "list.clipboard",
                selected: env.prefs.responseMode == .plan,
                palette: palette,
                lang: lang
            ) { select(mode: .plan) }
        }
    }

    // MARK: - Reply behaviour

    private var behaviourPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Chat.behaviourHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsToggleRow(
                title: Strings.Settings.Chat.think(lang),
                hint: thinkingAvailable
                    ? Strings.Settings.Chat.thinkHint(lang)
                    : Strings.Settings.Chat.thinkUnavailable(lang),
                isOn: thinkingBinding,
                palette: palette,
                isDisabled: !thinkingAvailable
            )

            SettingsDivider(palette: palette)

            SettingsToggleRow(
                title: Strings.Settings.Chat.webSearch(lang),
                hint: Strings.Settings.Chat.webSearchHint(lang),
                isOn: webSearchBinding,
                palette: palette
            )

            SettingsDivider(palette: palette)

            SettingsToggleRow(
                title: Strings.Settings.Chat.enterSend(lang),
                hint: Strings.Settings.Chat.enterSendHint(lang),
                isOn: enterSendBinding,
                palette: palette
            )

            SettingsNote(text: Strings.Settings.Chat.enterSendNote(lang), palette: palette)
        }
    }

    // MARK: - Images

    private var imagesPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Chat.imagesHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsToggleRow(
                title: Strings.Settings.Chat.sharpen(lang),
                hint: Strings.Settings.Chat.sharpenHint(lang),
                isOn: sharpenBinding,
                palette: palette
            )
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    /// Mini has no thinking pass. The row stays visible and says why, instead of disappearing and
    /// leaving the reader to wonder where the setting went.
    private var thinkingAvailable: Bool { env.prefs.tier.showThinking }

    private func select(mode: ResponseMode) {
        guard mode != env.prefs.responseMode else { return }
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            env.prefs.responseMode = mode
        }
    }

    private var thinkingBinding: Binding<Bool> {
        Binding(
            get: { env.prefs.thinkingEnabled && env.prefs.tier.showThinking },
            set: { newValue in
                guard env.prefs.tier.showThinking else { return }
                env.prefs.thinkingEnabled = newValue
            }
        )
    }

    private var webSearchBinding: Binding<Bool> {
        Binding(get: { env.prefs.webSearchEnabled }, set: { env.prefs.webSearchEnabled = $0 })
    }

    private var enterSendBinding: Binding<Bool> {
        Binding(get: { env.prefs.sendOnReturn }, set: { env.prefs.sendOnReturn = $0 })
    }

    private var sharpenBinding: Binding<Bool> {
        Binding(get: { env.prefs.sharpenImages }, set: { env.prefs.sharpenImages = $0 })
    }
}
