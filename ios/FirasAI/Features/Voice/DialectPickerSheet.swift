import SwiftUI

/// The dictation dialect picker: one radio list over `DictationDialect`, persisted immediately.
///
/// Reached from the mic button's long press, the recording bar's chip and Settings → الصوت
/// (`web-voice-call-mic.md §7.2`, `design-brief.md §7.14`). Every row carries its flag and the
/// full sentence-length label the web shows in the menu, not the short chip form.
struct DialectPickerSheet: View {

    @Environment(\.dismiss) private var dismiss

    private let prefs: PreferencesStore

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    init(env: AppEnvironment) {
        self.init(prefs: env.prefs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DictationDialect.allCases) { dialect in
                        row(for: dialect)
                    }
                } header: {
                    Text(Strings.Voice.dialectSub(lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .bidiIsland(for: Strings.Voice.dialectSub(lang), fallback: lang)
                }
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle(Text(Strings.Voice.dialectTitle(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(Strings.Common.done(lang))
                    }
                    .tint(palette.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .firasSheetBackground(palette)
    }

    // MARK: - Rows

    private func row(for dialect: DictationDialect) -> some View {
        let title = dialect.label(lang)
        let isSelected = prefs.dictationDialect == dialect

        return Button {
            guard !isSelected else {
                dismiss()
                return
            }
            Haptics.select()
            prefs.dictationDialect = dialect
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(dialect.flag)
                    .font(.system(size: 20))
                    .accessibilityHidden(true)

                Text(title)
                    .font(FirasType.label)
                    .foregroundStyle(palette.textPrimary)
                    .bidiIsland(for: title, fallback: lang)

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Tokens

    private var palette: FirasPalette { prefs.palette }

    private var lang: AppLanguage { prefs.lang }
}
