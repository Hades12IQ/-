import SwiftUI

/// The ```` ```firas-sources ```` block under a Brain answer (`web-brain-ux.md §11.2`).
///
/// One numbered row per pointer: the `[Sn]` number the answer's chips carry, the document title,
/// the stored snippet, and the unit line (`صفحة ٤٢ · label`). Tapping a row hands the source back
/// so the passage reader can open it at the exact chunk.
struct SourcesCard: View {

    private let sources: [BrainSource]
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onOpen: ((BrainSource) -> Void)?

    init(
        sources: [BrainSource],
        palette: FirasPalette,
        lang: AppLanguage,
        onOpen: ((BrainSource) -> Void)? = nil
    ) {
        self.sources = sources
        self.palette = palette
        self.lang = lang
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
            content
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    private var heading: some View {
        Text(SourcesCardCopy.heading(lang))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: SourcesCardCopy.heading(lang), fallback: lang)
    }

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            Text(SourcesCardCopy.empty(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: SourcesCardCopy.empty(lang), fallback: lang)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Rectangle()
                            .fill(palette.border)
                            .frame(height: 1)
                            .padding(.vertical, 2)
                    }
                    row(pair.element)
                }
            }
        }
    }

    // MARK: - Row

    private func row(_ source: BrainSource) -> some View {
        Button {
            onOpen?(source)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                badge(source.n)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText(source))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let snippet = snippetText(source) {
                        Text(snippet)
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(locationText(source))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: titleText(source), fallback: lang)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityLabel(Text(titleText(source) + " — " + locationText(source)))
    }

    private func badge(_ number: Int) -> some View {
        Text(ArabicText.count(number, lang))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.accent)
            .frame(minWidth: 22, minHeight: 22)
            .background(Circle().fill(palette.accentSoft))
            .accessibilityHidden(true)
    }

    // MARK: - Derived

    private func titleText(_ source: BrainSource) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? SourcesCardCopy.untitled(lang) : title
    }

    private func snippetText(_ source: BrainSource) -> String? {
        guard let raw = source.s else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(160))
    }

    /// `"${unitLabel(u)} ${p}" + (l ? " · " + l : "")` — the web's own line.
    private func locationText(_ source: BrainSource) -> String {
        var text = source.documentUnit.noun(lang) + " " + ArabicText.count(source.page, lang)
        if let label = source.label, !label.isEmpty {
            text += " · " + label
        }
        return text
    }
}

// MARK: - Copy

private enum SourcesCardCopy {
    static let heading = LText(ar: "المصادر", en: "Sources")
    static let empty = LText(ar: "لا مصادر لهذه الإجابة.", en: "This answer cites no sources.")
    static let untitled = LText(ar: "مستند بلا اسم", en: "Untitled document")
}
