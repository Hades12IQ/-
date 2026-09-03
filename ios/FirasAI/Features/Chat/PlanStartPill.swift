import SwiftUI

/// `▶ ابدأ التنفيذ` under a finished plan.
///
/// Tapping it sends the approval sentence as an ordinary user message (`web-plan-mode.md §3.7`);
/// the pill then dissolves because the cycle has left `awaitingApproval`. It is never shown on a
/// `firas-ask` turn, on the delivery turn, or in Agent / Code / Brain conversations — that decision
/// belongs to `PlanCycle.showsStartPill`, not to this view, and the owner's round-2 report
/// («يكتب الحل و حط ستارت تحته») is that decision going wrong, not this pill.
///
/// The play triangle is deliberately NOT mirrored in Arabic: playback and transport glyphs keep
/// their direction in RTL (Apple HIG), and the web uses the same unmirrored `ICONS.play`.
struct PlanStartPill: View {

    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let isEnabled: Bool
    private let action: () -> Void

    init(
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(Strings.Chat.planStart(lang))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 18)
            // 44, not 40: the capsule IS the hit area, and a plan is approved with a thumb.
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous).fill(palette.accent)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(palette.accentRing, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: palette.glassShadow, radius: 10, y: 4)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .disabled(!isEnabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(motionOn ? FirasMotion.revealTransition : .opacity)
        .accessibilityLabel(Text(Strings.Chat.planStart(lang)))
        .accessibilityHint(Text(Strings.Chat.planStartHint(lang)))
    }
}
