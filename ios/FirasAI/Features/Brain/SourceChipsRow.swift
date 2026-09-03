import SwiftUI

/// The row above the Brain composer (`web-brain-ux.md §10`, `design-brief.md §7.10`):
/// the `المصادر` button, one chip per active or pinned document, the page-range chip and the
/// compare chip. Chips are never glass — they sit on the composer's floating surface.
///
/// ROUND 3 — THE CHIP THAT LEFT THE BOX. «بفراس برين المصدر يخرج خارج البوكس».
/// The composer applies `.firasGlass(.floating, in: RoundedRectangle(cornerRadius: 24))` straight
/// to its `VStack(spacing: 0)`, and `firasGlass` is a `.background` plus an `.overlay` — it paints
/// the box, it never clips to it. This row was the first child of that stack, so its scroll
/// viewport ran edge to edge and top to top of a shape whose corners curve 24 pt inwards. A
/// horizontal scroll view clips its content to its own **rectangular** bounds, which meant the
/// chip sitting at the trailing edge was sliced along a straight line drawn outside the rounded
/// corner: the chip visibly stood proud of the glass, and with more chips than fit there is always
/// a chip at that edge.
///
/// The fix belongs here rather than in the composer, because this row is the only thing in the app
/// that rides the very edge of a rounded surface. It now owns its own inset: 10 pt of horizontal
/// padding puts the scroll viewport well inside the corner arc (the corner has curved in 3.8 pt by
/// the time the capsules start, so 10 pt clears it at every point), and 8 pt of top padding gives
/// the box the air it was missing. The first chip still begins 14 pt from the edge, exactly where
/// it did before, because the padding moved out of the scroll content and onto the viewport.
struct SourceChipsRow: View {

    private let store: BrainStore
    private let prefs: PreferencesStore
    private let onOpenLibrary: () -> Void

    @State private var editingRange = false
    @State private var fromText = ""
    @State private var toText = ""

    /// The chip title is trimmed before the layout sees it, so one long Arabic filename cannot
    /// turn the row into a hundred points of scrolling before the next chip appears.
    private static let chipTitleLimit = 24

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
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
        .accessibilityLabel(Text(verbatim: Strings.Brain.sourcesHead(lang)))
        .accessibilityValue(Text(verbatim: countLabel))
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
                    .accessibilityLabel(Text(verbatim: Strings.Brain.scopeRemove(lang)))
                }
            } else {
                FirasPill(
                    text: Strings.Brain.scope(lang),
                    symbol: "number",
                    selected: false,
                    palette: palette,
                    action: { openRangeEditor() }
                )
                .accessibilityHint(Text(verbatim: Strings.Brain.scopeHint(lang)))
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
            .accessibilityHint(Text(verbatim: Strings.Brain.compareTip(lang)))
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
            .accessibilityValue(Text(verbatim: document.title))
        }
    }

    private func chipTitle(_ document: BrainDocument) -> String {
        let title = document.title.isEmpty ? Strings.Brain.passageTitle(lang) : document.title
        guard title.count > Self.chipTitleLimit else { return title }
        return String(title.prefix(Self.chipTitleLimit - 1)) + "…"
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
            Text(verbatim: Strings.Brain.scopeHint(lang))
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: Strings.Brain.scopeHint(lang), fallback: lang)

            HStack(spacing: 12) {
                numberField(Strings.Brain.scopeFrom(lang), text: $fromText)
                numberField(Strings.Brain.scopeTo(lang), text: $toText)
            }

            Button {
                apply()
            } label: {
                Text(verbatim: Strings.Brain.scopeApply(lang))
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
            Text(verbatim: title)
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
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
