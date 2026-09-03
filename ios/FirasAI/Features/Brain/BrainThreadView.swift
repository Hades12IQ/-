import SwiftUI
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
    @State private var followsTail = true

    private static let tailAnchor = "brain-thread-tail"

    init(env: AppEnvironment, conversationID: String?, onCitation: @escaping (BrainSource) -> Void) {
        self.env = env
        self.conversationID = conversationID
        self.onCitation = onCitation
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty && !isAsking {
                        hero
                    }
                    ForEach(messages) { message in
                        row(for: message)
                            .id(message.id)
                    }
                    if isAsking {
                        liveTurn
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readingColumn(prefs.contentWidth)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    if value.translation.height > 12 { followsTail = false }
                }
            )
            .onChange(of: liveLength) { _, _ in
                scrollToTail(proxy, animated: false)
            }
            .onChange(of: messages.count) { _, _ in
                followsTail = true
                scrollToTail(proxy, animated: true)
            }
            .onChange(of: isAsking) { _, running in
                if running {
                    followsTail = true
                    scrollToTail(proxy, animated: true)
                }
            }
        }
    }

    // MARK: - Data

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var store: BrainStore { env.brain }

    private var messages: [ChatMessage] {
        guard let conversationID else { return [] }
        return env.chat.conversations[conversationID]?.messages ?? []
    }

    private var isAsking: Bool {
        store.isAsking && store.threadID == conversationID && conversationID != nil
    }

    private var liveLength: Int { store.liveAnswer.count }

    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }

    private func scrollToTail(_ proxy: ScrollViewProxy, animated: Bool) {
        guard followsTail else { return }
        if animated && motionOn {
            withAnimation(FirasMotion.standard) {
                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            BrainQuestionBubble(
                text: message.visibleContent,
                lang: language(of: message),
                palette: palette
            )
        case .assistant:
            BrainAnswerView(
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

    private func language(of message: ChatMessage) -> AppLanguage {
        if let raw = message.lang, let language = AppLanguage(rawValue: raw) { return language }
        return BidiText.isArabicDominant(message.content) ? .arabic : .english
    }

    // MARK: - Live turn

    @ViewBuilder
    private var liveTurn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = store.pendingNotice, !notice.isEmpty {
                FirasActivityLabel(text: notice, palette: palette, motionOn: motionOn)
            }
            if !store.liveAnswer.isEmpty {
                BrainAnswerView(
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

    // MARK: - Hero

    private var hero: some View {
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

// MARK: - The question bubble

/// The user's question. Clamped to 12 lines with a reveal control, exactly like the web's
/// `tclamp capLines:12` (`web-brain-ux.md §5.2a`).
private struct BrainQuestionBubble: View {

    let text: String
    let lang: AppLanguage
    let palette: FirasPalette

    @State private var expanded = false

    var body: some View {
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

    /// 20 pt corners with the bottom-trailing one at 7 (`design-brief.md §2.5`); the leading and
    /// trailing sides follow the layout direction, so the bubble flips with the language.
    private static var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 7,
            topTrailingRadius: 20,
            style: .continuous
        )
    }
}
