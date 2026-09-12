import SwiftUI
import Perception
import UIKit

/// The Firas Agent product: a conversation whose assistant turns are missions.
///
/// The composer is **always** visible — a mission cannot be stopped, so hiding the field while one
/// runs would only trap the user (`audit-ios-agent-code.md A16`). Sending while a mission is live
/// is refused by `AgentStore` with the web's toast, and the draft stays where it was.
struct AgentScreen: View {

    private let env: AppEnvironment
    private let conversationID: String?

    @State private var localConversationID = ""
    @State private var showsCredits = false
    @State private var announcedPhase = ""
    @State private var textSelection = FirasTextSelection()
    @State private var quotedText: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, conversationID: String?) {
        self.env = env
        self.conversationID = conversationID
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var activeID: String { conversationID ?? localConversationID }
    private var conversation: ChatConversation? { env.chat.conversation(activeID) }
    private var mission: AgentJob? { env.agent.missions[activeID] }
    private var blocked: ErrorAction? { env.agent.blocked[activeID] }

    var body: some View {
        return WithPerceptionTracking {
        FirasNavigationStack {
            ZStack {
                FirasBackground(palette: palette, showHalo: conversation?.messages.isEmpty ?? true)
                    .ignoresSafeArea()
                screenBody
            }
            .navigationTitle(Text(navigationTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task(id: conversationID) { await prepare() }
        .environment(\.firasTextSelection, textSelection)
        .firasOnChange(of: textSelection.request) { _, request in
            guard let request else { return }
            quotedText = String(request.text.prefix(8_000))
        }
        .firasOnChange(of: activeID) { _, _ in
            quotedText = nil
        }
        .firasOnChange(of: missionPhaseKey) { _, newValue in
            announce(newValue)
        }
        .sheet(isPresented: $showsCredits) {
            CreditsSheet(env: env)
        }
            }
    }

    private var navigationTitle: String {
        let title = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? ProductKind.agent.title(lang) : title
    }

    // MARK: - Body

    @ViewBuilder
    private var screenBody: some View {
        return WithPerceptionTracking {
        if env.session.isMember {
            memberBody
        } else {
            guestBody
        }
            }
    }

    @ViewBuilder
    private var memberBody: some View {
        return WithPerceptionTracking {
        VStack(spacing: 0) {
            if !env.network.isOnline {
                offlineStrip
            }
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if activeID.isEmpty {
                EmptyView()
            } else {
                AgentComposer(env: env, conversationID: activeID, quotedText: $quotedText)
            }
        }
            }
    }

    private var offlineStrip: some View {
        return WithPerceptionTracking {
        Text(Strings.Errors.offline(lang))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(palette.error)
            .accessibilityAddTraits(.isStaticText)
            }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        return WithPerceptionTracking {
        if isLoading {
            SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if rows.isEmpty && mission == nil && blocked == nil {
            welcome
        } else {
            Group {
                if #available(iOS 18.0, *), !TranscriptScrollCompatibility.forceLegacy {
                    ModernAgentTranscriptScroll(conversationID: activeID, rowCount: rows.count,
                        latestUserID: conversation?.messages.last(where: { $0.role == .user })?.id,
                        palette: palette, lang: lang, motionOn: motionOn, content: transcriptContent)
                } else {
                    LegacyTranscriptScroll(identity: activeID,
                        latestUserID: conversation?.messages.last(where: { $0.role == .user })?.id,
                        motionOn: motionOn) { jump in
                        TranscriptBottomButton(palette: palette, lang: lang, action: jump)
                    } content: { transcriptContent }
                    .contentShape(Rectangle())
                    .dismissesKeyboardOnTap()
                }
            }
        }
            }
    }

    private var transcriptContent: some View {
        return WithPerceptionTracking {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(rows) { row in
                WithPerceptionTracking {
row.view(env: env, conversationID: activeID)
                    .id(row.id)
                    .legacyTranscriptRowAnchor(row.id)

                }}
            liveCard.id("agent-live-card").legacyTranscriptRowAnchor("agent-live-card")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .readingColumn(env.prefs.contentWidth)
            }
    }

    /// The conversation is known to the list but its messages have not arrived yet.
    private var isLoading: Bool {
        guard conversation == nil, !activeID.isEmpty else { return false }
        return env.chat.summaries.contains { $0.id == activeID }
    }

    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    /// History turns. The live mission is appended separately so a snapshot never duplicates the
    /// turn the server already filed under the same `cid`.
    private var rows: [AgentRow] {
        let messages = conversation?.messages ?? []
        return messages.compactMap { message in
            switch message.role {
            case .user:
                let text = message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : AgentRow(id: message.id, kind: .user(text))
            case .assistant:
                let content = message.visibleContent
                if let job = AgentJob.parseFence(content) {
                    // A greeting or a direct answer was never a mission: it renders as an ordinary
                    // assistant bubble here exactly as it does live (`web-agent-ux.md §6.2`).
                    if job.presentation == .conversation, job.phase == .done, !job.final.isEmpty {
                        return AgentRow(id: message.id, kind: .answer(job.final))
                    }
                    return AgentRow(id: message.id, kind: .mission(job))
                }
                let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : AgentRow(id: message.id, kind: .answer(text))
            case .system, .unknown:
                return nil
            }
        }
    }

    /// The live card: shown until the server's own turn for this `cid` appears in history.
    @ViewBuilder
    private var liveCard: some View {
        return WithPerceptionTracking {
        if showsLiveCard {
            if let job = mission, job.presentation == .conversation, job.phase == .done, !job.final.isEmpty {
                MarkdownView(
                    markdown: job.final,
                    messageID: "agent-live-" + job.id,
                    streaming: false,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    onFence: { _ in nil }
                )
            } else {
                MissionCard(
                    env: env,
                    conversationID: activeID,
                    job: mission,
                    blocked: blocked,
                    stopped: env.agent.stoppedConversations.contains(activeID)
                )
            }
        } else if env.agent.starting.contains(activeID) {
            FirasActivityLabel(text: Strings.Agent.missionStarting(lang), palette: palette, motionOn: motionOn)
        }
            }
    }

    private var showsLiveCard: Bool {
        guard mission != nil || blocked != nil else { return false }
        guard let cid = env.agent.missionCID[activeID] else { return true }
        let filed = (conversation?.messages ?? []).contains { $0.role == .assistant && $0.cid == cid }
        return !filed
    }

    // MARK: - Welcome

    private var welcome: some View {
        return WithPerceptionTracking {
        ScrollView {
            VStack(spacing: 18) {
                FirasBrandMark(size: 54, showsWordmark: false, palette: palette)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(Strings.Agent.welcomeTitle(lang))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(Strings.Agent.welcomeBody(lang))
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                templatesStrip
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .readingColumn(env.prefs.contentWidth)
        }
        .contentShape(Rectangle())
        .dismissesKeyboardOnTap()
        .firasScrollDismissesKeyboard(.interactively)
            }
    }

    private var templatesStrip: some View {
        return WithPerceptionTracking {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Agent.templatesTitle(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentTemplate.all) { template in
                        WithPerceptionTracking {
FirasPill(
                            text: template.label(lang),
                            symbol: template.symbol,
                            selected: false,
                            palette: palette
                        ) {
                            Haptics.select()
                            guard !activeID.isEmpty else { return }
                            env.drafts.set(
                                template.task(lang),
                                for: DraftStore.key(conversationID: activeID)
                            )
                        }

                }}
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.top, 8)
            }
    }

    // MARK: - Guest

    private var guestBody: some View {
        return WithPerceptionTracking {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            EmptyStateView(
                title: Strings.Agent.guestTitle(lang),
                subtitle: Strings.Agent.guestBody(lang),
                buttonTitle: Strings.Agent.guestCta(lang),
                palette: palette,
                action: { env.router.showSignUp(feature: .agent) }
            )
            Text(Strings.Agent.tagline(lang))
                .font(.system(size: 14))
                .foregroundStyle(palette.textMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if horizontalSizeClass == .compact {
                Button {
                    Haptics.select()
                    withAnimation(FirasMotion.gated(FirasMotion.drawerFlick, motionOn: motionOn)) {
                        env.router.drawerOpen = true
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .accessibilityLabel(Text(Strings.Agent.openMenu(lang)))
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let credits = env.agent.credits, credits.configured {
                Button {
                    Haptics.select()
                    showsCredits = true
                } label: {
                    AgentCreditsChip(credits: credits, palette: palette, lang: lang)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(creditsAccessibilityLabel(credits)))
                .accessibilityHint(Text(Strings.Agent.creditsChipTitle(lang)))
            }
            Button {
                Haptics.select()
                env.router.newConversation(in: .agent)
            } label: {
                Image(systemName: "square.and.pencil")
                    .accessibilityLabel(Text(Strings.Common.new(lang)))
            }
        }
    }

    private func creditsAccessibilityLabel(_ credits: AgentCredits) -> String {
        let allowance = ArabicText.count(Int(credits.allowance.rounded()), lang)
        if credits.locked {
            return Strings.Agent.creditsChipAriaLocked.fmt(lang, allowance)
        }
        return Strings.Agent.creditsChipAria.fmt(
            lang,
            ArabicText.count(Int(credits.remaining.rounded()), lang),
            allowance,
            ArabicText.count(Int(credits.held.rounded()), lang)
        )
    }

    // MARK: - Lifecycle

    private func prepare() async {
        if let conversationID, !conversationID.isEmpty {
            await env.chat.open(conversationID)
        } else if localConversationID.isEmpty {
            localConversationID = env.chat.newConversation(
                product: .agent,
                flags: (agent: true, codeProj: false, brainNb: false)
            )
        }
        await env.agent.refreshCredits()
    }

    private var missionPhaseKey: String {
        guard let mission else { return blocked == nil ? "" : "blocked" }
        return mission.id + ":" + mission.phase.rawValue
    }

    private func announce(_ key: String) {
        guard key != announcedPhase, !key.isEmpty else { return }
        announcedPhase = key
        let phase: MissionDisplayPhase
        if blocked != nil {
            phase = .blocked
        } else if let mission {
            switch mission.phase {
            case .done: phase = .done
            case .fail: phase = .failed
            case .queued: phase = .queued
            case .run: phase = .running
            }
        } else {
            return
        }
        UIAccessibility.post(notification: .announcement, argument: phase.label(lang))
    }
}
