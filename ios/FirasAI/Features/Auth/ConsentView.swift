import SwiftUI

/// The first-run door (`design-brief.md §7.17 (1)`, copy verbatim in `web-chat-ux.md §1.1`).
///
/// Full screen on the theme ground, **no glass**: this is the one surface that must read as paper,
/// not as chrome. The checkbox is never pre-ticked and `متابعة` stays disabled until it is, exactly
/// as on the web.
///
/// The door also asks the one data question the app is allowed to ask: may the Firas AI team use
/// these conversations to train and improve the models? It is asked, never assumed — two cards of
/// exactly the same size, neither selected when the screen appears, each saying in one sentence
/// what it means. `متابعة` waits for an answer, and either answer opens it. Accepting writes
/// `prefs.consentAccepted` and the `TrainingConsent` record, then calls `onContinue`.
struct ConsentView: View {

    private let prefs: PreferencesStore
    private let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var agreed = false

    /// `nil` until the reader answers. Nothing is pre-selected: a pre-selected Accept is a
    /// pre-ticked box wearing a different hat.
    @State private var training: TrainingConsent?

    init(prefs: PreferencesStore, onContinue: @escaping () -> Void) {
        self.prefs = prefs
        self.onContinue = onContinue
    }

    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }
    private var columnWidth: CGFloat { horizontalSizeClass == .regular ? 620 : 560 }

    /// Both answers are answers. Only silence blocks the door.
    private var canContinue: Bool { agreed && training != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            FirasBackground(palette: palette, showHalo: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    section(title: Strings.Auth.consentProductsTitle(lang), lines: Strings.Auth.consentProducts)
                    section(title: Strings.Auth.consentWhyTitle(lang), lines: Strings.Auth.consentWhy)
                    section(title: Strings.Auth.consentFaqTitle(lang), lines: Strings.Auth.consentFaq)
                    trainingSection
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, 280)
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

    // MARK: - The data question

    private var trainingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: Strings.Settings.Privacy.consentTitle(lang))
                .font(FirasType.scaled(19, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: Strings.Settings.Privacy.consentQuestion(lang))
                .font(FirasType.scaled(15, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                choiceCard(
                    .accepted,
                    title: Strings.Settings.Privacy.acceptTitle(lang),
                    detail: Strings.Settings.Privacy.acceptBody(lang)
                )
                choiceCard(
                    .declined,
                    title: Strings.Settings.Privacy.declineTitle(lang),
                    detail: Strings.Settings.Privacy.declineBody(lang)
                )
            }

            Text(verbatim: Strings.Settings.Privacy.changeLater(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both cards are the same card: same height rule, same padding, same type, same target. Only
    /// the ring and the fill say which one is chosen — declining costs exactly one tap, like
    /// accepting.
    private func choiceCard(_ option: TrainingConsent, title: String, detail: String) -> some View {
        let selected = training == option
        return Button {
            guard training != option else { return }
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                training = option
            }
            Haptics.select()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? palette.accent : palette.borderStrong)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(FirasType.scaled(16, scale: prefs.fontScale, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    Text(verbatim: detail)
                        .font(FirasType.scaled(13, scale: prefs.fontScale))
                        .foregroundStyle(palette.textSecondary)
                        .lineSpacing(lang == .arabic ? 5 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? palette.accentSoft : palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? palette.accent : palette.border, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .bidiIsland(for: title, fallback: lang)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Gate

    private var gate: some View {
        VStack(spacing: 14) {
            checkbox
            legalLinks
            gateHint
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

    /// The one reason a reader can be stuck with the box ticked: the data question above is still
    /// unanswered, and a disabled button that never says why is the worst screen in software.
    @ViewBuilder
    private var gateHint: some View {
        if agreed, training == nil {
            Text(verbatim: Strings.Settings.Privacy.consentPending(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
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
            guard agreed, let answer = training else { return }
            TrainingConsent.record(answer)
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
                        .fill(canContinue ? palette.accent : palette.borderStrong)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.65)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: canContinue)
        .accessibilityLabel(Text(verbatim: Strings.Auth.consentContinue(lang)))
        .accessibilityHint(Text(verbatim: continueHint))
    }

    private var continueHint: String {
        if !agreed { return Strings.Auth.consentAgreeHint(lang) }
        if training == nil { return Strings.Settings.Privacy.consentPending(lang) }
        return ""
    }
}
