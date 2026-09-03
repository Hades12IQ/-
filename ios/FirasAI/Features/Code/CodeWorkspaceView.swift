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
                    Text(Strings.Code.serverKeep(lang))
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

/// `UIActivityViewController` for the ZIP and the share link. SwiftUI's `ShareLink` needs its item
/// at build time; both of these are produced by an async call, so the sheet carries them.
struct CodeWorkspaceShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
