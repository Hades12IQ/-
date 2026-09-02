import SwiftUI

/// The four quick commands (`web-chat-ux.md §7.1` and the Appendix A prompt bodies).
///
/// Picking one replaces the typed `/…` token with the command's **verbatim** body, which ends in a
/// blank line so the user's own text starts on its own paragraph.
enum SlashCommand: String, CaseIterable, Identifiable, Sendable {
    case summarize
    case translate
    case explain
    case review

    var id: String { rawValue }

    var label: LText {
        switch self {
        case .summarize: return Strings.Composer.slashSummarizeLabel
        case .translate: return Strings.Composer.slashTranslateLabel
        case .explain: return Strings.Composer.slashExplainLabel
        case .review: return Strings.Composer.slashReviewLabel
        }
    }

    var hint: LText {
        switch self {
        case .summarize: return Strings.Composer.slashSummarizeHint
        case .translate: return Strings.Composer.slashTranslateHint
        case .explain: return Strings.Composer.slashExplainHint
        case .review: return Strings.Composer.slashReviewHint
        }
    }

    /// The prompt body inserted into the composer, verbatim.
    var promptBody: LText {
        switch self {
        case .summarize: return Strings.Composer.slashSummarizeBody
        case .translate: return Strings.Composer.slashTranslateBody
        case .explain: return Strings.Composer.slashExplainBody
        case .review: return Strings.Composer.slashReviewBody
        }
    }

    var symbol: String {
        switch self {
        case .summarize: return "list.bullet.rectangle"
        case .translate: return "character.book.closed"
        case .explain: return "lightbulb"
        case .review: return "checkmark.seal"
        }
    }
}

/// The small panel that opens above the composer while the draft is nothing but a `/…` token.
struct SlashMenu: View {

    private let selection: Int
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onPick: (SlashCommand) -> Void

    init(
        selection: Int,
        palette: FirasPalette,
        lang: AppLanguage,
        onPick: @escaping (SlashCommand) -> Void
    ) {
        self.selection = selection
        self.palette = palette
        self.lang = lang
        self.onPick = onPick
    }

    /// The `/…` token to replace: the draft is a single slash word and nothing else.
    static func token(in text: String) -> Bool {
        guard text.hasPrefix("/"), text.count <= 24 else { return false }
        return !text.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" })
    }

    static var commands: [SlashCommand] { SlashCommand.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.Composer.slashTitle(lang))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(Array(Self.commands.enumerated()), id: \.element.id) { index, command in
                row(command, highlighted: index == selection)
                if command != Self.commands.last {
                    Divider().overlay(palette.border)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: 360)
        .firasGlass(
            .sheet,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .shadow(color: palette.glassShadow, radius: 18, y: 6)
        .accessibilityLabel(Text(Strings.Composer.slashTitle(lang)))
    }

    private func row(_ command: SlashCommand, highlighted: Bool) -> some View {
        Button {
            onPick(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.label(lang))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(command.hint(lang))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                .bidiIsland(for: command.label(lang), fallback: lang)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.accentSoft)
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
