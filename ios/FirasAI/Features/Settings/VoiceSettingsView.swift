import SwiftUI

/// Call voice → interruption → dictation dialect → interface sounds
/// (`web-auth-account-settings.md §6.4`, `web-voice-call-mic.md §9`, `design-brief.md §5.2`).
///
/// Fourteen dialects are a menu, never a segmented control
/// (`audit-ios-shell-settings-design.md F12`); five call voices are rows, because each one only
/// means something once you have heard it and the row can carry its name in both scripts.
@MainActor
struct VoiceSettingsView: View {

    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            callVoicePanel
            bargeInPanel
            dialectPanel
            soundsPanel
        }
    }

    // MARK: - Call voice

    private var callVoicePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Voice.callVoiceHeader(lang),
            subtitle: Strings.Settings.Voice.callVoiceSub(lang),
            palette: palette,
            lang: lang
        ) {
            ForEach(CallVoice.allCases) { voice in
                if voice != .cedar {
                    SettingsDivider(palette: palette)
                }
                SettingsChoiceRow(
                    title: voice.label(lang),
                    hint: voice.rawValue,
                    badge: nil,
                    symbol: "waveform",
                    selected: voice == env.prefs.callVoice,
                    palette: palette,
                    lang: lang
                ) {
                    select(voice: voice)
                }
            }

            SettingsNote(text: Strings.Settings.Voice.callVoiceNote(lang), palette: palette)
        }
    }

    // MARK: - Barge-in

    private var bargeInPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Voice.duringCallHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsToggleRow(
                title: Strings.Settings.Voice.bargeIn(lang),
                hint: Strings.Settings.Voice.bargeInHint(lang),
                isOn: bargeInBinding,
                palette: palette
            )
        }
    }

    // MARK: - Dictation dialect

    private var dialectPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Voice.dialectHeader(lang),
            subtitle: Strings.Settings.Voice.dialectSub(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsValueRow(palette: palette) {
                dialectMenu
            }
        }
    }

    private var dialectMenu: some View {
        Menu {
            ForEach(DictationDialect.allCases) { dialect in
                Button {
                    guard dialect != env.prefs.dictationDialect else { return }
                    Haptics.select()
                    env.prefs.dictationDialect = dialect
                } label: {
                    if dialect == env.prefs.dictationDialect {
                        Label(menuTitle(dialect), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(dialect))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(menuTitle(env.prefs.dictationDialect))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(Strings.Settings.Voice.dialectHeader(lang)))
    }

    private func menuTitle(_ dialect: DictationDialect) -> String {
        dialect.flag + " " + dialect.shortLabel(lang)
    }

    // MARK: - Interface sounds

    private var soundsPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Voice.soundsHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsToggleRow(
                title: Strings.Settings.Voice.sounds(lang),
                hint: Strings.Settings.Voice.soundsHint(lang),
                isOn: soundsBinding,
                palette: palette
            )
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    /// A live call has already minted its token: changing the voice now applies to the next call,
    /// and the toast says exactly that rather than pretending otherwise.
    private func select(voice: CallVoice) {
        guard voice != env.prefs.callVoice else { return }
        Haptics.select()
        env.prefs.callVoice = voice
        env.toasts.show(Strings.Settings.Voice.callVoiceSet.fmt(lang, voice.label(lang)))
    }

    private var bargeInBinding: Binding<Bool> {
        Binding(get: { env.prefs.bargeInEnabled }, set: { env.prefs.bargeInEnabled = $0 })
    }

    private var soundsBinding: Binding<Bool> {
        Binding(get: { env.prefs.uiSoundsEnabled }, set: { env.prefs.uiSoundsEnabled = $0 })
    }
}
