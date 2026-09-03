import SwiftUI

/// The row above the Brain composer (`web-brain-ux.md §10`, `design-brief.md §7.10`):
/// the `المصادر` button, one chip per active or pinned document, the page-range chip and the
/// compare chip. Chips are never glass — they sit on the composer's floating surface.
struct SourceChipsRow: View {

    private let store: BrainStore
    private let prefs: PreferencesStore
    private let onOpenLibrary: () -> Void

    @State private var editingRange = false
    @State private var fromText = ""
    @State private var toText = ""

    init(store: BrainStore, prefs: PreferencesStore, onOpenLibrary: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.onOpenLibrary = onOpenLibrary
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                libraryButton
                rangeChip
                compareChip
                documentChips
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $editingRange) {
            rangeEditor
                .presentationDetents([.height(260)])
                .firasSheetBackground(prefs.palette)
        }
    }

    private var lang: AppLanguage { prefs.lang }
    private var palette: FirasPalette { prefs.palette }

    // MARK: - Pieces

    private var libraryButton: some View {
        FirasPill(
            text: Strings.Brain.sources(lang) + " " + countLabel,
            symbol: "doc.text",
            selected: false,
            palette: palette,
            action: onOpenLibrary
        )
        .accessibilityLabel(Text(Strings.Brain.sourcesHead(lang)))
    }

    private var countLabel: String {
        let active = store.activeDocIDs.count
        let total = store.docs.count
        return ArabicText.count(active, lang) + "/" + ArabicText.count(total, lang)
    }

    @ViewBuilder
    private var rangeChip: some View {
        if store.hasDocuments {
            if let range = store.range {
                HStack(spacing: 4) {
                    FirasPill(
                        text: Strings.Brain.scopePages(lang) + " " + BrainAsker.rangeLabel(range, lang: lang),
                        symbol: "number",
                        selected: true,
                        palette: palette,
                        action: { openRangeEditor() }
                    )
                    Button {
                        store.clearRange()
                        Haptics.select()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Strings.Brain.scopeRemove(lang)))
                }
            } else {
                FirasPill(
                    text: Strings.Brain.scope(lang),
                    symbol: "number",
                    selected: false,
                    palette: palette,
                    action: { openRangeEditor() }
                )
                .accessibilityHint(Text(Strings.Brain.scopeHint(lang)))
            }
        }
    }

    @ViewBuilder
    private var compareChip: some View {
        if store.docs.count >= 2 {
            FirasPill(
                text: Strings.Brain.compare(lang),
                symbol: "rectangle.split.2x1",
                selected: store.compareArmed,
                palette: palette,
                action: { store.toggleCompare() }
            )
            .disabled(store.isAsking)
            .opacity(store.isAsking ? 0.5 : 1)
            .accessibilityHint(Text(Strings.Brain.compareTip(lang)))
        }
    }

    private var documentChips: some View {
        ForEach(store.docs) { document in
            let isActive = !store.excluded.contains(document.id)
            let isPinned = store.pins.contains(document.id)
            FirasPill(
                text: chipTitle(document),
                symbol: isPinned ? "pin.fill" : (isActive ? "checkmark" : "circle"),
                selected: isActive,
                palette: palette,
                action: {
                    store.toggleExcluded(document.id)
                    Haptics.select()
                }
            )
            .opacity(isPinned ? 0.95 : 1)
        }
    }

    private func chipTitle(_ document: BrainDocument) -> String {
        let title = document.title.isEmpty ? Strings.Brain.passageTitle(lang) : document.title
        return String(title.prefix(28))
    }

    // MARK: - Range editor

    private func openRangeEditor() {
        fromText = store.range.map { String($0.lowerBound) } ?? ""
        if let range = store.range, range.upperBound < 1_000_000_000 {
            toText = String(range.upperBound)
        } else {
            toText = ""
        }
        editingRange = true
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.Brain.scopeHint(lang))
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .bidiIsland(for: Strings.Brain.scopeHint(lang), fallback: lang)

            HStack(spacing: 12) {
                numberField(Strings.Brain.scopeFrom(lang), text: $fromText)
                numberField(Strings.Brain.scopeTo(lang), text: $toText)
            }

            Button {
                apply()
            } label: {
                Text(Strings.Brain.scopeApply(lang))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.accent)
                    }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .textFieldStyle(.plain)
                .font(.system(size: 16).monospacedDigit())
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surfaceSunken)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
                .forceLTR()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func apply() {
        store.setRange(from: Self.digits(fromText), to: Self.digits(toText))
        editingRange = false
        Haptics.select()
    }

    /// `brainScopeDigits` — Arabic-Indic and Eastern Arabic digits fold to ASCII first.
    static func digits(_ raw: String) -> Int? {
        var folded = ""
        for scalar in raw.unicodeScalars {
            var value: UInt32?
            switch scalar.value {
            case 0x0660...0x0669: value = scalar.value - 0x0660 + 48
            case 0x06F0...0x06F9: value = scalar.value - 0x06F0 + 48
            case 48...57: value = scalar.value
            default: value = nil
            }
            if let value, let converted = UnicodeScalar(value) {
                folded.unicodeScalars.append(converted)
            }
        }
        guard let value = Int(folded.prefix(6)), value > 0 else { return nil }
        return value
    }
}
