import SwiftUI
import UIKit

/// Which pane the phone is showing.
enum CodeWorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case files, code, preview, assistant

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: return "doc.on.doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .preview: return "play.rectangle"
        case .assistant: return "sparkles"
        }
    }

    var title: LText {
        switch self {
        case .files: return Strings.Code.tabFiles
        case .code: return Strings.Code.tabCode
        case .preview: return Strings.Code.tabPreview
        case .assistant: return Strings.Code.tabAssistant
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

/// The IDE shell: four panes on a phone, three columns on an iPad, the build strip on top, and
/// the diff review as an inspector where there is room for it and a sheet where there is not
/// (`design-brief.md §7.9, §8`).
///
/// The shell owns placement and nothing else. The editor, preview, console, command bar and diff
/// review are the panes named in `CodeWorkspacePanes.swift`; the workspace only decides where each
/// one sits, when the preview reloads, and where the console's "fix it with AI" lands.
struct CodeWorkspaceView: View {

    private let env: AppEnvironment
    private let projectID: String

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: CodeWorkspaceTab = .code
    @State private var rightPane: CodeWorkspaceRightPane = .preview
    @State private var railVisible = true
    @State private var previewToken = 0
    @State private var pendingPlan: CodeEditPlan?
    @State private var assistantPrefill = ""
    @State private var shareItem: CodeWorkspaceShareItem?
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
            Button(Strings.Common.done(lang)) {
                let wanted = newFilePath
                newFilePath = ""
                guard !wanted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                code.addFile(path: wanted)
                if !isWide { tab = .code }
            }
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

    // MARK: - Panes

    @ViewBuilder
    private func content(for project: CodeProject?) -> some View {
        if project == nil, code.openError == nil {
            // No project and nothing to report yet: the open is running, or about to.
            loadingState
        } else if project == nil {
            missingState
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

    // MARK: Compact

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

            VStack(spacing: 0) {
                CodeWorkspacePreview(env: env, reloadToken: previewToken)
                Divider().overlay(palette.border)
                consolePane.frame(height: 190)
            }
            .tabItem { Label(Strings.Code.tabPreview(lang), systemImage: CodeWorkspaceTab.preview.symbol) }
            .tag(CodeWorkspaceTab.preview)

            assistantPane
                .tabItem { Label(Strings.Code.tabAssistant(lang), systemImage: CodeWorkspaceTab.assistant.symbol) }
                .tag(CodeWorkspaceTab.assistant)
        }
        .tint(palette.accent)
    }

    // MARK: Wide

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
                assistantPane
            }
        }
    }

    // MARK: Shared panes

    private var consolePane: some View {
        CodeWorkspaceConsole(env: env) { errors in
            assistantPrefill = Strings.Code.fixWithAIPrompt(lang) + "\n" + errors
            if isWide {
                rightPane = .assistant
            } else {
                tab = .assistant
            }
        }
    }

    private var assistantPane: some View {
        CodeWorkspaceAssistant(env: env, prefill: $assistantPrefill) { plan in
            pendingPlan = plan
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
                Label(Strings.Code.home(lang), systemImage: "chevron.backward")
            }
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(code.openProjectName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary)
                    .bidiIsland(for: code.openProjectName, fallback: lang)
                Text(savePillText)
                    .font(.system(size: 11))
                    .foregroundStyle(code.saveState == .saved ? palette.textMuted : palette.accent)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
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

                if isWide {
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
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text(Strings.Code.moreTools(lang)))
            }
        }
    }

    private var savePillText: String {
        switch code.saveState {
        case .saved: return Strings.Code.saved(lang)
        case .editing: return Strings.Code.editing(lang)
        case .saving: return Strings.Code.saving(lang)
        }
    }

    // MARK: - Actions

    private func goHome() {
        code.closeProject()
        env.router.open(.code(projectID: nil))
    }

    private func runPreview() {
        previewToken += 1
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
