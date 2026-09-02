import SwiftUI

private enum ChatSheet: Identifiable, Equatable {
    case modelPicker
    case addContext
    case media(MediaStudioKind, focusedJobID: String?)

    var id: String {
        switch self {
        case .modelPicker: "model-picker"
        case .addContext: "add-context"
        case .media(let kind, let jobID): "media-\(kind.rawValue)-\(jobID ?? "new")"
        }
    }
}

private enum ChatNotice {
    case voiceUnavailable
    case contextProcessing
    case contextPreparationFailed

    var message: LocalizedStringResource {
        switch self {
        case .voiceUnavailable: ChatStrings.voiceUnavailable
        case .contextProcessing: ChatStrings.contextProcessing
        case .contextPreparationFailed: ChatStrings.contextFileImportFailed
        }
    }

    var systemImage: String {
        switch self {
        case .voiceUnavailable: "mic.slash"
        case .contextProcessing: "hourglass"
        case .contextPreparationFailed: "exclamationmark.triangle"
        }
    }
}

struct ChatScreen: View {
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    let onOpenProfile: () -> Void
    let onOpenBrain: () -> Void
    var onStartCall: (() -> Void)?
    let mediaPresentationRequest: MediaPresentationRequest?
    let onConsumeMediaPresentation: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(ChatStore.self) private var chatStore
    @Environment(MediaStudioStore.self) private var mediaStudioStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var draftContext = DraftContextSelection()
    @State private var presentedSheet: ChatSheet?
    @State private var notice: ChatNotice?
    @State private var isPreparingContext = false
    @FocusState private var isComposerFocused: Bool

    init(
        showsSidebarButton: Bool,
        onOpenSidebar: @escaping () -> Void,
        onOpenProfile: @escaping () -> Void,
        onOpenBrain: @escaping () -> Void,
        onStartCall: (() -> Void)? = nil,
        mediaPresentationRequest: MediaPresentationRequest? = nil,
        onConsumeMediaPresentation: @escaping () -> Void = {}
    ) {
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
        self.onOpenProfile = onOpenProfile
        self.onOpenBrain = onOpenBrain
        self.onStartCall = onStartCall
        self.mediaPresentationRequest = mediaPresentationRequest
        self.onConsumeMediaPresentation = onConsumeMediaPresentation
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                conversation
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                chatToolbar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let notice {
                        ChatNoticeBanner(notice: notice) {
                            self.notice = nil
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    ChatComposer(
                        draft: $draft,
                        isFocused: $isComposerFocused,
                        isSending: chatStore.isSending || isPreparingContext,
                        selectedTier: preferences.tier,
                        contextCount: draftContext.itemCount,
                        onAddContext: showAddContext,
                        onDraftChanged: dismissNotice,
                        onSelectModel: showModelPicker,
                        onSend: send,
                        onStop: stop,
                        onStartCall: startCallTapped
                    )
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .overlay(alignment: .top) {
                if let errorMessage = chatStore.errorMessage, !errorMessage.isEmpty {
                    ChatErrorBanner(message: errorMessage) {
                        chatStore.errorMessage = nil
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .modelPicker:
                ModelSelectionSheet()
            case .addContext:
                AddContextSheet(
                    selection: $draftContext,
                    onOpenBrain: onOpenBrain,
                    onOpenMedia: openMediaStudio
                )
            case .media(let kind, let focusedJobID):
                MediaStudioScreen(
                    store: mediaStudioStore,
                    initialKind: kind,
                    focusedJobID: focusedJobID,
                    onOpenProfile: openProfileFromMediaStudio
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
            }
        }
        .onChange(of: mediaPresentationRequest, initial: true) { _, request in
            guard let request else { return }
            isComposerFocused = false
            presentedSheet = .media(request.kind, focusedJobID: request.focusedJobID)
            onConsumeMediaPresentation()
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chatStore.messages.isEmpty {
                    ChatWelcomeView()
                        .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    LazyVStack(spacing: 24) {
                        ForEach(chatStore.messages) { message in
                            ChatMessageRow(message: message)
                                .id(message.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollAnchor.bottom)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: preferences.contentWidth.maxWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollTrigger, initial: true) {
                guard !chatStore.messages.isEmpty else { return }
                if reduceMotion || !preferences.motionEnabled {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                } else {
                    withAnimation(.smooth(duration: 0.24)) {
                        proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if showsSidebarButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(ShellStrings.openSidebar))
            }
        }

        if !chatStore.messages.isEmpty {
            ToolbarItem(placement: .principal) {
                ChatNavigationTitle(title: chatStore.selectedConversation?.title)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: openProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(ShellStrings.account))
        }
    }

    private var scrollTrigger: ChatScrollTrigger {
        ChatScrollTrigger(
            messageCount: chatStore.messages.count,
            lastMessageLength: chatStore.messages.last?.content.count ?? 0,
            phase: chatStore.jobPhase
        )
    }

    private func showModelPicker() {
        notice = nil
        isComposerFocused = false
        presentedSheet = .modelPicker
    }

    private func showAddContext() {
        notice = nil
        isComposerFocused = false
        presentedSheet = .addContext
    }

    private func openMediaStudio(_ kind: MediaStudioKind) {
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard presentedSheet == nil else { return }
            presentedSheet = .media(kind, focusedJobID: nil)
        }
    }

    private func openProfileFromMediaStudio() {
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            onOpenProfile()
        }
    }

    private func openSidebar() {
        isComposerFocused = false
        onOpenSidebar()
    }

    private func openProfile() {
        isComposerFocused = false
        onOpenProfile()
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !draftContext.isEmpty else { return }
        guard !chatStore.isSending, !isPreparingContext else { return }
        guard !draftContext.isProcessing else {
            withAnimation(noticeAnimation) {
                notice = .contextProcessing
            }
            return
        }
        isPreparingContext = true
        let images = draftContext.images
        let files = draftContext.files
        Task {
            defer { isPreparingContext = false }
            do {
                let context = try await ChatAttachmentProcessor.prepare(
                    images: images,
                    files: files,
                    sharpenImages: preferences.sharpenImages
                )
                guard !message.isEmpty || !context.isEmpty else {
                    notice = .contextPreparationFailed
                    return
                }

                draft = ""
                draftContext.clear()
                notice = nil
                await chatStore.send(
                    text: message,
                    tier: preferences.tier,
                    thinking: preferences.thinkingEnabled,
                    webSearch: preferences.webSearchEnabled,
                    language: preferences.language,
                    context: context
                )
            } catch {
                withAnimation(noticeAnimation) {
                    notice = .contextPreparationFailed
                }
            }
        }
    }

    private func stop() {
        notice = nil
        Task {
            await chatStore.stop()
        }
    }

    private func startCallTapped() {
        if let onStartCall {
            onStartCall()
        } else {
            withAnimation(noticeAnimation) {
                notice = .voiceUnavailable
            }
        }
    }

    private func dismissNotice() {
        guard notice != nil else { return }
        withAnimation(noticeAnimation) {
            notice = nil
        }
    }

    private var noticeAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .smooth(duration: 0.22)
    }
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom-anchor"
}

private struct ChatScrollTrigger: Equatable {
    let messageCount: Int
    let lastMessageLength: Int
    let phase: ChatJobPhase?
}

private struct ChatNavigationTitle: View {
    let title: String?

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 260)
        } else {
            Text(ShellStrings.productTitle(.ai))
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 260)
        }
    }
}

private struct ChatWelcomeView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 20) {
            FirasBrandMark(size: 54)

            Text("chat.empty.title")
                .font(.title2.weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 28)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ChatNoticeBanner: View {
    let notice: ChatNotice
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 15, tintStrength: 0.05) {
            HStack(spacing: 10) {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .accessibilityHidden(true)

                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(preferences.palette.textMuted)
                .accessibilityLabel(Text(ChatStrings.dismissNotice))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(maxWidth: 720, minHeight: 48)
        }
    }
}

private struct ChatErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(preferences.palette.error)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ChatStrings.dismissNotice))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(preferences.palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(preferences.palette.error.opacity(0.38), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .frame(maxWidth: 720, minHeight: 50)
        .accessibilityElement(children: .contain)
    }
}
