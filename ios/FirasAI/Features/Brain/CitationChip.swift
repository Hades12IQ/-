import SwiftUI

/// The `[Sn]` marker as a tappable capsule (`web-brain-ux.md §11.1`).
///
/// The number is always a Latin LTR run — a citation index is an address, not a quantity, and the
/// web never renders it in Arabic-Indic digits.
///
/// ROUND 3: the chip is now **incompressible**. It used to be the leading item of the source row's
/// `HStack`, where SwiftUI is free to squeeze whichever child will yield; a capsule holding one or
/// two digits has almost nothing to give, so under pressure from a long Arabic title it was pushed
/// narrower than its own background and the digit spilled past the accent capsule. `fixedSize()`
/// takes it out of that negotiation entirely: it always draws at its ideal width, the title beside
/// it wraps instead, and neither can leave the card.
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
            Text(verbatim: String(number))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 22)
                .background {
                    Capsule(style: .continuous).fill(palette.accentSoft)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(palette.accentRing, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .forceLTR()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var accessibilityLabel: String {
        if let subtitle, !subtitle.isEmpty {
            return String(number) + " — " + subtitle
        }
        return String(number)
    }
}
