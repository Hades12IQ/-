import SwiftUI

/// Points one session at one repository and branch.
///
/// Three states, in the order a reader meets them: the server has no GitHub app configured (say so
/// and stop), nobody is linked yet (one button, one sentence), or an account is linked (pick a
/// repository, then a branch). Nothing here writes to the repository — the choice is context the
/// composer shows and the commit endpoint will use.
struct CodeGitHubPickerSheet: View {

    private let env: AppEnvironment
    private let projectID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var pickedRepo: CodeGitHubRepo?
    @State private var showsReturnHint = false

    init(env: AppEnvironment, projectID: String) {
        self.env = env
        self.projectID = projectID
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var github: CodeGitHubModel { CodeGitHubModel.shared }
    private var currentLink: CodeGitHubLink? { github.link(for: projectID) }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.background.ignoresSafeArea())
                .navigationTitle(pickedRepo == nil ? Strings.Code.repoTitle(lang) : Strings.Code.branchTitle(lang))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .firasSheetBackground(palette)
        .task {
            await github.refreshStatus(api: env.api)
            await github.loadRepos(api: env.api)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !github.hasLoadedStatus {
            FirasActivityLabel(
                text: Strings.Code.reposLoading(lang),
                palette: palette,
                motionOn: motionOn
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else if !github.isConfigured {
            EmptyStateView(
                title: Strings.Code.gitHubTitle(lang),
                subtitle: Strings.Code.gitHubUnavailable(lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
        } else if !github.isConnected {
            connectPanel
        } else if let repo = pickedRepo {
            branchList(for: repo)
        } else {
            repoList
        }
    }

    // MARK: - Connect

    private var connectPanel: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                title: Strings.Code.gitHubConnect(lang),
                subtitle: Strings.Code.gitHubConnectHint(lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if github.isStarting {
                        ProgressView().controlSize(.small).tint(palette.onAccent)
                    }
                    Text(github.isStarting ? Strings.Code.gitHubOpening(lang) : Strings.Code.gitHubConnect(lang))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 22)
                .frame(minHeight: 46)
                .background { Capsule(style: .continuous).fill(palette.accent) }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(github.isStarting)

            if showsReturnHint {
                Text(Strings.Code.gitHubReturnHint(lang))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            failureLine
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failure = github.failure {
            Text(failure(lang))
                .font(.system(size: 13))
                .foregroundStyle(palette.error)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Repositories

    private var repoList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                searchField
                detachRow
                failureLine

                if github.isLoadingRepos, github.repos.isEmpty {
                    FirasActivityLabel(
                        text: Strings.Code.reposLoading(lang),
                        palette: palette,
                        motionOn: motionOn
                    )
                    .padding(.top, 8)
                } else if github.repos.isEmpty {
                    Text(Strings.Code.repoEmpty(lang))
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 8)
                } else if filteredRepos.isEmpty {
                    Text(Strings.Code.repoNoMatch(lang))
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 8)
                } else {
                    ForEach(filteredRepos) { repo in
                        repoRow(repo)
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            await github.loadRepos(api: env.api, force: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
            TextField(
                text: $query,
                prompt: Text(verbatim: Strings.Code.repoSearch(lang))
            ) {
                Text(verbatim: Strings.Code.repoSearch(lang))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .foregroundStyle(palette.textPrimary)
            .forceLTR()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.surfaceSunken)
        }
    }

    private var detachRow: some View {
        Button {
            github.setLink(nil, for: projectID)
            Haptics.select()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
                Text(Strings.Code.repoNone(lang))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if currentLink == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
    }

    private func repoRow(_ repo: CodeGitHubRepo) -> some View {
        Button {
            pick(repo)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: repo.fullName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .forceLTR()
                    if repo.isPrivate {
                        Text(Strings.Code.repoPrivate(lang))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textMuted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                    }
                    Spacer(minLength: 0)
                    if currentLink?.repo == repo.fullName {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
                if !repo.summary.isEmpty {
                    Text(verbatim: repo.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                        .bidiIsland(for: repo.summary, fallback: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
    }

    private var filteredRepos: [CodeGitHubRepo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return github.repos }
        return github.repos.filter {
            $0.fullName.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
        }
    }

    // MARK: - Branches

    private func branchList(for repo: CodeGitHubRepo) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(verbatim: repo.fullName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
                    .frame(maxWidth: .infinity, alignment: .leading)

                failureLine

                if github.isLoadingBranches, github.branches.isEmpty {
                    FirasActivityLabel(
                        text: Strings.Code.branchesLoading(lang),
                        palette: palette,
                        motionOn: motionOn
                    )
                } else if branchOptions(for: repo).isEmpty {
                    Text(Strings.Code.branchesEmpty(lang))
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textMuted)
                } else {
                    ForEach(branchOptions(for: repo), id: \.self) { branch in
                        branchRow(repo: repo, branch: branch)
                    }
                }
            }
            .padding(16)
        }
    }

    /// The default branch is always offered, even before the branch list lands, so a reader can
    /// finish the choice on a slow connection.
    private func branchOptions(for repo: CodeGitHubRepo) -> [String] {
        var names = github.branchesRepo == repo.fullName ? github.branches : []
        if names.isEmpty, !repo.defaultBranch.isEmpty { names = [repo.defaultBranch] }
        return names
    }

    private func branchRow(repo: CodeGitHubRepo, branch: String) -> some View {
        Button {
            github.setLink(CodeGitHubLink(repo: repo.fullName, branch: branch), for: projectID)
            Haptics.select()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
                Text(verbatim: branch)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .forceLTR()
                Spacer(minLength: 0)
                if currentLink?.repo == repo.fullName, currentLink?.branch == branch {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if pickedRepo == nil {
                Button(Strings.Common.close(lang)) { dismiss() }
            } else {
                Button {
                    pickedRepo = nil
                } label: {
                    Label(Strings.Common.back(lang), systemImage: "chevron.backward")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if github.isConnected, !github.login.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        Task { await github.disconnect(api: env.api) }
                    } label: {
                        Label(Strings.Code.gitHubDisconnect(lang), systemImage: "link.badge.plus")
                    }
                } label: {
                    Text(verbatim: github.login)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .forceLTR()
                }
            }
        }
    }

    // MARK: - Actions

    private func pick(_ repo: CodeGitHubRepo) {
        pickedRepo = repo
        Haptics.select()
        Task { await github.loadBranches(api: env.api, repo: repo.fullName) }
    }

    private func connect() async {
        let opened = await github.connect(api: env.api)
        showsReturnHint = opened
    }
}
