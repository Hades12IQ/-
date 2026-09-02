import SwiftUI

/// The first-run door (`design-brief.md §7.17 (1)`, copy verbatim in `web-chat-ux.md §1.1`).
///
/// Full screen on the theme ground, **no glass**: this is the one surface that must read as paper,
/// not as chrome. The checkbox is never pre-ticked and `متابعة` stays disabled until it is, exactly
/// as on the web. Accepting writes `prefs.consentAccepted` and calls `onContinue`.
struct ConsentView: View {

    private let prefs: PreferencesStore
    private let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var agreed = false

    init(prefs: PreferencesStore, onContinue: @escaping () -> Void) {
        self.prefs = prefs
        self.onContinue = onContinue
    }

    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }
    private var columnWidth: CGFloat { horizontalSizeClass == .regular ? 620 : 560 }

    var body: some View {
        ZStack(alignment: .bottom) {
            FirasBackground(palette: palette, showHalo: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    section(title: Strings.Auth.consentProductsTitle(lang), lines: Strings.Auth.consentProducts)
                    section(title: Strings.Auth.consentWhyTitle(lang), lines: Strings.Auth.consentWhy)
                    section(title: Strings.Auth.consentFaqTitle(lang), lines: Strings.Auth.consentFaq)
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, 240)
            }
            .scrollDismissesKeyboard(.immediately)

            gate
        }
        .bidiIsland(for: Strings.Auth.consentTitle(lang), fallback: lang)
        .background(palette.background)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            FirasBrandMark(size: 56, showsWordmark: true, palette: palette)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(verbatim: Strings.Auth.consentTitle(lang))
                .font(FirasType.scaled(28, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: Strings.Auth.consentLede(lang))
                .font(FirasType.scaled(16, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 7 : 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    private func section(title: String, lines: [Strings.Auth.ConsentLine]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(FirasType.scaled(19, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    bullet(line.text(lang))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(palette.accent)
                .frame(width: 5, height: 5)
                .offset(y: -3)
                .accessibilityHidden(true)

            Text(verbatim: text)
                .font(FirasType.scaled(15, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Gate

    private var gate: some View {
        VStack(spacing: 14) {
            checkbox
            legalLinks
            continueButton

            Text(verbatim: Strings.Auth.consentNote(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .background(alignment: .top) {
            gateBackground
        }
    }

    private var gateBackground: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [palette.background.opacity(0), palette.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 34)
            .offset(y: -34)

            palette.background
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    private var checkbox: some View {
        Button {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                agreed.toggle()
            }
            Haptics.select()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(agreed ? palette.accent : palette.textMuted)
                    .accessibilityHidden(true)

                Text(verbatim: Strings.Auth.consentAgree(lang))
                    .font(FirasType.scaled(15, scale: prefs.fontScale))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Strings.Auth.consentAgree(lang)))
        .accessibilityHint(Text(verbatim: Strings.Auth.consentAgreeHint(lang)))
        .accessibilityAddTraits(agreed ? [.isSelected] : [])
    }

    private var legalLinks: some View {
        HStack(spacing: 18) {
            legalLink(title: Strings.Auth.termsTitle(lang), address: Strings.Auth.termsURL)
            legalLink(title: Strings.Auth.privacyTitle(lang), address: Strings.Auth.privacyURL)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func legalLink(title: String, address: String) -> some View {
        if let url = URL(string: address) {
            Link(destination: url) {
                Text(verbatim: title)
                    .font(FirasType.caption)
                    .underline()
                    .foregroundStyle(palette.accent)
            }
            .accessibilityLabel(Text(verbatim: title))
        } else {
            Text(verbatim: title)
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
    }

    private var continueButton: some View {
        Button {
            guard agreed else { return }
            prefs.consentAccepted = true
            Haptics.select()
            onContinue()
        } label: {
            Text(verbatim: Strings.Auth.consentContinue(lang))
                .font(FirasType.scaled(17, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    Capsule(style: .continuous)
                        .fill(agreed ? palette.accent : palette.borderStrong)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!agreed)
        .opacity(agreed ? 1 : 0.65)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: agreed)
        .accessibilityLabel(Text(verbatim: Strings.Auth.consentContinue(lang)))
        .accessibilityHint(Text(verbatim: agreed ? "" : Strings.Auth.consentAgreeHint(lang)))
    }
}
