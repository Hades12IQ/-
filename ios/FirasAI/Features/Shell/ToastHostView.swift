import SwiftUI

/// Where every toast lands (`design-brief.md §7.1`).
///
/// One capsule at a time, bottom-centred above the composer, `.floating` glass, at most one button.
/// The timing, the queue and the VoiceOver announcement belong to `ToastCenter`; this view only
/// draws what the centre is currently holding, so a store can toast without importing a view.
@MainActor
struct ToastHostView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = env.toasts.current {
                capsule(for: toast)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 96)
                    .transition(motionOn ? FirasMotion.revealTransition : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(
            FirasMotion.gated(FirasMotion.standard, motionOn: motionOn),
            value: env.toasts.current
        )
        .allowsHitTesting(env.toasts.current != nil)
    }

    // MARK: - Pieces

    private func capsule(for toast: ToastCenter.Toast) -> some View {
        HStack(spacing: 12) {
            if toast.isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.error)
                    .accessibilityHidden(true)
            }

            Text(toast.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: toast.text, fallback: lang)

            if let actionTitle = toast.actionTitle, !actionTitle.isEmpty {
                Button {
                    env.toasts.performAction()
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .firasGlass(.floating, palette: palette, in: AnyShape(Capsule(style: .continuous)))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { env.toasts.dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(toast.text))
        .accessibilityHint(Text(Strings.Shell.toastDismiss(lang)))
    }
}
