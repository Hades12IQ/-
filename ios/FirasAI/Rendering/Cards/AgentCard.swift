import SwiftUI

/// The ```` ```firas-agent ```` summary card inside a transcript (`web-agent-ux.md §6.3, §7`).
///
/// The full mission — plan, timeline, tools, files, report — lives on the mission screen. In a chat
/// row this is a compact, tappable summary: title, live status, `done / total` steps, the number of
/// files the run produced, and the elapsed clock. A refused or failed run shows the sentence the
/// error code maps to, and offers Resume exactly when the web does.
struct AgentCard: View {

    private let job: AgentJob
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let onOpen: (() -> Void)?
    private let onResume: (() -> Void)?

    init(
        job: AgentJob,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool = true,
        onOpen: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil
    ) {
        self.job = job
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.onOpen = onOpen
        self.onResume = onResume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if let text = errorSentence {
                errorLine(text)
            }
            if showsResume, let onResume {
                resumeButton(onResume)
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: title, fallback: lang)

                statusRow
                statsRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if onOpen != nil {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    private var glyph: some View {
        Image(systemName: "wand.and.rays")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(palette.accent)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accentSoft)
            )
            .accessibilityHidden(true)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if isLive {
                LiveDot(palette: palette, motionOn: motionOn)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat(symbol: "checklist", text: stepsText)
            if fileCount > 0 {
                stat(symbol: "doc", text: filesText)
            }
            if let elapsed = elapsedText {
                stat(symbol: "clock", text: elapsed, latin: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func stat(symbol: String, text: String, latin: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(FirasType.caption)
                .lineLimit(1)
        }
        .foregroundStyle(palette.textMuted)
        .modifier(AgentCardLatinRun(enabled: latin))
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .font(FirasType.caption)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: text, fallback: lang)
    }

    private func resumeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(AgentCardCopy.resume(lang))
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(Capsule().fill(palette.accent))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AgentCardCopy.resume(lang)))
    }

    // MARK: - Derived

    private var title: String {
        if !job.title.isEmpty { return String(job.title.prefix(160)) }
        let task = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty { return String(task.prefix(120)) }
        return AgentCardCopy.untitled(lang)
    }

    private var isLive: Bool { job.phase == .run || job.phase == .queued }

    private var statusText: String {
        if !job.error.isEmpty { return AgentCardCopy.blocked(lang) }
        switch job.phase {
        case .queued: return AgentCardCopy.queued(lang)
        case .run: return AgentCardCopy.running(lang)
        case .done: return AgentCardCopy.done(lang)
        case .fail: return AgentCardCopy.failed(lang)
        }
    }

    private var statusColor: Color {
        if !job.error.isEmpty { return palette.error }
        switch job.phase {
        case .queued, .run: return palette.accent
        case .done: return palette.success
        case .fail: return palette.error
        }
    }

    private var stepsText: String {
        AgentCardCopy.steps.fmt(
            lang,
            ArabicText.count(job.doneStepCount, lang),
            ArabicText.count(job.steps.count, lang)
        )
    }

    private var fileCount: Int { job.surface?.files.count ?? 0 }

    private var filesText: String {
        ArabicPlurals.count(
            fileCount,
            lang,
            zero: AgentCardCopy.filesZero,
            one: AgentCardCopy.filesOne,
            two: AgentCardCopy.filesTwo,
            few: AgentCardCopy.filesFew,
            many: AgentCardCopy.filesMany,
            other: AgentCardCopy.filesOther
        )
    }

    private var elapsedText: String? {
        guard let milliseconds = job.elapsedMilliseconds, milliseconds >= 1_000 else { return nil }
        return ArabicText.timer(Int(milliseconds / 1_000))
    }

    /// `server-agent.md §11.2` / `ARCHITECTURE.md §2.15` — the sentence comes from the code, never
    /// from the server's own `final` text.
    private var errorSentence: String? {
        let code = job.error.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        switch code {
        case "agent_busy":
            return Strings.Errors.agentBusy(lang)
        case "credits_exhausted":
            return Strings.Errors.agentCreditsSpent(lang)
        case "credits_reserved":
            return Strings.Errors.agentCreditsReserved(lang)
        case "account_required", "signin_required":
            return Strings.Errors.agentSignIn(lang)
        default:
            return Strings.Errors.agentFailed(lang)
        }
    }

    /// The web shows Resume for a stopped or failed run that still has unfinished steps, and never
    /// while the failure is a credit or busy block (`web-agent-ux.md §7`, item 4).
    private var showsResume: Bool {
        guard job.phase == .fail else { return false }
        let code = job.error.trimmingCharacters(in: .whitespaces).lowercased()
        let blocked = code == "agent_busy" || code == "credits_reserved" || code == "credits_exhausted"
        guard !blocked else { return false }
        if job.steps.isEmpty { return true }
        return job.steps.contains { $0.s != .done }
    }
}

/// Timers and ids stay Latin and left-to-right even inside an Arabic row.
private struct AgentCardLatinRun: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.forceLTR()
        } else {
            content
        }
    }
}

// MARK: - Copy

/// `web-agent-ux.md §7` (Resume) plus the phase words the mission rail uses.
private enum AgentCardCopy {
    static let untitled = LText(ar: "مهمة فِراس Agent", en: "Firas Agent task")
    static let queued = LText(ar: "في الانتظار", en: "Queued")
    static let running = LText(ar: "ما زالت تشتغل", en: "still working")
    static let done = LText(ar: "اكتملت", en: "Done")
    static let failed = LText(ar: "تعثّرت", en: "Failed")
    static let blocked = LText(ar: "لم تبدأ", en: "Not started")
    static let resume = LText(ar: "استئناف المهمة", en: "Resume task")

    /// `%@ / %@` — done over total, already in the UI's digits.
    static let steps = LText(ar: "الخطوات: %@ / %@", en: "Steps: %@ / %@")

    static let filesZero = LText(ar: "بلا ملفات", en: "%ld files")
    static let filesOne = LText(ar: "ملف واحد", en: "%ld file")
    static let filesTwo = LText(ar: "ملفان", en: "%ld files")
    static let filesFew = LText(ar: "%ld ملفات", en: "%ld files")
    static let filesMany = LText(ar: "%ld ملفًا", en: "%ld files")
    static let filesOther = LText(ar: "%ld ملف", en: "%ld files")
}
