import SwiftUI

/// The empty conversation: the mark, one greeting line, nothing else.
///
/// The web deliberately shows no suggestion chips on Firas AI (`web-chat-ux.md §12`); Agent and Brain
/// get their one-line promise instead (`design-brief.md §7.1`). The halo behind it is painted by
/// `FirasBackground(showHalo: true)` at the screen level, so this view only settles the mark and
/// fades the words in.
struct WelcomeView: View {

    private let product: ProductKind
    private let firstName: String?
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool

    @State private var appeared = false

    init(
        product: ProductKind,
        firstName: String?,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool
    ) {
        self.product = product
        self.firstName = firstName
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
    }

    var body: some View {
        VStack(spacing: 18) {
            FirasBrandMark(size: 46, showsWordmark: false, palette: palette)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 8) {
                Text(headline)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .bidiIsland(for: headline, fallback: lang)
                    .multilineTextAlignment(.center)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                        .bidiIsland(for: subtitle, fallback: lang)
                        .multilineTextAlignment(.center)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .onAppear { reveal() }
    }

    private func reveal() {
        guard !appeared else { return }
        withAnimation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn)) { appeared = true }
    }

    // MARK: - Copy

    private var headline: String {
        switch product {
        case .agent:
            return Strings.Chat.agentWelcomeTitle(lang)
        case .brain:
            return Strings.Chat.brainWelcomeTitle(lang)
        case .ai, .code, .studio:
            return greeting
        }
    }

    private var subtitle: String? {
        switch product {
        case .agent:
            return Strings.Chat.agentWelcomeSubtitle(lang)
        case .brain:
            return Strings.Chat.brainWelcomeSubtitle(lang)
        case .ai, .code, .studio:
            return nil
        }
    }

    private var greeting: String {
        let base = Self.greetingBase(lang: lang)
        guard let name = firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return base
        }
        return Strings.Chat.greetingWithName.fmt(lang, base, name)
    }

    private static func greetingBase(lang: AppLanguage) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return Strings.Chat.greetingMorning(lang) }
        if hour < 18 { return Strings.Chat.greetingAfternoon(lang) }
        return Strings.Chat.greetingEvening(lang)
    }
}
