import Foundation
import SwiftUI

// The panes `CodeWorkspaceView` asks for by name. They are thin: every behaviour lives in
// `PreviewWebView`, `ConsoleView`, `CodeAIBar` and `DiffReviewSheet`; these types only fix the
// spelling the workspace calls them by, and keep the workspace in charge of what it already owns
// (the preview reload token, the fix-with-AI hand-off, and where the diff review is presented).
//
// Round 2 added the session conversation here; its composer is its own file
// (`CodeSessionComposer.swift`). Round 3 gives the thread the same rhythm the composer now has —
// one 8 pt gutter, text that follows the reader's font size, and nothing that can grow wider than
// the card it is printed on.

/// The preview pane. `reloadToken` is bumped by the workspace after a save or an applied edit.
struct CodeWorkspacePreview: View {
    private let env: AppEnvironment
    private let reloadToken: Int

    init(env: AppEnvironment, reloadToken: Int) {
        self.env = env
        self.reloadToken = reloadToken
    }

    var body: some View {
        PreviewWebView(env: env, reloadToken: reloadToken)
    }
}

/// The console pane. `onFix` receives the deduplicated error lines only — the caller puts its own
/// instruction sentence in front of them.
struct CodeWorkspaceConsole: View {
    private let env: AppEnvironment
    private let onFix: (String) -> Void

    init(env: AppEnvironment, onFix: @escaping (String) -> Void) {
        self.env = env
        self.onFix = onFix
    }

    var body: some View {
        ConsoleView(env: env, onFix: onFix)
    }
}

/// The AI pane. The plan is handed back instead of being presented here, so the workspace can put
/// the review in a sheet on iPhone and an inspector on iPad.
struct CodeWorkspaceAssistant: View {
    private let env: AppEnvironment
    @Binding private var prefill: String
    private let onPlan: (CodeEditPlan) -> Void

    init(env: AppEnvironment, prefill: Binding<String>, onPlan: @escaping (CodeEditPlan) -> Void) {
        self.env = env
        self._prefill = prefill
        self.onPlan = onPlan
    }

    var body: some View {
        CodeAIBar(env: env, prefill: $prefill, onPlan: onPlan)
    }
}

/// The diff review, presented by the workspace.
struct CodeWorkspaceDiffReview: View {
    private let env: AppEnvironment
    private let plan: CodeEditPlan
    private let onClose: () -> Void

    init(env: AppEnvironment, plan: CodeEditPlan, onClose: @escaping () -> Void) {
        self.env = env
        self.plan = plan
        self.onClose = onClose
    }

    var body: some View {
        DiffReviewSheet(env: env, plan: plan, onClose: onClose)
    }
}

// MARK: - Session conversation

/// What a session shows before anything else: the turns, or one calm question.
///
/// Deliberately quiet — no card, no illustration, no button. A reader who just tapped «جلسة جديدة»
/// should see a question and a composer, and nothing that needs deciding first.
struct CodeSessionThread: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var scale: FontScale { env.prefs.fontScale }
    private var turns: [CodeChatMessage] { env.code.thread.messages }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        if turns.isEmpty && !env.code.isAsking {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { pair in
                        turnRow(pair.element)
                    }
                    if env.code.isAsking { pendingRow }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                /* The composer floats over the bottom of this scroll view, so the last turn needs
                   more than the top gutter under it or it reads as clipped by the glass. */
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dismissesKeyboardOnTap()
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(verbatim: Strings.CodeUI.sessionEmptyTitle(lang))
                .font(FirasType.scaled(22, scale: scale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: Strings.CodeUI.sessionEmptyBody(lang))
                .font(FirasType.scaled(15, scale: scale))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Turns

    private func turnRow(_ turn: CodeChatMessage) -> some View {
        let isUser = turn.role == "user"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: isUser ? Strings.CodeUI.youLabel(lang) : Strings.CodeUI.firasLabel(lang))
                    .font(FirasType.scaled(12, scale: scale, weight: .semibold))
                    .foregroundStyle(isUser ? palette.textSecondary : palette.accent)
                    .lineLimit(1)
                    .fixedSize()
                if let changed = turn.n, changed > 0 {
                    Text(verbatim: Strings.CodeUI.fileCount(changed, lang))
                        .font(FirasType.scaled(11, scale: scale, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                }
                Spacer(minLength: 0)
            }

            /* AN ANSWER IS MARKDOWN, and this drew it as verbatim text.
               Firas Code answers the way Firas answers: headings, bold, lists, inline code, file
               names, fenced listings. Printed verbatim, every one of those markers is on screen
               as itself — the reader sees `**bot.js**` and backticks instead of a bold file name
               — and the whole answer takes ONE direction, so an Arabic explanation full of Latin
               file names comes apart: dashes on the wrong side, names scattered through the line.
               `MarkdownView` is the renderer the transcript uses. It gives the answer its
               structure back, and it decides direction per block, so an Arabic sentence stays
               Arabic and `render.yaml` stays left to right inside it.
               A question stays verbatim below: it is what the reader typed, and rendering their
               own asterisks as formatting would be putting words in their mouth. */
            if isUser {
                Text(verbatim: turn.content)
                    .font(FirasType.scaled(15, scale: scale))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: turn.content, fallback: lang)
            } else {
                MarkdownView(
                    markdown: turn.content,
                    messageID: "code-" + String(turn.content.hashValue),
                    streaming: false,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    onFence: { _ in nil }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    private var pendingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FirasActivityLabel(
                text: Strings.CodeUI.aiWorking(lang),
                palette: palette,
                motionOn: motionOn
            )
            if let started = env.code.askStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(verbatim: Strings.CodeUI.aiWorkingFor.fmt(lang, ArabicText.count(seconds, lang)))
                        .font(FirasType.scaled(12, scale: scale))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }
}
