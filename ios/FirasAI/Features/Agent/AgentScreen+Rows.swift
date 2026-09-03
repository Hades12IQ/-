import SwiftUI

/// The transcript rows of `AgentScreen`, the toolbar credits chip and the welcome templates.

// MARK: - Rows

/// One transcript row. The identity is the message id so a re-render never rebuilds the list.
struct AgentRow: Identifiable {

    enum Kind {
        case user(String)
        case answer(String)
        case mission(AgentJob)
    }

    let id: String
    let kind: Kind

    @MainActor @ViewBuilder
    func view(env: AppEnvironment, conversationID: String) -> some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        switch kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.userInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: text, fallback: lang)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20,
                            bottomLeadingRadius: 20,
                            bottomTrailingRadius: 7,
                            topTrailingRadius: 20,
                            style: .continuous
                        )
                        .fill(palette.userFill)
                    }
            }
        case .answer(let text):
            MarkdownView(
                markdown: text,
                messageID: id,
                streaming: false,
                lang: lang,
                palette: palette,
                prefs: env.prefs,
                background: palette.surface,
                onFence: { _ in nil }
            )
        case .mission(let job):
            MissionCard(env: env, conversationID: conversationID, job: job, blocked: nil, stopped: false)
        }
    }
}

// MARK: - Credits chip

struct AgentCreditsChip: View {

    let credits: AgentCredits
    let palette: FirasPalette
    let lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
            Text(caption)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(credits.held > 0 ? palette.accent : palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
        .overlay { Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
    }

    private var value: String {
        let amount = credits.locked ? credits.allowance : credits.remaining
        return ArabicText.count(Int(amount.rounded()), lang)
    }

    private var caption: String {
        if credits.locked { return Strings.Agent.creditsLockedChip(lang) }
        if credits.held > 0 { return Strings.Agent.creditsHeldChip(lang) }
        return Strings.Agent.creditsChip(lang)
    }
}

// MARK: - Templates

/// Starter missions shown on the welcome screen; tapping one fills the draft, it never sends.
struct AgentTemplate: Identifiable, Sendable {

    let id: String
    let symbol: String
    let label: LText
    let task: LText

    static let all: [AgentTemplate] = [
        AgentTemplate(
            id: "research",
            symbol: "magnifyingglass",
            label: Strings.Agent.templateResearchLabel,
            task: Strings.Agent.templateResearchTask
        ),
        AgentTemplate(
            id: "deck",
            symbol: "rectangle.on.rectangle",
            label: Strings.Agent.templateDeckLabel,
            task: Strings.Agent.templateDeckTask
        ),
        AgentTemplate(
            id: "analysis",
            symbol: "tablecells",
            label: Strings.Agent.templateAnalysisLabel,
            task: Strings.Agent.templateAnalysisTask
        ),
        AgentTemplate(
            id: "compare",
            symbol: "arrow.left.arrow.right",
            label: Strings.Agent.templateCompareLabel,
            task: Strings.Agent.templateCompareTask
        )
    ]
}
