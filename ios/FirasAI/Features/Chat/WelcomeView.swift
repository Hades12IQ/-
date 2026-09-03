import SwiftUI

/// The empty conversation: the mark, one greeting line, nothing else — and both of them in the
/// middle of the page, the way Claude's iPhone app opens.
///
/// The owner's note is the whole layout: «الشعار بالنص و تحته التحية، الاثنين بالنص». So the block
/// is centred on **both** axes rather than parked under the navigation bar, and it says the
/// reader's first name. There are still no suggestion chips — the web deliberately shows none on
/// Firas AI (`web-chat-ux.md §12`) — and Agent and Brain keep their one-line promise instead
/// (`design-brief.md §7.1`). The halo behind it is painted by `FirasBackground(showHalo: true)` at
/// the screen level, so this view only settles the mark and fades the words in.
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
        block
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            /* Vertical centring, and the one subtle thing in this file. The host (`ChatScreen`)
               hands this view to a `ScrollView` and pads it 60 pt down from the navigation bar, so
               asking for the container's full height would push the block half a title below the
               middle and leave the page scrollable by exactly that padding. Taking 120 pt off
               instead — the padding above, the same again below — puts the centre of this frame on
               the centre of the scroll view and leaves the page shorter than its container, which
               is why it does not scroll at all. The floor keeps a greeting that wrapped onto three
               lines from being squeezed. */
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in
                max(240, height - 120)
            }
            .accessibilityElement(children: .combine)
            .onAppear { reveal() }
    }

    /// The mark, then the words. Centred on the cross axis by the stack, centred on the page by the
    /// frame above.
    private var block: some View {
        VStack(spacing: 20) {
            FirasBrandMark(size: 52, showsWordmark: false, palette: palette)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)

            words
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
        }
    }

    private var words: some View {
        VStack(spacing: 8) {
            Text(headline)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                /* The island decides the direction from the first strong character, so an Arabic
                   greeting carrying a Latin name — «مساء الخير، Firas» — keeps both halves in the
                   order they were written. The alignment is re-stated after it: `bidiIsland` sets
                   `layoutDirection`, which resets the multiline alignment underneath it. */
                .bidiIsland(for: headline, fallback: lang)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: subtitle, fallback: lang)
                    .multilineTextAlignment(.center)
            }
        }
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

    /// The greeting is the hour's, and it carries the reader's first name when there is one — a
    /// guest, or an account with an empty name, simply gets the hour.
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
