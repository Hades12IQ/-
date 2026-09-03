import SwiftUI

/// The composer's response-style pill: `تلقائي` ⚡ / `تخطيط` 📋.
///
/// A `Menu` of two radio rows with the web's hints (`web-chat-ux.md §6`). The mode is a **device**
/// preference; a cycle that is already running keeps the mode it snapshotted, so switching in the
/// middle of one shows the one-line note instead of pretending the current plan changed
/// (`web-plan-mode.md §7.2`).
struct ModePill: View {

    private let prefs: PreferencesStore
    private let toasts: ToastCenter?
    private let overridePalette: FirasPalette?
    private let overrideLang: AppLanguage?
    private let planActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, conversationID: String) {
        self.prefs = env.prefs
        self.toasts = env.toasts
        self.overridePalette = nil
        self.overrideLang = nil
        // `resolve` first: `states` is keyed by the local id, so on a screen opened by server id
        // the pill read no cycle at all and stayed dark through a whole plan.
        if let cycle = env.chat.states[env.chat.resolve(conversationID)]?.plan {
            switch cycle.phase {
            case .none: self.planActive = false
            default: self.planActive = true
            }
        } else {
            self.planActive = false
        }
    }

    init(
        prefs: PreferencesStore,
        toasts: ToastCenter?,
        palette: FirasPalette,
        lang: AppLanguage,
        planActive: Bool
    ) {
        self.prefs = prefs
        self.toasts = toasts
        self.overridePalette = palette
        self.overrideLang = lang
        self.planActive = planActive
    }

    init(prefs: PreferencesStore, palette: FirasPalette, lang: AppLanguage) {
        self.init(prefs: prefs, toasts: nil, palette: palette, lang: lang, planActive: false)
    }

    var body: some View {
        let palette = overridePalette ?? prefs.palette
        let lang = overrideLang ?? prefs.lang
        let mode = prefs.responseMode

        return Menu {
            row(.auto, current: mode, lang: lang)
            row(.plan, current: mode, lang: lang)
        } label: {
            trigger(mode: mode, palette: palette, lang: lang)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.modeLabel(lang)))
        .accessibilityValue(Text(title(for: mode)(lang)))
    }

    // MARK: - Pieces

    private func trigger(mode: ResponseMode, palette: FirasPalette, lang: AppLanguage) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol(for: mode))
                .font(.system(size: 12, weight: .semibold))
            Text(title(for: mode)(lang))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.7)
        }
        .foregroundStyle(mode == .plan ? palette.accent : palette.textSecondary)
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background {
            Capsule(style: .continuous)
                .fill(mode == .plan ? palette.accentSoft : palette.surfaceSunken)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(mode == .plan ? palette.accentRing : palette.border, lineWidth: 1)
        }
        .frame(minHeight: 44)
        .contentShape(Capsule(style: .continuous))
    }

    private func row(_ mode: ResponseMode, current: ResponseMode, lang: AppLanguage) -> some View {
        Button {
            select(mode, lang: lang)
        } label: {
            Text(title(for: mode)(lang))
            Text(hint(for: mode)(lang))
            Image(systemName: current == mode ? "checkmark" : symbol(for: mode))
        }
    }

    private func select(_ mode: ResponseMode, lang: AppLanguage) {
        guard prefs.responseMode != mode else { return }
        Haptics.select()
        let motionOn = FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion)
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            prefs.responseMode = mode
        }
        if planActive {
            toasts?.show(Strings.Chat.modeSwitchedMidCycle(lang))
        }
    }

    private func symbol(for mode: ResponseMode) -> String {
        mode == .plan ? "list.clipboard" : "bolt.fill"
    }

    private func title(for mode: ResponseMode) -> LText {
        mode == .plan ? Strings.Chat.modePlan : Strings.Chat.modeAuto
    }

    private func hint(for mode: ResponseMode) -> LText {
        mode == .plan ? Strings.Chat.modePlanHint : Strings.Chat.modeAutoHint
    }
}
