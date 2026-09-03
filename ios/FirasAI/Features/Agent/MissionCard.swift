import SwiftUI

/// What the card is drawing right now. `blocked`, `credits` and `stopped` are **client-derived**:
/// the server never sends them (`web-agent-ux.md §6.2`, `server-agent.md §11.1`).
enum MissionDisplayPhase: Equatable, Sendable {
    case queued
    case running
    case done
    case failed
    case blocked
    case credits
    case stopped

    var isLive: Bool { self == .queued || self == .running }

    var label: LText {
        switch self {
        case .queued: return Strings.Agent.statusPlanning
        case .running: return Strings.Agent.statusWorking
        case .done: return Strings.Agent.statusDone
        case .failed: return Strings.Agent.statusFailed
        case .blocked: return Strings.Agent.statusBlocked
        case .credits: return Strings.Agent.statusCredits
        case .stopped: return Strings.Agent.statusStopped
        }
    }
}

/// The living mission card: header, speech line, plan, activity, files, deliverable, footer.
///
/// It never shortens itself on an older snapshot — `AgentStore` already refuses to adopt one — and
/// it offers no Stop, because a server mission cannot be stopped (`web-agent-ux.md §12`).
struct MissionCard: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let job: AgentJob?
    private let blocked: ErrorAction?
    private let stopped: Bool

    @State private var planExpanded = true
    @State private var exportText = ""
    @State private var artifact: MissionArtifactRequest?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, conversationID: String, job: AgentJob?, blocked: ErrorAction?, stopped: Bool) {
        self.env = env
        self.conversationID = conversationID
        self.job = job
        self.blocked = blocked
        self.stopped = stopped
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var phase: MissionDisplayPhase {
        if let blocked {
            switch blocked {
            case .blockedAgent: return .blocked
            case .creditsBlocked: return .credits
            default: break
            }
        }
        guard let job else { return stopped ? .stopped : .queued }
        switch job.phase {
        case .done: return .done
        case .fail: return .failed
        case .queued: return stopped ? .stopped : .queued
        case .run: return stopped ? .stopped : .running
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MissionCardHeader(phase: phase, job: job, palette: palette, lang: lang, motionOn: motionOn)
            speech
            blockedSentence
            planSection
            activitySection
            filesSection
            resultSection
            MissionCardFooter(
                env: env,
                conversationID: conversationID,
                phase: phase,
                job: job,
                blocked: blocked,
                exportText: exportText
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent.opacity(phase.isLive ? 0.6 : 0.85))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .task(id: exportSignature) { rebuildExport() }
        .onChange(of: doneStepCount) { _, _ in
            if phase.isLive { Haptics.toolStep() }
        }
        .sheet(item: $artifact) { request in
            ArtifactViewer(env: env, jobID: request.jobID, index: request.index, name: request.name, type: request.type)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(palette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.accent.opacity(0.04))
            }
    }

    // MARK: - Speech

    @ViewBuilder
    private var speech: some View {
        let line = (job?.surface?.says.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (job?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = line.isEmpty ? title : line
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 15, weight: line.isEmpty ? .semibold : .regular))
                .foregroundStyle(line.isEmpty ? palette.textPrimary : palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: text, fallback: lang)
                .transition(FirasMotion.revealTransition)
                .animation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn), value: text)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: - Blocked / credits

    @ViewBuilder
    private var blockedSentence: some View {
        if let sentence = blockedText {
            VStack(alignment: .leading, spacing: 10) {
                Text(sentence)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: sentence, fallback: lang)
                if let credits = blockedCredits {
                    MissionCreditsChipLabel(credits: credits, palette: palette, lang: lang)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
            }
        }
    }

    private var blockedText: String? {
        if let blocked {
            switch blocked {
            case .blockedAgent(_, let credits):
                let held = credits?.held ?? 0
                return held > 0 && (job?.error ?? "") == "credits_reserved"
                    ? Strings.Errors.agentCreditsReserved(lang)
                    : Strings.Errors.agentBusy(lang)
            case .creditsBlocked:
                return Strings.Errors.agentCreditsSpent(lang)
            case .signUpPrompt:
                return Strings.Errors.agentSignIn(lang)
            case .hideFeature:
                return Strings.Errors.featureUnavailable(lang)
            default:
                break
            }
        }
        if phase == .failed, let job, !job.error.isEmpty {
            return job.error == "task_unavailable"
                ? Strings.Agent.unavailableFinal(lang)
                : Strings.Errors.agentFailed(lang)
        }
        return nil
    }

    private var blockedCredits: AgentCredits? {
        guard let blocked else { return nil }
        switch blocked {
        case .blockedAgent(_, let credits): return credits ?? env.agent.credits
        case .creditsBlocked(let credits): return credits ?? env.agent.credits
        default: return nil
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planSection: some View {
        if let job, showsPlan(job) {
            DisclosureGroup(isExpanded: $planExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(job.steps.indices, id: \.self) { index in
                        MissionStepRow(
                            index: index,
                            step: job.steps[index],
                            events: bucketedEvents(job: job, step: index),
                            palette: palette,
                            lang: lang,
                            motionOn: motionOn
                        )
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(Strings.Agent.planGroup(lang))
                        .font(FirasType.label)
                        .foregroundStyle(palette.textPrimary)
                    Text(ArabicText.count(job.doneStepCount, lang) + " / " + ArabicText.count(job.steps.count, lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .forceLTR()
                }
            }
            .tint(palette.accent)
        }
    }

    /// Manus's boot plan is not a real step (`server-agent.md §11.1`).
    private func showsPlan(_ job: AgentJob) -> Bool {
        guard !job.steps.isEmpty else { return false }
        guard job.steps.count == 1 else { return true }
        let boot = ["بدء المهمة وتجهيز الخطة", "starting the task and preparing the plan"]
        let title = job.steps[0].title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard boot.contains(title) else { return true }
        let surface = job.surface
        let empty = (surface?.events.isEmpty ?? true)
            && (surface?.tools.isEmpty ?? true)
            && (surface?.says.isEmpty ?? true)
            && (surface?.files.isEmpty ?? true)
            && (surface?.live.isEmpty ?? true)
        return !empty
    }

    private func bucketedEvents(job: AgentJob, step: Int) -> [AgentEvent] {
        (job.surface?.events ?? []).filter { $0.step == step }
    }

    // MARK: - Activity, files, result

    @ViewBuilder
    private var activitySection: some View {
        if let job, blocked == nil {
            MissionTimeline(job: job, palette: palette, lang: lang, motionOn: motionOn)
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        if let job, blocked == nil, !(job.surface?.files.isEmpty ?? true) {
            MissionFiles(env: env, job: job) { request in
                artifact = request
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let job, !job.final.isEmpty, job.presentation == .task {
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.Agent.resultGroup(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.textPrimary)
                MarkdownView(
                    markdown: job.final,
                    messageID: "agent-final-" + job.id,
                    streaming: false,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    background: palette.surface,
                    onFence: { _ in nil }
                )
                .environment(\.openURL, OpenURLAction { url in
                    handleResultLink(url, job: job)
                })
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
            }
        }
    }

    /// A link that equals one of `surface.files[].url` opens the in-app viewer, never Safari.
    ///
    /// The address comes from `MissionFiles.request(for:in:)` and from nowhere else: a second
    /// hand-rolled copy of it here is how the list and the deliverable's own links start
    /// disagreeing about which artifact a name points at. A file the helper cannot address has no
    /// bytes we can fetch, so that link falls through to the system.
    private func handleResultLink(_ url: URL, job: AgentJob) -> OpenURLAction.Result {
        let target = url.absoluteString
        for file in job.surface?.files ?? [] where file.url == target || target.hasSuffix(file.url) {
            guard let request = MissionFiles.request(for: file, in: job) else { continue }
            artifact = request
            return .handled
        }
        return .systemAction
    }

    // MARK: - Export

    private var doneStepCount: Int { job?.doneStepCount ?? 0 }

    private var exportSignature: String {
        guard let job else { return "" }
        return job.id + "#" + String(job.steps.count) + "#" + String(job.final.count) + "#" + job.phase.rawValue
    }

    private func rebuildExport() {
        guard let job, job.phase.isTerminal || stopped else {
            exportText = ""
            return
        }
        let hasOutput = !job.final.isEmpty || job.steps.contains { !($0.out ?? "").isEmpty }
        guard hasOutput, job.error.isEmpty else {
            exportText = ""
            return
        }
        exportText = AgentStore.markdown(for: job, lang: lang)
    }
}

/// The file a viewer was asked to open.
struct MissionArtifactRequest: Identifiable, Equatable, Sendable {
    let jobID: String
    let index: Int
    let name: String
    let type: String

    var id: String { jobID + "#" + String(index) }
}
