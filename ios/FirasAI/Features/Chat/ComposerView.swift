import SwiftUI

/// The composer (`design-brief.md §7.3`, `web-chat-ux.md §7`).
///
/// One `.floating` glass card, radius 24, at the reading column's width: attachment tray, text
/// field, then a control row that becomes the dictation bar while recording. It is designed to be
/// hosted in a `safeAreaInset(edge: .bottom)` so the keyboard pushes it and the home indicator never
/// sits on top of it.
///
/// Everything that can refuse says why: a disabled send, a still-reading attachment and a running
/// Agent mission each toast (`audit-ios-chat.md §M4–M7, M19`). Nothing here talks to the network —
/// `ChatStore.send` owns the whole send path.
struct ComposerView: View {

    /// Not `private`: `ComposerView+Attachments.swift` extends this type in another file.
    let env: AppEnvironment
    private let conversationID: String
    private let product: ProductKind
    private let placeholder: String

    @State private var text = ""
    @State var attachments: [ComposerAttachmentItem] = []
    @State private var showAddContext = false
    @State private var slashSelection = 0
    @State private var dictating = false
    @State private var sendPulse = false
    @State private var warnedHardCap = false
    @FocusState private var fieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, conversationID: String, product: ProductKind, placeholder: String) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
        self.placeholder = placeholder
    }

    // MARK: - Environment shortcuts

    private var palette: FirasPalette { env.prefs.palette }
    var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var state: ConversationState? { env.chat.states[conversationID] }
    private var isBusy: Bool { state?.isBusy ?? false }
    private var isReading: Bool { attachments.contains { $0.isReading } }
    private var readyAttachments: [PreparedAttachment] { attachments.compactMap { $0.prepared } }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !readyAttachments.isEmpty
    }
    private var slashOpen: Bool { SlashMenu.token(in: text) }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 6) {
            if slashOpen {
                SlashMenu(selection: slashSelection, palette: palette, lang: lang, onPick: pick(_:))
                    .transition(motionOn ? FirasMotion.revealTransition : .opacity)
            }
            card
            footer
        }
        .frame(maxWidth: env.prefs.contentWidth.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: slashOpen)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: dictating)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: attachments)
        .task(id: conversationID) { restoreDraft() }
        .onChange(of: text) { _, newValue in draftChanged(newValue) }
        .onChange(of: env.drafts.draft(for: conversationID)) { _, stored in
            adoptExternalDraft(stored)
        }
        .onChange(of: env.dictation.state) { _, newValue in dictationStateChanged(newValue) }
        .onChange(of: env.dictation.isActive) { wasActive, isActive in
            if wasActive && !isActive { dictating = false }
        }
        .sheet(isPresented: $showAddContext) {
            AddContextSheet(env: env, product: product) { picked in
                ingest(picked)
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { cardBody }
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(spacing: 6) {
            if let conversation = state, let quote = conversation.pendingQuote, !quote.isEmpty {
                ComposerQuotePill(quote: quote, palette: palette, lang: lang) {
                    conversation.pendingQuote = nil
                }
            }
            if !attachments.isEmpty {
                AttachmentTray(
                    items: attachments,
                    palette: palette,
                    lang: lang,
                    motionOn: motionOn,
                    onRemove: remove(_:),
                    onTruncatedTap: explainTruncation(_:)
                )
            }
            field
            if dictating {
                DictationBar(
                    dictation: env.dictation,
                    dialect: env.prefs.dictationDialect,
                    palette: palette,
                    lang: lang,
                    motionOn: motionOn,
                    onCancel: cancelDictation,
                    onFinish: finishDictation,
                    onPickDialect: { env.router.sheet = .dialectPicker }
                )
            } else {
                controls
            }
        }
        .padding(8)
        .firasGlass(
            .floating,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay {
            if dictating {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var field: some View {
        ComposerField(
            text: $text,
            placeholder: placeholder,
            palette: palette,
            lang: lang,
            fontScale: env.prefs.fontScale,
            sendOnReturn: env.prefs.sendOnReturn,
            isFocused: $fieldFocused,
            onSubmit: send,
            onKey: handleKey(_:)
        )
    }

    /// The disclaimer is CENTRED under the composer — «فراس كان ميك مستيك، وسطها، حاليا هي على
    /// اليسار» — which is where the web puts it and where a line that belongs to no side belongs.
    /// It cannot share a row with the length meter without being pushed off centre by it, so the
    /// meter takes its own line underneath on the rare draft long enough to have one. The threshold
    /// is `LengthMeter`'s own, so the row and the meter can never disagree about whether there is
    /// anything to show.
    private var footer: some View {
        VStack(spacing: 4) {
            Text(Strings.Composer.disclaimer(lang))
                .font(.system(size: 11))
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            if text.count >= LengthMeter.showAt {
                LengthMeter(
                    text: text,
                    tier: env.prefs.tier,
                    palette: palette,
                    lang: lang,
                    onExplain: explainLength
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(showingTools: true)
            controlRow(showingTools: false)
        }
    }

    private func controlRow(showingTools: Bool) -> some View {
        HStack(spacing: 2) {
            ComposerPlusButton(
                count: attachments.count,
                toolsActive: env.prefs.webSearchEnabled || env.prefs.thinkingEnabled,
                label: product == .agent
                    ? Strings.Composer.agentAttachHint(lang)
                    : Strings.Composer.attachHint(lang),
                palette: palette
            ) {
                fieldFocused = false
                showAddContext = true
            }

            if product == .ai {
                ModePill(env: env, conversationID: conversationID)
            }

            if showingTools {
                ComposerToolToggle(
                    symbol: "globe",
                    label: Strings.Composer.webSearch(lang),
                    hint: env.prefs.webSearchEnabled
                        ? Strings.Composer.searchOn(lang)
                        : Strings.Composer.searchOff(lang),
                    isOn: env.prefs.webSearchEnabled,
                    palette: palette
                ) {
                    env.prefs.webSearchEnabled.toggle()
                    Haptics.select()
                }

                if env.prefs.tier.showThinking {
                    ComposerToolToggle(
                        symbol: "sparkles",
                        label: Strings.Composer.thinking(lang),
                        hint: env.prefs.thinkingEnabled
                            ? Strings.Composer.thinkOn(lang)
                            : Strings.Composer.thinkOff(lang),
                        isOn: env.prefs.thinkingEnabled,
                        palette: palette
                    ) {
                        env.prefs.thinkingEnabled.toggle()
                        Haptics.select()
                    }
                }
            }

            Spacer(minLength: 4)

            micButton
            if product == .ai {
                ComposerActionButton(
                    symbol: "phone",
                    label: Strings.Composer.callLabel(lang),
                    palette: palette
                ) {
                    fieldFocused = false
                    env.router.cover = .call
                }
            }
            primaryButton
        }
    }

    private var micButton: some View {
        ComposerActionButton(
            symbol: "mic",
            label: Strings.Composer.micLabel(lang),
            palette: palette,
            action: startDictation
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                env.router.sheet = .dialectPicker
            }
        )
        .accessibilityHint(Text(Strings.Composer.micHint(lang)))
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isBusy {
            ComposerActionButton(
                symbol: "stop.fill",
                label: Strings.Common.stop(lang),
                palette: palette,
                prominent: true,
                enabled: true,
                action: stop
            )
            .keyboardShortcut(.escape, modifiers: [])
        } else {
            ComposerActionButton(
                symbol: "arrow.up",
                label: Strings.Common.send(lang),
                palette: palette,
                prominent: true,
                enabled: canSend && !isReading,
                action: send
            )
            .scaleEffect(sendPulse ? 0.92 : 1)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Sending

    private func send() {
        guard !isBusy else { return }
        if isReading {
            toast(Strings.Composer.stillReading)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = readyAttachments
        guard !trimmed.isEmpty || !ready.isEmpty else {
            toast(Strings.Composer.nothingToSend)
            return
        }

        /* NO SOUND ON SEND. The owner was unambiguous: "من ادوس ارسال ما اريد يطلع نغمه…
           نغمة تطلع بس من يرسل اشعار". A chime on every message is a chime he hears fifty times an
           hour, and it says nothing he did not already know — he pressed the button. The haptic
           stays: it is felt, not heard, and it does not carry into the room. */
        Haptics.send()
        /* THE KEYBOARD GOES AWAY WITH THE MESSAGE. Sending is the end of typing, and leaving the
           keyboard up covers the answer the reader is waiting for — "يوخر الكيبورد مو يبقيني
           فوق و يبقي الكيبورد". The transcript scrolls to the new turn on the same frame. */
        fieldFocused = false
        pulse()

        text = ""
        attachments = []
        warnedHardCap = false
        env.drafts.clear(conversationID)

        Task {
            await env.chat.send(text: trimmed, attachments: ready, in: conversationID, product: product)
        }
    }

    private func stop() {
        // A running mission is cancelled through its own store: the job is the same queue
        // job, but the Agent keeps the mission record and the stopped set.
        if product == .agent {
            Task { await env.agent.stop(in: conversationID) }
            return
        }
        Haptics.stop()
        Task { await env.chat.stop(in: conversationID) }
    }

    private func pulse() {
        guard motionOn else { return }
        withAnimation(.easeOut(duration: 0.12)) { sendPulse = true }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62).delay(0.12)) { sendPulse = false }
    }

    // MARK: - Drafts, slash menu, keys

    private func restoreDraft() {
        let stored = env.drafts.draft(for: conversationID)
        if text != stored {
            text = stored
        }
        slashSelection = 0
    }

    /// A quick-reply chip (`AssistantTurnView`) writes its sentence straight into `DraftStore`,
    /// because it cannot reach this view's `text`. Without this the chip would appear to do nothing
    /// until the conversation was re-opened.
    ///
    /// A write this composer made itself is already equal to `text` and is ignored; a store clamp
    /// (20 000 characters) is refused too, so a long paste is never silently truncated back.
    private func adoptExternalDraft(_ stored: String) {
        guard stored != text, !stored.isEmpty else { return }
        guard text.isEmpty || stored.hasPrefix(text) else { return }
        text = stored
    }

    private func draftChanged(_ newValue: String) {
        env.drafts.set(newValue, for: conversationID)
        if slashSelection >= SlashMenu.commands.count { slashSelection = 0 }
        if newValue.count > ChatAttachmentProcessor.hardComposerCharacters {
            if !warnedHardCap {
                warnedHardCap = true
                explainLength()
            }
        } else {
            warnedHardCap = false
        }
    }

    private func pick(_ command: SlashCommand) {
        text = command.promptBody(lang)
        slashSelection = 0
        fieldFocused = true
        Haptics.select()
    }

    private func handleKey(_ key: ComposerKey) -> Bool {
        guard slashOpen else { return false }
        let commands = SlashMenu.commands
        switch key {
        case .up:
            slashSelection = max(0, slashSelection - 1)
        case .down:
            slashSelection = min(commands.count - 1, slashSelection + 1)
        case .accept:
            guard slashSelection >= 0, slashSelection < commands.count else { return false }
            pick(commands[slashSelection])
        case .escape:
            text = ""
        }
        return true
    }

    // MARK: - Dictation

    /// The draft binding goes to the controller, so the words appear in the field while the user
    /// is still speaking and the server's transcript replaces them where they sit when the take
    /// ends. `finish()` returns `nil` for a live take — the text is already in — so
    /// `appendTranscript` only runs on a device that could not listen along.
    private func startDictation() {
        guard !dictating else {
            finishDictation()
            return
        }
        dictating = true
        fieldFocused = false
        Task {
            let opened = await env.dictation.start(into: $text)
            if !opened { dictating = false }
        }
    }

    private func finishDictation() {
        Task {
            let transcript = await env.dictation.finish()
            dictating = false
            if let transcript { appendTranscript(transcript) }
            fieldFocused = true
        }
    }

    private func cancelDictation() {
        Task {
            await env.dictation.cancel()
            dictating = false
        }
    }

    private func dictationStateChanged(_ newValue: DictationController.State) {
        if case .failed = newValue {
            dictating = false
        }
    }

    private func appendTranscript(_ transcript: String) {
        text = DictationController.appending(transcript, to: text)
    }

    func toast(_ message: LText, error: Bool = false) {
        if error { Haptics.error() }
        env.toasts.show(message(lang), isError: error)
    }
}
