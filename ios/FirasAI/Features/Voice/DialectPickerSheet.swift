import Foundation
import SwiftUI

/// One entry in the dictation language list.
///
/// Two kinds of entry live in the same shape. A **suggested** entry wraps a `DictationDialect`,
/// which is the only thing `/api/transcribe` accepts as a hint and the only thing the on-device
/// recogniser gets a locale from. A **world** entry is built from `Locale`'s own data — its name
/// in Arabic, its name in English, its endonym — so the list is as long as the world is, not as
/// long as one table someone typed by hand.
struct SpokenLanguage: Identifiable, Hashable, Sendable {

    /// The dialect raw value for a suggested entry (`ar-EG`), the ISO language code for a world
    /// entry (`ja`). Unique across both sections.
    let id: String
    let arabicName: String
    let englishName: String
    /// The language's own name for itself, when it differs from both of the above.
    let nativeName: String?
    /// Only the suggested entries carry one; a world entry shows its code instead.
    let flag: String?
    /// `nil` when the transcriber has no hint for this language and detects it automatically.
    let dialect: DictationDialect?
    /// Normalised haystack for the search field: both names, the endonym and the code.
    let searchIndex: String

    init(
        id: String,
        arabicName: String,
        englishName: String,
        nativeName: String?,
        flag: String?,
        dialect: DictationDialect?
    ) {
        self.id = id
        self.arabicName = arabicName
        self.englishName = englishName
        self.nativeName = nativeName
        self.flag = flag
        self.dialect = dialect
        self.searchIndex = ArabicText.normalize(
            [arabicName, englishName, nativeName ?? "", id].joined(separator: " ")
        )
    }

    func name(_ lang: AppLanguage) -> String {
        lang == .arabic ? arabicName : englishName
    }

    /// `needle` is already normalised by the caller — normalising once per keystroke instead of
    /// once per row is the difference between a list that filters and a list that stutters.
    func matches(_ needle: String) -> Bool {
        needle.isEmpty || searchIndex.contains(needle)
    }
}

/// Builds both halves of the list and owns the selection.
///
/// The suggested half is `DictationDialect.allCases` in its declared order (`auto` first). The
/// world half is derived from `Locale.availableIdentifiers`, reduced to one entry per ISO language
/// code, named through `Locale(identifier: "ar")` and `Locale(identifier: "en")` so both scripts
/// are correct without a hand-written table, and sorted alphabetically in the interface language
/// (Arabic names are sorted with the definite article dropped, or every language would file under
/// alef).
enum SpokenLanguageCatalog {

    // MARK: - The two lists

    /// The fourteen the transcriber has a real dialect hint for.
    static var suggested: [SpokenLanguage] {
        DictationDialect.allCases.map { dialect in
            SpokenLanguage(
                id: dialect.rawValue,
                arabicName: dialect.label.ar,
                englishName: dialect.label.en,
                nativeName: nil,
                flag: dialect.flag,
                dialect: dialect
            )
        }
    }

    /// Everything else `Locale` knows about, sorted for `lang`. Pure and `nonisolated`, so the
    /// picker can build it off the main actor.
    static func world(for lang: AppLanguage) -> [SpokenLanguage] {
        let keyed: [(key: String, value: SpokenLanguage)] = base.map { language in
            (key: sortKey(language.name(lang)), value: language)
        }
        let ordered = keyed.sorted { left, right in left.key < right.key }
        return ordered.map { $0.value }
    }

    // MARK: - Selection

    /// The id of the entry that should carry the check mark.
    ///
    /// A world language cannot be spelled as a `DictationDialect`, so it is remembered beside the
    /// preference and only trusted while the preference still reads `auto` — which is exactly what
    /// picking a world language writes. Any later pick from the Settings menu moves the preference
    /// off `auto` and the remembered id is ignored from then on, so the two surfaces can never
    /// disagree about what is selected.
    @MainActor
    static func selected(prefs: PreferencesStore) -> String {
        let dialect = prefs.dictationDialect
        guard dialect == .auto else { return dialect.rawValue }
        let remembered = UserDefaults.standard.string(forKey: worldSelectionKey) ?? ""
        return remembered.isEmpty ? dialect.rawValue : remembered
    }

    @MainActor
    static func select(_ language: SpokenLanguage, prefs: PreferencesStore) {
        let defaults = UserDefaults.standard
        if let dialect = language.dialect {
            prefs.dictationDialect = dialect
            defaults.removeObject(forKey: worldSelectionKey)
        } else {
            // No hint exists for this language, so the honest server value is "detect it".
            prefs.dictationDialect = .auto
            defaults.set(language.id, forKey: worldSelectionKey)
        }
    }

    private static let worldSelectionKey = "dictationLanguageWorld"

    // MARK: - Building the world list

    /// The language codes the suggested section already covers.
    private static let suggestedCodes: Set<String> = ["auto", "ar", "en", "fr", "de", "tr"]

    private static let base: [SpokenLanguage] = buildBase()

    private static func buildBase() -> [SpokenLanguage] {
        let arabic = Locale(identifier: "ar")
        let english = Locale(identifier: "en")
        var seenCodes = Set<String>()
        var seenNames = Set<String>()
        var out: [SpokenLanguage] = []

        for identifier in Locale.availableIdentifiers {
            guard let code = languageCode(of: identifier) else { continue }
            guard !suggestedCodes.contains(code) else { continue }
            guard seenCodes.insert(code).inserted else { continue }
            guard let rawArabic = arabic.localizedString(forLanguageCode: code),
                  let rawEnglish = english.localizedString(forLanguageCode: code) else { continue }

            let arabicName = rawArabic.trimmingCharacters(in: .whitespacesAndNewlines)
            let englishName = rawEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
            // A code the system has no name for comes back as the code itself; that is a row
            // nobody can read, so it is not a row.
            guard !arabicName.isEmpty, !englishName.isEmpty,
                  arabicName.caseInsensitiveCompare(code) != .orderedSame,
                  englishName.caseInsensitiveCompare(code) != .orderedSame else { continue }
            guard seenNames.insert(englishName.lowercased()).inserted else { continue }

            let native = Locale(identifier: code).localizedString(forLanguageCode: code)
            out.append(
                SpokenLanguage(
                    id: code,
                    arabicName: arabicName,
                    englishName: englishName,
                    nativeName: endonym(native, arabicName: arabicName, englishName: englishName),
                    flag: nil,
                    dialect: nil
                )
            )
        }
        return out
    }

    /// The primary subtag of a locale identifier (`pt_BR` → `pt`), or `nil` when it is not a
    /// two/three-letter language code.
    private static func languageCode(of identifier: String) -> String? {
        var code = ""
        for character in identifier {
            if character == "_" || character == "-" || character == "@" { break }
            code.append(character)
        }
        let lowered = code.lowercased()
        guard lowered.count >= 2, lowered.count <= 3 else { return nil }
        guard lowered.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return lowered
    }

    private static func endonym(
        _ native: String?,
        arabicName: String,
        englishName: String
    ) -> String? {
        guard let native else { return nil }
        let trimmed = native.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != arabicName, trimmed.caseInsensitiveCompare(englishName) != .orderedSame else {
            return nil
        }
        return trimmed
    }

    /// Alphabetical order without the Arabic definite article, which every language name carries
    /// and which would otherwise collapse the whole list under one letter.
    private static func sortKey(_ name: String) -> String {
        let value = ArabicText.normalize(name)
        if value.hasPrefix("ال"), value.count > 3 {
            return String(value.dropFirst(2))
        }
        return value
    }
}

/// The dictation language picker: the fourteen dialects the transcriber understands, then every
/// language `Locale` can name, with a search field over both.
///
/// Reached from the mic button's long press, the recording bar's chip and Settings → الصوت
/// (`web-voice-call-mic.md §7.2`, `design-brief.md §7.14`).
@MainActor
struct DialectPickerSheet: View {

    @Environment(\.dismiss) private var dismiss

    private let prefs: PreferencesStore

    @State private var query = ""
    @State private var world: [SpokenLanguage] = []

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    init(env: AppEnvironment) {
        self.init(prefs: env.prefs)
    }

    var body: some View {
        let selected = SpokenLanguageCatalog.selected(prefs: prefs)
        let needle = ArabicText.normalize(query)

        return NavigationStack {
            list(selected: selected, needle: needle)
                .listStyle(.insetGrouped)
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
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(Strings.Settings.Voice.languageSearch(lang))
                )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .firasSheetBackground(palette)
        .task(id: lang) {
            await loadWorld(for: lang)
        }
    }

    // MARK: - List

    private func list(selected: String, needle: String) -> some View {
        let suggested = SpokenLanguageCatalog.suggested.filter { $0.matches(needle) }
        let others = world.filter { $0.matches(needle) }

        return List {
            if !suggested.isEmpty {
                Section {
                    ForEach(suggested) { language in
                        row(for: language, isSelected: language.id == selected)
                    }
                } header: {
                    header(Strings.Settings.Voice.languageSuggested(lang))
                }
                .listRowBackground(palette.surface)
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { language in
                        row(for: language, isSelected: language.id == selected)
                    }
                } header: {
                    header(Strings.Settings.Voice.languageAll(lang))
                } footer: {
                    worldFooter(shown: others.count)
                }
                .listRowBackground(palette.surface)
            }

            if suggested.isEmpty && others.isEmpty {
                Section {
                    Text(Strings.Common.noResults(lang))
                        .font(FirasType.label)
                        .foregroundStyle(palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .listRowBackground(palette.surface)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(FirasType.caption)
            .foregroundStyle(palette.textMuted)
            .bidiIsland(for: title, fallback: lang)
    }

    private func worldFooter(shown: Int) -> some View {
        let note = Strings.Settings.Voice.languageAutoNote(lang)
        let count = Strings.Settings.Voice.languageCount(shown, lang)
        return VStack(alignment: .leading, spacing: 4) {
            Text(note)
            Text(count)
        }
        .font(FirasType.caption)
        .foregroundStyle(palette.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: note, fallback: lang)
    }

    // MARK: - Row

    private func row(for language: SpokenLanguage, isSelected: Bool) -> some View {
        let title = language.name(lang)

        return Button {
            pick(language, isSelected: isSelected)
        } label: {
            HStack(spacing: 12) {
                badge(for: language)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FirasType.label)
                        .foregroundStyle(palette.textPrimary)
                    if let native = language.nativeName {
                        Text(native)
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: title, fallback: lang)

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

    /// A flag for the suggested rows, the language's own code for the rest — a code is honest and
    /// unambiguous where a flag would have to pick one country out of many that speak it.
    @ViewBuilder
    private func badge(for language: SpokenLanguage) -> some View {
        if let flag = language.flag {
            Text(flag)
                .font(.system(size: 20))
                .frame(width: 30)
                .accessibilityHidden(true)
        } else {
            Text(language.id.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 30, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.backgroundSubtle)
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    private func pick(_ language: SpokenLanguage, isSelected: Bool) {
        guard !isSelected else {
            dismiss()
            return
        }
        Haptics.select()
        SpokenLanguageCatalog.select(language, prefs: prefs)
        dismiss()
    }

    /// ~200 rows, three `Locale` lookups each: cheap, but not on the frame that opens the sheet.
    private func loadWorld(for language: AppLanguage) async {
        let built = await Task.detached(priority: .userInitiated) {
            SpokenLanguageCatalog.world(for: language)
        }.value
        world = built
    }

    // MARK: - Tokens

    private var palette: FirasPalette { prefs.palette }

    private var lang: AppLanguage { prefs.lang }
}
