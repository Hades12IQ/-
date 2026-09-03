import SwiftUI

/// Which sessions the home screen is showing.
enum CodeSessionFilter: String, CaseIterable, Identifiable, Sendable {
    case all, working, fresh

    var id: String { rawValue }

    var title: LText {
        switch self {
        case .all: return Strings.Code.filterAll
        case .working: return Strings.Code.filterWorking
        case .fresh: return Strings.Code.filterNew
        }
    }
}

/// Firas Code's home, rebuilt to the shape the owner sent: a title, a list of sessions where every
/// row says what it is doing and where it lives, one filter control, and a floating pill that
/// starts the next one.
///
/// There is no create form any more. A new session opens empty and asks its question inside the
/// session, which is where the reader is already looking — the old home asked for a name and a
/// brief before it would let anyone in.
struct CodeLauncherView: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var filter: CodeSessionFilter = .all
    @State private var deleteCandidate: ChatSummary?
    @State private var isOpeningNew = false

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var code: CodeStore { env.code }
    private var github: CodeGitHubModel { CodeGitHubModel.shared }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectRow
                header
                filterRow
                sessionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 96)
            .readingColumn(env.prefs.contentWidth)
        }
        .background {
            FirasBackground(palette: palette, showHalo: true).ignoresSafeArea()
        }
        .overlay(alignment: .bottom) { newSessionPill }
        .navigationTitle(Strings.Code.homeTitle(lang))
        .navigationBarTitleDisplayMode(.large)
        .task {
            await code.loadProjects()
            await github.refreshStatus(api: env.api)
        }
        .refreshable {
            await code.loadProjects()
            await github.refreshStatus(api: env.api, force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await github.refreshStatus(api: env.api, force: true) }
        }
        .alert(Strings.Code.deleteSessionConfirm(lang), isPresented: deleteBinding) {
            Button(Strings.Common.cancel(lang), role: .cancel) { deleteCandidate = nil }
            Button(Strings.Common.delete(lang), role: .destructive) {
                let target = deleteCandidate
                deleteCandidate = nil
                guard let target else { return }
                Task { await code.delete(target.id) }
            }
        }
    }

    // MARK: - GitHub

    /// One row, and only while the server says the feature exists and nobody is linked yet.
    @ViewBuilder
    private var connectRow: some View {
        if github.shouldOfferConnect {
            Button {
                Task { await connectGitHub() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(palette.accentSoft) }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.Code.gitHubConnect(lang))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        Text(Strings.Code.gitHubConnectHint(lang))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if github.isStarting {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textMuted)
                            .accessibilityHidden(true)
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .surfaceCard(palette)
            .disabled(github.isStarting)
        }
    }

    // MARK: - Header and filter

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Strings.Code.sessionsHeader(lang))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            if !code.projects.isEmpty {
                Text(verbatim: ArabicText.count(code.projects.count, lang))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CodeSessionFilter.allCases) { option in
                    FirasPill(
                        text: option.title(lang),
                        symbol: nil,
                        selected: filter == option,
                        palette: palette
                    ) {
                        guard filter != option else { return }
                        Haptics.select()
                        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                            filter = option
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 46)
        .accessibilityLabel(Text(Strings.Code.filterLabel(lang)))
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if code.isLoadingProjects, code.projects.isEmpty {
            SkeletonView(kind: .sidebar, palette: palette, motionOn: motionOn)
        } else if let error = code.listError, code.projects.isEmpty {
            EmptyStateView(
                title: error,
                subtitle: nil,
                buttonTitle: Strings.Common.retry(lang),
                palette: palette
            ) {
                Task { await code.loadProjects() }
            }
        } else if code.projects.isEmpty {
            EmptyStateView(
                title: code.deletedLastProject
                    ? Strings.Code.noProjectsLeft(lang)
                    : Strings.Code.sessionsEmptyTitle(lang),
                subtitle: Strings.Code.sessionsEmptyBody(lang),
                buttonTitle: Strings.Code.newSession(lang),
                palette: palette
            ) {
                Task { await startNewSession() }
            }
        } else if visibleSessions.isEmpty {
            EmptyStateView(
                title: Strings.Code.sessionsFilteredEmpty(lang),
                subtitle: nil,
                buttonTitle: Strings.Code.filterAll(lang),
                palette: palette
            ) {
                filter = .all
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(visibleSessions) { summary in
                    sessionRow(summary)
                }
            }
            guestNotice
        }
    }

    private var visibleSessions: [ChatSummary] {
        switch filter {
        case .all:
            return code.projects
        case .working:
            return code.projects.filter { code.isBuilding(projectID: $0.id) }
        case .fresh:
            return code.projects.filter { !code.isBuilding(projectID: $0.id) && isFresh($0) }
        }
    }

    /// "New" means nothing has been built into it yet: no files on record.
    private func isFresh(_ summary: ChatSummary) -> Bool {
        (code.fileCount(for: summary.id) ?? 0) == 0
    }

    private func sessionRow(_ summary: ChatSummary) -> some View {
        let working = code.isBuilding(projectID: summary.id)
        return Button {
            env.router.open(.code(projectID: summary.id))
        } label: {
            HStack(spacing: 12) {
                stateGlyph(working: working)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sessionTitle(summary))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .bidiIsland(for: sessionTitle(summary), fallback: lang)

                    Text(subtitle(for: summary, working: working))
                        .font(.system(size: 12))
                        .foregroundStyle(working ? palette.accent : palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
        .contextMenu {
            Button(role: .destructive) {
                deleteCandidate = summary
            } label: {
                Label(Strings.Common.delete(lang), systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(sessionTitle(summary)))
        .accessibilityValue(Text(subtitle(for: summary, working: working)))
    }

    /// A spinner while the server is building, a quiet dot when it is not — the two states the
    /// owner's shape shows, and nothing in between.
    @ViewBuilder
    private func stateGlyph(working: Bool) -> some View {
        if working {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(palette.accent)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(palette.borderStrong)
                .frame(width: 8, height: 8)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    private func sessionTitle(_ summary: ChatSummary) -> String {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? Strings.Code.sessionFallbackName(lang) : title
    }

    /// `state · owner/repo · branch`, with the file count standing in for the state once a session
    /// has files of its own.
    private func subtitle(for summary: ChatSummary, working: Bool) -> String {
        var parts: [String] = []
        if working {
            parts.append(Strings.Code.stateWorking(lang))
        } else if isFresh(summary) {
            parts.append(Strings.Code.stateNew(lang))
        } else {
            parts.append(Strings.Code.fileCount(code.fileCount(for: summary.id) ?? 0, lang))
        }
        parts.append(github.link(for: summary.id)?.label ?? Strings.Code.repoNone(lang))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var guestNotice: some View {
        if code.isGuest {
            Text(Strings.Code.guestLocalNotice(lang))
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - New session

    private var newSessionPill: some View {
        Button {
            Task { await startNewSession() }
        } label: {
            HStack(spacing: 8) {
                if isOpeningNew || code.isCreating {
                    ProgressView().controlSize(.small).tint(palette.onAccent)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(
                    isOpeningNew || code.isCreating
                        ? Strings.Code.openingSession(lang)
                        : Strings.Code.newSession(lang)
                )
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            }
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .background { Capsule(style: .continuous).fill(palette.accent) }
            .shadow(color: palette.glassShadow, radius: 18, y: 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isOpeningNew || code.isCreating)
        .padding(.bottom, sizeClass == .regular ? 24 : 18)
    }

    private func startNewSession() async {
        guard !isOpeningNew, !code.isCreating else { return }
        isOpeningNew = true
        defer { isOpeningNew = false }
        guard let id = await code.create(name: "", brief: "", attachments: []) else { return }
        Haptics.send()
        env.router.open(.code(projectID: id))
    }

    // MARK: - Actions

    private func connectGitHub() async {
        let opened = await github.connect(api: env.api)
        if opened {
            env.toasts.show(Strings.Code.gitHubReturnHint(lang))
        } else if let failure = github.failure {
            env.toasts.show(failure(lang), isError: true)
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )
    }
}
