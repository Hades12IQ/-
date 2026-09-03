import SwiftUI

/// The Agent product's composer.
///
/// It is deliberately its own view rather than the chat `ComposerView`: a mission is not a chat
/// turn — it goes to `AgentStore.start`, which charges, folds the attachments into the task and
/// hands the work to the durable queue. Everything else is shared with the chat composer
/// (`ComposerField`, `AttachmentTray`, `AddContextSheet`, `ChatAttachmentProcessor`).
///
/// The field never disappears: a running mission cannot be stopped, so the send button becomes an
/// hourglass and a send attempt answers with the web's "already running" toast
/// (`web-agent-ux.md §2.1.2`, `audit-ios-agent-code.md A16`).
struct AgentComposer: View {

    private let env: AppEnvironment
    private let conversationID: String

    @State private var text = ""
    @State private var attachments: [ComposerAttachmentItem] = []
    @State private var showsAddContext = false
    @State private var dictating = false
    @FocusState private var fieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, conversationID: String) {
        self.env = env
        self.conversationID = conversationID
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var draftKey: String { DraftStore.key(conversationID: conversationID) }

    private var isReading: Bool { attachments.contains { $0.isReading } }
    private var ready: [PreparedAttachment] { attachments.compactMap { $0.prepared } }
    private var isBusy: Bool {
        env.agent.liveConversationID != nil || env.agent.starting.contains(conversationID)
    }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ready.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentTray(
                    items: attachments,
                    palette: palette,
                    lang: lang,
                    motionOn: motionOn,
                    onRemove: remove(_:),
                    onTruncatedTap: { _ in toast(Strings.Agent.stillReading) }
                )
            }
            ComposerField(
                text: $text,
                placeholder: Strings.Agent.composerPlaceholder(lang),
                palette: palette,
                lang: lang,
                fontScale: env.prefs.fontScale,
                sendOnReturn: env.prefs.sendOnReturn,
                isFocused: $fieldFocused,
                onSubmit: send,
                onKey: { _ in false }
            )
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .firasGlass(.floating, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
        .overlay {
            if dictating {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: attachments)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: dictating)
        .task(id: conversationID) { text = env.drafts.draft(for: draftKey) }
        .onChange(of: text) { _, newValue in
            env.drafts.set(newValue, for: draftKey)
        }
        .onChange(of: env.dictation.state) { _, newValue in
            if case .failed = newValue { dictating = false }
        }
        .onChange(of: env.dictation.isActive) { wasActive, isActive in
            if wasActive && !isActive { dictating = false }
        }
        .sheet(isPresented: $showsAddContext) {
            AddContextSheet(env: env, product: .agent) { picked in
                ingest(picked)
            }
        }
        .accessibilityLabel(Text(Strings.Agent.composerLabel(lang)))
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ComposerPlusButton(
                count: attachments.count,
                toolsActive: false,
                label: Strings.Agent.attachHint(lang),
                palette: palette
            ) {
                Haptics.attach()
                showsAddContext = true
            }
            Spacer(minLength: 0)
            micButton
            ComposerActionButton(
                symbol: isBusy ? "hourglass" : "arrow.up",
                label: isBusy ? Strings.Agent.cannotStop(lang) : Strings.Agent.sendMission(lang),
                palette: palette,
                prominent: !isBusy,
                enabled: !isBusy && canSend && !isReading,
                action: send
            )
        }
    }

    private var micButton: some View {
        ComposerActionButton(
            symbol: "mic",
            label: Strings.Voice.micLabel(lang),
            palette: palette,
            action: startDictation
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                env.router.sheet = .dialectPicker
            }
        )
        .accessibilityHint(Text(Strings.Voice.micHint(lang)))
    }

    // MARK: - Dictation

    /// The same controller and the same bar as the chat composer — the mission field just hands it
    /// its own draft, so the words land here while the user speaks.
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
            if let transcript {
                text = DictationController.appending(transcript, to: text)
            }
            fieldFocused = true
        }
    }

    private func cancelDictation() {
        Task {
            await env.dictation.cancel()
            dictating = false
        }
    }

    // MARK: - Sending

    private func send() {
        guard !isBusy else {
            toast(Strings.Agent.cannotStop, error: true)
            return
        }
        if isReading {
            toast(Strings.Agent.stillReading)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = ready
        guard !trimmed.isEmpty || !prepared.isEmpty else { return }

        Haptics.send()
        text = ""
        attachments = []
        env.drafts.clear(draftKey)
        fieldFocused = false

        Task {
            await env.agent.start(task: trimmed, attachments: prepared, in: conversationID)
        }
    }

    // MARK: - Attachments

    private func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func ingest(_ pick: ComposerAttachmentPick) {
        switch pick {
        case .images(let payloads):
            addImages(payloads)
        case .files(let urls):
            addFiles(urls)
        }
    }

    private func addImages(_ payloads: [Data]) {
        let used = attachments.filter { $0.isImage }.count
        let room = ChatAttachmentProcessor.maxImages - used
        guard room > 0 else {
            toast(Strings.Agent.maxImages, error: true)
            return
        }
        if payloads.count > room {
            toast(Strings.Agent.maxImages, error: true)
        }
        for payload in payloads.prefix(room) {
            let item = ComposerAttachmentItem(name: "image", kind: "image")
            attachments.append(item)
            Task {
                do {
                    let prepared = try await ChatAttachmentProcessor.image(data: payload, name: item.name)
                    land(prepared, for: item.id, percentSent: 100)
                } catch {
                    fail(error, for: item.id)
                }
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            if ChatAttachmentProcessor.isImageFile(url) {
                guard attachments.filter({ $0.isImage }).count < ChatAttachmentProcessor.maxImages else {
                    toast(Strings.Agent.maxImages, error: true)
                    continue
                }
                let item = ComposerAttachmentItem(name: url.lastPathComponent, kind: "image")
                attachments.append(item)
                Task {
                    do {
                        let prepared = try await ChatAttachmentProcessor.image(url: url)
                        land(prepared, for: item.id, percentSent: 100)
                    } catch {
                        fail(error, for: item.id)
                    }
                }
                continue
            }

            guard attachments.filter({ !$0.isImage }).count < ChatAttachmentProcessor.maxFiles else {
                toast(Strings.Agent.maxFiles, error: true)
                continue
            }
            let remaining = max(0, ChatAttachmentProcessor.maxTotalFileCharacters - documentBudgetUsed)
            let item = ComposerAttachmentItem(
                name: url.lastPathComponent,
                kind: url.pathExtension.lowercased()
            )
            attachments.append(item)
            Task {
                do {
                    let result = try await ChatAttachmentProcessor.file(url: url, remainingCharacters: remaining)
                    land(result.attachment, for: item.id, percentSent: result.percentSent)
                } catch {
                    fail(error, for: item.id)
                }
            }
        }
    }

    private var documentBudgetUsed: Int {
        attachments.reduce(0) { $0 + $1.textCost }
    }

    private func land(_ prepared: PreparedAttachment, for id: UUID, percentSent: Int) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].status = .ready(prepared)
        attachments[index].percentSent = percentSent
    }

    private func fail(_ error: Error, for id: UUID) {
        attachments.removeAll { $0.id == id }
        if let known = error as? ChatAttachmentError {
            toast(known.message, error: true)
        } else {
            toast(Strings.Errors.generic, error: true)
        }
    }

    // MARK: - Toasts

    private func toast(_ message: LText, error: Bool = false) {
        if error { Haptics.error() }
        env.toasts.show(message(lang), isError: error)
    }
}
