import SwiftUI

/// The fifth product: `الاستوديو`.
///
/// Two surfaces, one record. The library is every media fence the account has ever written, the
/// create form is a front end onto the same routes an in-chat request uses, and a creation made
/// here lands in a conversation exactly as a typed «اصنع لي صورة…» would — which is what keeps
/// sharing, reattachment after a relaunch and the completion notification working
/// (`web-media-ux.md §12.2`, `design-brief.md §7.11, §8`).
///
/// iPhone: two tabs. iPad: the grid stays on screen and the form is a trailing inspector, because
/// a studio whose pictures disappear while you describe the next one is not a studio.
@MainActor
struct MediaStudioScreen: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var tab: StudioTab = .library
    @State private var inspectorPresented = true

    init(env: AppEnvironment) {
        self.env = env
    }

    private enum StudioTab: String, Hashable {
        case library
        case create
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isRegular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .background(palette.background.ignoresSafeArea())
        .task(id: env.session.identityID) { await env.media.reload() }
    }

    // MARK: - iPhone

    private var compactLayout: some View {
        studioTabs
            .overlay(alignment: .bottom) { renderingStrip.padding(.bottom, 58) }
    }

    @ViewBuilder
    private var studioTabs: some View {
        if #available(iOS 26.0, *) {
            tabContainer.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabContainer
        }
    }

    private var tabContainer: some View {
        TabView(selection: $tab) {
            NavigationStack {
                libraryPane
            }
            .tabItem { Label(Strings.Media.libraryTab(lang), systemImage: "square.grid.2x2") }
            .tag(StudioTab.library)

            NavigationStack {
                createPane
            }
            .tabItem { Label(Strings.Media.createTab(lang), systemImage: "wand.and.stars") }
            .tag(StudioTab.create)
        }
        .tint(palette.accent)
    }

    // MARK: - iPad

    private var regularLayout: some View {
        NavigationStack {
            libraryPane
                .inspector(isPresented: $inspectorPresented) {
                    MediaCreateForm(env: env)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            inspectorPresented.toggle()
                        } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .accessibilityLabel(Text(Strings.Media.createTab(lang)))
                    }
                }
        }
        .overlay(alignment: .bottom) { renderingStrip.padding(.bottom, 18) }
    }

    // MARK: - Panes

    private var libraryPane: some View {
        MediaLibraryGrid(
            env: env,
            columns: isRegular ? 5 : 3,
            onCreate: {
                if isRegular {
                    inspectorPresented = true
                } else {
                    tab = .create
                }
            }
        )
        .navigationTitle(Text(Strings.Media.title(lang)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var createPane: some View {
        MediaCreateForm(env: env)
            .navigationTitle(Text(Strings.Media.createTab(lang)))
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Still rendering

    /// A quiet floating line while renders are in flight. There is deliberately no cancel: no media
    /// route has one, the render always completes, and the slot is charged either way — offering a
    /// button that does nothing is worse than offering none (`web-media-ux.md §13.7`).
    @ViewBuilder
    private var renderingStrip: some View {
        let live = env.media.liveCreations
        if !live.isEmpty {
            HStack(spacing: 8) {
                LiveDot(palette: palette, motionOn: env.prefs.motionEnabled)
                Text(Strings.Media.stillRendering.fmt(lang, ArabicText.count(live.count, lang)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .firasGlass(.floating, palette: palette)
            .padding(.horizontal, 16)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}
