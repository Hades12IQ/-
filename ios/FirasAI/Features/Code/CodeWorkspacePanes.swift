import Foundation
import SwiftUI

// The panes `CodeWorkspaceView` asks for by name. They are thin: every behaviour lives in
// `PreviewWebView`, `ConsoleView`, `CodeAIBar` and `DiffReviewSheet`; these types only fix the
// spelling the workspace calls them by, and keep the workspace in charge of what it already owns
// (the preview reload token, the fix-with-AI hand-off, and where the diff review is presented).
//
// Round 2 adds the session conversation here; its composer is its own file
// (`CodeSessionComposer.swift`).

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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(Strings.CodeUI.sessionEmptyTitle(lang))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(Strings.CodeUI.sessionEmptyBody(lang))
                .font(.system(size: 15))
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
                Spacer(minLength: 0)
            }

            Text(verbatim: turn.content)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: turn.content, fallback: lang)
        }
        .padding(12)
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
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }
}

