import SwiftUI
import Perception

/// The iOS18 Chat scroll policy, separated only to keep ScrollPosition out of older view storage.
@available(iOS 18.0, *)
struct ModernChatTranscriptScroll<Content: View>: View {
    let conversationID: String
    let latestUserID: String?
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool
    let onPinned: (Bool) -> Void
    let content: Content
    @State private var position = ScrollPosition(edge: .top)
    @State private var showsChip = false
    @State private var followsTail = true
    @State private var isUserScrolling = false
    @State private var isJumping = false
    @State private var lastUserID: String?
    @State private var seededConversationID: String?
    @State private var metrics = ChatScrollMeasurement()

    var body: some View {
        return WithPerceptionTracking {
        ScrollView { content }
            .scrollPosition($position)
            .firasScrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ChatScrollMeasurement.self) { geometry in
                let distance = max(0, geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.contentOffset.y - geometry.containerSize.height)
                return ChatScrollMeasurement(contentHeight: geometry.contentSize.height.rounded(),
                    viewportHeight: geometry.containerSize.height.rounded(), pinned: distance <= 48, away: distance > 220)
            } action: { old, new in
                metrics = new
                onPinned(new.pinned)
                if isUserScrolling { followsTail = new.pinned }
                let chip = new.away && !isJumping
                if showsChip != chip { showsChip = chip }
                if !isUserScrolling, followsTail,
                   old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight {
                    scrollToEnd(animated: false)
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    isUserScrolling = true
                    followsTail = false
                    isJumping = false
                } else if phase == .idle {
                    if isUserScrolling { followsTail = metrics.pinned }
                    isUserScrolling = false
                    if isJumping {
                        isJumping = false
                        if followsTail { scrollToEnd(animated: false) }
                    }
                }
            }
            .firasOnChange(of: latestUserID) { _, newest in
                guard newest != lastUserID else { return }
                lastUserID = newest
                jump()
            }
            .onAppear { seed() }
            .firasOnChange(of: conversationID) { _, _ in seed() }
            .overlay(alignment: .bottom) {
                if showsChip { ChatTranscriptJumpButton(palette: palette, lang: lang, action: jump) }
            }
            }
    }

    private func seed() {
        guard seededConversationID != conversationID else { return }
        seededConversationID = conversationID
        lastUserID = latestUserID
        followsTail = true
        isUserScrolling = false
        isJumping = false
        showsChip = false
        scrollToEnd(animated: false)
    }

    private func jump() {
        Keyboard.dismiss()
        isUserScrolling = false
        followsTail = true
        isJumping = motionOn
        showsChip = false
        onPinned(true)
        scrollToEnd(animated: motionOn)
    }

    private func scrollToEnd(animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.30)) { position.scrollTo(edge: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        }
    }
}

private struct ChatScrollMeasurement: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var pinned = true
    var away = false
}

@available(iOS 18.0, *)
struct ModernBrainTranscriptScroll<Content: View>: View {
    let conversationID: String?
    let messageCount: Int
    let isAsking: Bool
    let liveLength: Int
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool
    let content: Content
    @State private var followsTail = true
    @State private var atBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var scrollPhase: ScrollPhase = .idle

    var body: some View {
        return WithPerceptionTracking {
        ScrollView { content.scrollTargetLayout() }
            .contentShape(Rectangle())
            .dismissesKeyboardOnTap()
            .firasScrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                if phase == .tracking || phase == .interacting { followsTail = false }
                if phase == .idle { followsTail = atBottom }
            }
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { TranscriptScrollMetrics($0) } action: { old, new in
                atBottom = new.distance < 72
                if followsTail, scrollPhase == .idle,
                   old.height != new.height || old.viewport != new.viewport {
                    scrollToTail(animated: false)
                }
            }
            .firasOnChange(of: liveLength) { _, _ in scrollToTail(animated: false) }
            .firasOnChange(of: conversationID) { _, _ in
                followsTail = true
                scrollToTail(animated: false)
            }
            .firasOnChange(of: messageCount) { _, _ in scrollToTail(animated: false) }
            .firasOnChange(of: isAsking) { _, running in
                if running {
                    followsTail = true
                    Keyboard.dismiss()
                    scrollToTail(animated: true)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    TranscriptBottomButton(palette: palette, lang: lang) {
                        Keyboard.dismiss()
                        followsTail = true
                        scrollToTail(animated: true)
                    }
                }
            }
            }
    }

    private func scrollToTail(animated: Bool) {
        guard followsTail else { return }
        if animated && motionOn {
            withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
        } else { scrollPosition.scrollTo(edge: .bottom) }
    }
}

@available(iOS 18.0, *)
struct ModernAgentTranscriptScroll<Content: View>: View {
    let conversationID: String
    let rowCount: Int
    let latestUserID: String?
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool
    let content: Content
    @State private var atBottom = true
    @State private var followsTail = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var scrollPhase: ScrollPhase = .idle

    var body: some View {
        return WithPerceptionTracking {
        ScrollView { content.scrollTargetLayout() }
            .contentShape(Rectangle())
            .dismissesKeyboardOnTap()
            .firasScrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                if phase == .tracking || phase == .interacting { followsTail = false }
                if phase == .idle { followsTail = atBottom }
            }
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { TranscriptScrollMetrics($0) } action: { old, new in
                atBottom = new.distance < 72
                if followsTail, scrollPhase == .idle,
                   old.height != new.height || old.viewport != new.viewport {
                    scrollToTail(animated: false)
                }
            }
            .firasOnChange(of: rowCount) { _, _ in scrollToTail(animated: false) }
            .firasOnChange(of: latestUserID) { _, _ in
                followsTail = true
                Keyboard.dismiss()
                scrollToTail(animated: true)
            }
            .firasOnChange(of: conversationID) { _, _ in
                followsTail = true
                scrollToTail(animated: false)
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    TranscriptBottomButton(palette: palette, lang: lang) {
                        Keyboard.dismiss()
                        followsTail = true
                        scrollToTail(animated: true)
                    }
                }
            }
            }
    }

    private func scrollToTail(animated: Bool) {
        guard followsTail else { return }
        if animated && motionOn {
            withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
        } else { scrollPosition.scrollTo(edge: .bottom) }
    }
}

@available(iOS 18.0, *)
struct ModernCodeTranscriptScroll<Content: View>: View {
    let latestUserID: String?
    let latestTurnID: String?
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool
    let content: Content
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true
    @State private var followsLatest = true

    var body: some View {
        return WithPerceptionTracking {
        ScrollView { content }
            .dismissesKeyboardOnTap()
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .firasScrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 90
            } action: { _, isNear in nearBottom = isNear }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsLatest = false }
                if phase == .idle { followsLatest = nearBottom }
            }
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
            } action: { _, _ in
                if followsLatest { position.scrollTo(edge: .bottom) }
            }
            .firasOnChange(of: latestUserID) { _, _ in scrollToLatest() }
            .firasOnChange(of: latestTurnID) { _, _ in
                if followsLatest { position.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !nearBottom { CodeTranscriptJumpButton(palette: palette, lang: lang, action: scrollToLatest) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func scrollToLatest() {
        Keyboard.dismiss()
        followsLatest = true
        withAnimation(motionOn ? .smooth(duration: 0.32) : nil) { position.scrollTo(edge: .bottom) }
    }
}

struct ChatTranscriptJumpButton: View {
    let palette: FirasPalette
    let lang: AppLanguage
    let action: () -> Void
    var body: some View {
        return WithPerceptionTracking {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 36, height: 36)
                .firasGlass(.floating, palette: palette, in: FirasAnyShape(Circle()))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .transition(.opacity)
        .accessibilityLabel(Text(Strings.Chat.scrollToBottom(lang)))
            }
    }
}

struct CodeTranscriptJumpButton: View {
    let palette: FirasPalette
    let lang: AppLanguage
    let action: () -> Void
    var body: some View {
        return WithPerceptionTracking {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 44, height: 44)
                .firasGlass(.floating, palette: palette, in: FirasAnyShape(Circle()))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .accessibilityLabel(Text(Strings.Chat.scrollToBottom(lang)))
            }
    }
}
