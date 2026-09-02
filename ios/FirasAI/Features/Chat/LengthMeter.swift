import SwiftUI

/// The composer's character / token read-out (`web-chat-ux.md §7.1`, `design-brief.md §7.3`).
///
/// Silent under 400 characters. At 80 % of the tier's window it turns `accent` and says
/// `اقترب من حدّ …`; past the window it turns `error` and says `تجاوز حدّ …`. Tapping it explains the
/// 200 000-character hard cut — the number is an estimate and the copy says so.
struct LengthMeter: View {

    /// `LENM_SHOW_AT`.
    static let showAt = 400
    /// `LENM_HARD_CHARS` — past this the server may cut a saved message.
    static let hardCharacters = 200_000
    /// `LENM_NEAR`.
    private static let nearFraction = 0.8

    private let text: String
    private let tier: ModelTier
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onExplain: () -> Void

    init(
        text: String,
        tier: ModelTier,
        palette: FirasPalette,
        lang: AppLanguage,
        onExplain: @escaping () -> Void
    ) {
        self.text = text
        self.tier = tier
        self.palette = palette
        self.lang = lang
        self.onExplain = onExplain
    }

    var body: some View {
        if text.count >= Self.showAt {
            Button(action: onExplain) {
                HStack(spacing: 6) {
                    Text(charactersLabel)
                    Text(verbatim: "·")
                        .foregroundStyle(palette.textMuted)
                    Text(tokensLabel)
                    if let warning {
                        Text(verbatim: "·")
                            .foregroundStyle(palette.textMuted)
                        Text(warning)
                            .fontWeight(.medium)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
        }
    }

    // MARK: - Copy

    private var charactersLabel: String {
        Strings.Composer.lengthChars.fmt(lang, ArabicText.count(text.count, lang))
    }

    private var tokensLabel: String {
        Strings.Composer.lengthTokens.fmt(lang, ArabicText.count(tokens, lang))
    }

    private var warning: String? {
        let short = tier.short(lang)
        if isOver { return Strings.Composer.lengthOver.fmt(lang, short) }
        if isNear { return Strings.Composer.lengthNear.fmt(lang, short) }
        return nil
    }

    private var accessibilityLabel: String {
        [charactersLabel, tokensLabel, warning].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - State

    private var tokens: Int { Self.estimatedTokens(text) }

    private var isOver: Bool { tokens > Self.tokenWindow(for: tier) }

    private var isNear: Bool {
        !isOver && Double(tokens) >= Double(Self.tokenWindow(for: tier)) * Self.nearFraction
    }

    private var tint: Color {
        if isOver { return palette.error }
        if isNear { return palette.accent }
        return palette.textMuted
    }

    // MARK: - Estimation

    /// `LENM_TIER_TOKENS` — the window the meter measures against. This is deliberately *not*
    /// `ModelTier.tokenCap` (that one is the answer's `max_tokens`).
    static func tokenWindow(for tier: ModelTier) -> Int {
        switch tier {
        case .mini: return 4_000
        case .pro, .ultra: return 16_000
        case .max: return 24_000
        }
    }

    /// A rough estimate, exactly as the tooltip promises: Arabic packs ~2.2 characters per token,
    /// Latin ~4, and a mixed message lands in between.
    static func estimatedTokens(_ text: String) -> Int {
        var arabic = 0
        var counted = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            counted += 1
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                arabic += 1
            default:
                break
            }
        }
        guard counted > 0 else { return 0 }
        let ratio = Double(arabic) / Double(counted)
        let charactersPerToken = 4.0 - (1.8 * ratio)
        return max(1, Int((Double(counted) / charactersPerToken).rounded()))
    }
}
