import SwiftUI

/// The `[Sn]` marker as a tappable capsule (`web-brain-ux.md §11.1`).
///
/// The number is always a Latin LTR run — a citation index is an address, not a quantity, and the
/// web never renders it in Arabic-Indic digits.
struct CitationChip: View {

    private let number: Int
    private let subtitle: String?
    private let palette: FirasPalette
    private let action: () -> Void

    init(number: Int, subtitle: String? = nil, palette: FirasPalette, action: @escaping () -> Void) {
        self.number = number
        self.subtitle = subtitle
        self.palette = palette
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(String(number))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 22)
                .background {
                    Capsule(style: .continuous).fill(palette.accentSoft)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(palette.accentRing, lineWidth: 0.5)
                }
                .forceLTR()
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        if let subtitle, !subtitle.isEmpty {
            return String(number) + " — " + subtitle
        }
        return String(number)
    }
}
