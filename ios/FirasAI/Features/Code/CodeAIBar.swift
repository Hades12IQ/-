import Foundation
import SwiftUI

/// The AI pane: the project thread on top, the command bar underneath
/// (`web-code-ux.md §6.1`, `design-brief.md §7.9`).
///
/// An edit answer opens the diff review; a question is answered into the thread by the store. The
/// bar never applies anything on its own.
struct CodeAIBar: View {

    private static let instructionLimit = 1_200

    private let env: AppEnvironment
    private let onPlan: ((CodeEditPlan) -> Void)?
    @Binding private var prefill: String
    @Binding private var attachments: [PreparedAttachment]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft: String = ""
    @State private var isSending = false
    @State private var sendStartedAt: Date?
    @State private var plan: CodeEditPlan?
    @State private var showsDiff = false
    @FocusState private var focused: Bool

    /// Both bindings are optional at the call site: `CodeAIBar(env: env)` is a complete pane. The
    /// workspace passes `prefill` so the console's "fix it with AI" can hand over its error buffer,
    /// and `attachments` when it has staged files through `ChatAttachmentProcessor`.
    init(
        env: AppEnvironment,
        prefill: Binding<String> = .constant(""),
        attachments: Binding<[PreparedAttachment]> = .constant([]),
        onPlan: ((CodeEditPlan) -> Void)? = nil
    ) {
        self.env = env
        self.onPlan = onPlan
        self._prefill = prefill
        self._attachments = attachments
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var turns: [CodeChatMessage] { env.code.thread.messages }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        VStack(spacing: 0) {
            thread
            mentionRow
            attachmentTray
            composer
        }
        .background(palette.background)
        .onAppear { absorbPrefill() }
        .onChange(of: prefill) { _, _ in absorbPrefill() }
        .onChange(of: draft) { _, newValue in
            if newValue.count > Self.instructionLimit {
                draft = String(newValue.prefix(Self.instructionLimit))
            }
        }
        .sheet(isPresented: $showsDiff) {
            if let plan {
                DiffReviewSheet(env: env, plan: plan)
            }
        }
    }

    // MARK: - Thread

    @ViewBuilder
    private var thread: some View {
        if turns.isEmpty && !isSending {
            emptyThread
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { pair in
                        turnRow(pair.element)
                    }
                    if isSending { pendingRow }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyThread: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                title: Strings.CodeUI.assistantTab(lang),
                subtitle: Strings.CodeUI.threadEmpty(lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
            FirasPill(
                text: Strings.CodeUI.threadExplain(lang),
                symbol: "questionmark.circle",
                selected: false,
                palette: palette
            ) {
                draft = Strings.CodeUI.threadExplain(lang)
                send()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func turnRow(_ turn: CodeChatMessage) -> some View {
        let isUser = turn.role == "user"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: isUser ? Strings.CodeUI.youLabel(lang) : Strings.CodeUI.firasLabel(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUser ? palette.textSecondary : palette.accent)
                if let changed = turn.n, changed > 0 {
                    Text(verbatim: Strings.CodeUI.fileCount(changed, lang))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                }
            }

            Text(verbatim: turn.content)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: turn.content, fallback: lang)

            if isUser { mentionChips(in: turn.content) }
        }
        .padding(12)
        .surfaceCard(palette, radius: 9)
    }

    @ViewBuilder
    private func mentionChips(in text: String) -> some View {
        let files = env.code.project?.files ?? []
        let tokens = Self.mentionTokens(in: text)
        if !tokens.isEmpty {
            HStack(spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    let known = CodeAskAI.matchPath(token, in: files) != nil
                    Text(verbatim: token)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(known ? palette.accent : palette.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background {
                            Capsule(style: .continuous)
                                .fill(known ? palette.accentSoft : palette.surfaceSunken)
                        }
                        .forceLTR()
                        .accessibilityLabel(
                            Text(verbatim: known ? token : token + " — " + Strings.CodeUI.noFileMatches(lang))
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var pendingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FirasActivityLabel(
                text: Strings.CodeUI.aiWorking(lang),
                palette: palette,
                motionOn: motionOn
            )
            if let started = sendStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(verbatim: Strings.CodeUI.aiWorkingFor.fmt(lang, ArabicText.count(seconds, lang)))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette, radius: 9)
    }

    // MARK: - Mentions

    @ViewBuilder
    private var mentionRow: some View {
        if let token = mentionToken, let project = env.code.project {
            let matches = CodeAskAI.suggestions(for: token, files: project.files)
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches, id: \.self) { path in
                            Button {
                                insertMention(path)
                            } label: {
                                Text(verbatim: path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(palette.textPrimary)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 32)
                                    .background {
                                        Capsule(style: .continuous).fill(palette.surfaceSunken)
                                    }
                                    .forceLTR()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .accessibilityLabel(Text(verbatim: Strings.CodeUI.mentionFiles(lang)))
            }
        }
    }

    private var mentionToken: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let token = draft[draft.index(after: at)...]
        guard !token.contains(" "), !token.contains("\n") else { return nil }
        return String(token)
    }

    private func insertMention(_ path: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + path + " "
        Haptics.select()
    }

    static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        for piece in text.components(separatedBy: .whitespacesAndNewlines) where piece.hasPrefix("@") {
            let token = String(piece.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
            if !token.isEmpty, !tokens.contains(token) { tokens.append(token) }
        }
        return tokens
    }

    // MARK: - Attachments

    @ViewBuilder
    private var attachmentTray: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { pair in
                        HStack(spacing: 6) {
                            Image(systemName: pair.element.imageBase64 == nil ? "doc.text" : "photo")
                                .font(.system(size: 11))
                                .accessibilityHidden(true)
                            Text(verbatim: pair.element.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Button {
                                remove(at: pair.offset)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: Strings.CodeUI.removeAttachment(lang)))
                        }
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
    }

    private func remove(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                text: $draft,
                prompt: Text(verbatim: Strings.CodeUI.aiPlaceholder(lang)),
                axis: .vertical
            ) {
                Text(verbatim: Strings.CodeUI.aiPlaceholder(lang))
            }
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(.system(size: 16))
            .foregroundStyle(palette.textPrimary)
            .focused($focused)
            .disabled(isSending)
            .bidiIsland(for: draft, fallback: lang)

            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .firasGlass(
            .floating,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
                label: Strings.CodeUI.aiRun(lang),
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
        guard !isSending, env.code.project != nil else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: - Sending

    private func absorbPrefill() {
        let incoming = prefill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        draft = String(incoming.prefix(Self.instructionLimit))
        prefill = ""
        focused = true
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
        sendStartedAt = Date()
        focused = false
        let staged = attachments

        Task {
            let before = env.code.thread.messages.count
            let result = await env.code.askAI(instruction: instruction, attachments: staged)
            isSending = false
            sendStartedAt = nil

            if let result, !result.isEmpty {
                Haptics.toolStep()
                if let onPlan {
                    onPlan(result)
                } else {
                    plan = result
                    showsDiff = true
                }
            } else if result != nil {
                env.toasts.show(Strings.CodeUI.noChanges(lang))
            }

            let grew = env.code.thread.messages.count > before
            if result != nil || grew {
                draft = ""
                attachments = []
            }
        }
    }
}
