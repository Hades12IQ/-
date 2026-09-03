import SwiftUI

/// Theme, text size, reading width, motion, language — in that order
/// (`web-auth-account-settings.md §6.2`, minus the web-only "UI 2.0" switch: this build *is* the
/// new look). Every control writes `PreferencesStore` directly; nothing is staged in local state,
/// so the whole app repaints on the same frame as the tap.
@MainActor
struct AppearanceSettingsView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            themePanel
            textSizePanel
            widthPanel
            motionPanel
            languagePanel
        }
    }

    // MARK: - Theme

    private var themePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Appearance.themeHeader(lang),
            subtitle: Strings.Settings.Appearance.themeSub(lang),
            palette: palette,
            lang: lang
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                spacing: 10
            ) {
                ForEach(FirasTheme.allCases) { theme in
                    themeTile(theme)
                }
            }
            .padding(14)
        }
    }

    private func themeTile(_ theme: FirasTheme) -> some View {
        let selected = theme == env.prefs.theme
        let colors = theme.palette.swatch
        return Button {
            guard !selected else { return }
            Haptics.select()
            withAnimation(.easeInOut(duration: 0.25)) {
                env.prefs.theme = theme
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(colors.indices), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(colors[index])
                            .frame(height: 26)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }

                HStack(spacing: 5) {
                    Text(theme.title(lang))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.accent : palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? palette.accentSoft : palette.surfaceSunken)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? palette.accentRing : palette.border, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.title(lang)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Text

    private var textSizePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Appearance.textSizeHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsSegmentedRow(
                options: FontScale.allCases,
                selection: fontScaleBinding,
                label: { Strings.Settings.Appearance.textSize($0)(lang) },
                palette: palette,
                motionOn: motionOn
            )
        }
    }

    private var widthPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Appearance.widthHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsSegmentedRow(
                options: ContentWidth.allCases,
                selection: widthBinding,
                label: { Strings.Settings.Appearance.width($0)(lang) },
                palette: palette,
                motionOn: motionOn
            )
        }
    }

    // MARK: - Motion

    private var motionPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Appearance.motionHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsSegmentedRow(
                hint: reduceMotion ? Strings.Settings.Appearance.motionSystemNote(lang) : nil,
                options: MotionPreference.allCases,
                selection: motionBinding,
                label: { Strings.Settings.Appearance.motion($0)(lang) },
                palette: palette,
                motionOn: motionOn
            )
        }
    }

    // MARK: - Language

    private var languagePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Appearance.languageHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsSegmentedRow(
                options: AppLanguage.allCases,
                selection: languageBinding,
                label: { Strings.Settings.Appearance.language($0)(lang) },
                palette: palette,
                motionOn: motionOn
            )
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var fontScaleBinding: Binding<FontScale> {
        Binding(get: { env.prefs.fontScale }, set: { env.prefs.fontScale = $0 })
    }

    private var widthBinding: Binding<ContentWidth> {
        Binding(get: { env.prefs.contentWidth }, set: { env.prefs.contentWidth = $0 })
    }

    private var motionBinding: Binding<MotionPreference> {
        Binding(get: { env.prefs.motionPreference }, set: { env.prefs.motionPreference = $0 })
    }

    /// Switching language relabels the whole app immediately and says so once, in the language
    /// just chosen (`toast تم تغيير لغة الواجهة ✓`).
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { env.prefs.language },
            set: { newValue in
                guard newValue != env.prefs.language else { return }
                env.prefs.language = newValue
                env.toasts.show(Strings.Settings.Appearance.languageChanged(newValue))
            }
        )
    }
}
