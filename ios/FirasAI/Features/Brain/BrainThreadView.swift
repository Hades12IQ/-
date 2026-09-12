import SwiftUI
import Perception
import UIKit

/// The Brain ask thread (`web-brain-ux.md §5.2a`): the question bubbles, the answers, the pending
/// notice while a turn runs, and the hero when nothing has been asked yet.
///
/// A stopped or failed turn never replaces what is already on screen — `BrainStore` appends the
/// notice to the partial text and files the message, so this view only ever renders messages.
struct BrainThreadView: View {

    private let env: AppEnvironment
    private let conversationID: String?
    private let onCitation: (BrainSource) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let tailAnchor = "brain-thread-tail"

    init(env: AppEnvironment, conversationID: String?, onCitation: @escaping (BrainSource) -> Void) {
        self.env = env
        self.conversationID = conversationID
        self.onCitation = onCitation
    }

    var body: some View {
        return WithPerceptionTracking {
        Group {
            if #available(iOS 18.0, *), !TranscriptScrollCompatibility.forceLegacy {
                ModernBrainTranscriptScroll(conversationID: conversationID, messageCount: messages.count,
                    isAsking: isAsking, liveLength: liveLength, palette: palette, lang: prefs.lang,
                    motionOn: motionOn, content: transcriptContent)
            } else {
                LegacyTranscriptScroll(identity: conversationID ?? "brain-empty",
                    latestUserID: messages.last(where: { $0.role == .user })?.id,
                    sending: isAsking, motionOn: motionOn) { jump in
                    TranscriptBottomButton(palette: palette, lang: prefs.lang, action: jump)
                } content: { transcriptContent }
                .contentShape(Rectangle())
                .dismissesKeyboardOnTap()
            }
        }
            }
    }

    private var transcriptContent: some View {
        return WithPerceptionTracking {
        LazyVStack(alignment: .leading, spacing: 22) {
            if messages.isEmpty && !isAsking { hero }
            ForEach(messages) { message in
                WithPerceptionTracking {
row(for: message)
                    .id(message.id)
                    .legacyTranscriptRowAnchor(message.id)

                }}
            if isAsking { liveTurn.legacyTranscriptRowAnchor("brain-live-turn") }
            Color.clear.frame(height: 1).id(Self.tailAnchor)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readingColumn(prefs.contentWidth)
            }
    }

    // MARK: - Data

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var store: BrainStore { env.brain }

    private var messages: [ChatMessage] {
        guard let conversationID else { return [] }
        return env.chat.conversation(conversationID)?.messages ?? []
    }

    private var isAsking: Bool {
        store.isAsking && store.threadID == conversationID && conversationID != nil
    }

    private var liveLength: Int { store.liveAnswer.count }

    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }

    // MARK: - Rows

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        return WithPerceptionTracking {
        switch message.role {
        case .user:
            BrainQuestionBubble(
                text: message.visibleContent,
                lang: language(of: message),
                palette: palette
            )
        case .assistant:
            BrainAnswerView(
                env: env,
                markdown: message.visibleContent,
                messageID: message.id,
                streaming: false,
                lang: language(of: message),
                palette: palette,
                prefs: prefs,
                onCitation: onCitation
            )
        case .system, .unknown:
            EmptyView()
        }
            }
    }

    private func language(of message: ChatMessage) -> AppLanguage {
        if let raw = message.lang, let language = AppLanguage(rawValue: raw) { return language }
        return BidiText.isArabicDominant(message.content) ? .arabic : .english
    }

    // MARK: - Live turn

    @ViewBuilder
    private var liveTurn: some View {
        return WithPerceptionTracking {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = store.pendingNotice, !notice.isEmpty {
                FirasActivityLabel(text: notice, palette: palette, motionOn: motionOn)
            }
            if !store.liveAnswer.isEmpty {
                BrainAnswerView(
                    env: env,
                    markdown: store.liveAnswer,
                    messageID: "brain-live",
                    streaming: true,
                    lang: prefs.lang,
                    palette: palette,
                    prefs: prefs,
                    onCitation: onCitation
                )
            } else if store.pendingNotice == nil {
                FirasActivityLabel(
                    text: Strings.Brain.thinking(prefs.lang),
                    palette: palette,
                    motionOn: motionOn
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    // MARK: - Hero

    private var hero: some View {
        return WithPerceptionTracking {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.accent)
            EmptyStateView(
                title: Strings.Brain.heroTitle(prefs.lang),
                subtitle: Strings.Brain.heroBody(prefs.lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
            }
    }
}

// MARK: - The question bubble

/// The user's question. Clamped to 12 lines with a reveal control, exactly like the web's
/// `tclamp capLines:12` (`web-brain-ux.md §5.2a`).
private struct BrainQuestionBubble: View {

    let text: String
    let lang: AppLanguage
    let palette: FirasPalette

    @State private var expanded = false

    var body: some View {
        return WithPerceptionTracking {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(palette.userInk)
                .lineLimit(expanded ? nil : 12)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    Self.bubbleShape.fill(palette.userFill)
                }
                .overlay {
                    Self.bubbleShape.stroke(palette.userEdge, lineWidth: 0.5)
                }
                .bidiIsland(for: text, fallback: lang)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.select()
                    } label: {
                        Label(Strings.Common.copy(lang), systemImage: "doc.on.doc")
                    }
                }

            if text.count > 400 {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? Strings.Brain.showLess(lang) : Strings.Brain.showMore(lang))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
            }
    }

    /// 20 pt corners with the bottom-trailing one at 7 (`design-brief.md §2.5`); the leading and
    /// trailing sides follow the layout direction, so the bubble flips with the language.
    private static var bubbleShape: FirasUnevenRoundedRectangle {
        FirasUnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 7,
            topTrailingRadius: 20,
            style: .continuous
        )
    }
}
