import SwiftUI
import UIKit

/// Which half of a session the reader is in: the conversation, or the files behind it.
enum CodeWorkspaceSurface: String, Sendable {
    case session, workspace
}

/// Which pane the phone shows once it is inside the workspace half.
enum CodeWorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case files, code, preview, console

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: return "doc.on.doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .preview: return "play.rectangle"
        case .console: return "terminal"
        }
    }

    var title: LText {
        switch self {
        case .files: return Strings.Code.tabFiles
        case .code: return Strings.Code.tabCode
        case .preview: return Strings.Code.tabPreview
        case .console: return Strings.Code.paneConsole
        }
    }
}

/// Which pane the iPad's right column is showing.
enum CodeWorkspaceRightPane: String, CaseIterable, Identifiable, Sendable {
    case preview, console, assistant

    var id: String { rawValue }

    var title: LText {
        switch self {
        case .preview: return Strings.Code.tabPreview
        case .console: return Strings.Code.paneConsole
        case .assistant: return Strings.Code.tabAssistant
        }
    }
}

/// A file the share sheet is about to hand over.
struct CodeWorkspaceShareItem: Identifiable, Equatable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

/// One session, rebuilt to the shape the owner sent: a back chevron, the conversation, and a
/// composer that carries the context (the model, and `owner/repo · branch`) with attach, mic and
/// send.
///
/// The IDE did not go anywhere — it moved one tap away. The toolbar's folder button swaps the
/// conversation for the files: four tabs on a phone, three columns on an iPad. The diff review is
/// still an inspector where there is room and a sheet where there is not.
struct CodeWorkspaceView: View {

    private let env: AppEnvironment
    private let projectID: String

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var surface: CodeWorkspaceSurface = .session
    @State private var tab: CodeWorkspaceTab = .code
    @State private var rightPane: CodeWorkspaceRightPane = .preview
    @State private var railVisible = true
    @State private var previewToken = 0
    @State private var pendingPlan: CodeEditPlan?
    @State private var composerPrefill = ""
    @State private var shareItem: CodeWorkspaceShareItem?
    @State private var showsRepositoryPicker = false
    @State private var showsRepositoryFiles = false
    /// Set by the file browser when it has nothing to browse. Two sheets cannot change places in
    /// the same frame, so the picker is opened from the browser's `onDismiss` instead.
    @State private var wantsRepositoryPicker = false
    @State private var isExporting = false
    @State private var isAddingFile = false
    @State private var newFilePath = ""

    init(env: AppEnvironment, projectID: String) {
        self.env = env
        self.projectID = projectID
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var code: CodeStore { env.code }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var isWide: Bool { sizeClass == .regular }
    private var link: CodeGitHubLink? { CodeGitHubModel.shared.link(for: projectID) }

    var body: some View {
        VStack(spacing: 0) {
            buildStrip
            offlineStrip
            content(for: code.project)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(code.openProjectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: projectID) {
            await code.open(projectID)
        }
        .alert(Strings.Code.newFilePrompt(lang), isPresented: $isAddingFile) {
            TextField(Strings.Code.newFilePrompt(lang), text: $newFilePath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button(Strings.Common.cancel(lang), role: .cancel) { newFilePath = "" }
            Button(Strings.Common.done(lang)) { commitNewFile() }
        }
        .sheet(isPresented: $showsRepositoryPicker) {
            CodeGitHubPickerSheet(env: env, projectID: projectID)
        }
        .sheet(
            isPresented: $showsRepositoryFiles,
            onDismiss: {
                guard wantsRepositoryPicker else { return }
                wantsRepositoryPicker = false
                showsRepositoryPicker = true
            },
            content: {
                CodeRepositoryBrowserSheet(
                    env: env,
                    projectID: projectID,
                    onPickRepository: {
                        wantsRepositoryPicker = true
                        showsRepositoryFiles = false
                    }
                )
            }
        )
        .sheet(item: $shareItem) { item in
            CodeWorkspaceShareSheet(url: item.url)
        }
        .sheet(isPresented: sheetPlanBinding) { diffReview }
        .inspector(isPresented: inspectorPlanBinding) {
            diffReview
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
    }

    // MARK: - Surfaces

    @ViewBuilder
    private func content(for project: CodeProject?) -> some View {
        if project == nil, code.openError == nil {
            loadingState
        } else if project == nil {
            missingState
        } else if surface == .session {
            sessionSurface
        } else if isWide {
            wideLayout
        } else {
            phoneTabs
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            FirasActivityLabel(
                text: Strings.Code.workspaceLoading(lang),
                palette: palette,
                motionOn: motionOn
            )
            SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 40)
    }

    private var missingState: some View {
        EmptyStateView(
            title: code.openError ?? Strings.Code.workspaceMissing(lang),
            subtitle: Strings.Code.workspaceMissingHint(lang),
            buttonTitle: Strings.Code.home(lang),
            palette: palette
        ) {
            goHome()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The conversation and its composer — the default face of a session.
    private var sessionSurface: some View {
        VStack(spacing: 0) {
            CodeSessionThread(env: env)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CodeSessionComposer(
                env: env,
                prefill: $composerPrefill,
                onPlan: { plan in pendingPlan = plan },
                onOpenRepository: { showsRepositoryPicker = true }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Compact workspace

    @ViewBuilder
    private var phoneTabs: some View {
        if #available(iOS 26.0, *) {
            phoneTabsBase.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            phoneTabsBase
        }
    }

    private var phoneTabsBase: some View {
        TabView(selection: $tab) {
            FileNavigator(env: env)
                .tabItem { Label(Strings.Code.tabFiles(lang), systemImage: CodeWorkspaceTab.files.symbol) }
                .tag(CodeWorkspaceTab.files)

            CodeEditorView(env: env)
                .tabItem { Label(Strings.Code.tabCode(lang), systemImage: CodeWorkspaceTab.code.symbol) }
                .tag(CodeWorkspaceTab.code)

            CodeWorkspacePreview(env: env, reloadToken: previewToken)
                .tabItem { Label(Strings.Code.tabPreview(lang), systemImage: CodeWorkspaceTab.preview.symbol) }
                .tag(CodeWorkspaceTab.preview)

            consolePane
                .tabItem { Label(Strings.Code.paneConsole(lang), systemImage: CodeWorkspaceTab.console.symbol) }
                .tag(CodeWorkspaceTab.console)
        }
        .tint(palette.accent)
    }

    // MARK: Wide workspace

    private var wideLayout: some View {
        HStack(spacing: 0) {
            if railVisible {
                FileNavigator(env: env)
                    .frame(width: 220)
                Divider().overlay(palette.border)
            }
            CodeEditorView(env: env)
                .frame(minWidth: 320)
                .layoutPriority(1.1)
            Divider().overlay(palette.border)
            rightColumn
                .frame(minWidth: 300)
                .layoutPriority(1)
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 0) {
            Picker(selection: $rightPane) {
                ForEach(CodeWorkspaceRightPane.allCases) { pane in
                    Text(pane.title(lang)).tag(pane)
                }
            } label: {
                Text(Strings.Code.tabPreview(lang))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider().overlay(palette.border)

            switch rightPane {
            case .preview:
                CodeWorkspacePreview(env: env, reloadToken: previewToken)
            case .console:
                consolePane
            case .assistant:
                CodeWorkspaceAssistant(env: env, prefill: $composerPrefill) { plan in
                    pendingPlan = plan
                }
            }
        }
    }

    private var consolePane: some View {
        CodeWorkspaceConsole(env: env) { errors in
            composerPrefill = Strings.Code.fixWithAIPrompt(lang) + "\n" + errors
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                surface = .session
            }
        }
    }

    @ViewBuilder
    private var diffReview: some View {
        if let plan = pendingPlan {
            CodeWorkspaceDiffReview(env: env, plan: plan) {
                pendingPlan = nil
                previewToken += 1
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Strips

    @ViewBuilder
    private var buildStrip: some View {
        if let phase = code.buildPhase, phase.isLive {
            HStack(spacing: 10) {
                LiveDot(palette: palette, motionOn: motionOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(buildHeadline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(buildSubline)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(ArabicText.timer(Int(code.buildElapsed)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.surfaceSunken)
            .overlay(alignment: .bottom) { Divider().overlay(palette.border) }
        }
    }

    /// The build has no percentage to report — the queue answers `progress: null` for a code build
    /// — so the strip counts the files that have actually landed instead of faking a bar.
    private var buildHeadline: String {
        guard code.buildFileCount > 0 else { return Strings.Code.planningHeadline(lang) }
        return Strings.Code.buildingHeadline(lang) + " · "
            + Strings.Code.fileCount(code.buildFileCount, lang)
    }

    /// The line under the headline said «يُبنى على الخادم» whatever was actually happening — to a
    /// reader watching the files land on this screen, one by one, as the app wrote them. That is
    /// the sentence that made a live build read as work that had been sent away and forgotten.
    /// It is now the truth in both directions: here while it is here, there once it is there.
    private var buildSubline: String {
        code.isBuildingHere(projectID: projectID)
            ? Strings.CodeBuild.hereLine(lang)
            : Strings.Code.serverKeep(lang)
    }

    @ViewBuilder
    private var offlineStrip: some View {
        if code.usingCachedCopy {
            Text(Strings.Code.offlineCopy(lang))
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.surfaceSunken)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                goHome()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel(Text(Strings.Code.home(lang)))
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(code.openProjectName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary)
                    .bidiIsland(for: code.openProjectName, fallback: lang)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(code.saveState == .saved ? palette.textMuted : palette.accent)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleSurface()
            } label: {
                Image(systemName: surface == .session ? "folder" : "text.bubble")
            }
            .accessibilityLabel(
                Text(
                    surface == .session
                        ? Strings.Code.workspaceOpen(lang)
                        : Strings.Code.workspaceBack(lang)
                )
            )
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                toolsMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text(Strings.Code.moreTools(lang)))
            }
        }
    }

    @ViewBuilder
    private var toolsMenu: some View {
        Button {
            runPreview()
        } label: {
            Label(Strings.Code.run(lang), systemImage: "play.fill")
        }
        .keyboardShortcut("r", modifiers: .command)

        Button {
            Task { await code.save() }
        } label: {
            Label(Strings.Common.save(lang), systemImage: "tray.and.arrow.down")
        }
        .keyboardShortcut("s", modifiers: .command)

        Button {
            newFilePath = ""
            isAddingFile = true
        } label: {
            Label(Strings.Code.newFile(lang), systemImage: "doc.badge.plus")
        }

        Button {
            showsRepositoryPicker = true
        } label: {
            Label(Strings.Code.repoTitle(lang), systemImage: "arrow.triangle.branch")
        }

        Button {
            showsRepositoryFiles = true
        } label: {
            Label(Strings.CodeRepo.filesTitle(lang), systemImage: "doc.text.magnifyingglass")
        }

        if isWide, surface == .workspace {
            Button {
                withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                    railVisible.toggle()
                }
            } label: {
                Label(
                    railVisible ? Strings.Code.collapseRail(lang) : Strings.Code.expandRail(lang),
                    systemImage: "sidebar.leading"
                )
            }
        }

        Divider()

        Button {
            openInSafari()
        } label: {
            Label(Strings.Code.openInSafari(lang), systemImage: "safari")
        }

        Button {
            Task { await shareProject() }
        } label: {
            Label(Strings.Code.share(lang), systemImage: "square.and.arrow.up")
        }

        Button {
            Task { await exportZip() }
        } label: {
            Label(Strings.Code.zip(lang), systemImage: "doc.zipper")
        }
        .disabled(isExporting)
    }

    /// The repository when there is one — it is the context the owner wants visible — and the save
    /// state when there is not.
    private var subtitleText: String {
        if let link { return link.label }
        switch code.saveState {
        case .saved: return Strings.Code.saved(lang)
        case .editing: return Strings.Code.editing(lang)
        case .saving: return Strings.Code.saving(lang)
        }
    }

    // MARK: - Actions

    private func toggleSurface() {
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            surface = surface == .session ? .workspace : .session
        }
    }

    private func commitNewFile() {
        let wanted = newFilePath
        newFilePath = ""
        guard !wanted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        code.addFile(path: wanted)
        surface = .workspace
        if !isWide { tab = .code }
    }

    private func goHome() {
        code.closeProject()
        env.router.open(.code(projectID: nil))
    }

    private func runPreview() {
        previewToken += 1
        surface = .workspace
        if isWide {
            rightPane = .preview
        } else {
            tab = .preview
        }
    }

    /// Safari gets a fully inlined copy: the live preview serves its files through a custom
    /// scheme, and nothing outside the app can read that.
    private func openInSafari() {
        guard let project = code.project,
              let html = CodeExport.previewDocument(for: project, entryPath: code.selectedPath) else {
            env.toasts.show(Strings.Code.addIndexFirst(lang), isError: true)
            return
        }
        do {
            let url = try CodeExport.writeTemporaryDocument(html, name: code.openProjectName)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } catch {
            env.toasts.show(Strings.Code.openInSafariFailed(lang), isError: true)
        }
    }

    private func shareProject() async {
        guard let url = await code.share() else { return }
        UIPasteboard.general.string = url.absoluteString
        shareItem = CodeWorkspaceShareItem(url: url)
    }

    private func exportZip() async {
        guard !isExporting else { return }
        isExporting = true
        env.toasts.show(Strings.Code.exporting(lang))
        let url = await code.exportZip()
        isExporting = false
        guard let url else { return }
        shareItem = CodeWorkspaceShareItem(url: url)
    }

    // MARK: - Bindings

    private var sheetPlanBinding: Binding<Bool> {
        Binding(
            get: { pendingPlan != nil && !isWide },
            set: { if !$0 { pendingPlan = nil } }
        )
    }

    private var inspectorPlanBinding: Binding<Bool> {
        Binding(
            get: { pendingPlan != nil && isWide },
            set: { if !$0 { pendingPlan = nil } }
        )
    }
}

/// One file of the connected repository, read and held for as long as it is on screen.
struct CodeRepositoryFileDraft: Identifiable, Hashable, Sendable {
    let path: String
    let content: String
    /// The blob was longer than `CodeProject.maximumFileCharacters`, and `content` is its head.
    let truncated: Bool

    var id: String { path }
}

/// The repository, browsable.
///
/// The GitHub half of Firas Code could link an account and point a session at `owner/repo · branch`
/// and then stopped — the two endpoints that make a repository real, `/api/github/tree` and
/// `/api/github/file`, had no caller at all. So the reader could see a repository named in the
/// composer's pill and never see a single file in it, which is the other half of «ولا يفحص
/// الرسبايرتوري».
///
/// This is the reading half: the branch's whole file list, a search over it, one file at a time,
/// and — because a file worth reading is usually a file worth working on — a way to copy one into
/// the project. The writing half already exists on the server (`POST /api/github/commit`) and is
/// not wired here; nothing in this sheet can change a repository.
struct CodeRepositoryBrowserSheet: View {

    private let env: AppEnvironment
    private let projectID: String
    private let onPickRepository: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var opened: CodeRepositoryFileDraft?
    /// The path currently being read, so its row spins instead of the whole list.
    @State private var reading = ""
    @State private var failure: String?
    /// False until the first `load` has been all the way through. Nothing else distinguishes «the
    /// status call has not come back yet» from «this branch has no files in it».
    @State private var settled = false

    init(env: AppEnvironment, projectID: String, onPickRepository: @escaping () -> Void) {
        self.env = env
        self.projectID = projectID
        self.onPickRepository = onPickRepository
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var github: CodeGitHubModel { CodeGitHubModel.shared }
    private var link: CodeGitHubLink? { github.link(for: projectID) }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.background.ignoresSafeArea())
                .navigationTitle(Strings.CodeRepo.filesTitle(lang))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(Strings.Common.close(lang)) { dismiss() }
                    }
                }
                .navigationDestination(item: $opened) { file in
                    fileDetail(file)
                }
        }
        .firasSheetBackground(palette)
        .task { await load(force: false) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if link == nil {
            EmptyStateView(
                title: Strings.CodeRepo.notLinkedTitle(lang),
                subtitle: Strings.CodeRepo.notLinkedBody(lang),
                buttonTitle: Strings.CodeRepo.pickRepository(lang),
                palette: palette,
                action: onPickRepository
            )
        } else if isLoading {
            FirasActivityLabel(
                text: Strings.CodeRepo.filesLoading(lang),
                palette: palette,
                motionOn: motionOn
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else if !github.isConnected {
            // A repository choice outlives the account that could read it: the link is kept on this
            // device, the token on the server, and unlinking leaves the first without the second.
            // «لا ملفات في هذا الفرع» there would blame the branch for a missing account.
            EmptyStateView(
                title: Strings.Code.gitHubConnect(lang),
                subtitle: Strings.Code.gitHubConnectHint(lang),
                buttonTitle: Strings.CodeRepo.pickRepository(lang),
                palette: palette,
                action: onPickRepository
            )
        } else {
            fileList
        }
    }

    /// The list is worth drawing only once the tree in the model is *this* branch's tree.
    ///
    /// `load` calls the status endpoint before the tree endpoint, and for the whole of that first
    /// round trip nothing is loading and nothing has arrived — which is exactly the shape of an
    /// empty branch, and is what the sheet used to open on. A tree already cached for this very
    /// branch counts as arrived: it is what `loadTree` is about to hand back anyway.
    private var isLoading: Bool {
        if github.isLoadingTree, entries.isEmpty { return true }
        return !settled && !treeMatchesLink
    }

    /// The model holds one tree, belonging to whichever branch was asked for last — a build reading
    /// the repository for a question can be that asker as easily as this sheet.
    private var treeMatchesLink: Bool {
        guard let link else { return false }
        return github.treeKey == CodeGitHubModel.refKey(repo: link.repo, ref: link.branch)
    }

    /// The model's tree, but only while it is this session's. Anything else is another branch's
    /// file list, and a row of it would send this branch a path it has never had.
    private var entries: [CodeGitHubTreeEntry] {
        treeMatchesLink ? github.tree : []
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                repositoryLine
                searchField
                failureLine

                if entries.isEmpty {
                    quietLine(Strings.CodeRepo.filesEmpty(lang))
                } else if visible.isEmpty {
                    quietLine(Strings.CodeRepo.filesNoMatch(lang))
                } else {
                    ForEach(visible) { entry in
                        fileRow(entry)
                    }
                    if github.treeTruncated {
                        quietLine(Strings.CodeRepo.filesTruncated(lang))
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await load(force: true) }
    }

    private var repositoryLine: some View {
        Text(verbatim: link?.label ?? "")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .forceLTR()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
            TextField(
                text: $query,
                prompt: Text(verbatim: Strings.CodeRepo.filesSearch(lang))
            ) {
                Text(verbatim: Strings.CodeRepo.filesSearch(lang))
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

    /// This sheet's own failure first — a file that would not open is about the row the reader just
    /// tapped — and the model's behind it. Without the second, a tree that never arrived is
    /// reported to the reader as a branch with no files in it.
    private var failureText: String? {
        if let failure { return failure }
        guard let carried = github.failure else { return nil }
        return carried(lang)
    }

    @ViewBuilder
    private var failureLine: some View {
        if let message = failureText {
            Text(verbatim: message)
                .font(.system(size: 13))
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quietLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 14))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(_ entry: CodeGitHubTreeEntry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .forceLTR()
                    Text(verbatim: entry.path)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .forceLTR()
                }

                Spacer(minLength: 0)

                if reading == entry.path {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.accent)
                        .accessibilityLabel(Text(verbatim: Strings.CodeRepo.fileOpening(lang)))
                } else {
                    Text(verbatim: sizeLabel(entry.size))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
        .accessibilityLabel(Text(verbatim: entry.path))
    }

    /// Read-only, monospaced, and selectable. Nothing here writes to the repository.
    private func fileDetail(_ file: CodeRepositoryFileDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: file.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .forceLTR()

                // A viewer that stops at the ceiling and says nothing shows the reader the head of
                // a file and lets them believe they scrolled to its end.
                if file.truncated {
                    Text(
                        verbatim: Strings.CodeRepo.fileTruncated.fmt(
                            lang,
                            ArabicText.count(CodeProject.maximumFileCharacters, lang)
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(file.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard env.code.importFile(path: file.path, content: file.content) else { return }
                    opened = nil
                    dismiss()
                } label: {
                    Label(Strings.CodeRepo.fileImport(lang), systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    // MARK: - Data

    private var visible: [CodeGitHubTreeEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.path.lowercased().contains(needle) }
    }

    /// Empty for an entry GitHub did not size, which arrives as zero: rounding that up to «١ ك.ب»
    /// puts a number on the row that the reader can check and find wrong.
    private func sizeLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let kilobytes = max(1, Int((Double(bytes) / 1024).rounded()))
        return Strings.CodeRepo.fileSize.fmt(lang, ArabicText.count(kilobytes, lang))
    }

    private func load(force: Bool) async {
        guard let link else { return }
        await github.refreshStatus(api: env.api)
        await github.loadTree(api: env.api, repo: link.repo, ref: link.branch, force: force)
        settled = true
    }

    /// One read at a time. Tapping a second row while the first is still in flight would leave two
    /// answers racing for the same destination, and the loser would win by arriving last.
    private func open(_ entry: CodeGitHubTreeEntry) {
        guard let link, reading.isEmpty else { return }
        reading = entry.path
        failure = nil
        Haptics.select()
        Task {
            let body = await github.readFile(
                api: env.api,
                repo: link.repo,
                ref: link.branch,
                path: entry.path
            )
            reading = ""
            guard let body else {
                failure = Strings.CodeRepo.fileFailed(lang)
                return
            }
            let head = String(body.prefix(CodeProject.maximumFileCharacters))
            opened = CodeRepositoryFileDraft(
                path: entry.path,
                content: head,
                truncated: head.count < body.count
            )
        }
    }
}

/// `UIActivityViewController` for the ZIP and the share link. SwiftUI's `ShareLink` needs its item
/// at build time; both of these are produced by an async call, so the sheet carries them.
struct CodeWorkspaceShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
