import SwiftUI

struct TranslationLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let nativeName: String
    let englishName: String

    static func all(lang: AppLanguage) -> [TranslationLanguage] {
        let display = Locale(identifier: lang.rawValue)
        let english = Locale(identifier: "en")
        let excluded: Set<String> = ["und", "mul", "zxx", "mis"]
        var codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
        codes.formUnion(["ckb", "ku", "zh-Hans", "zh-Hant", "pt-BR", "pt-PT"])
        return codes.filter { !excluded.contains($0) }.map { code in
            let native = Locale(identifier: code)
            return TranslationLanguage(
                id: code,
                name: display.localizedString(forIdentifier: code) ?? code,
                nativeName: native.localizedString(forIdentifier: code) ?? code,
                englishName: english.localizedString(forIdentifier: code) ?? code
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Uses the system's language catalogue and names, so the picker is not limited to the app's
/// Arabic/English interface languages. Search accepts localized names, native names and codes.
struct TranslationLanguagePicker: View {
    let lang: AppLanguage
    let palette: FirasPalette
    let onSelect: (TranslationLanguage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let languages: [TranslationLanguage]

    init(lang: AppLanguage, palette: FirasPalette, onSelect: @escaping (TranslationLanguage) -> Void) {
        self.lang = lang
        self.palette = palette
        self.onSelect = onSelect
        self.languages = TranslationLanguage.all(lang: lang)
    }

    private var filtered: [TranslationLanguage] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return languages }
        return languages.filter {
            [$0.name, $0.nativeName, $0.englishName, $0.id].contains {
                $0.localizedStandardContains(value)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { language in
                Button {
                    dismiss()
                    onSelect(language)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.name)
                                .foregroundStyle(palette.textPrimary)
                            Text(language.nativeName)
                                .font(.subheadline)
                                .foregroundStyle(palette.textSecondary)
                        }
                        Spacer(minLength: 12)
                        Text(language.id.uppercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.textMuted)
                            .forceLTR()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(palette.surfaceSunken)
            }
            .scrollContentBackground(.hidden)
            .background(palette.surface)
            .navigationTitle(lang == .arabic ? "الترجمة إلى" : "Translate to")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: lang == .arabic ? "ابحث عن لغة" : "Search languages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Common.cancel(lang)) { dismiss() }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .tint(palette.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
