import SwiftUI

/// The long-press menu on a turn.
///
/// The web's order, trimmed to the verbs this app actually performs (`design-brief.md §7.7`): copy,
/// listen, regenerate, continue, retry with Max, share. The system provides the haptic and the
/// preview — nothing here fires one of its own.
///
/// Used as `.contextMenu { MessageContextMenu(...) }`, so its body is a plain list of buttons.
struct MessageContextMenu: View {

    private let env: AppEnvironment
    private let message: ChatMessage
    private let conversationID: String
    private let product: ProductKind

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

    var body: some View {
        let lang = env.prefs.lang

        Button {
            copy(lang: lang)
        } label: {
            Text(Strings.Common.copy(lang))
            Image(systemName: "doc.on.doc")
        }

        if message.role == .assistant {
            assistantItems(lang: lang)
        }
    }

    @ViewBuilder
    private func assistantItems(lang: AppLanguage) -> some View {
        let isCard = ChatTurnActions.isCardTurn(message)

        Button {
            ChatTurnActions.listen(message: message, env: env)
        } label: {
            Text(listenTitle(lang))
            Image(systemName: env.tts.speakingMessageID == message.id ? "stop.fill" : "speaker.wave.2")
        }

        if product == .ai {
            Button {
                ChatTurnActions.regenerate(
                    messageID: message.id,
                    conversationID: conversationID,
                    tier: nil,
                    env: env
                )
            } label: {
                Text(Strings.Chat.regenerate(lang))
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

            if !isCard, ChatTurnActions.looksTruncated(message) {
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
        }

        if !isCard {
            ShareLink(item: ChatTurnActions.plainText(message)) {
                Text(Strings.Common.share(lang))
                Image(systemName: "square.and.arrow.up")
            }

            Button {
                ChatTurnActions.share(
                    message: message,
                    conversationID: conversationID,
                    env: env
                )
            } label: {
                Text(Strings.Chat.shareOne(lang))
                Image(systemName: "link")
            }
        }
    }

    private func listenTitle(_ lang: AppLanguage) -> String {
        env.tts.speakingMessageID == message.id
            ? Strings.Chat.listenStop(lang)
            : Strings.Chat.listen(lang)
    }

    private func copy(lang: AppLanguage) {
        let text = message.role == .assistant
            ? ChatTurnActions.markdown(message)
            : message.content
        if !ChatTurnActions.copy(text, env: env) {
            env.toasts.show(Strings.Common.copyFailed(lang), isError: true)
        }
    }
}
