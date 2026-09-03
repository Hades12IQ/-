import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The Code session composer.
///
/// The first message in a blank session is a **build** — the session was created as an empty
/// scaffold, so the first instruction goes to the durable `codebuild` queue and keeps running
/// after the app is closed. Every later message is an edit, reviewed in the diff sheet before a
/// single character changes.
///
/// ROUND 3 — THE VERTICAL RHYTHM. «بفراس كود مكان الكتابة بالبوكس نازل جوة، ما صاير احترافي».
/// The old layout hung a bare text field off the **bottom** edge of an `HStack(alignment: .bottom)`
/// it shared with three 44 pt round buttons, under a 44 pt scrolling pill row that took the whole
/// top of the box. A `TextField` with no vertical padding is only ~21 pt tall, so bottom-aligning
/// it dropped the caret and the placeholder 11 pt below the optical centre of everything beside
/// them, and the pill row left no air above.
///
/// This is now exactly the chat composer's shape (`design-brief.md §7.3`): 8 pt inner padding and
/// two rows. Row one is the field alone, `minHeight: 44` so its text sits optically centred in its
/// own band with the same 8/6 pt insets `ComposerField` uses. Row two carries everything that acts
/// on it — attach, the model pill, the repository pill, then mic and send on the trailing edge.
/// The box breathes at 8 + 44 + 6 + 44 + 8 = 110 pt, the height of the chat composer.
struct CodeSessionComposer: View {

    private static let instructionLimit = 1_200

    /// `owner/repo · branch` is trimmed before the layout ever sees it, and the pill that carries
    /// it is the one that yields width first, so a long branch name can never push send off the
    /// trailing edge of a narrow phone.
    private static let repoLabelLimit = 24

    private let env: AppEnvironment
    @Binding private var prefill: String
    private let onPlan: (CodeEditPlan) -> Void
    private let onOpenRepository: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var attachments: [PreparedAttachment] = []
    @State private var isImporting = false
    @State private var isReadingAttachments = false
    @State private var isSending = false
    @State private var dictating = false
    @FocusState private var focused: Bool

    init(
        env: AppEnvironment,
        prefill: Binding<String>,
        onPlan: @escaping (CodeEditPlan) -> Void,
        onOpenRepository: @escaping () -> Void
    ) {
        self.env = env
        self._prefill = prefill
        self.onPlan = onPlan
        self.onOpenRepository = onOpenRepository
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var projectID: String { env.code.openProjectID ?? "" }
    private var link: CodeGitHubLink? { CodeGitHubModel.shared.link(for: projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            attachmentTray
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
                controlRow
            }
        }
        .padding(8)
        .firasGlass(
            .floating,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: dictating)
        .onAppear { absorbPrefill() }
        .onChange(of: prefill) { _, _ in absorbPrefill() }
        .onChange(of: draft) { _, value in
            if value.count > Self.instructionLimit {
                draft = String(value.prefix(Self.instructionLimit))
            }
        }
        .onChange(of: env.dictation.state) { _, value in
            if case .failed = value { dictating = false }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: ChatAttachmentProcessor.acceptedFileTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Row one: the field

    /// `minHeight: 44` with 6 pt of vertical padding is what makes one line of text sit in the
    /// middle of its band instead of on the floor of it: a `frame(minHeight:)` centres its child,
    /// so the caret, the placeholder and the buttons in the row below all share one optical centre.
    private var field: some View {
        TextField(
            text: $draft,
            prompt: Text(verbatim: Strings.CodeUI.composerPlaceholder(lang)),
            axis: .vertical
        ) {
            Text(verbatim: Strings.CodeUI.composerPlaceholder(lang))
        }
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .font(FirasType.scaled(17, scale: env.prefs.fontScale))
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
        .focused($focused)
        .disabled(isSending)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: draft, fallback: lang)
    }

    // MARK: - Row two: the controls

    private var controlRow: some View {
        HStack(spacing: 2) {
            FirasIconButton(
                symbol: "paperclip",
                label: Strings.CodeUI.attachLabel(lang),
                palette: palette
            ) {
                focused = false
                isImporting = true
            }
            .disabled(isSending)
            .opacity(isSending ? 0.45 : 1)

            tierPill
            repositoryPill

            Spacer(minLength: 0)

            FirasIconButton(
                symbol: "mic",
                label: Strings.CodeUI.micLabel(lang),
                palette: palette
            ) {
                startDictation()
            }
            .disabled(isSending)
            .opacity(isSending ? 0.45 : 1)

            sendButton
        }
        .frame(minHeight: 44)
    }

    /// The model pill keeps its full label under pressure — it is two or three characters wide and
    /// there is nothing to gain by shortening it.
    private var tierPill: some View {
        FirasPill(
            text: env.prefs.tier.short(lang),
            symbol: "sparkles",
            selected: false,
            palette: palette
        ) {
            Haptics.select()
            env.router.sheet = .tierPicker
        }
        .layoutPriority(1)
        .accessibilityLabel(Text(verbatim: Strings.CodeUI.contextModel(lang)))
    }

    private var repositoryPill: some View {
        FirasPill(
            text: repoLabel,
            symbol: link == nil ? "link" : "arrow.triangle.branch",
            selected: link != nil,
            palette: palette
        ) {
            Haptics.select()
            onOpenRepository()
        }
        .accessibilityLabel(Text(verbatim: Strings.Code.repoTitle(lang)))
        .accessibilityValue(Text(verbatim: link?.label ?? Strings.Code.repoNone(lang)))
    }

    private var repoLabel: String {
        guard let raw = link?.label, !raw.isEmpty else { return Strings.Code.repoNone(lang) }
        guard raw.count > Self.repoLabelLimit else { return raw }
        return String(raw.prefix(Self.repoLabelLimit - 1)) + "…"
    }

    @ViewBuilder
    private var sendButton: some View {
        if isSending {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(palette.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(verbatim: Strings.CodeUI.aiWorking(lang)))
        } else {
            FirasIconButton(
                symbol: "arrow.up",
                label: Strings.CodeUI.sendLabel(lang),
                palette: palette,
                prominent: canSend
            ) {
                send()
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)
        }
    }

    private var canSend: Bool {
        guard !isSending, !isReadingAttachments, env.code.project != nil else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: - Attachments

    /// The tray lives inside the card's 8 pt padding, which is exactly what keeps a chip clear of
    /// the 24 pt corner: at 8 pt down from the top edge the corner has already curved 6.1 pt in.
    @ViewBuilder
    private var attachmentTray: some View {
        if isReadingAttachments {
            FirasActivityLabel(
                text: Strings.CodeUI.attachReading(lang),
                palette: palette,
                motionOn: motionOn
            )
            .padding(.horizontal, 6)
            .frame(minHeight: 32)
        } else if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { pair in
                        attachmentChip(pair.element, index: pair.offset)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
        }
    }

    private func attachmentChip(_ attachment: PreparedAttachment, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.imageBase64 == nil ? "doc.text" : "photo")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(verbatim: attachment.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: Strings.CodeUI.removeAttachment(lang)))
        }
        .foregroundStyle(palette.textSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 32)
        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
    }

    private func remove(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    // MARK: - Sending

    /// A session created from the home screen holds the untouched scaffold, so the first
    /// instruction is a build, not an edit.
    private var isBlankScaffold: Bool {
        env.code.project?.files == CodeProject.blankFiles
    }

    private func send() {
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending else { return }
        guard env.code.project != nil else {
            env.toasts.show(Strings.CodeUI.needProject(lang), isError: true)
            return
        }
        guard !instruction.isEmpty || !attachments.isEmpty else { return }

        Haptics.send()
        isSending = true
        focused = false
        let staged = attachments
        let buildFirst = isBlankScaffold && !instruction.isEmpty

        Task {
            if buildFirst {
                await startBuild(instruction: instruction, staged: staged)
            } else {
                await askForEdits(instruction: instruction, staged: staged)
            }
            isSending = false
        }
    }

    private func startBuild(instruction: String, staged: [PreparedAttachment]) async {
        let id = projectID
        guard !id.isEmpty else {
            env.toasts.show(Strings.CodeUI.needProject(lang), isError: true)
            return
        }
        let attachText = CodeStore.attachmentText(staged, cap: CodeStore.attachmentCharacterCap)
        await env.code.startBuild(
            projectID: id,
            name: env.code.openProjectName,
            brief: instruction,
            attach: attachText
        )
        draft = ""
        attachments = []
    }

    private func askForEdits(instruction: String, staged: [PreparedAttachment]) async {
        let before = env.code.thread.messages.count
        let result = await env.code.askAI(instruction: instruction, attachments: staged)

        if let result, !result.isEmpty {
            Haptics.toolStep()
            onPlan(result)
        } else if result != nil {
            env.toasts.show(Strings.CodeUI.noChanges(lang))
        }

        let grew = env.code.thread.messages.count > before
        if result != nil || grew {
            draft = ""
            attachments = []
        }
    }

    // MARK: - Prefill

    private func absorbPrefill() {
        let incoming = prefill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        draft = String(incoming.prefix(Self.instructionLimit))
        prefill = ""
        focused = true
    }

    // MARK: - Dictation

    /// The bar goes up optimistically, so a microphone that never opened has to take it back
    /// down: `start` answers `false` for a refusal it did not turn into a `.failed` state (a take
    /// that is already running), and the `.failed` observer alone would leave the bar up forever.
    private func startDictation() {
        guard !dictating else {
            finishDictation()
            return
        }
        dictating = true
        focused = false
        Task {
            /* `start(into:)` rather than `start()`: the recogniser writes into this field as the
               words are spoken and replaces its own run as it refines them, which is what every
               other composer in the app now does. `finish()` returns nil for a live take — the
               text is already here — so the append in `finishDictation` correctly does nothing. */
            let opened = await env.dictation.start(into: $draft)
            if !opened { dictating = false }
        }
    }

    private func finishDictation() {
        Task {
            let transcript = await env.dictation.finish()
            dictating = false
            if let transcript {
                draft = DictationController.appending(transcript, to: draft)
            }
            focused = true
        }
    }

    private func cancelDictation() {
        Task {
            await env.dictation.cancel()
            dictating = false
        }
    }

    // MARK: - Attachment import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isReadingAttachments = true
        Task {
            var prepared: [PreparedAttachment] = []
            var remaining = CodeStore.attachmentCharacterCap
            var failure: String?

            for url in urls.prefix(ChatAttachmentProcessor.maxFiles) {
                do {
                    let imported = try await ChatAttachmentProcessor.file(
                        url: url,
                        remainingCharacters: max(0, remaining)
                    )
                    remaining -= imported.attachment.text?.count ?? 0
                    prepared.append(imported.attachment)
                } catch let error as ChatAttachmentError {
                    failure = error.message(lang)
                } catch {
                    failure = Strings.CodeUI.attachUnsupported(lang)
                }
            }

            attachments.append(contentsOf: prepared)
            isReadingAttachments = false
            if !prepared.isEmpty { Haptics.attach() }
            if let failure { env.toasts.show(failure, isError: true) }
        }
    }
}
