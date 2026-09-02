import Foundation
import SwiftUI

// The four panes `CodeWorkspaceView` asks for by name. They are thin: every behaviour lives in
// `PreviewWebView`, `ConsoleView`, `CodeAIBar` and `DiffReviewSheet`; these types only fix the
// spelling the workspace calls them by, and keep the workspace in charge of what it already owns
// (the preview reload token, the fix-with-AI hand-off, and where the diff review is presented).

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
