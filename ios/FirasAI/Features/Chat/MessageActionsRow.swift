import SwiftUI
import UIKit

/// The quiet row under an answer: copy, regenerate, listen, export, more.
///
/// It is furniture, not content. Ghost glyphs in `textMuted` with no chip, no ring and no ground —
/// the row should be findable when you look for it and invisible when you are reading, which is what
/// "a row that does not shout" means. On a pointer device it sits at 78 % and comes to full strength
/// on hover; on touch there is no hover to reveal it with, so it simply stays legible.
///
/// Copy says `تم النسخ` in place for 1.4 s — never a toast for the happy path, always one for the
/// failure (`design-brief.md §7.7`).
struct MessageActionsRow: View {

    private let env: AppEnvironment
    private let message: ChatMessage
    private let conversationID: String
    private let product: ProductKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var copied = false
    @State private var hovering = false
    @State private var translation: String?
    @State private var isTranslating = false
    @State private var isExporting = false
    @State private var exportResult: ExportController.Export?

    /// Wide enough to hit, small enough to disappear into the page.
    private static let buttonWidth: CGFloat = 38
    private static let buttonHeight: CGFloat = 34

    init(
        env: AppEnvironment,
        message: ChatMessage,
        conversationID: String,
        product: ProductKind
    ) {
        self.env = env
        self.message = message
        self.conversationID = conversationID
        self.product = product
    }

    /// Both switches, never just the in-app one (`FirasMotion.isOn`).
    private var motionOn: Bool {
        FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
    }

    var body: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang

        return VStack(alignment: .leading, spacing: 10) {
            row(palette: palette, lang: lang)
            translationBlock(palette: palette, lang: lang)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $exportResult) { export in
            FirasActivitySheet(url: export.url)
        }
    }

    // MARK: - The row

    private func row(palette: FirasPalette, lang: AppLanguage) -> some View {
        HStack(spacing: 0) {
            copyButton(palette: palette, lang: lang)
            if product == .ai {
                regenerateMenu(palette: palette, lang: lang)
            }
            listenButton(palette: palette, lang: lang)
            exportMenu(palette: palette, lang: lang)
            moreMenu(palette: palette, lang: lang)
            Spacer(minLength: 0)
        }
        // The whole row is inset by the glyph's own optical padding so the first icon lines up with
        // the first letter of the answer above it instead of floating a few points to its side.
        .padding(.leading, -10)
        .opacity(hovering ? 1 : 0.78)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func copyButton(palette: FirasPalette, lang: AppLanguage) -> some View {
        ghost(
            symbol: copied ? "checkmark" : "doc.on.doc",
            title: copied ? Strings.Common.copied(lang) : Strings.Common.copy(lang),
            tint: copied ? palette.success : palette.textMuted
        ) {
            performCopy(lang: lang)
        }
    }

    private func listenButton(palette: FirasPalette, lang: AppLanguage) -> some View {
        let speaking = env.tts.speakingMessageID == message.id
        return ghost(
            symbol: speaking ? "stop.fill" : "speaker.wave.2",
            title: speaking ? Strings.Chat.listenStop(lang) : Strings.Chat.listen(lang),
            tint: speaking ? palette.accent : palette.textMuted
        ) {
            ChatTurnActions.listen(message: message, env: env)
        }
    }

    private func regenerateMenu(palette: FirasPalette, lang: AppLanguage) -> some View {
        Menu {
            Button {
                ChatTurnActions.regenerate(
                    messageID: message.id,
                    conversationID: conversationID,
                    tier: nil,
                    env: env
                )
            } label: {
                Text(Strings.Chat.regenSame(lang))
                Image(systemName: "arrow.clockwise")
            }

            if message.tier != ModelTier.max.rawValue {
                Button {
                    ChatTurnActions.regenerate(
                        messageID: message.id,
                        conversationID: conversationID,
                        tier: .max,
                        env: env
                    )
                } label: {
                    Text(Strings.Chat.regenMax(lang))
                    Image(systemName: "crown")
                }
            }
        } label: {
            ghostLabel(symbol: "arrow.clockwise", tint: palette.textMuted)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.regenerate(lang)))
    }

    private func exportMenu(palette: FirasPalette, lang: AppLanguage) -> some View {
        Menu {
            ForEach(ExportController.Format.allCases) { format in
                Button {
                    export(format, lang: lang)
                } label: {
                    Text(format.label(lang))
                    Image(systemName: format.symbol)
                }
            }
        } label: {
            ghostLabel(
                symbol: isExporting ? "hourglass" : "square.and.arrow.down",
                tint: palette.textMuted
            )
        }
        .menuOrder(.fixed)
        .disabled(isExporting)
        .accessibilityLabel(Text(Strings.Chat.download(lang)))
    }

    private func export(_ format: ExportController.Format, lang: AppLanguage) {
        guard !isExporting else { return }
        isExporting = true
        let controller = ExportController(env: env)
        let source = ChatTurnActions.markdown(message)
        let title = env.chat.conversations[conversationID]?.title ?? Strings.Chat.newChat(lang)
        Task {
            await controller.export(format, markdown: source, title: title)
            isExporting = false
            if let finished = controller.result {
                exportResult = finished
            }
        }
    }

    private func moreMenu(palette: FirasPalette, lang: AppLanguage) -> some View {
        Menu {
            if ChatTurnActions.looksTruncated(message), !ChatTurnActions.isCardTurn(message) {
                Button {
                    ChatTurnActions.continueAnswer(
                        messageID: message.id,
                        conversationID: conversationID,
                        env: env
                    )
                } label: {
                    Text(Strings.Chat.continueAnswer(lang))
                    Image(systemName: "text.append")
                }
            }

            Button {
                ChatTurnActions.share(message: message, conversationID: conversationID, env: env)
            } label: {
                Text(Strings.Chat.shareOne(lang))
                Image(systemName: "link")
            }

            if env.session.isMember {
                Button {
                    translate(lang: lang)
                } label: {
                    Text(translation == nil ? Strings.Chat.translateAction(lang) : Strings.Chat.translateHide(lang))
                    Image(systemName: "character.book.closed")
                }
            }
        } label: {
            ghostLabel(symbol: "ellipsis", tint: palette.textMuted)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.more(lang)))
    }

    // MARK: - Translation

    @ViewBuilder
    private func translationBlock(palette: FirasPalette, lang: AppLanguage) -> some View {
        if isTranslating {
            FirasActivityLabel(
                text: Strings.Chat.translateWorking(lang),
                palette: palette,
                motionOn: motionOn
            )
        } else if let translation {
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.Chat.translateTitle(lang))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                Text(translation)
                    .font(FirasType.scaled(15, scale: env.prefs.fontScale))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .bidiIsland(for: translation, fallback: lang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceSunken)
            }
        }
    }

    private func translate(lang: AppLanguage) {
        if translation != nil {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                translation = nil
            }
            return
        }
        let source = ChatTurnActions.plainText(message)
        guard !source.isEmpty else {
            env.toasts.show(Strings.Chat.exportEmpty(lang), isError: true)
            return
        }
        let messageLang = message.lang ?? lang.rawValue
        let target = messageLang.hasPrefix("ar") ? "en" : "ar"
        isTranslating = true
        let api = env.api
        let toasts = env.toasts
        let motion = motionOn
        Task {
            let result = try? await api.translate(text: source, to: target)
            isTranslating = false
            if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motion)) {
                    translation = result
                }
            } else {
                toasts.show(Strings.Chat.translateFailed(lang), isError: true)
            }
        }
    }

    // MARK: - Copy

    private func performCopy(lang: AppLanguage) {
        guard ChatTurnActions.copy(ChatTurnActions.markdown(message), env: env) else {
            env.toasts.show(Strings.Common.copyFailed(lang), isError: true)
            return
        }
        withAnimation(FirasMotion.gated(FirasMotion.fade, motionOn: motionOn)) { copied = true }
        let flag = $copied
        let animate = motionOn
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(FirasMotion.gated(FirasMotion.fade, motionOn: animate)) {
                flag.wrappedValue = false
            }
        }
    }

    // MARK: - Chrome

    private func ghost(
        symbol: String,
        title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ghostLabel(symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func ghostLabel(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: MessageActionsRow.buttonWidth, height: MessageActionsRow.buttonHeight)
            .contentShape(Rectangle())
    }
}
