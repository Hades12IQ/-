import SwiftUI

/// `‹ ٢/٣ ›` above an answer that was regenerated.
///
/// The counter is Arabic-Indic in Arabic (`ArabicText.count`) but always reads left to right, because
/// `n / total` is a fraction, not a sentence (`design-brief.md §4.2`). Paging never re-asks the model;
/// it only moves `altAt` through `ChatStore.selectVersion`.
struct VersionPager: View {

    private let index: Int
    private let total: Int
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onSelect: (Int) -> Void

    init(
        index: Int,
        total: Int,
        palette: FirasPalette,
        lang: AppLanguage,
        onSelect: @escaping (Int) -> Void
    ) {
        self.index = index
        self.total = total
        self.palette = palette
        self.lang = lang
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Strings.Chat.verLabel(lang))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textMuted)

            HStack(spacing: 2) {
                step(symbol: "chevron.left", label: Strings.Chat.verPrev(lang), delta: -1)
                counter
                step(symbol: "chevron.right", label: Strings.Chat.verNext(lang), delta: 1)
            }
            .forceLTR()
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(Text(Strings.Chat.verHint(lang)))
    }

    private var counter: some View {
        Text(
            Strings.Chat.verCounter.fmt(
                lang,
                ArabicText.count(index + 1, lang),
                ArabicText.count(total, lang)
            )
        )
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(palette.textSecondary)
        .frame(minWidth: 40)
    }

    private func step(symbol: String, label: String, delta: Int) -> some View {
        let target = index + delta
        let enabled = target >= 0 && target < total
        return Button {
            guard enabled else { return }
            Haptics.select()
            onSelect(target)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? palette.textSecondary : palette.textMuted.opacity(0.4))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}
