import SwiftUI

/// The pieces of `MissionCard`: identity header with the elapsed clock, one plan step, the footer
/// actions, and the credits chip that rides along with a blocked state.

// MARK: - Header

struct MissionCardHeader: View {

    let phase: MissionDisplayPhase
    let job: AgentJob?
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            FirasBrandMark(size: 22, showsWordmark: false, palette: palette)
                .accessibilityHidden(true)
            Text(Strings.Agent.name(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            statusPill
            Spacer(minLength: 8)
            clock
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if phase.isLive {
                LiveDot(palette: palette, motionOn: motionOn)
            }
            Text(phase.label(lang))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(pillForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background { Capsule(style: .continuous).fill(pillBackground) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(phase.label(lang)))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var pillForeground: Color {
        switch phase {
        case .done: return palette.success
        case .failed, .credits: return palette.error
        case .blocked, .stopped: return palette.textSecondary
        case .queued, .running: return palette.accent
        }
    }

    private var pillBackground: Color {
        switch phase {
        case .done: return palette.success.opacity(0.12)
        case .failed, .credits: return palette.error.opacity(0.12)
        case .blocked, .stopped: return palette.surfaceSunken
        case .queued, .running: return palette.accentSoft
        }
    }

    @ViewBuilder
    private var clock: some View {
        if let startedAt = job?.surface?.startedAt, startedAt > 0 {
            let endedAt = job?.surface?.endedAt ?? 0
            if endedAt > 0 {
                clockLabel(seconds: Int(max(0, endedAt - startedAt) / 1000))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = context.date.timeIntervalSince1970 * 1000
                    clockLabel(seconds: Int(max(0, now - startedAt) / 1000))
                }
            }
        }
    }

    private func clockLabel(seconds: Int) -> some View {
        Text(ArabicText.timer(seconds))
            .font(.system(size: 12, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.textMuted)
            .forceLTR()
            .accessibilityLabel(Text(Strings.Agent.elapsedLabel(lang)))
    }
}

// MARK: - Step row

struct MissionStepRow: View {

    let index: Int
    let step: AgentStep
    let events: [AgentEvent]
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            detailBody(for: step)
                .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(metaWord)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
        }
        .tint(palette.accent)
        .onAppear { if step.s == .run { expanded = true } }
    }

    private var glyph: String {
        switch step.s {
        case .todo: return "circle"
        case .run: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .fail: return "xmark.circle"
        }
    }

    private var glyphColor: Color {
        switch step.s {
        case .todo: return palette.textMuted
        case .run: return palette.accent
        case .done: return palette.success
        case .fail: return palette.error
        }
    }

    private var metaWord: String {
        if !events.isEmpty {
            return Strings.Agent.eventsCount.fmt(lang, ArabicText.count(events.count, lang))
        }
        switch step.s {
        case .run: return Strings.Agent.running(lang)
        case .done: return Strings.Agent.completed(lang)
        case .fail: return Strings.Agent.failedShort(lang)
        case .todo: return Strings.Agent.waiting(lang)
        }
    }

    @ViewBuilder
    private func detailBody(for step: AgentStep) -> some View {
        let output = (step.out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.Agent.stepOutput(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
                Text(output)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: output, fallback: lang)
            }
        } else if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events.suffix(8)) { event in
                    Text(event.text.isEmpty ? event.arg : event.text)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(step.s == .run ? Strings.Agent.stepNow(lang) : Strings.Agent.stepLater(lang))
                .font(.system(size: 13))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Footer

struct MissionCardFooter: View {

    let env: AppEnvironment
    let conversationID: String
    let phase: MissionDisplayPhase
    let job: AgentJob?
    let blocked: ErrorAction?
    let exportText: String

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    @ViewBuilder
    var body: some View {
        if showsResume || showsOpenRunning || !exportText.isEmpty {
            HStack(spacing: 10) {
                if showsResume {
                    Button {
                        Task { await env.agent.resume(in: conversationID) }
                    } label: {
                        footerLabel(Strings.Agent.resume(lang), filled: true)
                    }
                    .buttonStyle(.plain)
                }
                if showsOpenRunning {
                    Button(action: openRunning) {
                        footerLabel(Strings.Agent.openRunning(lang), filled: false)
                    }
                    .buttonStyle(.plain)
                }
                if !exportText.isEmpty {
                    ShareLink(item: exportText) {
                        footerLabel(Strings.Agent.exportMarkdown(lang), filled: false)
                    }
                    .accessibilityHint(Text(Strings.Agent.exportMarkdownHint(lang)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var showsResume: Bool {
        guard blocked == nil else { return false }
        guard phase == .failed || phase == .stopped else { return false }
        guard let job else { return true }
        if job.steps.isEmpty { return true }
        return job.steps.contains { $0.s != .done }
    }

    private var activeJob: AgentActiveJob? {
        guard let blocked else { return nil }
        if case .blockedAgent(let job, _) = blocked { return job }
        return nil
    }

    private var showsOpenRunning: Bool {
        !(activeJob?.chatId ?? "").isEmpty
    }

    private func openRunning() {
        guard let serverChatID = activeJob?.chatId, !serverChatID.isEmpty else { return }
        let local = env.chat.conversations.first(where: { $0.value.serverID == serverChatID })?.key
        if let local {
            env.router.select(conversationID: local, product: .agent)
        } else {
            env.toasts.show(Strings.Agent.refreshListToFind(lang), isError: true)
        }
    }

    private func footerLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(filled ? palette.onAccent : palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(filled ? palette.accent : palette.accentSoft)
            }
            .contentShape(Capsule(style: .continuous))
    }
}

// MARK: - Credits chip inside the card

struct MissionCreditsChipLabel: View {

    let credits: AgentCredits
    let palette: FirasPalette
    let lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(ArabicText.count(Int(credits.remaining.rounded()), lang) + " " + Strings.Agent.creditsChip(lang))
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background { Capsule(style: .continuous).fill(palette.surface) }
        .overlay { Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
    }
}
