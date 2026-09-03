import SwiftUI

/// The signed-in root: one product on screen, the sidebar beside it or over it, and every sheet
/// and cover in the app presented from exactly one place (`ARCHITECTURE.md §2.8`,
/// `design-brief.md §1, §8`).
///
/// The shell is fixed left-to-right — the web's `applyShellLang` rule — and this is the only site
/// that sets `layoutDirection`. Message bodies, titles and card text become bidirectional islands
/// through `bidiIsland(for:fallback:)` further down.
///
/// Compact is a drawer that **pushes** the conversation aside; regular is a `NavigationSplitView`
/// with a persistent sidebar. A Stage Manager window narrow enough to matter already reports
/// `.compact`, so the size class is the whole rule.
///
/// The shell supplies the navigation container for the screens that do not own one — `ChatScreen`,
/// `BrainScreen` and the Code pair. `AgentScreen` and `MediaStudioScreen` already carry their own,
/// so they are placed bare (`INTERFACES.md` open item 4).
@MainActor
struct AppShell: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var isCompact: Bool { horizontalSizeClass != .regular }

    var body: some View {
        @Bindable var router = env.router

        return ZStack {
            palette.background.ignoresSafeArea()
            layout(drawerOpen: $router.drawerOpen)
            ToastHostView(env: env)
            KeyboardCommands(env: env)
        }
        .environment(\.layoutDirection, .leftToRight)
        .tint(palette.accent)
        .preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
        .sheet(item: $router.sheet) { sheet in
            sheetView(sheet)
        }
        .fullScreenCover(item: $router.cover) { cover in
            coverView(cover)
        }
        .onAppear { consumePendingRoute() }
        .onChange(of: env.router.pendingRoute) { _, _ in consumePendingRoute() }
    }

    // MARK: - Layout

    /// The compact stack is deliberately only two children deep. Everything about the push —
    /// how far, how fast, when it is grabbable — belongs to `DrawerMotion`, which the drawer owns
    /// and this layer only reads. Neither `AppShell.body` nor the product screen re-evaluates
    /// while a finger is on the drawer: only `DrawerPushLayer` observes the travel.
    @ViewBuilder
    private func layout(drawerOpen: Binding<Bool>) -> some View {
        if isCompact {
            ZStack {
                DrawerPushLayer(motion: DrawerMotion.shared) { detail }
                CompactDrawer(env: env, isOpen: drawerOpen)
            }
        } else {
            splitLayout
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(env: env)
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } detail: {
            extendedBackground(detail)
        }
        .navigationSplitViewStyle(.balanced)
        /* `⌘⇧O` — and anything else that asks for the panel — speaks `drawerOpen`, which only the
           compact drawer draws. On a split view the column is `columnVisibility`, so the request is
           consumed here and turned into a column toggle. Clearing the flag on the way through is
           what keeps `Router.select` / `switchTo` / `newConversation`, all of which set
           `drawerOpen = false` on every navigation, from collapsing the iPad sidebar. */
        .onChange(of: env.router.drawerOpen) { _, open in
            guard open else { return }
            env.router.drawerOpen = false
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    /// On iOS 26 the sidebar floats as glass; the conversation is asked to continue underneath it
    /// so the column edge is not a seam.
    @ViewBuilder
    private func extendedBackground<C: View>(_ content: C) -> some View {
        if #available(iOS 26.0, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch env.router.product {
        case .ai:
            NavigationStack {
                ChatScreen(
                    env: env,
                    conversationID: env.router.selectedConversationID,
                    product: .ai
                )
            }
        case .agent:
            // `AgentScreen` owns its own `NavigationStack` (it presents the credits sheet from
            // inside it); a second container here would draw a second navigation bar.
            AgentScreen(env: env, conversationID: env.router.selectedConversationID)
        case .code:
            NavigationStack { codeDetail }
        case .brain:
            NavigationStack {
                BrainScreen(env: env, conversationID: env.router.selectedConversationID)
                    .toolbar { drawerToolbarItem }
            }
        case .studio:
            studioDetail
        }
    }

    /// A project is open when the router holds its id; otherwise the launcher lists them.
    /// `CodeWorkspaceView` already puts its own «الرئيسية» chevron in the leading slot, so only the
    /// launcher gets the drawer button.
    @ViewBuilder
    private var codeDetail: some View {
        if let projectID = env.router.selectedConversationID, !projectID.isEmpty {
            CodeWorkspaceView(env: env, projectID: projectID)
        } else {
            CodeLauncherView(env: env)
                .toolbar { drawerToolbarItem }
        }
    }

    /// The Studio owns its own `TabView` and its own navigation stacks, so it is not wrapped in a
    /// third one; on iPhone it gets a floating drawer button in the empty leading slot instead of a
    /// toolbar item there is no toolbar to hold.
    @ViewBuilder
    private var studioDetail: some View {
        if isCompact {
            MediaStudioScreen(env: env)
                .overlay(alignment: .topLeading) {
                    drawerButton
                        .padding(.leading, 10)
                        .padding(.top, 2)
                }
        } else {
            MediaStudioScreen(env: env)
        }
    }

    // MARK: - Drawer affordance

    @ToolbarContentBuilder
    private var drawerToolbarItem: some ToolbarContent {
        if isCompact {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    openDrawer()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .accessibilityLabel(Text(Strings.Shell.openSidebar(lang)))
            }
        }
    }

    private var drawerButton: some View {
        Button {
            openDrawer()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
        .accessibilityLabel(Text(Strings.Shell.openSidebar(lang)))
    }

    /// No `withAnimation` here any more: the drawer watches `drawerOpen` and animates its own
    /// travel, so every entry point — this button, `⌘⇧O`, a notification route, `Router.select` —
    /// moves the panel and the conversation on the same spring whether or not the caller thought
    /// to ask for one.
    private func openDrawer() {
        Haptics.select()
        env.router.drawerOpen = true
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .settings(let section):
            SettingsView(env: env, section: section)
        case .tierPicker:
            TierPickerSheet(env: env)
        case .addContext:
            AddContextSheet(env: env)
        case .announcements:
            AnnouncementsSheet(env: env)
        case .share(let conversationID, let messageCID):
            ShareSheetView(env: env, conversationID: conversationID, messageCID: messageCID)
        case .signUpPrompt(let feature):
            SignUpPromptSheet(env: env, feature: feature)
        case .dialectPicker:
            DialectPickerSheet(env: env)
        case .memory:
            pushedSheet { MemorySettingsView(env: env) }
        case .longFile(let jobID):
            LongFileViewer(env: env, jobID: jobID)
        case .codeViewer(let messageID):
            CodeViewerSheet(env: env, messageID: messageID)
        case .notificationExplainer:
            pushedSheet { NotificationSettingsView(env: env) }
        case .allChats:
            AllChatsView(env: env)
        }
    }

    /// The two Settings pages that are reached as their own sheets are written as pushed pages:
    /// they carry a `navigationTitle` and nothing else, so the shell supplies the container and the
    /// one way out.
    private func pushedSheet<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            env.router.sheet = nil
                        } label: {
                            Text(Strings.Common.done(lang))
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .firasSheetBackground(palette)
        .tint(palette.accent)
        .preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
    }

    // MARK: - Covers

    @ViewBuilder
    private func coverView(_ cover: AppCover) -> some View {
        switch cover {
        case .auth(let mode):
            AuthView(env: env, mode: mode)
        case .call:
            CallScreen(env: env)
        case .mediaViewer(let creationID):
            MediaViewer(env: env, creationID: creationID)
        case .artifact(let url):
            artifactCover(url)
        }
    }

    /// `AppCover.artifact` carries the endpoint the fence wrote. `ArtifactViewer` fetches by job and
    /// index, so the query is read back out; anything else is an honest dead end with a way out
    /// rather than a blank screen.
    @ViewBuilder
    private func artifactCover(_ raw: String) -> some View {
        if let request = Self.artifactRequest(from: raw) {
            ArtifactViewer(
                env: env,
                jobID: request.jobID,
                index: request.index,
                name: request.name,
                type: request.type
            )
        } else {
            NavigationStack {
                EmptyStateView(
                    title: Strings.Shell.artifactUnavailable.text(lang),
                    subtitle: nil,
                    buttonTitle: Strings.Common.close(lang),
                    palette: palette
                ) {
                    env.router.cover = nil
                }
                .frame(maxHeight: .infinity)
                .background(palette.background.ignoresSafeArea())
            }
        }
    }

    private static func artifactRequest(
        from raw: String
    ) -> (jobID: String, index: Int, name: String, type: String)? {
        guard let components = URLComponents(string: raw) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let jobID = value("id"), !jobID.isEmpty else { return nil }
        let index = value("index").flatMap { Int($0) } ?? 0
        return (jobID, index, value("name") ?? "", value("type") ?? "")
    }

    // MARK: - Routes

    /// Consumed once. `.verify` and `.reset` are the exception: `AuthView` reads the payload out of
    /// `pendingRoute` itself, so the shell only opens the door and leaves the note on the table.
    private func consumePendingRoute() {
        guard let route = env.router.pendingRoute else { return }
        env.router.open(route)
        switch route {
        case .verify, .reset:
            return
        default:
            env.router.pendingRoute = nil
        }
    }
}

// MARK: - The pushed conversation

/// The conversation, translated by exactly as much as the drawer has travelled.
///
/// This is the whole of the owner's «يدفع المحادثة يمين و يطلع بنفس الوقت»: the panel's right edge
/// is at `panelOffset + panelWidth` and the conversation's left edge is at `contentPush`, which is
/// the same number. They cannot drift apart, in flight or at rest, because there is only one
/// number.
///
/// It is a separate view for one reason: `DrawerMotion.openness` changes on every frame of a drag,
/// and only this ten-line body may re-evaluate that often. `content` is already built by the time
/// it gets here, so the product screen underneath is not asked to lay itself out again.
///
/// No shadow and no scale: both force an off-screen render of the entire conversation on every
/// frame, and the drawer's own edge shadow already reads the seam.
@MainActor
private struct DrawerPushLayer<Content: View>: View {

    private let motion: DrawerMotion
    private let content: Content

    /// Spelled out rather than left to the memberwise initialiser: the builder has to be on the
    /// parameter, and a synthesised one is a detail of the language this file should not depend on.
    init(motion: DrawerMotion, @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.content = content()
    }

    var body: some View {
        content
            .offset(x: motion.contentPush)
            /* The scrim above already swallows taps, but the part of the conversation that has been
               pushed past the screen edge must not answer a touch either. */
            .allowsHitTesting(!motion.isEngaged)
    }
}
