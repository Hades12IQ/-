import SwiftUI

/// The logged-out hero (`design-brief.md §7.17 (3)`, copy verbatim in
/// `web-auth-account-settings.md §2`).
///
/// One guest CTA, one sign-in link, four product marks, seven feature cards and the image-beta
/// note. **No fabricated counters** — the web removed them and they do not come back. Glass appears
/// exactly once, on the pinned CTA bar; every card is an opaque `SurfaceCard`.
struct LandingView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(env: AppEnvironment) {
        self.env = env
    }

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }
    private var isWide: Bool { horizontalSizeClass == .regular }
    private var columnWidth: CGFloat { isWide ? 720 : 560 }

    private var featureColumns: [GridItem] {
        isWide
            ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible())]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            FirasBackground(palette: palette, showHalo: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero
                    scaleRow
                    featuresBlock
                    imageNote
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 52)
                .padding(.bottom, 260)
            }
            .scrollIndicators(.hidden)

            ctaBar
        }
        .background(palette.background)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
        .onChange(of: env.session.errorText) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            AccessibilityNotification.Announcement(newValue).post()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            FirasBrandMark(size: 62, showsWordmark: true, palette: palette)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(verbatim: Strings.Auth.landingAbout(lang))
                .font(FirasType.scaled(16, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 8 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: Strings.Auth.landingAbout(lang), fallback: lang)
        }
    }

    // MARK: - Four product marks

    private var scaleRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
            spacing: 10
        ) {
            ForEach(Strings.Auth.landingScale) { mark in
                VStack(spacing: 4) {
                    Text(verbatim: mark.name)
                        .font(FirasType.scaled(13, scale: prefs.fontScale, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .forceLTR()

                    Text(verbatim: mark.label(lang))
                        .font(FirasType.scaled(14, scale: prefs.fontScale))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.surfaceSunken)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Feature cards

    private var featuresBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: Strings.Auth.landingFeaturesTitle(lang))
                    .font(FirasType.scaled(22, scale: prefs.fontScale, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Text(verbatim: Strings.Auth.landingFeaturesSub(lang))
                    .font(FirasType.scaled(15, scale: prefs.fontScale))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(lang == .arabic ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: Strings.Auth.landingFeaturesTitle(lang), fallback: lang)

            LazyVGrid(columns: featureColumns, alignment: .leading, spacing: 12) {
                ForEach(Strings.Auth.landingFeatures) { feature in
                    featureCard(feature)
                }
            }
        }
    }

    private func featureCard(_ feature: Strings.Auth.LandingFeature) -> some View {
        SurfaceCard(palette: palette, radius: 9) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    Text(verbatim: feature.title(lang))
                        .font(FirasType.scaled(16, scale: prefs.fontScale, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(verbatim: feature.body(lang))
                    .font(FirasType.scaled(14, scale: prefs.fontScale))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(lang == .arabic ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: feature.title(lang), fallback: lang)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Image beta note

    private var imageNote: some View {
        SurfaceCard(palette: palette, radius: 9) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text(verbatim: Strings.Auth.landingImageBadge(lang))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            Capsule(style: .continuous).fill(palette.accentSoft)
                        }

                    Text(verbatim: Strings.Auth.landingImageTitle(lang))
                        .font(FirasType.scaled(16, scale: prefs.fontScale, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    Spacer(minLength: 0)
                }

                Text(verbatim: Strings.Auth.landingImageBody(lang))
                    .font(FirasType.scaled(14, scale: prefs.fontScale))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(lang == .arabic ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: Strings.Auth.landingImageTitle(lang), fallback: lang)
    }

    // MARK: - CTA bar (the only glass on this screen)

    private var ctaBar: some View {
        VStack(spacing: 10) {
            if !env.network.isOnline {
                statusLine(text: Strings.Errors.offline(lang), symbol: "wifi.slash", isError: false)
            } else if let message = env.session.errorText, !message.isEmpty {
                statusLine(text: message, symbol: "exclamationmark.triangle.fill", isError: true)
            }

            guestButton
            signInButton

            Text(verbatim: Strings.Auth.landingGuestHint(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity)
        /* THE DOOR IS NOT A WINDOW. Floating glass is for a panel that sits over a conversation
           the reader already knows — it belongs to what is behind it. This card is the first
           thing anybody sees, it sits over an illustrated ground, and there is nothing behind it
           worth showing through: all the transparency did was make «ابدأ» and «أنشئ حساباً»
           compete with whatever happened to be under them. A real surface, its own hairline and
           the same lift. */
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: palette.glassShadow, radius: 24, y: 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func statusLine(text: String, symbol: String, isError: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isError ? palette.error : palette.textMuted)
                .accessibilityHidden(true)

            Text(verbatim: text)
                .font(FirasType.caption)
                .foregroundStyle(isError ? palette.error : palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: text, fallback: lang)
        .accessibilityElement(children: .combine)
    }

    private var guestButton: some View {
        Button(action: startGuest) {
            HStack(spacing: 9) {
                if env.session.isStartingGuest {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.onAccent)
                        .accessibilityHidden(true)
                }

                Text(verbatim: Strings.Auth.landingStart(lang))
                    .font(FirasType.scaled(17, scale: prefs.fontScale, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background {
                Capsule(style: .continuous).fill(palette.accent)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(env.session.isStartingGuest)
        .opacity(env.session.isStartingGuest ? 0.75 : 1)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: env.session.isStartingGuest)
        .accessibilityLabel(Text(verbatim: Strings.Auth.landingStart(lang)))
    }

    private var signInButton: some View {
        Button {
            Haptics.select()
            env.router.open(.auth(mode: .login))
        } label: {
            Text(verbatim: Strings.Auth.landingSignIn(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Strings.Auth.landingSignIn(lang)))
    }

    // MARK: - Actions

    private func startGuest() {
        guard !env.session.isStartingGuest else { return }
        Haptics.select()
        Task {
            _ = await env.session.continueAsGuest()
        }
    }
}
